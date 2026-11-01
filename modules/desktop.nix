{ config, pkgs, lib, ... }:
{
  # ── Desktop environment & window managers ──────────────────────
  # Enable the X11 windowing system.
  # You can disable this if you're only using the Wayland session.
  # Enable the KDE Plasma Desktop Environment.

  services.greetd = {
    enable = true;
    settings = {
      default_session =
        let
          # This variable only exists inside this specific block!
          dir = "${config.services.displayManager.sessionData.desktops}/share";
        in
        {
          command = "${lib.getExe pkgs.tuigreet} --time --asterisks --user-menu --sessions ${dir}/wayland-sessions --xsessions ${dir}/xsessions";
          user = "greeter";
        };
    };
  };

  services.desktopManager.plasma6.enable = true;
  programs.kdeconnect.enable = true;
  services.displayManager.defaultSession = lib.mkForce "niri";
  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # enable Sway window manager
  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
  };
  programs.niri.enable = true;
  xdg.portal.config.niri = {
    "org.freedesktop.impl.portal.FileChooser" = [ "kde" ];
  };

  services.xserver.windowManager.i3.enable = true;

}
