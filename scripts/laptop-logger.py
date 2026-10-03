#!/usr/bin/env python3
import os, time, subprocess, csv, glob
from datetime import datetime
import psutil

LOG_DIR = os.path.expanduser("~/.local/share/telemetry")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "laptop_telemetry.csv")

# Thresholds are now managed declaratively via NixOS environment variables
POWER_THRESHOLD_BATTERY_W = float(os.getenv("TELEMETRY_POWER_THRESH_W", 18.0))
CPU_THRESHOLD_PCT = float(os.getenv("TELEMETRY_CPU_THRESH_PCT", 40.0))
MAX_LOG_SIZE_BYTES = 10 * 1024 * 1024  # 10 MB limit for log rotation

def is_nvidia_active():
    for path in glob.glob("/sys/bus/pci/devices/*/power/runtime_status"):
        try:
            vendor_path = os.path.join(os.path.dirname(path), "vendor")
            if os.path.exists(vendor_path):
                with open(vendor_path, "r") as f:
                    if f.read().strip() == "0x10de":
                        with open(path, "r") as status_file:
                            return status_file.read().strip() == "active"
        except Exception:
            pass
    return False

def get_battery_info():
    battery = psutil.sensors_battery()
    pct = battery.percent if battery else 0
    plugged = battery.power_plugged if battery else False
    status = "AC" if plugged else "Battery"
    
    power_w = 0.0
    for bat in ["BAT0", "BAT1"]:
        power_path = f"/sys/class/power_supply/{bat}/power_now"
        if os.path.exists(power_path):
            try:
                with open(power_path, "r") as f:
                    power_w = float(f.read().strip()) / 1000000.0
                break
            except Exception:
                pass
    return pct, status, power_w

def get_cpu_temp():
    temps = psutil.sensors_temperatures()
    for key in ['coretemp', 'k10temp', 'cpu_thermal', 'acpitz']:
        if key in temps and len(temps[key]) > 0:
            return temps[key][0].current
    return 0.0

def get_gpu_info():
    if not is_nvidia_active():
        return 0.0, 0.0 
    try:
        res = subprocess.run(
            ["nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=1
        )
        if res.returncode == 0 and res.stdout.strip():
            usage, temp = res.stdout.strip().split(',')
            return float(usage), float(temp)
    except Exception:
        pass
    return 0.0, 0.0

def get_high_power_causes():
    procs = []
    for p in psutil.process_iter(['name', 'cpu_percent']):
        try:
            cpu = p.info['cpu_percent'] or 0.0
            if cpu > 3.0:
                procs.append((p.info['name'], cpu))
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    procs.sort(key=lambda x: x[1], reverse=True)
    top_3 = [f"{name} ({cpu:.0f}%)" for name, cpu in procs[:3]]
    return ", ".join(top_3) if top_3 else "High System Load"

def init_csv():
    if not os.path.exists(LOG_FILE):
        with open(LOG_FILE, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow([
                "Timestamp", "Battery_Pct", "Power_Source", "Power_Draw_W",
                "CPU_Usage_Pct", "CPU_Temp_C", "RAM_Used_MB", 
                "GPU_Usage_Pct", "GPU_Temp_C", "Power_Status", "High_Power_Causes"
            ])

def rotate_log_if_needed():
    if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > MAX_LOG_SIZE_BYTES:
        backup_file = f"{LOG_FILE}.{datetime.now().strftime('%Y%m%d%H%M%S')}.bak"
        os.rename(LOG_FILE, backup_file)
        init_csv()

def main():
    init_csv()
    psutil.cpu_percent(interval=None)
    time.sleep(1)

    while True:
        rotate_log_if_needed()
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        bat_pct, power_src, power_w = get_battery_info()
        cpu_pct = psutil.cpu_percent(interval=None)
        cpu_temp = get_cpu_temp()
        ram_mb = psutil.virtual_memory().used // (1024 * 1024)
        gpu_pct, gpu_temp = get_gpu_info()

        is_above_normal = (power_src == "Battery" and power_w > POWER_THRESHOLD_BATTERY_W) or (cpu_pct > CPU_THRESHOLD_PCT)
        power_status = "ABOVE NORMAL" if is_above_normal else "Normal"
        causes = get_high_power_causes() if is_above_normal else "None"

        with open(LOG_FILE, "a", newline="") as f:
            writer = csv.writer(f)
            writer.writerow([
                now, bat_pct, power_src, f"{power_w:.2f}",
                f"{cpu_pct:.1f}", f"{cpu_temp:.1f}", ram_mb,
                f"{gpu_pct:.1f}", f"{gpu_temp:.1f}", power_status, causes
            ])
        time.sleep(5)

if __name__ == "__main__":
    main()
