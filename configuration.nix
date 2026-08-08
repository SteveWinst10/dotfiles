# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs,lib,inputs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  nix.optimise.automatic = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  

  systemd.oomd.enable = true;
  zramSwap.enable = true;
  swapDevices = [{
    device = "/var/lib/swapfile";
    size = 16*1024; # 16 GiB
  }];
  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];
  boot.kernelParams = [ "8250.nr_uarts=0" ];
  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_zen;
  
  networking.hostName = "SunnyGo"; # Define your hostname.
  #networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Asia/Kolkata";
  # Select internationalisation properties.
  # Select internationalisation properties.
    
    # NixOS expects the specific glibc format: "locale/encoding"
    # Note: en_IN does not use a .UTF-8 suffix in its name here
  
  # Enable the X11 windowing system.
  # You can disable this if you're only using the Wayland session.
  services.xserver.enable = true;
  # Enable the KDE Plasma Desktop Environment.
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  nix.settings.experimental-features = ["nix-command" "flakes"];

  # Enable CUPS to print documents.
  services.printing.enable = true;

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
  hardware.enableAllFirmware = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.steve = {
    isNormalUser = true;
    shell =  pkgs.zsh;
    description = "Steve Winston";
    extraGroups = [ "networkmanager" "wheel" "docker" ];
    packages = with pkgs; [
      kdePackages.kate
    #  thunderbird
    ];
  };
  users.users.hat = {
      isNormalUser = true;
      shell =  pkgs.zsh;
      description = "Rest of the Team";
      extraGroups = [ "networkmanager" "wheel" ];
    };
  users.defaultUserShell = pkgs.zsh;
  environment.sessionVariables = {
    AQ_NO_ATOMIC = "1";
    WLR_DRM_DEVICES= "/dev/dri/card1";
  };
  environment = {
    shells = [ pkgs.zsh ];
    variables = {
      EDITOR = "micro";
      SYSTEMD_EDITOR = "micro";
      VISUAL = "micro";
    };
  };

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
  # Install firefox.
  programs.firefox.enable = true;
  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget

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
  programs.hyprland = {
      enable = false;
      # Ensures the wrapper loads the exact pinned flake binary
      package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    };
  environment.systemPackages = with pkgs; [
  #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
  	 neovim
  	 onlyoffice-desktopeditors

  	 gnome-network-displays

  	 dnsmasq
  	 nmap
  	 sniffnet
  	 wireshark
  	 i2p
  	 i2pd

  	 kubernetes
	 foundry
	 usbutils
	 wl-clipboard
	 unzip
	 imv
	 kitty

	 gcc
	 gdb
	 clang
	 perf
	 valgrind
	 android-tools 

	 python313Packages.pygame
	 python313Packages.flask

	 localsend

	 nps
	 nh
	 comma
	 nix-index
	 nurl
	 nix-init
	 statix
	 nix-direnv
	 lon
	 	 
	 heroic
	 vulkan-tools
	 (import inputs.nixpkgs-wolfssl {
	        system = "x86_64-linux";
	        config.allowUnfree = true;
	      }).rpcs3
	 protontricks
	 protonplus
	 
	 swaybg
	 i3
	 i3status
	 waybar
	 ashell

	 spotdl

	 kicad
	 staruml

	 
	 platformio
	 platformio-core
	 avrdude
	 telegram-desktop
	 yt-dlp
     wget
     micro
     notepad-next
     zoxide
     fastfetch
     (ghidra.overrideAttrs (oldAttrs: {
           postInstall = (oldAttrs.postInstall or "") + "ln -sf ${./launch.properties} $out/lib/ghidra/support/launch.properties";
     }))
     ida-free
     starship
     tailscale
     git
     podman
     podman-compose
	 gh
     qbittorrent

     ntfs3g
     exfat
     exfatprogs
     btrfs-progs
     btrfs-assistant
	 snapper

	 zsh
	 duf
	 ncdu
	 bat
	 eza
	 
	 vlc
	 mpv
	 ffmpeg
	 obs-studio
	 jellyfin
	 jellyfin-tui

	 supertuxkart
	 alsa-tools
	 libv4l
	 evtest
	 wev
	 #(hyprland.overrideAttrs (oldAttrs: {version = "0.49"; src = fetchurl {
	 #    url = "https://github.com/hyprwm/Hyprland/releases/download/v0.49.0/source-v0.49.0.tar.gz";
	 #    hash = "sha256-/Zb7BDz+2gmhq5petp/uVVYkdcDGpB952tK8xlLcVzA="; };} ))
	 #(aquamarine.overrideAttrs (oldAttrs: {version = "0.9.1-1"; src = fetchurl {
	 #	url = "https://github.com/hyprwm/aquamarine/archive/refs/tags/v0.9.1.tar.gz";
		# 	hash = "sha256-1DFmY9+Mf0g0uujE/ptn5TpOxXbHE7w9gps5QUntrRQ=";
	 #};}))
	 hyprpanel
	 hypridle
	 hyprpaper
	 hyprlock
	 hyprcursor

	 mango

	 niri

	  
	 btop
	 p7zip
	 peazip
	 nvtopPackages.v3d
	 lshw	
	 openssh_hpn
	 
	 jetbrains.clion
	 jetbrains.rust-rover
	 jetbrains.webstorm
	 jetbrains.pycharm
	 jetbrains.idea
	 nodejs_24
	 cargo
	 oracle-instantclient

	 gemini-cli-bin
	 opencode
	 aichat
	 open-webui
	 inputs.antigravity-nix.packages.${system}.default

	 chromium
	 firefox-devedition-bin   
	 floorp-bin


	 wofi
	 xdg-desktop-portal-gtk
     xdg-desktop-portal-gnome
     gnome-keyring

	 python313
	 
	 uv
	 tlp
	 blueman
	 bluez
	 rar
	 wine-wayland
	 openssl
	 qdirstat
	 sshuttle
	 proton-vpn
	 proton-vpn-cli
	 ripgrep
	 fzy
	 scrcpy
	 python313Packages.pygame
	 python313Packages.pip
	 libsecret
	 lact

	 jdk25

	 ryzenadj
  ];

  # Inside your primary system flake.nix inputs:
 
  
  # Inside your configuration.nix module (passing inputs via specialArgs):

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
   networking.firewall.allowedTCPPorts = [ 
		  4318
		  53317
    ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false; 
  networking.firewall = {
    # This makes the hotspot interface a "free-fire" zone for local data
    trustedInterfaces = [ "wlan0" ]; 
    
    # Some LAN games specifically need these for discovery
    allowedUDPPorts = [ 5353 53317]; # For mDNS (finding each other)
  };
  boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
    };
  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?

  # Enable the gnome-keyring secrets vault. 
    # Will be exposed through DBus to programs willing to store secrets.
    services.gnome.gnome-keyring.enable = true;
   programs.direnv.enable = true;
   programs.nix-ld.enable = true;
    # enable Sway window manager
    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true;
    };
   services.openssh = {
    enable = true;
  };
  services.xserver.windowManager.i3.enable = true;
  #Asus specific packages
  services.supergfxd.enable = true;
  services = {
      asusd = {
        enable = true;
        #enableUserService = true;
      };
  };


 services.udev.packages = with pkgs; [ platformio-core.udev ];
 programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
    extraCompatPackages = [
        pkgs.proton-ge-bin
      ];
  };

 virtualisation.containers.enable = true;
  virtualisation = {
    podman = {
      enable = true;
      # Create a `docker` alias for podman, to use it as a drop-in replacement
      # Required for containers under podman-compose to be able to talk to each other.
      defaultNetwork.settings.dns_enabled = true;
    };
  };
 services.ollama = {
   enable = false;
   package = pkgs.ollama-cuda;
 };
 services.tailscale = { 
   enable = true;
   useRoutingFeatures = "client";
 };
 systemd.services.tailscaled = {
   enable = true;
   #restartIfChanged = false;
   #serviceConfig.RemainAfterExit = false;
   wantedBy = lib.mkForce [ ];
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

# pkgs.hyprland.overrideAttrs (finalAttrs: previousAttrs: {
# 	version = "0.49";	
#});


 #programs.hyprland = {
 #    enable = true;
 #    withUWSM = false; # recommended for most users
 #    xwayland.enable = true; # Xwayland can be disabled.
 #  };
 programs.niri.enable = true;

#power management
 #services.auto-cpufreq.enable = true;
# powerManagement.powertop.enable = true;
# powerManagement.powertop.postStart = "echo 'on' > '/sys/bus/usb/devices/3-2/power/control' ";
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
systemd.settings = {
  Manager = {
    DefaultTimeoutStopSec = "10s";
  };
};
 
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
     # of just the bare essentials.
     powerManagement.enable = true;
 
     # Fine-grained power management. Turns off GPU when not in use.
     # Experimental and only works on modern Nvidia GPUs (Turing or newer).
     powerManagement.finegrained = true;
 
     # Use the NVidia open source kernel module (not to be confused with the
     # independent third-party "nouveau" open source driver).
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
   /*	boot.extraModprobeConfig = ''
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
}
