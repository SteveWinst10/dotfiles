{ config, pkgs, lib, ... }:
{
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

}
