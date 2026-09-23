# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, inputs, ... }:
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # ── Nix & package management ──────────────────────────────────
  nix.optimise.automatic = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # ── System identity, locale & time ─────────────────────────────
  networking.hostName = "Thousand Sunny"; # Define your hostname.
  time.timeZone = "Asia/Kolkata";
  # Select internationalisation properties.
  # NixOS expects the specific glibc format: "locale/encoding"
  # Note: en_IN does not use a .UTF-8 suffix in its name here

  # ── Boot, kernel & memory management ───────────────────────────
  systemd.oomd.enable = true;
  zramSwap.enable = true;
  swapDevices = [{
    device = "/var/lib/swapfile";
    size = 16*1024; # 16 GiB
  }];
  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_zen;

  # ── Networking ──────────────────────────────────────────────────
  #networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # IP forwarding — required for bridged VM (libvirtd) and container (podman)
  # networking; see the Virtualisation and Containers sections below.
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };

  # Open ports in the firewall.
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;
  networking.firewall = {
    # This makes the hotspot interface a "free-fire" zone for local data
    trustedInterfaces = [ "wlan0" ];

    # Some LAN games specifically need these for discovery
    allowedUDPPortRanges = [
      { from = 1714; to = 1764; } #KDE Connect
    ];
    allowedUDPPorts = [ 53 67 5353 53317 ]; # For mDNS (finding each other)
    allowedTCPPortRanges = [
      { from = 1714; to = 1764; } #KDE Connect
    ];
    allowedTCPPorts = [
      53 4318 53317
      11434 # ollama — see the Misc services section; bound to 0.0.0.0,
            # so this exposes the API to the whole LAN, not just localhost
    ];
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

  # (disabled) local DNS/DHCP server for a lab network. Kept for reference —
  # re-enable by uncommenting if the lab network setup is needed again.
  /*services.dnsmasq = {
      enable = false;

      # Declarative settings (translates directly into dnsmasq.conf syntax)
      settings = {
        # 1. Network Interfaces to listen on
        interface = [ "eth0" "eth1" ];

        # 2. Upstream DNS Servers (e.g., Cloudflare/Quad9)
        server = [ "1.1.1.1" "9.9.9.9" ];

        # 3. Local Domain & DHCP Settings
        domain = "lab.local";
        local = "/lab.local/";

        # Set dynamic IP range, subnet mask, and lease duration (12 hours)
        dhcp-range = [ "192.168.1.50,192.168.1.200,255.255.255.0,12h" ];

        # Set Default Gateway / Router IP announced via DHCP
        dhcp-option = [ "option:router,192.168.1.1" ];

        # 4. Static IP Assignments (MAC Address -> Hostname -> IP)
        dhcp-host = [
          "aa:bb:cc:dd:ee:01,nas,192.168.1.10"
          "aa:bb:cc:dd:ee:02,proxmox,192.168.1.20"
        ];

        # 5. Local DNS Overrides (Map arbitrary domain names to IPs)
        address = [
          "/router.lab.local/192.168.1.1"
        ];

        # 6. Security and Optimization
        domain-needed = true; # Don't forward plain names without a domain
        bogus-priv = true;    # Don't forward reverse-DNS lookups for private IP ranges
        cache-size = 1000;    # Number of cached DNS queries in RAM
        extraConfig = ''
            bind-interfaces
            except-interface=virbr0
          '';
      };
    };
  */

  # ── Security, sandboxing & packet analysis tools ───────────────
  programs.wireshark = {
    enable = true;
    package = pkgs.wireshark;
    usbmon.enable = true;
  };
  security.wrappers.sniffnet = {
    source = "${pkgs.sniffnet}/bin/sniffnet";
    capabilities = "cap_net_raw,cap_net_admin+eip";
    owner = "root";
    group = "root";
  };
  programs.firejail = {
    enable = true;
    wrappedBinaries = {
      packettracer9 = {
        executable = lib.getExe pkgs.cisco-packet-tracer_9;

        # Will still want a .desktop entry as the package is not directly added

        extraArgs = [
          # This should make it run in isolated netns, preventing internet access
          "--net=none"

          # firejail is only needed for network isolation so no futher profile is needed
          "--noprofile"

          # Packet tracer doesn't play nice with dark QT themes so this
          # should unset the theme. Uncomment if you have this issue.
          # ''--env=QT_STYLE_OVERRIDE=""''
        ];
      };
    };
  };

  # ── Users & shell ───────────────────────────────────────────────
  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.steve = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "Steve Winston";
    extraGroups = [ "networkmanager" "wheel" "docker" "wireshark" "libvirtd" ];
    packages = with pkgs; [
      kdePackages.kate
    #  thunderbird
    ];
  };
  users.users.hat = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "Rest of the Team";
    extraGroups = [ "networkmanager" "wheel" ];
  };
  users.defaultUserShell = pkgs.zsh;

  environment = {
    shells = [ pkgs.zsh ];
    variables = {
      EDITOR = "micro";
      SYSTEMD_EDITOR = "micro";
      VISUAL = "micro";
    };
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
    histSize = 10000;
    shellAliases = {
      ls = "eza";
      cd = "z";
      cat = "bat";
      df = "duf";
      nixcedit = "micro ~/.dotfiles/configuration.nix";
      nixhedit = "micro ~/.dotfiles/hardware-configuration.nix";
      update = "sudo nixos-rebuild switch --flake ~/.dotfiles/";
    };
  };
  programs.starship.enable = true;
  programs.zoxide.enableZshIntegration = true;

  # ── Desktop environment & window managers ──────────────────────
  # Enable the X11 windowing system.
  # You can disable this if you're only using the Wayland session.
  services.xserver.enable = true;
  # Enable the KDE Plasma Desktop Environment.
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;
  services.displayManager.defaultSession = lib.mkForce "plasma";
  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };
  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  programs.hyprland = {
    enable = false;
    # Ensures the wrapper loads the exact pinned flake binary
    package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
  };
  # (disabled) old pinned-version override experiment, and an alternate
  # hyprland.enable form — kept for reference only.
  # pkgs.hyprland.overrideAttrs (finalAttrs: previousAttrs: {
  # 	version = "0.49";
  # });
  #programs.hyprland = {
  #    enable = true;
  #    withUWSM = false; # recommended for most users
  #    xwayland.enable = true; # Xwayland can be disabled.
  #  };
  # enable Sway window manager
  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
  };
  programs.niri.enable = true;
  services.xserver.windowManager.i3.enable = true;

  # ── Audio ───────────────────────────────────────────────────────
  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  security.polkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };
  programs.dconf.enable = true; # for easyeffects

  # **********************User Apps**********************

  # Spicetify
  
  programs.spicetify =
  let
    spicePkgs = inputs.spicetify-nix.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  in
  {
      enable = true;
  
      theme = spicePkgs.themes.dribbblish;
  	  colorScheme = "catppuccin-mocha";
      enabledExtensions = with spicePkgs.extensions; [
        adblock
        shuffle
        groupSession
        powerBar
        seekSong
        keyboardShortcut
        fullAppDisplay
        volumePercentage
        oldLikeButton
        ytVideo
        sessionStats
        focusMode
        sidebarCustomizer
      ];
      enabledCustomApps = with spicePkgs.apps; [
          ncsVisualizer
          lyricsPlus
          betterLibrary
        ];
      enabledSnippets = with spicePkgs.snippets; [
          rotatingCoverart
          pointer
        ];
    };

  # ── Fonts ───────────────────────────────────────────────────────
  fonts = {
    enableDefaultPackages = true;
    fontconfig = {
      enable = true;
      defaultFonts = {
        monospace = ["Fira Code" "0xProto Nerd Font" "Lilex"];
        sansSerif = ["Fira Code" "Lilex" "0xProto Nerd Font"];
        serif =  ["Fira Code" "Lilex" "0xProto Nerd Font"];
      };
    };

    packages = with pkgs; [
      lilex
      nerd-fonts._0xproto
      fira-code
    ];
  };

  # ── Hardware & firmware ─────────────────────────────────────────
  hardware.enableAllFirmware = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
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

  # ── Graphics / NVIDIA ───────────────────────────────────────────
  #boot.initrd.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];

  # Enable OpenGL
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
  services.lact.enable = true;
  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = ["nvidia"];
  hardware.nvidia = {

    # Modesetting is required.
    modesetting.enable = true;

    # Nvidia power management. Experimental, and can cause sleep/suspend to fail.
    # Enable this if you have graphical corruption issues or application crashes after waking
    # up from sleep. This fixes it by saving the entire VRAM memory to /tmp/ instead
    # Support is limited to the Turing and later architectures. Full list of
    # supported GPUs is at:
    # https://github.com/NVIDIA/open-gpu-kernel-modules#compatible-gpus
    # Only available from driver 515.43.04+

    open = true;
    # Enable the Nvidia settings menu,
    # accessible via `nvidia-settings`.
    nvidiaSettings = true;

    # Optionally, you may need to select the appropriate driver version for your specific GPU.
    package = config.boot.kernelPackages.nvidiaPackages.latest;
  };
  hardware.nvidia.prime = {
    offload.enable = true;
    offload.enableOffloadCmd = true;
    # Make sure to use the correct Bus ID values for your system!
    amdgpuBusId = "PCI:101:0:0";
    nvidiaBusId = "PCI:100:0:0";
    # amdgpuBusId = "PCI:54:0:0"; For AMD GPU
  };
  # (disabled) older nouveau-blacklisting approach, superseded by the
  # hardware.nvidia config above. Kept for reference only.
  /* boot.extraModprobeConfig = ''
        blacklist nouveau
        options nouveau modeset=0
      '';

      services.udev.extraRules = ''
        # Remove NVIDIA USB xHCI Host Controller devices, if present
        ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c0330", ATTR{power/control}="auto", ATTR{remove}="1"
        # Remove NVIDIA USB Type-C UCSI devices, if present
        ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c8000", ATTR{power/control}="auto", ATTR{remove}="1"
        # Remove NVIDIA Audio devices, if present
        ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", ATTR{power/control}="auto", ATTR{remove}="1"
        # Remove NVIDIA VGA/3D controller devices
        ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", ATTR{power/control}="auto", ATTR{remove}="1"
      '';
      boot.blacklistedKernelModules = [ "nouveau" "nvidia" "nvidia_drm" "nvidia_modeset" ];
  */

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

  boot.kernelParams = [
    "amd_iommu=on" # or "amd_iommu=on"
    #"vfio-pci.ids=10de:28e0,10de:22be"
    "8250.nr_uarts=0" # unrelated to VFIO; disables unused UART ports
  ];
  boot.kernelModules = [ "kvmfr" ];
  boot.extraModulePackages = [ config.boot.kernelPackages.kvmfr ];
  boot.extraModprobeConfig = ''
      options kvmfr static_size_mb=64
    '';
  services.udev.extraRules = ''
      SUBSYSTEM=="kvmfr", OWNER="steve", GROUP="libvirtd", MODE="0660"
    '';
  system.activationScripts.libvirt-hooks.text = ''
      mkdir -p /var/lib/libvirt/hooks/qemu.d/archlinux/prepare/begin
      mkdir -p /var/lib/libvirt/hooks/qemu.d/archlinux/release/end
  
      # Main hook router
      cat <<'EOF' > /var/lib/libvirt/hooks/qemu
      #!/run/current-system/sw/bin/bash
      GUEST_NAME="$1"
      HOOK_NAME="$2"
      STATE_NAME="$3"
      HOOKPATH="/var/lib/libvirt/hooks/qemu.d/$GUEST_NAME/$HOOK_NAME/$STATE_NAME"
      if [ -f "$HOOKPATH" ]; then
        eval "$HOOKPATH" "$@"
      elif [ -d "$HOOKPATH" ]; then
        for file in "$HOOKPATH"/*; do
          [ -x "$file" ] && eval "$file" "$@"
        done
      fi
      EOF
      chmod +x /var/lib/libvirt/hooks/qemu
  
      # Detach NVIDIA dGPU (Runs before VM starts)
      cat <<'EOF' > /var/lib/libvirt/hooks/qemu.d/archlinux/prepare/begin/bind_vfio.sh
      #!/run/current-system/sw/bin/bash
      supergfxctl -m Vfio
      EOF
      chmod +x /var/lib/libvirt/hooks/qemu.d/archlinux/prepare/begin/bind_vfio.sh
  
      # Reattach NVIDIA dGPU (Runs after VM shuts down)
      cat <<'EOF' > /var/lib/libvirt/hooks/qemu.d/archlinux/release/end/revert_vfio.sh
      #!/run/current-system/sw/bin/bash
      supergfxctl -m Hybrid
      EOF
      chmod +x /var/lib/libvirt/hooks/qemu.d/archlinux/release/end/revert_vfio.sh
    '';

  # ── Containers ──────────────────────────────────────────────────
  hardware.nvidia-container-toolkit.enable = true;
  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    # Create a `docker` alias for podman, to use it as a drop-in replacement
    # Required for containers under podman-compose to be able to talk to each other.
    defaultNetwork.settings.dns_enabled = true;
  };

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

  # ── ASUS laptop services ────────────────────────────────────────
  services.supergfxd.enable = true;
  services.asusd.enable = true;
  #services.asusd.enableUserService = true;

  # ── Misc services & developer conveniences ─────────────────────
  # Enable the gnome-keyring secrets vault.
  # Will be exposed through DBus to programs willing to store secrets.
  services.gnome.gnome-keyring.enable = true;
  programs.direnv.enable = true;
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
  };

  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
    # Bound to all interfaces and reachable via the firewall rule above —
    # confirm this LAN-wide exposure is intended (vs. localhost + Tailscale).
    host = "0.0.0.0";
    port = 11434;
  };

  systemd.settings = {
    Manager = {
      DefaultTimeoutStopSec = "10s";
    };
  };

  #power management
  #services.auto-cpufreq.enable = true;
  # powerManagement.powertop.enable = true;
  # powerManagement.powertop.postStart = "echo 'on' > '/sys/bus/usb/devices/3-2/power/control' ";

  # Install firefox.
  programs.firefox.enable = true;

  # (disabled) Ghidra UI-scaling override experiment.
  #environment.etc."ghidra/support/launch.properties" = {
  #   source = ./launch.properties;
  #};
  /*programs.ghidra.package = pkgs.ghidra.overrideAttrs (old: {
    postFixup = ''
      substituteInPlace support/launch.properties \
        --replace "VMARGS_LINUX=-Dsun.java2d.uiScale=1" "VMARGS_LINUX=-Dsun.java2d.uiScale=2 "
    '';
  });
  programs.ghidra.package = pkgs.ghidra.override {
    vmArgs = [ "-Dsun.java2d.uiScale=2" ];
  };
  */

  # ── System packages ─────────────────────────────────────────────
  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.

    # Editors & core CLI
    neovim
    wget
    micro
    notepad-next
    starship
    git
    gh

    # Shell & CLI utilities
    zsh
    duf
    ncdu
    bat
    eza
    file
    zoxide
    fastfetch
    btop
    p7zip
    peazip
    ripgrep
    fzy
    comma
    nh
    nix-index
    nurl
    nix-init
    statix
    nix-direnv
    lon
    nps
    qdirstat
    sshuttle
    rar
    unzip
    lshw
    openssh_hpn
    ryzenadj
    tlp
    blueman
    bluez
    libsecret
    openssl
    nvtopPackages.v3d
    lact
    usbutils
    wl-clipboard

    # Networking & remote access
    nmap
    sniffnet
    i2p
    i2pd
    kubernetes
    localsend
    kdePackages.kdeconnect-kde
    gnome-network-displays
    scrcpy
    proton-vpn
    proton-vpn-cli
    amnezia-vpn
    amneziawg-go
    amneziawg-tools
    tailscale

    # Virtualisation / GPU passthrough
    # (disabled: depends on the kvmfr kernel module, currently commented out
    # in the Virtualisation & GPU passthrough section above)
    # looking-glass-client

    # Filesystem & disk utilities
    ntfs3g
    exfat
    exfatprogs
    btrfs-progs
    btrfs-assistant
    snapper

    # Reverse engineering / security research
    (ghidra.overrideAttrs (oldAttrs: {
          postInstall = (oldAttrs.postInstall or "") + "ln -sf ${./launch.properties} $out/lib/ghidra/support/launch.properties";
    }))
    ida-free
    cisco-packet-tracer_9
    foundry
    kicad
    platformio
    platformio-core
    avrdude
    arduino
    arduino-ide
    android-tools

    # Development toolchains & IDEs
    gcc
    gdb
    clang
    perf
    valgrind
    jetbrains.clion
    jetbrains.rust-rover
    jetbrains.webstorm
    jetbrains.pycharm
    jetbrains.idea
    nodejs_24
    cargo
    oracle-instantclient
    python313
    python313Packages.pygame
    python313Packages.flask
    python313Packages.pip
    uv
    jdk25

    # AI / LLM tools
    opencode
    aichat
    open-webui
    antigravity-ide-fhs
    antigravity-cli
    #n8n
    codex

    # Wayland / niri desktop ecosystem
    niri
    xwayland-satellite
    noctalia
    mango
    hypridle
    hyprpaper
    hyprlock
    hyprcursor
    waybar
    ashell
    wofi
    swaybg
    i3
    i3status
    xdg-desktop-portal-gtk
    xdg-desktop-portal-gnome
    gnome-keyring
    imv
    kitty
    evtest
    wev
    #(hyprland.overrideAttrs (oldAttrs: {version = "0.49"; src = fetchurl {
    #    url = "https://github.com/hyprwm/Hyprland/releases/download/v0.49.0/source-v0.49.0.tar.gz";
    #    hash = "sha256-/Zb7BDz+2gmhq5petp/uVVYkdcDGpB952tK8xlLcVzA="; };} ))
    #(aquamarine.overrideAttrs (oldAttrs: {version = "0.9.1-1"; src = fetchurl {
    #	url = "https://github.com/hyprwm/aquamarine/archive/refs/tags/v0.9.1.tar.gz";
    #	hash = "sha256-1DFmY9+Mf0g0uujE/ptn5TpOxXbHE7w9gps5QUntrRQ=";
    #};}))

    # Media & audio
    vlc
    mpv
    ffmpeg
    obs-studio
    jellyfin
    jellyfin-tui
    easyeffects
    deepfilternet # Contains the LADSPA noise cancellation plugin
    alsa-tools
    libv4l
    spotdl

    # Communication & office
    telegram-desktop
    vesktop
    onlyoffice-desktopeditors

    # Gaming
    supertuxkart
    heroic
    vulkan-tools
    (import inputs.nixpkgs-wolfssl {
           system = "x86_64-linux";
           config.allowUnfree = true;
         }).rpcs3
    protontricks
    protonplus
    wine-wayland

    # Browsers
    chromium
    firefox-devedition
    floorp-bin

    # Torrents / downloads
    qbittorrent
    yt-dlp

    # Containers (CLI, in addition to the services configured above)
    podman
    podman-compose
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?
}
