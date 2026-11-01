{ config, pkgs, lib, inputs, ... }:
{
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

}
