# The built-in WiFi is the uplink: SSH, deploys, the time and the tunnel.
{ config, lib, pkgs, ... }:
let
  # Menu to join another WiFi, e.g. via SSH from a phone at the booth
  wlan = pkgs.writeShellApplication {
    name = "wlan";
    runtimeInputs = with pkgs; [ dialog wpa_supplicant iw curl lynx ];
    text = ''
      DECLARED_NETWORKS=${lib.escapeShellArg (lib.concatLines (lib.attrNames config.networking.wireless.networks))}
      HOTSPOT_SSID=${lib.escapeShellArg config.services.hostapd.radios.wlanap.networks.wlanap.ssid}
    '' + builtins.readFile ./wlan.sh;
  };
in
{
  environment.systemPackages = [ wlan ];

  age.secrets.wireless.file = ../secrets/wireless.conf.age;

  # A stable name for the built-in WiFi. Left to the kernel it's wlan0 or wlan1,
  # depending on whether the USB stick got probed first.
  systemd.network.links."10-wlan-uplink" = {
    matchConfig.Driver = "brcmfmac";
    linkConfig.Name = "wlanup";
  };

  networking = {
    networkmanager.enable = lib.mkForce false;
    interfaces."wlanup".useDHCP = true;
    wireless = {
      interfaces = [ "wlanup" ];
      enable = true;
      # psk_<network>=<output of `wpa_passphrase <network>`>
      secretsFile = config.age.secrets.wireless.path;
      # Without it the chip also scans channel 165, which isn't allowed in Austria:
      # "brcmf_set_channel: set chanspec 0xd0a5 fail" every 11 s while unconnected.
      extraConfig = "country=AT";
      # For `wlan`: wpa_cli can talk to it, and networks added there persist in
      # /etc/wpa_supplicant.conf
      userControlled.enable = true;
      allowAuxiliaryImperativeNetworks = true;
      networks = {
        # Preferred over banananet when both are in range
        knoedlnetz = {
          pskRaw = "ext:psk_knoedlnetz";
          priority = 10;
        };
        banananet.pskRaw = "ext:psk_banananet";
      };
    };
  };
}
