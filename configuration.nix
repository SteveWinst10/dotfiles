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
  networking.hostName = "Thousand-Sunny";
  time.timeZone = "Asia/Kolkata";

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

  # ── Networking ──────────────────────────────────────────────────
  networking.networkmanager.enable = true;

  networking.firewall = {
    trustedInterfaces = [ "wlan0" ];
    allowedUDPPortRanges = [
      { from = 1714; to = 1764; } #KDE Connect
    ];
    allowedUDPPorts = [ 53 67 5353 53317 ]; 
    allowedTCPPortRanges = [
      { from = 1714; to = 1764; } #KDE Connect
    ];
    allowedTCPPorts = [ 53 4318 53317 ];
  };

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
  };
  
  systemd.services.tailscaled = {
    enable = true;
    wantedBy = lib.mkForce [ ];
  };

  # ── Users & shell ───────────────────────────────────────────────
  users.users.steve = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "Steve Winston";
    extraGroups = [ "networkmanager" "wheel" "wireshark" ];
    packages = with pkgs; [ kdePackages.kate ];
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
  services.xserver.enable = true;
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;
  services.displayManager.defaultSession = lib.mkForce "plasma";
  
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
  };
  programs.niri.enable = true;
  services.xserver.windowManager.i3.enable = true;

  # ── Audio ───────────────────────────────────────────────────────
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  security.polkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  programs.dconf.enable = true;

  # ── Spicetify ───────────────────────────────────────────────────
  programs.spicetify =
  let
    spicePkgs = inputs.spicetify-nix.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  in
  {
      enable = true;
      theme = spicePkgs.themes.dribbblish;
  	  colorScheme = "catppuccin-mocha";
      enabledExtensions = with spicePkgs.extensions; [
        adblock shuffle groupSession powerBar seekSong keyboardShortcut
        fullAppDisplay volumePercentage oldLikeButton ytVideo sessionStats
        focusMode sidebarCustomizer
      ];
      enabledCustomApps = with spicePkgs.apps; [
          ncsVisualizer lyricsPlus betterLibrary
        ];
      enabledSnippets = with spicePkgs.snippets; [
          rotatingCoverart pointer
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
    packages = with pkgs; [ lilex nerd-fonts._0xproto fira-code ];
  };

  # ── Hardware & firmware ─────────────────────────────────────────
  hardware.enableAllFirmware = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = false; # Disabled on boot for power savings
    settings = {
      General = { Experimental = true; };
      Policy = { AutoEnable = true; };
    };
  };
  services.input-remapper.enable = true;
  services.udev.packages = with pkgs; [ platformio-core.udev ];

  # ── Graphics (Integrated Only) ──────────────────────────────────
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
  services.lact.enable = true;

  # ── ASUS laptop services ────────────────────────────────────────
  services.supergfxd.enable = true;
  services.asusd.enable = true;

  # ── Power Management ────────────────────────────────────────────
  services.auto-cpufreq.enable = true;
  services.power-profiles-daemon.enable = false;
  powerManagement.powertop.enable = true;
  powerManagement.powertop.postStart = "echo 'on' > '/sys/bus/usb/devices/3-2/power/control' ";

  # ── Misc services & developer conveniences ─────────────────────
  services.gnome.gnome-keyring.enable = true;
  programs.direnv.enable = true;
  programs.nix-ld.enable = true;
  services.printing.enable = true;
  services.openssh.enable = true;
  programs.firefox.enable = true;

  systemd.settings = {
    Manager = {
      DefaultTimeoutStopSec = "10s";
    };
  };

  # ── System packages ─────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    # Editors & core CLI
    neovim wget micro notepad-next starship git gh
    
    # Shell & CLI utilities
    zsh duf ncdu bat eza file zoxide fastfetch btop p7zip peazip ripgrep
    fzy comma nh nix-index nurl nix-init statix nix-direnv lon nps qdirstat
    sshuttle rar unzip lshw openssh_hpn ryzenadj tlp blueman bluez libsecret
    openssl nvtopPackages.v3d lact usbutils wl-clipboard

    # Networking & remote access
    nmap sniffnet i2p i2pd kubernetes localsend kdePackages.kdeconnect-kde
    gnome-network-displays scrcpy proton-vpn proton-vpn-cli amnezia-vpn
    amneziawg-go amneziawg-tools tailscale

    # Filesystem & disk utilities
    ntfs3g exfat exfatprogs btrfs-progs btrfs-assistant snapper

    # Reverse engineering / security research
    (ghidra.overrideAttrs (oldAttrs: {
          postInstall = (oldAttrs.postInstall or "") + "ln -sf ${./launch.properties} $out/lib/ghidra/support/launch.properties";
    }))
    ida-free cisco-packet-tracer_9 foundry kicad platformio platformio-core
    avrdude arduino arduino-ide android-tools

    # Development toolchains & IDEs
    gcc gdb clang perf valgrind jetbrains.clion jetbrains.rust-rover
    jetbrains.webstorm jetbrains.pycharm jetbrains.idea nodejs_24 cargo
    oracle-instantclient python313 python313Packages.pygame
    python313Packages.flask python313Packages.pip uv jdk25

    # AI / LLM tools (Heaviest removed for power savings)
    opencode aichat open-webui antigravity-ide-fhs antigravity-cli codex

    # Wayland / niri desktop ecosystem
    niri xwayland-satellite noctalia mango hypridle hyprpaper hyprlock
    hyprcursor waybar ashell wofi swaybg i3 i3status xdg-desktop-portal-gtk
    xdg-desktop-portal-gnome gnome-keyring imv kitty evtest wev

    # Media & audio
    vlc mpv ffmpeg obs-studio jellyfin jellyfin-tui easyeffects
    deepfilternet alsa-tools libv4l spotdl

    # Communication & office
    telegram-desktop vesktop onlyoffice-desktopeditors

    # Gaming (Drained services removed, pure packages kept)
    supertuxkart heroic vulkan-tools
    (import inputs.nixpkgs-wolfssl {
           system = "x86_64-linux";
           config.allowUnfree = true;
         }).rpcs3
    protontricks protonplus wine-wayland

    # Browsers
    chromium firefox-devedition floorp-bin

    # Torrents / downloads
    qbittorrent yt-dlp
  ];

  system.stateVersion = "25.05";
}
