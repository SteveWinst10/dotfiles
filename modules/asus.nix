{ config, pkgs, lib, ... }:
{
  # ── Hardware & firmware ─────────────────────────────────────────
  hardware.enableAllFirmware = true;
  services.fstrim.enable = true; # periodic SSD TRIM
  services.fwupd.enable = true; # firmware updates (LVFS)
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = false;
    settings = {
      General = {
        # Shows battery charge of connected devices on supported
        # Bluetooth adapters. Defaults to 'false'.
        Experimental = true;
        # When enabled other devices can connect faster to us, however
        # the tradeoff is increased power consumption. Defaults to
        # 'false'.
      };
      Policy = {
        # Enable all controllers when they are found. This includes
        # adapters present on start as well as adapters that are plugged
        # in later on. Defaults to 'true'.
        AutoEnable = true;
      };
    };
  };
  services.input-remapper.enable = true; # convert mouse/kb to joystick
  services.udev.packages = with pkgs; [ platformio-core.udev ];

}
