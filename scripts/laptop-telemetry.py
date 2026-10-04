#!/usr/bin/env python3
"""
Laptop Telemetry — Unified Collector + Real-Time Dashboard Server
ASUS Zephyrus G16 (AMD Ryzen + Radeon iGPU + NVIDIA RTX 4060 dGPU)

Single process: collects system metrics every ~2s in a background thread,
serves a live dashboard via FastAPI + SSE on localhost:9999.
"""

import asyncio
import glob
import json
import os
import subprocess
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

import psutil
import uvicorn
from fastapi import FastAPI
from fastapi.responses import FileResponse, HTMLResponse
from starlette.responses import StreamingResponse

# ── Configuration ────────────────────────────────────────────────
HOST = os.getenv("TELEMETRY_HOST", "127.0.0.1")
PORT = int(os.getenv("TELEMETRY_PORT", "9999"))
POLL_INTERVAL = float(os.getenv("TELEMETRY_POLL_INTERVAL", "2.0"))
HTML_PATH = os.getenv(
    "TELEMETRY_HTML_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html"),
)

# ── Shared State ─────────────────────────────────────────────────
_metrics: dict = {}
_metrics_lock = threading.Lock()

# ── RAPL Energy Tracking ────────────────────────────────────────
_rapl_prev: dict = {}  # energy_path -> (energy_uj, timestamp_ns)


def _find_rapl_domains() -> dict:
    """Discover RAPL energy domains from /sys/class/powercap.

    Returns a dict keyed by sysfs entry name (e.g. "intel-rapl:0") with:
      - name: domain name (e.g. "package-0", "core")
      - energy_path: path to energy_uj counter
      - is_toplevel: True for package-level (intel-rapl:N), False for
        subdomains (intel-rapl:N:M)
    """
    domains = {}
    base = "/sys/class/powercap"
    if not os.path.isdir(base):
        return domains
    for entry in os.listdir(base):
        if not entry.startswith("intel-rapl"):
            continue
        name_path = os.path.join(base, entry, "name")
        energy_path = os.path.join(base, entry, "energy_uj")
        if not (os.path.exists(name_path) and os.path.exists(energy_path)):
            continue
        try:
            with open(name_path) as f:
                name = f.read().strip()
            # intel-rapl:0 = top-level, intel-rapl:0:0 = subdomain
            parts = entry.split(":")
            is_toplevel = len(parts) == 2
            domains[entry] = {
                "name": name,
                "energy_path": energy_path,
                "is_toplevel": is_toplevel,
            }
        except Exception:
            pass
    return domains


def _read_all_rapl_powers(domains: dict) -> dict:
    """Read every RAPL domain's energy counter once and compute watts.

    Must be called exactly once per collection cycle so the deltas are
    meaningful (avoids double-reading the same counter with a ~0 ns gap).

    Returns {domain_name: {"watts": float, "is_toplevel": bool}}.
    """
    powers = {}
    for _entry_name, info in domains.items():
        path = info["energy_path"]
        try:
            with open(path) as f:
                energy_uj = int(f.read().strip())
            now_ns = time.monotonic_ns()

            if path in _rapl_prev:
                prev_uj, prev_ns = _rapl_prev[path]
                delta_uj = energy_uj - prev_uj
                delta_ns = now_ns - prev_ns

                # Handle counter overflow
                if delta_uj < 0:
                    try:
                        max_path = path.replace("energy_uj", "max_energy_range_uj")
                        with open(max_path) as f:
                            max_uj = int(f.read().strip())
                        delta_uj = (max_uj - prev_uj) + energy_uj
                    except Exception:
                        delta_uj = 0

                if delta_ns > 0:
                    # µJ / ns  =  (J × 10⁻⁶) / (s × 10⁻⁹)  =  W × 10³
                    watts = (delta_uj * 1_000.0) / delta_ns
                    powers[info["name"]] = {
                        "watts": round(watts, 2),
                        "is_toplevel": info["is_toplevel"],
                    }

            _rapl_prev[path] = (energy_uj, now_ns)
        except Exception:
            pass
    return powers


# ── hwmon Scanning ──────────────────────────────────────────────
_hwmon_cache: dict = {}  # chip name -> hwmon dir path


def _find_hwmon(chip_name: str) -> str | None:
    """Find hwmon directory by chip name (e.g. 'amdgpu'), with caching."""
    if chip_name in _hwmon_cache:
        cached = _hwmon_cache[chip_name]
        if os.path.isdir(cached):
            return cached
        del _hwmon_cache[chip_name]

    for hwmon_dir in glob.glob("/sys/class/hwmon/hwmon*"):
        name_path = os.path.join(hwmon_dir, "name")
        try:
            with open(name_path) as f:
                if f.read().strip() == chip_name:
                    _hwmon_cache[chip_name] = hwmon_dir
                    return hwmon_dir
        except Exception:
            pass
    return None


def _read_hwmon(hwmon_path: str | None, filename: str, divisor: float = 1.0):
    """Read a numeric value from a hwmon sysfs file."""
    if not hwmon_path:
        return None
    path = os.path.join(hwmon_path, filename)
    try:
        with open(path) as f:
            return round(int(f.read().strip()) / divisor, 2)
    except Exception:
        return None


# ── NVIDIA dGPU ─────────────────────────────────────────────────
def _is_nvidia_awake() -> bool:
    """Check PCI bus power state before polling nvidia-smi.

    Scans /sys/bus/pci/devices for the NVIDIA vendor ID (0x10de) and
    checks runtime_status. Returns True only if the device is 'active'.
    If it reports 'suspended' (D3cold), we must NOT call nvidia-smi
    or the kernel will wake the GPU and drain the battery.
    """
    for path in glob.glob("/sys/bus/pci/devices/*/power/runtime_status"):
        try:
            vendor_path = os.path.join(os.path.dirname(path), "vendor")
            if not os.path.exists(vendor_path):
                continue
            with open(vendor_path) as f:
                if f.read().strip() != "0x10de":
                    continue
            # Check class to confirm it's a VGA/3D controller (not USB/audio)
            class_path = os.path.join(os.path.dirname(path), "class")
            if os.path.exists(class_path):
                with open(class_path) as f:
                    dev_class = f.read().strip()
                # 0x030000 = VGA, 0x030200 = 3D controller
                if not dev_class.startswith("0x03"):
                    continue
            with open(path) as f:
                return f.read().strip() == "active"
        except Exception:
            pass
    return False


def _get_nvidia_metrics() -> dict | None:
    """Query nvidia-smi for dGPU metrics. Only called when GPU is awake."""
    try:
        res = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=temperature.gpu,utilization.gpu,power.draw,"
                "memory.used,memory.total,fan.speed",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=3,
        )
        if res.returncode != 0 or not res.stdout.strip():
            return None

        parts = [p.strip() for p in res.stdout.strip().split(",")]
        if len(parts) < 5:
            return None

        def _parse(val: str):
            """Parse nvidia-smi value; returns None for '[N/A]' or errors."""
            val = val.strip()
            if val in ("[N/A]", "[Not Supported]", "N/A", ""):
                return None
            try:
                return float(val)
            except ValueError:
                return None

        return {
            "temp_c": _parse(parts[0]),
            "util_pct": _parse(parts[1]),
            "power_w": _parse(parts[2]),
            "vram_used_mb": _parse(parts[3]),
            "vram_total_mb": _parse(parts[4]),
            "fan_pct": _parse(parts[5]) if len(parts) > 5 else None,
        }
    except Exception:
        return None


def _is_ac_online() -> bool:
    """Check /sys/class/power_supply/*/online for any AC / Mains adapter."""
    for online_path in glob.glob("/sys/class/power_supply/*/online"):
        try:
            with open(online_path) as f:
                if f.read().strip() == "1":
                    return True
        except Exception:
            pass
    batt = psutil.sensors_battery()
    return batt.power_plugged is True if batt else False


# ── Battery & Power ─────────────────────────────────────────────
def _get_battery_info() -> dict:
    """Battery percentage, charge state, discharge power, and time left."""
    battery = psutil.sensors_battery()
    if not battery:
        return {
            "percent": None,
            "state": "No Battery",
            "power_w": None,
            "time_left": None,
        }

    ac_online = _is_ac_online()

    raw_status = None
    for bat in ("BAT0", "BAT1"):
        stat_path = f"/sys/class/power_supply/{bat}/status"
        if os.path.exists(stat_path):
            try:
                with open(stat_path) as f:
                    raw_status = f.read().strip()
                break
            except Exception:
                pass

    if ac_online:
        if raw_status == "Charging":
            state = "Charging"
        elif raw_status == "Full":
            state = "Full"
        elif raw_status == "Not charging":
            state = "AC (Plugged In)"
        else:
            state = "AC"
    else:
        state = "Discharging" if raw_status == "Discharging" else "Battery"

    # Read battery discharge rate from sysfs
    power_w = None
    for bat in ("BAT0", "BAT1"):
        power_path = f"/sys/class/power_supply/{bat}/power_now"
        if os.path.exists(power_path):
            try:
                with open(power_path) as f:
                    raw = int(f.read().strip())
                if raw > 0:
                    power_w = round(raw / 1_000_000, 2)
                    break
            except Exception:
                pass

    # Fallback: current_now × voltage_now
    if power_w is None:
        for bat in ("BAT0", "BAT1"):
            cur = f"/sys/class/power_supply/{bat}/current_now"
            vol = f"/sys/class/power_supply/{bat}/voltage_now"
            if os.path.exists(cur) and os.path.exists(vol):
                try:
                    with open(cur) as f:
                        current_ua = int(f.read().strip())
                    with open(vol) as f:
                        voltage_uv = int(f.read().strip())
                    power_w = round((current_ua * voltage_uv) / 1e12, 2)
                    break
                except Exception:
                    pass

    # Time remaining
    secs = battery.secsleft
    if secs and secs > 0:
        time_left = str(timedelta(seconds=secs))
    elif ac_online:
        if raw_status == "Charging":
            time_left = "Charging"
        elif raw_status in ("Full", "Not charging"):
            time_left = "Plugged In"
        else:
            time_left = "AC Connected"
    else:
        time_left = None

    return {
        "percent": round(battery.percent, 1),
        "state": state,
        "power_w": power_w,
        "time_left": time_left,
    }


# ── Fan Speeds ──────────────────────────────────────────────────
def _get_fan_speeds() -> dict:
    """Read fan RPMs from psutil or ASUS-specific hwmon entries."""
    fans = {}

    # psutil approach
    try:
        psutil_fans = psutil.sensors_fans()
        if psutil_fans:
            for chip, entries in psutil_fans.items():
                for entry in entries:
                    label = entry.label or chip
                    fans[label] = int(entry.current)
    except Exception:
        pass

    # ASUS-specific hwmon fallback
    if not fans:
        for hwmon_dir in glob.glob("/sys/class/hwmon/hwmon*"):
            name_path = os.path.join(hwmon_dir, "name")
            try:
                with open(name_path) as f:
                    chip = f.read().strip()
                if chip not in ("asus-nb-wmi", "asus_fan", "asus-ec-sensors"):
                    continue
                for fan_file in sorted(glob.glob(os.path.join(hwmon_dir, "fan*_input"))):
                    with open(fan_file) as f:
                        rpm = int(f.read().strip())
                    idx = os.path.basename(fan_file).replace("fan", "").replace("_input", "")
                    fans[f"Fan {idx}"] = rpm
            except Exception:
                pass

    return fans


# ── Top Processes ───────────────────────────────────────────────
def _get_top_processes(n: int = 5) -> list[dict]:
    """Top N processes by CPU usage (always collected, not conditional)."""
    procs = []
    for p in psutil.process_iter(["pid", "name", "cpu_percent", "memory_info"]):
        try:
            cpu = p.info["cpu_percent"] or 0.0
            if cpu < 0.5:
                continue
            mem = p.info.get("memory_info")
            mem_mb = round(mem.rss / (1024**2), 1) if mem else 0
            procs.append(
                {
                    "pid": p.info["pid"],
                    "name": p.info["name"] or "?",
                    "cpu_pct": round(cpu, 1),
                    "mem_mb": mem_mb,
                }
            )
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    procs.sort(key=lambda x: x["cpu_pct"], reverse=True)
    return procs[:n]


# ── Misc Helpers ────────────────────────────────────────────────
def _get_uptime() -> str:
    try:
        with open("/proc/uptime") as f:
            secs = int(float(f.read().split()[0]))
        return str(timedelta(seconds=secs))
    except Exception:
        return "Unknown"


# ── Rate-Tracking State ────────────────────────────────────────
_prev_net = None
_prev_disk = None
_prev_time: float | None = None


# ── Main Collector ──────────────────────────────────────────────
def collect_metrics() -> dict:
    """Collect every system metric in one pass."""
    global _prev_net, _prev_disk, _prev_time

    # ── RAPL (read all domains exactly once) ──
    rapl_domains = _find_rapl_domains()
    rapl = _read_all_rapl_powers(rapl_domains)

    # CPU package power (RAPL "package-0" — includes cores + iGPU on AMD APU)
    cpu_power = None
    for name in ("package-0", "Package-0", "package_0"):
        if name in rapl:
            cpu_power = rapl[name]["watts"]
            break

    # ── CPU ──
    cpu_pct = psutil.cpu_percent(interval=None)
    cpu_per_core = psutil.cpu_percent(interval=None, percpu=True)
    cpu_freq = psutil.cpu_freq()
    load1, load5, load15 = os.getloadavg()

    cpu_temp = None
    temps = psutil.sensors_temperatures()
    for key in ("k10temp", "zenpower", "coretemp", "cpu_thermal", "acpitz"):
        if key not in temps or not temps[key]:
            continue
        for entry in temps[key]:
            if entry.label in ("Tctl", "Tdie", ""):
                cpu_temp = round(entry.current, 1)
                break
        if cpu_temp is None:
            cpu_temp = round(temps[key][0].current, 1)
        break

    # ── iGPU (AMD Radeon integrated) ──
    amdgpu_hwmon = _find_hwmon("amdgpu")
    igpu_temp = _read_hwmon(amdgpu_hwmon, "temp1_input", 1_000.0)

    igpu_power = None
    for pf in ("power1_average", "power1_input"):
        igpu_power = _read_hwmon(amdgpu_hwmon, pf, 1_000_000.0)
        if igpu_power is not None:
            break

    # ── dGPU (NVIDIA) ──
    dgpu_awake = _is_nvidia_awake()
    dgpu = {
        "state": "Active" if dgpu_awake else "Suspended",
        "temp_c": None,
        "util_pct": None,
        "power_w": None,
        "vram_used_mb": None,
        "vram_total_mb": None,
        "fan_pct": None,
    }
    if dgpu_awake:
        nv = _get_nvidia_metrics()
        if nv:
            dgpu.update(nv)
            dgpu["state"] = "Active"

    # ── Memory ──
    ram = psutil.virtual_memory()
    swap = psutil.swap_memory()

    # ── Battery & Power ──
    battery = _get_battery_info()

    # System total power estimate
    system_power = None
    is_on_battery = battery["state"] in ("Battery", "Discharging")
    if is_on_battery and battery.get("power_w") and battery["power_w"] > 0:
        # On battery the BAT power_now is total system draw
        system_power = battery["power_w"]
    else:
        # On AC or fallback: sum top-level RAPL domains + dGPU
        rapl_total = 0.0
        has_rapl = False
        for _name, info in rapl.items():
            if info.get("is_toplevel"):
                rapl_total += info["watts"]
                has_rapl = True
        if has_rapl:
            system_power = round(rapl_total, 2)
        elif igpu_power is not None:
            # Fallback if RAPL is unreadable (e.g. non-root test)
            system_power = round(igpu_power, 2)
        if dgpu.get("power_w"):
            system_power = round((system_power or 0) + dgpu["power_w"], 2)

    # ── Fans ──
    fans = _get_fan_speeds()

    # ── Network & Disk rates ──
    net = psutil.net_io_counters()
    disk_io = psutil.disk_io_counters()
    disk_usage = psutil.disk_usage("/")
    now = time.monotonic()

    net_sent_rate = 0.0
    net_recv_rate = 0.0
    disk_read_rate = 0.0
    disk_write_rate = 0.0

    if _prev_time is not None:
        dt = now - _prev_time
        if dt > 0:
            if _prev_net:
                net_sent_rate = round(
                    (net.bytes_sent - _prev_net.bytes_sent) / dt / 1024, 1
                )
                net_recv_rate = round(
                    (net.bytes_recv - _prev_net.bytes_recv) / dt / 1024, 1
                )
            if _prev_disk and disk_io:
                disk_read_rate = round(
                    (disk_io.read_bytes - _prev_disk.read_bytes)
                    / dt
                    / (1024 * 1024),
                    2,
                )
                disk_write_rate = round(
                    (disk_io.write_bytes - _prev_disk.write_bytes)
                    / dt
                    / (1024 * 1024),
                    2,
                )

    _prev_net = net
    _prev_disk = disk_io
    _prev_time = now

    # ── Top Processes ──
    top_procs = _get_top_processes(5)

    # ── Build payload ──
    return {
        "timestamp": datetime.now().isoformat(),
        "hostname": os.uname().nodename,
        "kernel": os.uname().release,
        "uptime": _get_uptime(),
        "cpu": {
            "temp_c": cpu_temp,
            "power_w": cpu_power,
            "usage_pct": round(cpu_pct, 1),
            "per_core_pct": [round(c, 1) for c in cpu_per_core],
            "freq_mhz": round(cpu_freq.current, 0) if cpu_freq else None,
            "freq_max_mhz": (
                round(cpu_freq.max, 0)
                if cpu_freq and cpu_freq.max
                else None
            ),
            "core_count": psutil.cpu_count(logical=False),
            "thread_count": psutil.cpu_count(logical=True),
            "load_avg": [round(load1, 2), round(load5, 2), round(load15, 2)],
        },
        "igpu": {
            "temp_c": igpu_temp,
            "power_w": igpu_power,
        },
        "dgpu": dgpu,
        "ram": {
            "used_mb": round(ram.used / (1024**2)),
            "total_mb": round(ram.total / (1024**2)),
            "percent": ram.percent,
        },
        "swap": {
            "used_mb": round(swap.used / (1024**2)),
            "total_mb": round(swap.total / (1024**2)),
            "percent": swap.percent,
        },
        "battery": battery,
        "system_power_w": system_power,
        "fans": fans,
        "top_processes": top_procs,
        "network": {
            "sent_rate_kbps": max(net_sent_rate, 0),
            "recv_rate_kbps": max(net_recv_rate, 0),
            "total_sent_mb": round(net.bytes_sent / (1024**2), 1),
            "total_recv_mb": round(net.bytes_recv / (1024**2), 1),
        },
        "disk": {
            "read_rate_mbps": max(disk_read_rate, 0),
            "write_rate_mbps": max(disk_write_rate, 0),
            "usage_percent": disk_usage.percent,
            "used_gb": round(disk_usage.used / (1024**3), 1),
            "total_gb": round(disk_usage.total / (1024**3), 1),
        },
    }


# ── Background Collection Thread ────────────────────────────────
def _collector_loop():
    """Runs in a daemon thread, refreshes _metrics every POLL_INTERVAL."""
    global _metrics

    # Prime psutil's internal counters (first call always returns 0)
    psutil.cpu_percent(interval=None)
    psutil.cpu_percent(interval=None, percpu=True)
    time.sleep(1)

    while True:
        try:
            data = collect_metrics()
            with _metrics_lock:
                _metrics = data
        except Exception as exc:
            print(f"[collector] error: {exc}", flush=True)
        time.sleep(POLL_INTERVAL)


# ── FastAPI Application ─────────────────────────────────────────
app = FastAPI(title="Laptop Telemetry", docs_url=None, redoc_url=None)


@app.get("/")
async def serve_dashboard():
    """Serve the single-page HTML dashboard."""
    if os.path.exists(HTML_PATH):
        return FileResponse(HTML_PATH, media_type="text/html")
    return HTMLResponse(
        "<h1>index.html not found — check TELEMETRY_HTML_PATH</h1>",
        status_code=404,
    )


@app.get("/api/snapshot")
async def snapshot():
    """One-shot JSON snapshot (for curl / debugging)."""
    with _metrics_lock:
        return _metrics or {"status": "collecting"}


@app.get("/api/stream")
async def stream():
    """Server-Sent Events endpoint — pushes a JSON frame every cycle."""

    async def _generate():
        while True:
            with _metrics_lock:
                data = json.dumps(_metrics) if _metrics else "{}"
            yield f"data: {data}\n\n"
            await asyncio.sleep(POLL_INTERVAL)

    return StreamingResponse(
        _generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# ── Entrypoint ──────────────────────────────────────────────────
if __name__ == "__main__":
    collector = threading.Thread(target=_collector_loop, daemon=True)
    collector.start()
    print(
        f"[telemetry] dashboard → http://{HOST}:{PORT}",
        flush=True,
    )
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
