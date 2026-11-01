{ config, pkgs, lib, inputs, ... }:

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
    jdt-language-server

    # AI / LLM tools
    opencode
    aichat
    # open-webui
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

}
