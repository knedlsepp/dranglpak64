# Live dashboard at http://dranglpak64.local (and the hotspot, and the tunnel),
# the state of the N64 and the Pi at /status
{ config, lib, pkgs, ... }:
{
  systemd.services.drangl-dashboard = {
    enable = true;
    description = "Dranglpak64 live dashboard";
    wantedBy = [ "multi-user.target" ];
    # For the WiFi on /status
    path = [ pkgs.iw pkgs.iproute2 ];
    # The units on /status
    environment.STATUS_UNITS = builtins.toJSON ([
      { unit = "sc64deployer.service"; label = "ROM-Upload & Pumpen"; }
      { unit = "drangl-dashboard.service"; label = "Dashboard"; }
      { unit = "wpa_supplicant-wlanup.service"; label = "WLAN"; }
      { unit = "hostapd.service"; label = "Hotspot"; }
      { unit = "dnsmasq.service"; label = "Hotspot-DHCP/DNS"; }
    ] ++ map (id: { unit = "cloudflared-tunnel-${id}.service"; label = "Tunnel"; })
      (lib.attrNames config.services.cloudflared.tunnels));
    serviceConfig = {
      Type = "simple";
      SyslogIdentifier = "drangl-dashboard";
      ExecStart =
        let
          dashboard = pkgs.writers.writePython3Bin "drangl-dashboard"
            {
              flakeIgnore = [ "E501" ];
            }
            (builtins.readFile ./dashboard.py);
        in
        "${dashboard}/bin/drangl-dashboard ${../web}";
      DynamicUser = true;
      # Allow binding to port 80
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      StateDirectory = "drangl-dashboard";
      Restart = "always";
      RestartSec = "1";
    };
  };
  networking.firewall.allowedTCPPorts = [ 80 ];
}
