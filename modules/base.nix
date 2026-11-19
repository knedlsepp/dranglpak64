# The basics of the Pi: file system, boot loader, kernel, nix itself
{ pkgs, lib, ... }:
{
  # "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix" creates a
  # disk with this label on first boot. Therefore, we need to keep it. It is the
  # only information from the installer image that we need to keep persistent
  fileSystems."/" =
    {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
    };
  boot = {
    kernelPackages = lib.mkForce pkgs.linuxPackages_latest;
    loader = {
      generic-extlinux-compatible.enable = lib.mkDefault true;
      grub.enable = lib.mkDefault false;
      # No boot menu: there's no keyboard on the Pi anyway, and it delays the ROM
      # upload by 5 s
      timeout = 0;
    };
    # Unused audio, camera and Bluetooth. Their drivers warned on every boot
    # ("module is from the staging directory").
    blacklistedKernelModules = [
      "snd_bcm2835"
      "bcm2835_v4l2"
      "bcm2835_mmal_vchiq"
      "vchiq"
      "bluetooth"
      "hci_uart"
      "btbcm"
      "btqca"
      "btsdio"
    ];
  };
  nix.settings = {
    experimental-features = lib.mkDefault "nix-command flakes";
    trusted-users = [ "root" "@wheel" ];
  };
}
