{ config, pkgs, lib, ... }:
{
  # ── Graphics / NVIDIA ───────────────────────────────────────────

  # Enable OpenGL
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    open = true;
    # Modesetting is required.
    modesetting.enable = true;
    powerManagement.enable = true;
    powerManagement.finegrained = true;

    # Nvidia power management. Experimental, and can cause sleep/suspend to fail.
    # Enable this if you have graphical corruption issues or application crashes after waking
    # up from sleep. This fixes it by saving the entire VRAM memory to /tmp/ instead
    # Support is limited to the Turing and later architectures. Full list of
    # supported GPUs is at:
    # https://github.com/NVIDIA/open-gpu-kernel-modules#compatible-gpus
    # Only available from driver 515.43.04+

    # Enable the Nvidia settings menu,
    # accessible via `nvidia-settings`.
    nvidiaSettings = true;

    # Optionally, you may need to select the appropriate driver version for your specific GPU.
    package = config.boot.kernelPackages.nvidiaPackages.latest;
    prime = {
      offload.enable = true;
      offload.enableOffloadCmd = true;
      amdgpuBusId = "PCI:101:0:0";
      nvidiaBusId = "PCI:100:0:0";
    };

  };
  # ── Virtualisation & GPU passthrough (VFIO) ─────────────────────
  virtualisation.libvirtd = {
    enable = true;
    # (Optional) Enable file sharing between host and guest (virtiofs)
    qemu.vhostUserPackages = with pkgs; [ virtiofsd ];
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
    };
  };
  # Enable virt-manager GUI frontend
  programs.virt-manager.enable = true;
  # (Optional) Enable USB Redirection inside Virt-Manager
  virtualisation.spiceUSBRedirection.enable = true;

  services.udev.extraRules = ''
    SUBSYSTEM=="kvmfr", OWNER="steve", GROUP="libvirtd", MODE="0660"
  '';
  # ── Containers ──────────────────────────────────────────────────
  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    # Create a `docker` alias for podman, to use it as a drop-in replacement
    # Required for containers under podman-compose to be able to talk to each other.
    defaultNetwork.settings.dns_enabled = true;
  };

}
