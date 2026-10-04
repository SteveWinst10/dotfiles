{ config, pkgs, lib, ... }:

let
  telemetryPython = pkgs.python3.withPackages (ps: with ps; [
    psutil
    fastapi
    uvicorn
  ]);

  # On-demand launcher script for the dashboard web server
  showTelemetryScript = pkgs.writeShellScriptBin "show-telemetry" ''
    URL="http://127.0.0.1:9999"

    echo "Starting Laptop Telemetry Dashboard..."
    systemctl --user start laptop-telemetry-dashboard

    # Wait up to 3s for dashboard to respond
    for i in {1..12}; do
      if ${pkgs.curl}/bin/curl -s "$URL/api/snapshot" > /dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done

    echo "Opening Telemetry Dashboard: $URL"
    ${pkgs.xdg-utils}/bin/xdg-open "$URL"
  '';

  # Clean script to stop the on-demand dashboard server
  stopTelemetryScript = pkgs.writeShellScriptBin "stop-telemetry" ''
    echo "Stopping Laptop Telemetry Dashboard..."
    systemctl --user stop laptop-telemetry-dashboard
    echo "Dashboard stopped. (24/7 background logger remains running)."
  '';
in
{
  environment.systemPackages = with pkgs; [
    telemetryPython
    lm_sensors
    pciutils
    showTelemetryScript
    stopTelemetryScript
  ];

  # 24/7 Background System Logger Daemon
  # Runs continuously as root to monitor RAPL energy counters, hwmon sensors,
  # and dGPU power safely without waking it from D3cold deep sleep.
  systemd.services.laptop-telemetry-logger = {
    description = "Laptop Telemetry — 24/7 Background System Logger Daemon";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [
      pkgs.lm_sensors
      pkgs.pciutils
    ] ++ lib.optional (config.hardware.nvidia ? package && config.hardware.nvidia.package != null) config.hardware.nvidia.package;

    environment = {
      TELEMETRY_LOG_INTERVAL = "5.0";
      TELEMETRY_LOG_DIR = "/var/log/telemetry";
      TELEMETRY_RUN_DIR = "/run/telemetry";
    };

    serviceConfig = {
      ExecStart = "${telemetryPython}/bin/python3 ${./scripts/laptop-telemetry-logger.py}";
      Restart = "always";
      RestartSec = "5s";
      RuntimeDirectory = "telemetry";
      LogsDirectory = "telemetry";
    };
  };

  # On-Demand Dashboard User Service (NOT enabled at boot)
  # Started by running `show-telemetry`, stopped by `stop-telemetry`
  systemd.user.services.laptop-telemetry-dashboard = {
    description = "Laptop Telemetry — On-Demand Dashboard Web Server";
    serviceConfig = {
      ExecStart = "${telemetryPython}/bin/python3 ${./scripts/laptop-telemetry-server.py}";
      Restart = "no";
    };
    environment = {
      TELEMETRY_HTML_PATH = "${./scripts/index.html}";
      TELEMETRY_LOG_DIR = "/var/log/telemetry";
      TELEMETRY_RUN_DIR = "/run/telemetry";
    };
  };

  # Hook the scripts up to ZSH aliases
  programs.zsh.shellAliases = {
    show-telemetry = "${showTelemetryScript}/bin/show-telemetry";
    stop-telemetry = "${stopTelemetryScript}/bin/stop-telemetry";
  };
}
