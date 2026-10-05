#!/usr/bin/env python3
"""
Laptop Telemetry — 24/7 Background System Logger Daemon
ASUS Zephyrus G16 (AMD Ryzen + Radeon iGPU + NVIDIA RTX 4060 dGPU)

Runs continuously as a systemd system service (root).
- Collects all metrics every 5 seconds.
- Atomically writes latest snapshot to /run/telemetry/latest.json (for live dashboard).
- Appends to daily CSV in /var/log/telemetry/telemetry-YYYY-MM-DD.csv and ~/.local/share/telemetry/.
- Records time-series data to SQLite /var/log/telemetry/telemetry.db for fast trends queries.
"""

import csv
import glob
import json
import os
import sqlite3
import subprocess
import time
from datetime import datetime, timedelta
from pathlib import Path

import psutil

# ── Configuration ────────────────────────────────────────────────
LOG_INTERVAL = float(os.getenv("TELEMETRY_LOG_INTERVAL", "5.0"))
RUN_DIR = Path(os.getenv("TELEMETRY_RUN_DIR", "/run/telemetry"))
LOG_DIR = Path(os.getenv("TELEMETRY_LOG_DIR", "/var/log/telemetry"))
USER_LOG_DIR = Path(os.getenv("TELEMETRY_USER_LOG_DIR", "/home/steve/.local/share/telemetry"))
DB_PATH = LOG_DIR / "telemetry.db"

# System draw (watts) at or above which a sample is flagged as "high power".
HIGH_POWER_W = float(os.getenv("TELEMETRY_HIGH_POWER_W", "20.0"))
# Number of processes captured in the log whenever high power is detected.
TOP_N_HIGH_POWER = int(os.getenv("TELEMETRY_TOP_N_HIGH_POWER", "5"))
# Hard ceiling for a believable laptop SoC draw. Anything above this is a
# sensor/timing artefact, not physics, and is discarded instead of logged.
MAX_PLAUSIBLE_W = float(os.getenv("TELEMETRY_MAX_PLAUSIBLE_W", "400.0"))
# A RAPL window longer than this means we were descheduled or suspended, so the
# average is not representative of "now" and is dropped. See _read_all_rapl_powers.
MAX_RAPL_WINDOW_S = float(os.getenv("TELEMETRY_MAX_RAPL_WINDOW_S", "20.0"))

# Ensure directories exist
RUN_DIR.mkdir(parents=True, exist_ok=True)
try:
    os.chmod(RUN_DIR, 0o755)
except Exception:
    pass

LOG_DIR.mkdir(parents=True, exist_ok=True)
try:
    os.chmod(LOG_DIR, 0o755)
except Exception:
    pass

if USER_LOG_DIR.exists():
    try:
        os.chmod(USER_LOG_DIR, 0o775)
    except Exception:
        pass


# ── SQLite Setup ─────────────────────────────────────────────────
def init_db():
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                iso_time TEXT NOT NULL,
                battery_pct REAL,
                battery_state TEXT,
                battery_power_w REAL,
                system_power_w REAL,
                cpu_usage_pct REAL,
                cpu_temp_c REAL,
                cpu_power_w REAL,
                igpu_temp_c REAL,
                igpu_power_w REAL,
                dgpu_state TEXT,
                dgpu_temp_c REAL,
                dgpu_power_w REAL,
                dgpu_util_pct REAL,
                ram_used_mb INTEGER,
                ram_percent REAL,
                swap_used_mb INTEGER,
                top_process TEXT,
                power_flag TEXT,
                high_power_w REAL,
                high_power_processes TEXT,
                high_power_streak INTEGER
            );
        """)
        # Additive migration for databases created by older builds.
        existing = {r[1] for r in cursor.execute("PRAGMA table_info(telemetry);")}
        for col, decl in (
            ("power_flag", "TEXT"),
            ("high_power_w", "REAL"),
            ("high_power_processes", "TEXT"),
            ("high_power_streak", "INTEGER"),
        ):
            if col not in existing:
                cursor.execute(f"ALTER TABLE telemetry ADD COLUMN {col} {decl};")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_telemetry_ts ON telemetry(timestamp);")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_telemetry_high ON telemetry(power_flag);")
        conn.commit()
        conn.close()
        try:
            os.chmod(DB_PATH, 0o666)
        except Exception:
            pass
    except Exception as exc:
        print(f"[db-init] warning: {exc}", flush=True)


# ── RAPL Energy Tracking ────────────────────────────────────────
# Maps each energy_uj file to the last (energy_uj, CLOCK_BOOTTIME) reading.
_rapl_prev = {}

# CLOCK_BOOTTIE counts time spent suspended, which is exactly what we need:
# the RAPL energy_uj counter keeps accumulating while the machine is asleep in
# s2idle, so the denominator has to advance across a suspend too.
# CLOCK_MONOTONIC (what time.monotonic_ns() used to return) does NOT advance
# during s2idle, which made every resume produce a multi-kilowatt phantom spike:
# a real 4.4 kJ of energy spread over a 5 s monotonic window reads as ~9.9 kW.
def _boottime_ns() -> int:
    return time.clock_gettime_ns(time.CLOCK_BOOTTIME)


def _find_rapl_domains() -> dict:
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
            parts = entry.split(":")
            domains[entry] = {
                "name": name,
                "energy_path": energy_path,
                "is_toplevel": len(parts) == 2,
            }
        except Exception:
            pass
    return domains


def _read_all_rapl_powers(domains: dict) -> dict:
    """
    Derive per-domain average power (W) from RAPL energy deltas.

    Two guards keep bogus readings out of the logs:
      1. A window longer than MAX_RAPL_WINDOW_S means we were suspended or the
         daemon was starved. The energy delta is real but the average spans
         minutes of wall time, so it is not a meaningful "current" draw and is
         dropped (the baseline is still advanced so the next window is clean).
      2. Results above MAX_PLAUSIBLE_W are counter resets / wrap artefacts.
    """
    powers = {}
    for _entry_name, info in domains.items():
        path = info["energy_path"]
        try:
            with open(path) as f:
                energy_uj = int(f.read().strip())
            now_ns = _boottime_ns()

            if path in _rapl_prev:
                prev_uj, prev_ns = _rapl_prev[path]
                delta_uj = energy_uj - prev_uj
                delta_ns = now_ns - prev_ns
                delta_s = delta_ns / 1_000_000_000

                if delta_uj < 0:
                    max_path = os.path.join(os.path.dirname(path), "max_energy_range_uj")
                    if os.path.exists(max_path):
                        with open(max_path) as mf:
                            max_range = int(mf.read().strip())
                        delta_uj += max_range

                if delta_s > 0 and delta_uj >= 0:
                    watts = (delta_uj / 1_000_000) / delta_s
                    if delta_s > MAX_RAPL_WINDOW_S:
                        print(
                            f"[rapl] skipping {info['name']}: {delta_s:.1f}s window "
                            f"(suspend/deschedule), {watts:.1f}W not representative",
                            flush=True,
                        )
                    elif watts <= MAX_PLAUSIBLE_W:
                        powers[info["name"]] = {
                            "watts": round(max(watts, 0.0), 2),
                            "is_toplevel": info["is_toplevel"],
                        }
                    else:
                        print(
                            f"[rapl] rejecting {info['name']}: {watts:.1f}W exceeds "
                            f"{MAX_PLAUSIBLE_W}W ceiling (counter artefact)",
                            flush=True,
                        )

            _rapl_prev[path] = (energy_uj, now_ns)
        except Exception:
            pass
    return powers


# ── Hardware Sensors ────────────────────────────────────────────
def _get_cpu_temp() -> float | None:
    try:
        temps = psutil.sensors_temperatures()
        if "k10temp" in temps:
            for entry in temps["k10temp"]:
                if entry.label in ("Tctl", "Tdie"):
                    return round(entry.current, 1)
            return round(temps["k10temp"][0].current, 1)
        for key in ("coretemp", "cpu_thermal"):
            if key in temps and temps[key]:
                return round(temps[key][0].current, 1)
    except Exception:
        pass
    return None


def _get_igpu_metrics() -> tuple[float | None, float | None]:
    temp_c = None
    power_w = None
    for hwmon in glob.glob("/sys/class/hwmon/hwmon*"):
        name_path = os.path.join(hwmon, "name")
        if not os.path.exists(name_path):
            continue
        try:
            with open(name_path) as f:
                name = f.read().strip()
            if name == "amdgpu":
                for tfile in ("temp1_input", "temp2_input"):
                    tp = os.path.join(hwmon, tfile)
                    if os.path.exists(tp):
                        with open(tp) as f:
                            raw = int(f.read().strip())
                        if raw > 0:
                            temp_c = round(raw / 1000.0, 1)
                            break
                for pfile in ("power1_average", "power1_input"):
                    pp = os.path.join(hwmon, pfile)
                    if os.path.exists(pp):
                        with open(pp) as f:
                            raw = int(f.read().strip())
                        if raw > 0:
                            power_w = round(raw / 1_000_000.0, 2)
                            break
                break
        except Exception:
            pass
    return temp_c, power_w


def _is_nvidia_awake() -> bool:
    for path in glob.glob("/sys/bus/pci/devices/*/power/runtime_status"):
        try:
            vendor_path = os.path.join(os.path.dirname(path), "vendor")
            if not os.path.exists(vendor_path):
                continue
            with open(vendor_path) as f:
                if f.read().strip() != "0x10de":
                    continue
            class_path = os.path.join(os.path.dirname(path), "class")
            if os.path.exists(class_path):
                with open(class_path) as f:
                    dev_class = f.read().strip()
                if not dev_class.startswith("0x03"):
                    continue
            with open(path) as f:
                return f.read().strip() == "active"
        except Exception:
            pass
    return False


def _get_nvidia_metrics() -> dict | None:
    try:
        res = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=temperature.gpu,utilization.gpu,power.draw,memory.used,memory.total,fan.speed",
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
    for online_path in glob.glob("/sys/class/power_supply/*/online"):
        try:
            with open(online_path) as f:
                if f.read().strip() == "1":
                    return True
        except Exception:
            pass
    batt = psutil.sensors_battery()
    return batt.power_plugged is True if batt else False


def _get_battery_info() -> dict:
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


def _get_fan_speeds() -> dict:
    fans = {}
    try:
        ps_fans = psutil.sensors_fans()
        for label, entries in ps_fans.items():
            for i, entry in enumerate(entries):
                key = f"{label}_{i}" if len(entries) > 1 else label
                if entry.current > 0:
                    fans[key] = entry.current
    except Exception:
        pass

    if not fans:
        for hwmon in glob.glob("/sys/class/hwmon/hwmon*"):
            try:
                name_path = os.path.join(hwmon, "name")
                hwmon_name = "fan"
                if os.path.exists(name_path):
                    with open(name_path) as f:
                        hwmon_name = f.read().strip()
                for fan_input in sorted(glob.glob(os.path.join(hwmon, "fan*_input"))):
                    with open(fan_input) as f:
                        rpm = int(f.read().strip())
                    base = os.path.basename(fan_input).replace("_input", "")
                    label_path = os.path.join(hwmon, f"{base}_label")
                    if os.path.exists(label_path):
                        with open(label_path) as lf:
                            lbl = lf.read().strip()
                    else:
                        lbl = f"{hwmon_name}_{base}"
                    if rpm > 0:
                        fans[lbl] = rpm
            except Exception:
                pass
    return fans


def _get_top_processes(n: int = 5, min_cpu_pct: float = 0.5, min_mem_mb: float = 200.0) -> list[dict]:
    """
    Top `n` processes by CPU, with memory hogs included even when idle.

    The memory floor matters for high-power attribution: a 4 GB video decode in
    a mostly-idle process still costs real watts, but a pure CPU sort would hide it.
    """
    procs = []
    for p in psutil.process_iter(["pid", "name", "cpu_percent", "memory_info"]):
        try:
            cpu = p.info["cpu_percent"] or 0.0
            mem = p.info.get("memory_info")
            mem_mb = round(mem.rss / (1024**2), 1) if mem else 0
            if cpu < min_cpu_pct and mem_mb < min_mem_mb:
                continue
            procs.append({
                "pid": p.info["pid"],
                "name": p.info["name"] or "?",
                "cpu_pct": round(cpu, 1),
                "mem_mb": mem_mb,
            })
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    procs.sort(key=lambda x: (x["cpu_pct"], x["mem_mb"]), reverse=True)
    return procs[:n]


def _format_top_processes(procs: list[dict] | None, n: int = 5) -> str:
    """Render a compact 'name:cpu%|memMB' list for the CSV/DB log columns."""
    if not procs:
        return ""
    parts = []
    for p in procs[:n]:
        parts.append(f"{p['name']}:{p['cpu_pct']}%/{p['mem_mb']}MB")
    return "; ".join(parts)


_prev_net = None
_prev_disk = None
_prev_time = None
# Consecutive samples at/over HIGH_POWER_W, so the log can note a sustained
# high-power episode rather than a single-sample blip.
_high_power_streak = 0


def collect_metrics() -> dict:
    global _prev_net, _prev_disk, _prev_time, _high_power_streak

    rapl_domains = _find_rapl_domains()
    rapl = _read_all_rapl_powers(rapl_domains)

    cpu_temp = _get_cpu_temp()
    cpu_pct = psutil.cpu_percent(interval=None)
    cpu_per_core = psutil.cpu_percent(interval=None, percpu=True)
    cpu_freq = psutil.cpu_freq()
    load1, load5, load15 = psutil.getloadavg()

    # Prefer the RAPL package domain; a bare "core" sub-domain is a fraction of
    # the SoC, so it must never be reported as total CPU power.
    cpu_power = None
    for name, info in rapl.items():
        if "package" in name.lower():
            cpu_power = info["watts"]
            break
    if cpu_power is None:
        for _name, info in rapl.items():
            if info.get("is_toplevel"):
                cpu_power = info["watts"]
                break

    igpu_temp, igpu_power = _get_igpu_metrics()

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

    ram = psutil.virtual_memory()
    swap = psutil.swap_memory()
    battery = _get_battery_info()

    system_power = None
    is_on_battery = battery["state"] in ("Battery", "Discharging")
    if is_on_battery and battery.get("power_w") and battery["power_w"] > 0:
        system_power = battery["power_w"]
    else:
        rapl_total = 0.0
        has_rapl = False
        for _name, info in rapl.items():
            if info.get("is_toplevel"):
                rapl_total += info["watts"]
                has_rapl = True
        if has_rapl:
            system_power = round(rapl_total, 2)
        elif igpu_power is not None:
            system_power = round(igpu_power, 2)
        if dgpu.get("power_w"):
            system_power = round((system_power or 0) + dgpu["power_w"], 2)
    if system_power is not None:
        system_power = min(system_power, MAX_PLAUSIBLE_W)

    fans = _get_fan_speeds()

    net = psutil.net_io_counters()
    disk_io = psutil.disk_io_counters()
    disk_usage = psutil.disk_usage("/")
    # CLOCK_BOOTTIME, not monotonic: a suspend must stretch the rate window
    # instead of collapsing it into a single absurd sample.
    now = time.clock_gettime(time.CLOCK_BOOTTIME)

    net_sent_rate = 0.0
    net_recv_rate = 0.0
    disk_read_rate = 0.0
    disk_write_rate = 0.0

    if _prev_time is not None:
        dt = now - _prev_time
        if 0 < dt <= MAX_RAPL_WINDOW_S:
            if _prev_net:
                net_sent_rate = round((net.bytes_sent - _prev_net.bytes_sent) / dt / 1024, 1)
                net_recv_rate = round((net.bytes_recv - _prev_net.bytes_recv) / dt / 1024, 1)
            if _prev_disk and disk_io:
                disk_read_rate = round((disk_io.read_bytes - _prev_disk.read_bytes) / dt / (1024 * 1024), 2)
                disk_write_rate = round((disk_io.write_bytes - _prev_disk.write_bytes) / dt / (1024 * 1024), 2)

    _prev_net = net
    _prev_disk = disk_io
    _prev_time = now

    top_procs = _get_top_processes(5)

    # High-power attribution: when the draw crosses HIGH_POWER_W we snapshot the
    # top N processes so the log can answer "what was burning the watts".
    is_high_power = system_power is not None and system_power >= HIGH_POWER_W
    _high_power_streak = _high_power_streak + 1 if is_high_power else 0
    if is_high_power:
        high_power_procs = _get_top_processes(TOP_N_HIGH_POWER, min_cpu_pct=0.0)
    else:
        high_power_procs = []

    now_dt = datetime.now()
    return {
        "timestamp": now_dt.isoformat(),
        "epoch": int(now_dt.timestamp()),
        "hostname": os.uname().nodename,
        "kernel": os.uname().release,
        "uptime": str(timedelta(seconds=int(float(open("/proc/uptime").read().split()[0])))),
        "cpu": {
            "temp_c": cpu_temp,
            "power_w": cpu_power,
            "usage_pct": round(cpu_pct, 1),
            "per_core_pct": [round(c, 1) for c in cpu_per_core],
            "freq_mhz": round(cpu_freq.current, 0) if cpu_freq else None,
            "freq_max_mhz": round(cpu_freq.max, 0) if cpu_freq and cpu_freq.max else None,
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
        "high_power": {
            "is_high": is_high_power,
            "threshold_w": HIGH_POWER_W,
            "streak_samples": _high_power_streak,
            "processes": high_power_procs,
        },
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


# ── Persistence (Latest JSON, Daily CSV, SQLite) ─────────────────
CSV_FIELDS = [
    "Timestamp", "Battery_Pct", "Battery_State", "Battery_Power_W",
    "System_Power_W", "CPU_Usage_Pct", "CPU_Temp_C", "CPU_Power_W",
    "iGPU_Temp_C", "iGPU_Power_W", "dGPU_State", "dGPU_Temp_C",
    "dGPU_Power_W", "dGPU_Util_Pct", "RAM_Used_MB", "RAM_Percent",
    "Swap_Used_MB", "Top_Process", "Power_Flag", "High_Power_W",
    "High_Power_Processes",
]

# Columns added after the original schema shipped. A pre-existing daily CSV keeps
# its short header, so we rewrite it into its own day-scoped file rather than
# appending long rows under a short header (which silently corrupts alignment).
LEGACY_CSV_FIELDS = [
    "Timestamp", "Battery_Pct", "Battery_State", "Battery_Power_W",
    "System_Power_W", "CPU_Usage_Pct", "CPU_Temp_C", "CPU_Power_W",
    "iGPU_Temp_C", "iGPU_Power_W", "dGPU_State", "dGPU_Temp_C",
    "dGPU_Power_W", "dGPU_Util_Pct", "RAM_Used_MB", "RAM_Percent",
    "Swap_Used_MB", "Top_Process",
]


def write_latest_json(data: dict):
    """Atomically write latest snapshot for instant dashboard consumption."""
    tmp_path = RUN_DIR / "latest.json.tmp"
    final_path = RUN_DIR / "latest.json"
    try:
        with open(tmp_path, "w") as f:
            json.dump(data, f)
        os.chmod(tmp_path, 0o666)
        os.replace(tmp_path, final_path)
    except Exception as exc:
        print(f"[latest-json] error: {exc}", flush=True)


def _read_csv_header(path: Path) -> list[str] | None:
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return next(csv.reader(f), None)
    except Exception:
        return None


def _align_target(target: Path, date_str: str) -> Path:
    """
    Return a writable CSV path for today whose header matches CSV_FIELDS.

    A file left over from the pre-'High_Power' schema has fewer columns than
    CSV_FIELDS. Appending to it would write rows that no longer line up with the
    header, so we divert to a '-v2' sidecar and leave the original intact.
    """
    header = _read_csv_header(target)
    if header == CSV_FIELDS or header is None:
        return target
    if len(header) >= len(LEGACY_CSV_FIELDS):
        return target.with_name(f"{target.stem}-v2{target.suffix}")
    return target


def append_csv_log(data: dict):
    """Write log entry to daily CSV in /var/log/telemetry/ and ~/.local/share/telemetry/."""
    dt = datetime.fromisoformat(data["timestamp"])
    date_str = dt.strftime("%Y-%m-%d")
    high = data.get("high_power") or {}

    top_proc_str = "None"
    if data.get("top_processes"):
        tp = data["top_processes"][0]
        top_proc_str = f"{tp['name']}:{tp['cpu_pct']}%"

    row = {
        "Timestamp": dt.strftime("%Y-%m-%d %H:%M:%S"),
        "Battery_Pct": data["battery"]["percent"],
        "Battery_State": data["battery"]["state"],
        "Battery_Power_W": data["battery"]["power_w"],
        "System_Power_W": data["system_power_w"],
        "CPU_Usage_Pct": data["cpu"]["usage_pct"],
        "CPU_Temp_C": data["cpu"]["temp_c"],
        "CPU_Power_W": data["cpu"]["power_w"],
        "iGPU_Temp_C": data["igpu"]["temp_c"],
        "iGPU_Power_W": data["igpu"]["power_w"],
        "dGPU_State": data["dgpu"]["state"],
        "dGPU_Temp_C": data["dgpu"]["temp_c"],
        "dGPU_Power_W": data["dgpu"]["power_w"],
        "dGPU_Util_Pct": data["dgpu"]["util_pct"],
        "RAM_Used_MB": data["ram"]["used_mb"],
        "RAM_Percent": data["ram"]["percent"],
        "Swap_Used_MB": data["swap"]["used_mb"],
        "Top_Process": top_proc_str,
        "Power_Flag": "HIGH" if high.get("is_high") else "",
        "High_Power_W": high.get("threshold_w"),
        "High_Power_Processes": _format_top_processes(high.get("processes"), TOP_N_HIGH_POWER),
    }

    for target in (LOG_DIR / f"telemetry-{date_str}.csv", USER_LOG_DIR / f"telemetry-{date_str}.csv"):
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            target = _align_target(target, date_str)
            needs_header = not target.exists() or target.stat().st_size == 0
            with open(target, "a", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
                if needs_header:
                    writer.writeheader()
                writer.writerow(row)
            try:
                os.chmod(target, 0o666)
            except Exception:
                pass
        except Exception:
            pass


def insert_db_record(data: dict):
    """Insert into SQLite database for fast trend analytics."""
    try:
        top_proc_str = "None"
        if data.get("top_processes"):
            tp = data["top_processes"][0]
            top_proc_str = f"{tp['name']}:{tp['cpu_pct']}%"

        high = data.get("high_power") or {}

        conn = sqlite3.connect(DB_PATH, timeout=5)
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO telemetry (
                timestamp, iso_time, battery_pct, battery_state, battery_power_w,
                system_power_w, cpu_usage_pct, cpu_temp_c, cpu_power_w,
                igpu_temp_c, igpu_power_w, dgpu_state, dgpu_temp_c, dgpu_power_w,
                dgpu_util_pct, ram_used_mb, ram_percent, swap_used_mb, top_process,
                power_flag, high_power_w, high_power_processes, high_power_streak
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            data["epoch"],
            data["timestamp"],
            data["battery"]["percent"],
            data["battery"]["state"],
            data["battery"]["power_w"],
            data["system_power_w"],
            data["cpu"]["usage_pct"],
            data["cpu"]["temp_c"],
            data["cpu"]["power_w"],
            data["igpu"]["temp_c"],
            data["igpu"]["power_w"],
            data["dgpu"]["state"],
            data["dgpu"]["temp_c"],
            data["dgpu"]["power_w"],
            data["dgpu"]["util_pct"],
            data["ram"]["used_mb"],
            data["ram"]["percent"],
            data["swap"]["used_mb"],
            top_proc_str,
            "HIGH" if high.get("is_high") else None,
            high.get("threshold_w"),
            _format_top_processes(high.get("processes"), TOP_N_HIGH_POWER) or None,
            high.get("streak_samples") or 0,
        ))
        conn.commit()
        conn.close()
    except Exception as exc:
        print(f"[db-insert] error: {exc}", flush=True)


# ── Main Daemon Loop ─────────────────────────────────────────────
def main():
    print(f"[telemetry-logger] starting 24/7 daemon (interval: {LOG_INTERVAL}s)...", flush=True)
    init_db()

    # Prime psutil counters
    psutil.cpu_percent(interval=None)
    psutil.cpu_percent(interval=None, percpu=True)
    for p in psutil.process_iter(["pid", "cpu_percent"]):
        pass
    time.sleep(1)

    cycle = 0
    while True:
        try:
            data = collect_metrics()
            write_latest_json(data)
            append_csv_log(data)
            insert_db_record(data)

            # Prune records older than 30 days once every 500 cycles (~40 mins)
            cycle += 1
            if cycle % 500 == 0:
                try:
                    cutoff = int(time.time()) - (30 * 86400)
                    conn = sqlite3.connect(DB_PATH, timeout=5)
                    conn.cursor().execute("DELETE FROM telemetry WHERE timestamp < ?", (cutoff,))
                    conn.commit()
                    conn.close()
                except Exception:
                    pass
        except Exception as exc:
            print(f"[telemetry-logger] loop error: {exc}", flush=True)

        time.sleep(LOG_INTERVAL)


if __name__ == "__main__":
    main()
