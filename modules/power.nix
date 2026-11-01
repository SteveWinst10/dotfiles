{ config, pkgs, lib, ... }:
{
  # ── Misc services & developer conveniences ─────────────────────
  # Enable the gnome-keyring secrets vault.
  # Will be exposed through DBus to programs willing to store secrets.
  services.gnome.gnome-keyring.enable = true;
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    silent = true;
  };
  programs.nix-ld.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false; # PAM can still accept passwords otherwise
      PermitRootLogin = "no";
      AllowUsers = [ "steve" ]; # optional: stop `hat` from SSHing in
    };
  };

  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
    # Bound to all interfaces and reachable via the firewall rule above —
    # confirm this LAN-wide exposure is intended (vs. localhost + Tailscale).
    host = "0.0.0.0";
    port = 11434;
    # Fine-grained power management (D3cold) keeps /dev/nvidia* absent until a
    # CUDA client wakes the GPU.  Setting power/control to "on" for the duration
    # of the Ollama service prevents the GPU from sleeping out from under it.
    environmentVariables = {
      CUDA_VISIBLE_DEVICES = "0";
    };
  };
  systemd.services.ollama = {
    wantedBy = lib.mkForce [ ];
    serviceConfig = {
      ExecStartPre = [
        "+/bin/sh -c 'echo on > /sys/bus/pci/devices/0000:64:00.0/power/control'"
      ];
      ExecStopPost = [
        "+/bin/sh -c 'echo auto > /sys/bus/pci/devices/0000:64:00.0/power/control'"
      ];
    };
  };

  systemd.settings = {
    Manager = {
      DefaultTimeoutStopSec = "10s";
    };
  };

  #power management
  services.power-profiles-daemon.enable = true;
  services.printing.browsed.enable = false;
  # Install firefox.
  programs.firefox.enable = true;

}
