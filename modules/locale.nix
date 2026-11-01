{ ... }:
{
  networking.hostName = "Thousand-Sunny"; # Define your hostname.
  time.timeZone = "Asia/Kolkata";
  # Select internationalisation properties.
  # NixOS expects the specific glibc format: "locale/encoding"
  # Note: en_IN does not use a .UTF-8 suffix in its name here
}
