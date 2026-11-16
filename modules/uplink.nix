# The built-in WiFi is the uplink: SSH, deploys, the time and the tunnel.
{ config, lib, ... }:
{
  age.secrets.wireless.file = ../secrets/wireless.conf.age;

  networking = {
    networkmanager.enable = lib.mkForce false;
    interfaces."wlan0".useDHCP = true;
    wireless = {
      interfaces = [ "wlan0" ];
      enable = true;
      # psk_<network>=<output of `wpa_passphrase <network>`>
      secretsFile = config.age.secrets.wireless.path;
      networks = {
        knoedlnetz.pskRaw = "ext:psk_knoedlnetz";
        banananet.pskRaw = "ext:psk_banananet";
      };
    };
  };
}
