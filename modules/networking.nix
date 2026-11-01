{ config, pkgs, lib, ... }:
{
  # ── Networking ──────────────────────────────────────────────────
  #networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary

  # Enable networking
  networking.networkmanager.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;
  networking.firewall = {

    # Some LAN games specifically need these for discovery
    interfaces."wlan0" = {
      # only if your NM hotspot runs here
      allowedUDPPorts = [
        53
        67
      ];
      allowedTCPPorts = [ 53 ];
    };
    allowedUDPPorts = [ 53317 ]; # For mDNS (finding each other)
    allowedTCPPorts = [ 53317 ];

    interfaces."tailscale0".allowedTCPPorts = [ 22 ];
  };

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
  };
  # Tailscale is enabled but intentionally not started automatically on boot;
  # start it manually with `systemctl start tailscaled` when needed.
  systemd.services.tailscaled = {
    enable = true;
    #restartIfChanged = false;
    #serviceConfig.RemainAfterExit = false;
    wantedBy = lib.mkForce [ ];
  };

}
