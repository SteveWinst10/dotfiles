{ config, pkgs, lib, ... }:

let
  telemetryPython = pkgs.python3.withPackages (ps: with ps; [
    psutil
    fastapi
    uvicorn
  ]);

  # Shared preamble for the user-level helpers. `systemctl --user` needs a session
  # bus; without XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS it fails outright, and a
  # naive script that ignores the exit code will happily report success while the
  # service keeps running. Reconstructing the bus path is what makes these work
  # from cron, TTYs, ssh and inside nixos-rebuild shells.
  userSystemctlEnv = ''
    uid="$(id -u)"
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$uid}"
    if [ ! -S "$XDG_RUNTIME_DIR/systemd/private" ]; then
      unset DBUS_SESSION_BUS_ADDRESS
    else
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    fi
  '';

  # On-demand launcher script for the dashboard web server
  showTelemetryScript = pkgs.writeShellScriptBin "show-telemetry" ''
    set -euo pipefail
    ${userSystemctlEnv}

    URL="http://127.0.0.1:9999"

    echo "Starting Laptop Telemetry Dashboard..."
    if ! systemctl --user start laptop-telemetry-dashboard; then
      echo "ERROR: failed to start laptop-telemetry-dashboard" >&2
      echo "  systemctl --user status laptop-telemetry-dashboard" >&2
      exit 1
    fi

    # Wait up to 5s for the dashboard to answer before opening a browser
    for _ in $(seq 1 20); do
      if ${pkgs.curl}/bin/curl -s --max-time 1 "$URL/api/snapshot" > /dev/null 2>&1; then
        echo "Opening Telemetry Dashboard: $URL"
        exec ${pkgs.xdg-utils}/bin/xdg-open "$URL"
      fi
      sleep 0.25
    done

    echo "ERROR: dashboard did not respond on $URL" >&2
    systemctl --user --no-pager status laptop-telemetry-dashboard >&2 || true
    exit 1
  '';

  # Stop the dashboard (and, with --all, the 24/7 logger). Verifies the unit is
  # actually gone, then falls back to killing the process directly, so it can no
  # longer lie about having stopped something.
  stopTelemetryScript = pkgs.writeShellScriptBin "stop-telemetry" ''
    set -uo pipefail
    ${userSystemctlEnv}

    DASHBOARD=laptop-telemetry-dashboard
    LOGGER=laptop-telemetry-logger

    stop_unit() {
      local scope="$1" unit="$2"
      echo "Stopping $unit ($scope)..."
      systemctl "$scope" --no-block stop "$unit" 2>&1 | sed 's/^/  /' || true
      systemctl "$scope" reset-failed "$unit" > /dev/null 2>&1 || true

      for _ in $(seq 1 20); do
        if ! systemctl "$scope" is-active --quiet "$unit"; then
          echo "  OK: $unit is stopped."
          return 0
        fi
        sleep 0.25
      done

      # systemctl reported success but the unit is still running (or we could
      # never talk to the bus at all). Fall back to signalling the process.
      echo "  $unit still running - falling back to SIGTERM."
      local pids
      pids="$(systemctl "$scope" show -p MainPID --value "$unit" 2>/dev/null || true)"
      if [ -n "''${pids:-}" ] && [ "$pids" != "0" ]; then
        kill -TERM "$pids" 2>/dev/null || true
      fi
      pkill -TERM -f 'laptop-telemetry-(server|logger)\.py' 2>/dev/null || true

      for _ in $(seq 1 20); do
        systemctl "$scope" is-active --quiet "$unit" || { echo "  OK: $unit is stopped."; return 0; }
        sleep 0.25
      done

      pkill -KILL -f 'laptop-telemetry-(server|logger)\.py' 2>/dev/null || true
      sleep 0.5
      if systemctl "$scope" is-active --quiet "$unit"; then
        echo "  ERROR: could not stop $unit." >&2
        return 1
      fi
      echo "  OK: $unit is stopped."
    }

    rc=0
    stop_unit --user "$DASHBOARD" || rc=1

    if [ "''${1:-}" = "--all" ]; then
      echo
      echo "Stopping the 24/7 background logger too (--all)..."
      if systemctl stop "$LOGGER" 2>/dev/null; then
        rc=0
        echo
        echo "Re-enable later with: sudo systemctl enable --now $LOGGER"
      else
        echo "  NOTE: could not stop $LOGGER - run: sudo systemctl stop $LOGGER" >&2
      fi
      echo
      echo "All telemetry services stopped."
    else
      echo
      echo "Dashboard stopped. The 24/7 logger is still running (use 'stop-telemetry --all' to stop it too)."
    fi
    exit $rc
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
      TELEMETRY_USER_LOG_DIR = "/home/steve/.local/share/telemetry";
      # System draw at/above which a sample is flagged HIGH and logs its top 5 processes.
      TELEMETRY_HIGH_POWER_W = "20.0";
      # Discard readings above this instead of logging them (guards RAPL artefacts).
      TELEMETRY_MAX_PLAUSIBLE_W = "400.0";
      TELEMETRY_TOP_N_HIGH_POWER = "5";
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
      KillSignal = "SIGINT";
      TimeoutStopSec = "10";
    };
    environment = {
      TELEMETRY_HTML_PATH = "${./scripts/index.html}";
      TELEMETRY_LOG_DIR = "/var/log/telemetry";
      TELEMETRY_RUN_DIR = "/run/telemetry";
      TELEMETRY_USER_LOG_DIR = "/home/steve/.local/share/telemetry";
      TELEMETRY_HIGH_POWER_W = "20.0";
      TELEMETRY_MAX_PLAUSIBLE_W = "400.0";
    };
  };

  # Hook the scripts up to ZSH aliases
  programs.zsh.shellAliases = {
    show-telemetry = "${showTelemetryScript}/bin/show-telemetry";
    stop-telemetry = "${stopTelemetryScript}/bin/stop-telemetry";
  };
}
