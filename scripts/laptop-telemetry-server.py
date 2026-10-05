#!/usr/bin/env python3
"""
Laptop Telemetry — On-Demand Dashboard Server
ASUS Zephyrus G16 (AMD Ryzen + Radeon iGPU + NVIDIA RTX 4060 dGPU)

Started ON DEMAND (via `show-telemetry`).
- Serves the 3-tab Web UI (Live Telemetry, Trends & Analytics, Log Viewer).
- SSE streaming: pulls latest snapshot from /run/telemetry/latest.json (with fallback).
- Trends API: queries /var/log/telemetry/telemetry.db for aggregated history.
- Log Viewer API: discovers, filters, paginates, and downloads CSV logs.
"""

import asyncio
import csv
import glob
import json
import os
import sqlite3
import time
from datetime import datetime, timedelta
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse
from starlette.responses import StreamingResponse

# ── Configuration ────────────────────────────────────────────────
HOST = os.getenv("TELEMETRY_HOST", "127.0.0.1")
PORT = int(os.getenv("TELEMETRY_PORT", "9999"))
STREAM_INTERVAL = float(os.getenv("TELEMETRY_STREAM_INTERVAL", "1.5"))

HTML_PATH = Path(os.getenv(
    "TELEMETRY_HTML_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html"),
))

LATEST_JSON = Path(os.getenv("TELEMETRY_RUN_DIR", "/run/telemetry")) / "latest.json"
DB_PATH = Path(os.getenv("TELEMETRY_LOG_DIR", "/var/log/telemetry")) / "telemetry.db"
LOG_DIRS = [
    Path(os.getenv("TELEMETRY_LOG_DIR", "/var/log/telemetry")),
    Path(os.getenv("TELEMETRY_USER_LOG_DIR", "/home/steve/.local/share/telemetry")),
]

# Mirrors the logger's TELEMETRY_HIGH_POWER_W so the log-viewer filters and the
# Power_Flag column always agree on what "high power" means.
HIGH_POWER_W = float(os.getenv("TELEMETRY_HIGH_POWER_W", "20.0"))
# Above this a reading is treated as a sensor/timing artefact (see logger).
MAX_PLAUSIBLE_W = float(os.getenv("TELEMETRY_MAX_PLAUSIBLE_W", "400.0"))

app = FastAPI(title="Laptop Telemetry Server", docs_url=None, redoc_url=None)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Live State Retrieval ─────────────────────────────────────────
def _get_live_data() -> dict:
    """Read latest.json written by the 24/7 logger daemon, or fallback."""
    if LATEST_JSON.exists():
        try:
            with open(LATEST_JSON) as f:
                data = json.load(f)
            # Check staleness: if younger than 30s, use it
            mtime = LATEST_JSON.stat().st_mtime
            data["_logger_active"] = (time.time() - mtime) < 15.0
            # Backfill for a logger build that predates the high-power fields.
            data.setdefault("high_power", {
                "is_high": (data.get("system_power_w") or 0) >= HIGH_POWER_W,
                "threshold_w": HIGH_POWER_W,
                "streak_samples": 0,
                "processes": [],
            })
            return data
        except Exception:
            pass

    # Fallback if logger is not yet running or file is missing
    return {
        "timestamp": datetime.now().isoformat(),
        "epoch": int(time.time()),
        "hostname": os.uname().nodename,
        "kernel": os.uname().release,
        "uptime": "Unknown",
        "_logger_active": False,
        "cpu": {"temp_c": None, "power_w": None, "usage_pct": 0, "per_core_pct": [], "load_avg": [0,0,0]},
        "igpu": {"temp_c": None, "power_w": None},
        "dgpu": {"state": "Suspended", "temp_c": None, "power_w": None, "util_pct": None},
        "ram": {"used_mb": 0, "total_mb": 1, "percent": 0},
        "swap": {"used_mb": 0, "total_mb": 1, "percent": 0},
        "battery": {"percent": 0, "state": "Unknown", "power_w": None, "time_left": None},
        "system_power_w": None,
        "fans": {},
        "top_processes": [],
        "high_power": {"is_high": False, "threshold_w": HIGH_POWER_W, "streak_samples": 0, "processes": []},
        "network": {"sent_rate_kbps": 0, "recv_rate_kbps": 0, "total_sent_mb": 0, "total_recv_mb": 0},
        "disk": {"read_rate_mbps": 0, "write_rate_mbps": 0, "usage_percent": 0, "used_gb": 0, "total_gb": 0},
    }


# ── Web UI ───────────────────────────────────────────────────────
@app.get("/")
async def serve_index():
    if HTML_PATH.exists():
        return FileResponse(HTML_PATH, media_type="text/html")
    return HTMLResponse("<h1>index.html not found</h1>", status_code=404)


# ── Real-Time Streaming (SSE) ────────────────────────────────────
@app.get("/api/snapshot")
async def get_snapshot():
    return _get_live_data()


@app.get("/api/stream")
async def get_stream():
    async def _event_generator():
        while True:
            data = _get_live_data()
            yield f"data: {json.dumps(data)}\n\n"
            await asyncio.sleep(STREAM_INTERVAL)

    return StreamingResponse(
        _event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# ── Trends & Historical Analytics ────────────────────────────────
@app.get("/api/trends")
async def get_trends(range: str = "24h"):
    """
    Returns time series downsampled points and summary statistics.
    Supported ranges: 1h, 6h, 24h, 7d, 30d
    """
    range_seconds = {
        "1h": 3600,
        "6h": 6 * 3600,
        "24h": 24 * 3600,
        "7d": 7 * 86400,
        "30d": 30 * 86400,
    }.get(str(range).lower(), 24 * 3600)

    now_epoch = int(time.time())
    start_epoch = now_epoch - range_seconds

    # Target ~120-180 points for optimal chart rendering
    target_points = 150
    bucket_size = max(int(range_seconds / target_points), 5)

    if not DB_PATH.exists():
        # Fallback: try parsing legacy/daily CSV if DB not ready
        return _trends_from_csv(start_epoch, now_epoch, bucket_size)

    try:
        conn = sqlite3.connect(DB_PATH, timeout=5)
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()

        # Overall summary stats
        cur.execute("""
            SELECT
                COUNT(*) as count,
                AVG(system_power_w) as avg_power_w,
                MAX(system_power_w) as max_power_w,
                MIN(CASE WHEN system_power_w > 0 THEN system_power_w ELSE NULL END) as min_power_w,
                AVG(CASE WHEN cpu_temp_c > 0 THEN cpu_temp_c ELSE NULL END) as avg_cpu_temp,
                MAX(cpu_temp_c) as max_cpu_temp,
                AVG(CASE WHEN igpu_temp_c > 0 THEN igpu_temp_c ELSE NULL END) as avg_igpu_temp,
                MAX(igpu_temp_c) as max_igpu_temp,
                AVG(CASE WHEN dgpu_temp_c > 0 THEN dgpu_temp_c ELSE NULL END) as avg_dgpu_temp,
                MAX(dgpu_temp_c) as max_dgpu_temp,
                AVG(cpu_usage_pct) as avg_cpu_usage,
                AVG(battery_pct) as avg_battery_pct,
                SUM(CASE WHEN dgpu_state = 'Active' THEN 1 ELSE 0 END) as dgpu_active_count,
                SUM(CASE WHEN dgpu_state = 'Suspended' THEN 1 ELSE 0 END) as dgpu_suspended_count,
                SUM(CASE WHEN battery_state = 'Battery' OR battery_state = 'Discharging' THEN 1 ELSE 0 END) as on_battery_count,
                SUM(CASE WHEN system_power_w >= ? THEN 1 ELSE 0 END) as high_power_count
            FROM telemetry
            WHERE timestamp >= ?
        """, (HIGH_POWER_W, start_epoch))
        summary_row = cur.fetchone()

        total_samples = summary_row["count"] or 0
        dgpu_active_pct = 0.0
        if total_samples > 0:
            dgpu_active_pct = round(((summary_row["dgpu_active_count"] or 0) / total_samples) * 100, 1)
        high_power_count = summary_row["high_power_count"] or 0

        summary = {
            "sample_count": total_samples,
            "avg_power_w": round(summary_row["avg_power_w"] or 0.0, 1),
            "max_power_w": round(summary_row["max_power_w"] or 0.0, 1),
            "min_power_w": round(summary_row["min_power_w"] or 0.0, 1),
            "avg_cpu_temp": round(summary_row["avg_cpu_temp"] or 0.0, 1),
            "max_cpu_temp": round(summary_row["max_cpu_temp"] or 0.0, 1),
            "avg_igpu_temp": round(summary_row["avg_igpu_temp"], 1) if summary_row["avg_igpu_temp"] is not None else None,
            "max_igpu_temp": round(summary_row["max_igpu_temp"], 1) if summary_row["max_igpu_temp"] is not None else None,
            "avg_dgpu_temp": round(summary_row["avg_dgpu_temp"], 1) if summary_row["avg_dgpu_temp"] is not None else None,
            "max_dgpu_temp": round(summary_row["max_dgpu_temp"], 1) if summary_row["max_dgpu_temp"] is not None else None,
            "avg_cpu_usage": round(summary_row["avg_cpu_usage"] or 0.0, 1),
            "dgpu_active_pct": dgpu_active_pct,
            "dgpu_suspended_pct": round(100.0 - dgpu_active_pct, 1),
            "on_battery_pct": round(((summary_row["on_battery_count"] or 0) / total_samples) * 100, 1) if total_samples else 0.0,
            "high_power_w": HIGH_POWER_W,
            "high_power_count": high_power_count,
            "high_power_pct": round((high_power_count / total_samples) * 100, 1) if total_samples else 0.0,
        }


        # Downsampled time series via bucket aggregation
        cur.execute(f"""
            SELECT
                (timestamp / {bucket_size}) * {bucket_size} as bucket,
                AVG(system_power_w) as system_power_w,
                AVG(cpu_power_w) as cpu_power_w,
                AVG(igpu_power_w) as igpu_power_w,
                AVG(dgpu_power_w) as dgpu_power_w,
                AVG(cpu_temp_c) as cpu_temp_c,
                AVG(igpu_temp_c) as igpu_temp_c,
                AVG(dgpu_temp_c) as dgpu_temp_c,
                AVG(cpu_usage_pct) as cpu_usage_pct,
                AVG(battery_pct) as battery_pct,
                AVG(ram_used_mb) as ram_used_mb
            FROM telemetry
            WHERE timestamp >= ?
            GROUP BY bucket
            ORDER BY bucket ASC
        """, (start_epoch,))

        series = []
        for r in cur.fetchall():
            dt = datetime.fromtimestamp(r["bucket"])
            label = dt.strftime("%H:%M") if range_seconds <= 86400 else dt.strftime("%m/%d %H:%M")
            series.append({
                "epoch": r["bucket"],
                "time_label": label,
                "system_power_w": round(r["system_power_w"], 1) if r["system_power_w"] is not None else None,
                "cpu_power_w": round(r["cpu_power_w"], 1) if r["cpu_power_w"] is not None else None,
                "igpu_power_w": round(r["igpu_power_w"], 1) if r["igpu_power_w"] is not None else None,
                "dgpu_power_w": round(r["dgpu_power_w"], 1) if r["dgpu_power_w"] is not None else None,
                "cpu_temp_c": round(r["cpu_temp_c"], 1) if r["cpu_temp_c"] is not None else None,
                "igpu_temp_c": round(r["igpu_temp_c"], 1) if r["igpu_temp_c"] is not None else None,
                "dgpu_temp_c": round(r["dgpu_temp_c"], 1) if r["dgpu_temp_c"] is not None else None,
                "cpu_usage_pct": round(r["cpu_usage_pct"], 1) if r["cpu_usage_pct"] is not None else None,
                "battery_pct": round(r["battery_pct"], 1) if r["battery_pct"] is not None else None,
                "ram_used_mb": round(r["ram_used_mb"]) if r["ram_used_mb"] is not None else None,
            })

        conn.close()
        return {"range": str(range), "summary": summary, "series": series}

    except Exception as exc:
        print(f"[trends] sqlite error: {exc}", flush=True)
        return _trends_from_csv(start_epoch, now_epoch, bucket_size)


def _trends_from_csv(start_epoch: int, now_epoch: int, bucket_size: int) -> dict:
    """Fallback parser if SQLite database is empty or not yet created."""
    csv_candidates = []
    for d in LOG_DIRS:
        if d.exists():
            csv_candidates.extend(d.glob("*.csv"))

    if not csv_candidates:
        return {"range": "fallback", "summary": {}, "series": []}

    latest_csv = max(csv_candidates, key=lambda p: p.stat().st_mtime)
    buckets = {}

    try:
        with open(latest_csv, "r", encoding="utf-8", errors="ignore") as f:
            reader = csv.DictReader(f)
            for row in reader:
                ts_str = row.get("Timestamp")
                if not ts_str:
                    continue
                try:
                    dt = datetime.strptime(ts_str.strip(), "%Y-%m-%d %H:%M:%S")
                    epoch = int(dt.timestamp())
                except Exception:
                    continue

                if epoch < start_epoch:
                    continue

                bucket = (epoch // bucket_size) * bucket_size
                if bucket not in buckets:
                    buckets[bucket] = {
                        "p": [], "cpu_p": [], "igpu_p": [], "dgpu_p": [],
                        "c_t": [], "c_u": [], "b": [], "ig_t": [], "dg_t": [],
                    }

                p_val = float(row.get("System_Power_W") or row.get("Power_Draw_W") or 0)
                ct_val = float(row.get("CPU_Temp_C") or 0)
                cu_val = float(row.get("CPU_Usage_Pct") or 0)
                b_val = float(row.get("Battery_Pct") or 0)
                igt_val = float(row.get("iGPU_Temp_C") or 0)
                dgt_val = float(row.get("dGPU_Temp_C") or row.get("GPU_Temp_C") or 0)

                buckets[bucket]["p"].append(p_val)
                buckets[bucket]["c_t"].append(ct_val)
                buckets[bucket]["c_u"].append(cu_val)
                buckets[bucket]["b"].append(b_val)
                for key, col in (("cpu_p", "CPU_Power_W"), ("igpu_p", "iGPU_Power_W"), ("dgpu_p", "dGPU_Power_W")):
                    raw = row.get(col)
                    if raw:
                        buckets[bucket][key].append(float(raw))
                if igt_val > 0:
                    buckets[bucket]["ig_t"].append(igt_val)
                if dgt_val > 0:
                    buckets[bucket]["dg_t"].append(dgt_val)

        def _avg(vals):
            return sum(vals) / len(vals) if vals else None

        series = []
        all_p, all_ct, all_igt, all_dgt = [], [], [], []
        high_power_samples = 0
        for b in sorted(buckets.keys()):
            dt = datetime.fromtimestamp(b)
            all_p.extend(buckets[b]["p"])
            all_ct.extend(buckets[b]["c_t"])
            all_igt.extend(buckets[b]["ig_t"])
            all_dgt.extend(buckets[b]["dg_t"])
            high_power_samples += sum(1 for v in buckets[b]["p"] if v >= HIGH_POWER_W)

            series.append({
                "epoch": b,
                "time_label": dt.strftime("%H:%M"),
                "system_power_w": round(_avg(buckets[b]["p"]), 1) if _avg(buckets[b]["p"]) is not None else None,
                "cpu_power_w": round(_avg(buckets[b]["cpu_p"]), 1) if _avg(buckets[b]["cpu_p"]) is not None else None,
                "igpu_power_w": round(_avg(buckets[b]["igpu_p"]), 1) if _avg(buckets[b]["igpu_p"]) is not None else None,
                "dgpu_power_w": round(_avg(buckets[b]["dgpu_p"]), 1) if _avg(buckets[b]["dgpu_p"]) is not None else None,
                "cpu_temp_c": round(_avg(buckets[b]["c_t"]), 1) if _avg(buckets[b]["c_t"]) is not None else None,
                "cpu_usage_pct": round(_avg(buckets[b]["c_u"]), 1) if _avg(buckets[b]["c_u"]) is not None else None,
                "battery_pct": round(_avg(buckets[b]["b"]), 1) if _avg(buckets[b]["b"]) is not None else None,
                "igpu_temp_c": round(_avg(buckets[b]["ig_t"]), 1) if _avg(buckets[b]["ig_t"]) is not None else None,
                "dgpu_temp_c": round(_avg(buckets[b]["dg_t"]), 1) if _avg(buckets[b]["dg_t"]) is not None else None,
            })

        high_pct = round((high_power_samples / len(all_p)) * 100, 1) if all_p else 0.0
        summary = {
            "sample_count": len(all_p),
            "avg_power_w": round(sum(all_p) / len(all_p), 1) if all_p else 0,
            "max_power_w": round(max(all_p), 1) if all_p else 0,
            "min_power_w": round(min(all_p), 1) if all_p else 0,
            "avg_cpu_temp": round(sum(all_ct) / len(all_ct), 1) if all_ct else 0,
            "max_cpu_temp": round(max(all_ct), 1) if all_ct else 0,
            "avg_igpu_temp": round(sum(all_igt) / len(all_igt), 1) if all_igt else None,
            "max_igpu_temp": round(max(all_igt), 1) if all_igt else None,
            "avg_dgpu_temp": round(sum(all_dgt) / len(all_dgt), 1) if all_dgt else None,
            "max_dgpu_temp": round(max(all_dgt), 1) if all_dgt else None,
            "high_power_w": HIGH_POWER_W,
            "high_power_count": high_power_samples,
            "high_power_pct": high_pct,
        }
        return {"range": "csv", "summary": summary, "series": series}
    except Exception as exc:
        return {"range": "error", "error": str(exc), "summary": {}, "series": []}


# ── Log Files & Log Viewer ───────────────────────────────────────
@app.get("/api/logs")
async def list_logs():
    """Discover all available log files from system and user directories."""
    files = {}
    for d in LOG_DIRS:
        if not d.exists():
            continue
        for p in d.glob("*.csv"):
            if p.name not in files or p.stat().st_mtime > files[p.name]["modified_epoch"]:
                st = p.stat()
                files[p.name] = {
                    "filename": p.name,
                    "path": str(p),
                    "size_bytes": st.st_size,
                    "size_formatted": _fmt_size(st.st_size),
                    "modified_epoch": int(st.st_mtime),
                    "modified_str": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
                }

    # Sort descending by modification time (most recent first)
    log_list = sorted(files.values(), key=lambda x: x["modified_epoch"], reverse=True)
    return {"logs": log_list}


def _fmt_size(size_bytes: int) -> str:
    if size_bytes < 1024:
        return f"{size_bytes} B"
    if size_bytes < 1024**2:
        return f"{size_bytes / 1024:.1f} KB"
    return f"{size_bytes / (1024**2):.1f} MB"


def _resolve_log_path(filename: str) -> Path | None:
    safe_name = os.path.basename(filename)
    for d in LOG_DIRS:
        candidate = d / safe_name
        if candidate.exists() and candidate.is_file():
            return candidate
    return None


def _to_float(raw) -> float | None:
    if raw is None:
        return None
    raw = str(raw).strip()
    if not raw or raw.lower() in ("none", "nan", "null"):
        return None
    try:
        return float(raw)
    except ValueError:
        return None


# Preset predicates for the log viewer's filter dropdown. Each takes the parsed
# row plus the active high-power threshold and returns True when the row matches.
LOG_FILTERS = {
    "all": lambda row, hp: True,
    "high_power": lambda row, hp: (_to_float(row.get("System_Power_W")) or 0.0) >= hp,
    "on_battery": lambda row, hp: row.get("Battery_State", "") in ("Battery", "Discharging"),
    "on_ac": lambda row, hp: "Plugged" in row.get("Battery_State", "") or row.get("Battery_State", "") in ("AC", "Charging", "Full"),
    "dgpu_active": lambda row, hp: row.get("dGPU_State", "") == "Active",
    "dgpu_suspended": lambda row, hp: row.get("dGPU_State", "") == "Suspended",
    "cpu_hot": lambda row, hp: (_to_float(row.get("CPU_Temp_C")) or 0.0) >= 80.0,
    "cpu_busy": lambda row, hp: (_to_float(row.get("CPU_Usage_Pct")) or 0.0) >= 50.0,
    "spike": lambda row, hp: (_to_float(row.get("System_Power_W")) or 0.0) > MAX_PLAUSIBLE_W,
}

LOG_FILTER_LABELS = {
    "all": "All entries",
    "high_power": "High power usage",
    "on_battery": "On battery",
    "on_ac": "On AC power",
    "dgpu_active": "dGPU active",
    "dgpu_suspended": "dGPU suspended",
    "cpu_hot": "CPU hot (>= 80°C)",
    "cpu_busy": "CPU busy (>= 50%)",
    "spike": "Implausible spikes (> 400W)",
}


@app.get("/api/logs/filters")
async def list_log_filters():
    """Expose the available log filters and the active threshold to the UI."""
    return {
        "filters": [{"id": k, "label": v} for k, v in LOG_FILTER_LABELS.items()],
        "high_power_w": HIGH_POWER_W,
        "max_plausible_w": MAX_PLAUSIBLE_W,
    }


@app.get("/api/logs/{filename}")
async def read_log_records(
    filename: str,
    page: int = 1,
    page_size: int = 50,
    q: str = "",
    sort_order: str = "desc",
    filter: str = "all",
    min_power: float | None = None,
    max_power: float | None = None,
    high_power_w: float | None = None,
):
    """
    Paginate, search, filter and parse rows from a specific CSV log file.
    """
    path = _resolve_log_path(filename)
    if not path:
        raise HTTPException(status_code=404, detail=f"Log file '{filename}' not found.")

    page = max(1, int(page or 1))
    page_size = min(500, max(1, int(page_size or 50)))

    filter_id = str(filter or "all").strip().lower()
    if filter_id not in LOG_FILTERS:
        raise HTTPException(status_code=400, detail=f"Unknown filter '{filter}'. Valid: {', '.join(LOG_FILTERS)}")
    threshold = float(high_power_w) if high_power_w is not None else HIGH_POWER_W
    predicate = LOG_FILTERS[filter_id]

    try:
        rows = []
        matched_high = 0
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            reader = csv.DictReader(f)
            columns = reader.fieldnames or []
            search_lower = str(q or "").strip().lower()

            for row in reader:
                power = _to_float(row.get("System_Power_W"))
                if min_power is not None and (power is None or power < min_power):
                    continue
                if max_power is not None and (power is None or power > max_power):
                    continue
                if not predicate(row, threshold):
                    continue
                if search_lower:
                    row_str = " ".join(str(v) for v in row.values()).lower()
                    if search_lower not in row_str:
                        continue
                if power is not None and power >= threshold:
                    matched_high += 1
                rows.append(row)

        total_rows = len(rows)
        if sort_order != "asc":
            rows.reverse()

        total_pages = max(1, (total_rows + page_size - 1) // page_size)
        start_idx = (page - 1) * page_size
        paginated_rows = rows[start_idx:start_idx + page_size]

        return {
            "filename": filename,
            "columns": columns,
            "filter": filter_id,
            "filter_label": LOG_FILTER_LABELS[filter_id],
            "high_power_w": threshold,
            "min_power": min_power,
            "max_power": max_power,
            "total_rows": total_rows,
            "high_power_rows": matched_high,
            "total_pages": total_pages,
            "page": page,
            "page_size": page_size,
            "rows": paginated_rows,
        }
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Failed to read log file: {exc}")


@app.get("/api/logs/{filename}/download")
async def download_log(filename: str):
    path = _resolve_log_path(filename)
    if not path:
        raise HTTPException(status_code=404, detail="Log file not found.")
    return FileResponse(path, filename=path.name, media_type="text/csv")


# ── High Power Attribution ───────────────────────────────────────
@app.get("/api/high-power")
async def get_high_power(hours: int = 24, limit: int = 20):
    """
    Aggregated high-power episodes with the processes recorded alongside them.

    Reads the SQLite time-series (which stores one row per 5s sample). Returns
    the worst contiguous episodes plus a per-process leaderboard, so the log
    viewer can answer "what was burning the watts" instead of only "when".
    """
    hours = min(24 * 30, max(1, int(hours or 24)))
    limit = min(200, max(1, int(limit or 20)))
    start_epoch = int(time.time()) - hours * 3600

    if not DB_PATH.exists():
        raise HTTPException(status_code=503, detail="Telemetry database not available yet.")

    try:
        conn = sqlite3.connect(DB_PATH, timeout=5)
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()

        cur.execute("""
            SELECT iso_time, timestamp, system_power_w, cpu_power_w, igpu_power_w,
                   dgpu_power_w, cpu_usage_pct, cpu_temp_c, battery_state,
                   dgpu_state, top_process, high_power_processes
            FROM telemetry
            WHERE timestamp >= ? AND system_power_w >= ?
            ORDER BY system_power_w DESC
            LIMIT ?
        """, (start_epoch, HIGH_POWER_W, limit))
        events = [
            {
                "iso_time": r["iso_time"],
                "timestamp": r["timestamp"],
                "system_power_w": round(r["system_power_w"], 2) if r["system_power_w"] is not None else None,
                "cpu_power_w": r["cpu_power_w"],
                "igpu_power_w": r["igpu_power_w"],
                "dgpu_power_w": r["dgpu_power_w"],
                "cpu_usage_pct": r["cpu_usage_pct"],
                "cpu_temp_c": r["cpu_temp_c"],
                "battery_state": r["battery_state"],
                "dgpu_state": r["dgpu_state"],
                "top_process": r["top_process"],
                "processes": [p for p in (r["high_power_processes"] or "").split("; ") if p],
            }
            for r in cur.fetchall()
        ]

        # Which processes keep showing up during high-power samples?
        cur.execute("""
            SELECT high_power_processes FROM telemetry
            WHERE timestamp >= ? AND system_power_w >= ? AND high_power_processes IS NOT NULL
            ORDER BY timestamp DESC LIMIT 5000
        """, (start_epoch, HIGH_POWER_W))
        counts = {}
        for r in cur.fetchall():
            for proc in (r["high_power_processes"] or "").split("; "):
                proc = proc.strip()
                if not proc:
                    continue
                name = proc.rsplit(":", 1)[0]
                counts[name] = counts.get(name, 0) + 1

        cur.execute("""
            SELECT COUNT(*) as total,
                   SUM(CASE WHEN system_power_w >= ? THEN 1 ELSE 0 END) as high
            FROM telemetry WHERE timestamp >= ?
        """, (HIGH_POWER_W, start_epoch))
        counts_row = cur.fetchone()
        total = counts_row["total"] or 0
        high = counts_row["high"] or 0
        conn.close()

        return {
            "hours": hours,
            "high_power_w": HIGH_POWER_W,
            "total_samples": total,
            "high_power_samples": high,
            "high_power_pct": round((high / total) * 100, 1) if total else 0.0,
            "top_offenders": [
                {"name": name, "samples": count} for name, count in sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:20]
            ],
            "events": events,
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Failed to query high power events: {exc}")


# ── Entrypoint ──────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"[telemetry-server] starting dashboard on http://{HOST}:{PORT}", flush=True)
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
