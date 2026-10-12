# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  hostSystem = pkgs.stdenv.hostPlatform.system;
  pkgs-wolfssl = import inputs.nixpkgs-wolfssl {
    system = hostSystem;
    config.allowUnfree = true;
  };
  # Ghidra with HiDPI scaling. A wrapper is used instead of overrideAttrs so
  # Ghidra is not rebuilt from source whenever the derivation changes.
  ghidra-hidpi = pkgs.symlinkJoin {
    name = "ghidra-hidpi-${pkgs.ghidra.version}";
    paths = [ pkgs.ghidra ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/ghidra \
        --set JAVA_TOOL_OPTIONS "-Dsun.java2d.uiScale=2"
    '';
  };
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./telemetry.nix
  ];

  # ── Nix & package management ──────────────────────────────────
  nix.optimise.automatic = true;
  programs.nh = {
    enable = true;
    flake = "/home/steve/.dotfiles";
    clean = {
      enable = true;
      dates = "weekly";
      extraArgs = "--keep-since 14d --keep 5";
    };
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nixpkgs.config.allowUnfree = true;
  # ── System identity, locale & time ─────────────────────────────
  networking.hostName = "Thousand-Sunny"; # Define your hostname.
  time.timeZone = "Asia/Kolkata";
  # Select internationalisation properties.
  # NixOS expects the specific glibc format: "locale/encoding"
  # Note: en_IN does not use a .UTF-8 suffix in its name here

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

  # ── Security, sandboxing & packet analysis tools ───────────────
  programs.wireshark = {
    enable = true;
    package = pkgs.wireshark;
    usbmon.enable = true;
  };
  security.wrappers.sniffnet = {
    source = lib.getExe pkgs.sniffnet;
    capabilities = "cap_net_raw,cap_net_admin+eip";
    owner = "root";
    group = "wireshark";
    permissions = "u+rx,g+x";
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
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
      "wireshark"
      "libvirtd"
      "dialout"
    ];
    packages = with pkgs; [
      kdePackages.kate
      #  thunderbird
    ];
  };
  users.users.hat = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "Rest of the Team";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
  };
  users.defaultUserShell = pkgs.zsh;

  environment = {
    shells = [ pkgs.zsh ];
    variables = {
      EDITOR = "nvim";
      SYSTEMD_EDITOR = "nvim";
      VISUAL = "nvim";
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
      nixcedit = "nvim ~/.dotfiles/configuration.nix";
      nixhedit = "nvim ~/.dotfiles/hardware-configuration.nix";
      rebuild = "nh os switch --flake ~/.dotfiles/"; # rebuild + switch
      update = "nh os switch --update --flake ~/.dotfiles/";
    };
  };
  programs.starship.enable = true;
  programs.zoxide.enableZshIntegration = true;

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
        monospace = [
          "Fira Code"
          "0xProto Nerd Font"
          "Lilex"
        ];
        sansSerif = [ "Inter" ];
        serif = [ "Noto Serif" ];
      };
    };

    packages = with pkgs; [
      lilex
      nerd-fonts._0xproto
      fira-code
      inter
      noto-fonts
      noto-fonts-cjk-sans
    ];
  };

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

  # ── System packages ─────────────────────────────────────────────
  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [

    # Editors & core CLI
    neovim
    wget
    micro
    notepad-next
    git
    gh

    # Shell & CLI utilities
    duf
    fd
    tree-sitter
    ncdu
    bat
    eza
    file
    zoxide
    fastfetch
    btop
    peazip
    ripgrep
    fzy
    comma
    nixfmt
    nix-index
    nurl
    nix-init
    statix
    lon
    nps
    qdirstat
    sshuttle
    rar
    unzip
    lshw
    openssh_hpn
    ryzenadj
    blueman
    libsecret
    openssl
    nvtopPackages.full
    usbutils
    wl-clipboard
    # Networking & remote access
    nmap
    sniffnet
    kubernetes
    localsend
    gnome-network-displays
    scrcpy
    proton-vpn
    proton-vpn-cli
    amnezia-vpn
    amneziawg-go
    amneziawg-tools

    # Virtualisation / GPU passthrough
    # (disabled: depends on the kvmfr kernel module, currently commented out
    # in the Virtualisation & GPU passthrough section above)
    # looking-glass-client

    # Filesystem & disk utilities
    ntfs3g
    exfatprogs
    btrfs-progs
    btrfs-assistant
    snapper

    # Reverse engineering / security research
    ghidra-hidpi
    ida-free
    cisco-packet-tracer_9
    foundry
    kicad
    platformio
    platformio-core
    avrdude
    android-tools

    # Development toolchains & IDEs
    gcc
    gdb
    gnumake
    clang
    perf
    valgrind
    jetbrains.clion
    jetbrains.rust-rover
    jetbrains.webstorm
    jetbrains.pycharm
    jetbrains.idea
    jetbrains.datagrip
    nodejs_24
    playwright
    playwright-test
    playwright-mcp
    cargo
    oracle-instantclient
    uv
    jdk25

    #Language servers
    nixd
    lua-language-server
    stylua

    # AI / LLM tools
    opencode
    aichat
    open-webui
    antigravity-ide-fhs
    antigravity-cli
    #n8n
    codex
    tesseract
    # Wayland / niri desktop ecosystem
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
    gnome-keyring
    imv
    kitty
    evtest
    wev
    grim
    slurp
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
    playerctl
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
  environment.sessionVariables = {
    # Force Firefox to use native Wayland instead of XWayland

    # Force Firefox to use your integrated AMD GPU (Mesa driver)
    # instead of trying to invoke NVIDIA EGL buffers under Niri
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?
}
