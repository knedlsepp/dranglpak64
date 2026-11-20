{ pkgs, ... }:
{
  imports = [
    ./modules/base.nix
    ./modules/drink-dispenser.nix
    ./modules/dashboard.nix
    ./modules/tunnel.nix
    ./modules/hotspot.nix
    ./modules/uplink.nix
  ];

  environment.systemPackages = with pkgs; [ vim git htop strace sc64deployer ];

  services.openssh.enable = true;
  # Reachable as dranglpak64.local on whatever network we're on
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };
  networking.hostName = "dranglpak64";
  time.timeZone = "Europe/Vienna";
  users = {
    users.root = {
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDTL9AJG8V8Hl3yiPJeghn3GcIy3sl+jsED+RgC5Md4E sepp@localhohohost"
        # Phone, for emergencies at the booth via the hotspot
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIpypxRXKqsWteFp0z8NEfmKxR8BZ3tolHnWupmbyjXx JuiceSSH@Fairphone"
      ];
    };
  };
  system.stateVersion = "25.11";
}
