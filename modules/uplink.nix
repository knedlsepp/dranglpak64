# The built-in WiFi is the uplink: SSH, deploys, the time and the tunnel.
{ config, lib, ... }:
{
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
