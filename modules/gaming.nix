{ config, pkgs, lib, ... }:
{
  # ── Gaming ──────────────────────────────────────────────────────
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
    extraCompatPackages = [
      pkgs.proton-ge-bin
    ];
  };
  programs.gamescope = {
    enable = true;

    # Acts as the toggle for gamescope-wsi. It ensures the Vulkan layer
    # is injected and built right along with Gamescope.
    enableWsi = true;

    # Grants the binary capability to prioritize its thread for smoother frame pacing
    capSysNice = true;

    # Optional: You can hardcode default arguments passed to every gamescope instance
    args = [
      "-W 1920"
      "-H 1200"
      "-r 144"
    ];
  };

}
