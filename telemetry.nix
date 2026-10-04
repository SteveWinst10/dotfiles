{ config, pkgs, lib, ... }:

let
  telemetryPython = pkgs.python3.withPackages (ps: with ps; [
    psutil
    fastapi
    uvicorn
  ]);
in
{
  environment.systemPackages = with pkgs; [
    telemetryPython
    lm_sensors
    pciutils
  ];

  # System service running as root to access RAPL power counters (/sys/class/powercap)
  # and hwmon sensors, binding to 127.0.0.1:9999.
  systemd.services.laptop-telemetry = {
    description = "Laptop Telemetry — Unified Collector & Real-Time Dashboard";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [
      pkgs.lm_sensors
      pkgs.pciutils
    ] ++ lib.optional (config.hardware.nvidia ? package && config.hardware.nvidia.package != null) config.hardware.nvidia.package;

    environment = {
      TELEMETRY_HTML_PATH = "${./scripts/index.html}";
      TELEMETRY_HOST = "127.0.0.1";
      TELEMETRY_PORT = "9999";
      TELEMETRY_POLL_INTERVAL = "2.0";
      TELEMETRY_POWER_THRESH_W = "15.0";
      TELEMETRY_CPU_THRESH_PCT = "45.0";
    };

    serviceConfig = {
      ExecStart = "${telemetryPython}/bin/python3 ${./scripts/laptop-telemetry.py}";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  # Hook the dashboard up to your ZSH aliases
  programs.zsh.shellAliases = {
    show-telemetry = "xdg-open http://localhost:9999";
  };
}
