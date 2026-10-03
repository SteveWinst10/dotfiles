{ config, pkgs, lib, ... }:

let
  telemetryPython = pkgs.python3.withPackages (ps: with ps; [
    psutil
    pandas
    plotly
    streamlit
  ]);
in
{
  environment.systemPackages = with pkgs; [
    telemetryPython
    lm_sensors
    pciutils
  ];

  # The systemd user service natively references the script from your dotfiles repo.
  # Nix will automatically copy the script to the read-only Nix store on build.
  systemd.user.services.laptop-telemetry = {
    description = "Laptop Telemetry & Power Logger";
    wantedBy = [ "default.target" ];
    
    environment = {
      TELEMETRY_POWER_THRESH_W = "15.0";
      TELEMETRY_CPU_THRESH_PCT = "45.0";
    };
    
    serviceConfig = {
      # Path interpolation `${./...}` ensures it points to the Nix store
      ExecStart = "${telemetryPython}/bin/python3${./scripts/laptop-logger.py}";
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # Hook the dashboard up to your ZSH aliases
  programs.zsh.shellAliases = {
    show-telemetry = "${telemetryPython}/bin/streamlit run${./scripts/laptop-dashboard.py}";
  };
}
