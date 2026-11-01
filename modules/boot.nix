{ config, pkgs, lib, ... }:
{
  # ── Boot, kernel & memory management ───────────────────────────
  systemd.oomd.enable = true;
  zramSwap.enable = true;
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 16 * 1024; # 16 GiB
    }
  ];
  # Bootloader.
  boot = {
    loader = {
      systemd-boot = {
        enable = true;
        # Keep the ESP from filling up with old kernels/initrds.
        configurationLimit = 10;
      };
      efi.canTouchEfiVariables = true;
    };

    # Latest kernel. Out-of-tree modules (nvidia, kvmfr) can break on new
    # kernels; if that happens, boot the previous generation, or switch this
    # to pkgs.linuxPackages (LTS).
    kernelPackages = pkgs.linuxPackages_latest;

    kernelParams = [
      "amd_iommu=on"
      #"vfio-pci.ids=10de:28e0,10de:22be"
      "8250.nr_uarts=0" # unrelated to VFIO; disables unused UART ports
    ];

    # Looking Glass shared-memory device (VFIO guest)
    kernelModules = [ "kvmfr" ];
    extraModulePackages = [ config.boot.kernelPackages.kvmfr ];
    extraModprobeConfig = ''
      options kvmfr static_size_mb=64
      options snd-hda-intel patch=hda-jack.fw
    '';

    # IP forwarding — required for bridged VM (libvirtd) and container (podman)
    # networking; see the Virtualisation and Containers sections below.
    kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
    };
  };

}
