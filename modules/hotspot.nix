# Open visitor hotspot on the USB WiFi stick (RTL8188CUS). Every DNS name
# resolves to the Pi, so phones show the dashboard as captive portal page
# right after connecting.
{ ... }:
{
  # The stick's firmware (rtlwifi/rtl8192cufw*.bin) is in linux-firmware.
  # Without it the driver complained on every boot.
  hardware.enableRedistributableFirmware = true;

  # A stable name for the stick regardless of USB port
  systemd.network.links."10-wlan-hotspot" = {
    matchConfig.Driver = "rtl8192cu";
    linkConfig.Name = "wlanap";
  };

  services.hostapd = {
    enable = true;
    radios.wlanap = {
      band = "2g";
      channel = 6;
      countryCode = "AT";
      wifi4.capabilities = [ "SHORT-GI-20" ];
      wifi5.enable = false;
      networks.wlanap = {
        ssid = "DranglPak64";
        authentication.mode = "none";
        # Visitors' phones shouldn't see each other
        apIsolate = true;
        # No management frame protection on an open network
        settings.ieee80211w = 0;
      };
    };
  };
  services.dnsmasq = {
    enable = true;
    # The Pi itself keeps using real DNS via the uplink
    resolveLocalQueries = false;
    settings = {
      interface = "wlanap";
      bind-dynamic = true;
      no-resolv = true;
      dhcp-range = "192.168.64.10,192.168.64.250,1h";
      address = "/#/192.168.64.1";
      # RFC 8910 captive portal announcement
      dhcp-option = "114,http://192.168.64.1/";
    };
  };
  networking.interfaces."wlanap" = {
    useDHCP = false;
    ipv4.addresses = [{ address = "192.168.64.1"; prefixLength = 24; }];
  };
  networking.firewall.interfaces.wlanap = {
    allowedUDPPorts = [ 53 67 ];
    allowedTCPPorts = [ 53 ];
  };
  # Every name resolves to the Pi, so phones and browsers also try HTTPS here.
  # Refuse it right away instead of silently dropping, or they hang until timeout.
  networking.firewall.extraCommands = ''
    iptables -I nixos-fw -i wlanap -p tcp --dport 443 -j REJECT --reject-with tcp-reset
  '';
}
