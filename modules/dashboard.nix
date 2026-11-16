# Live dashboard at http://dranglpak64.local (and the hotspot, and the tunnel)
{ pkgs, ... }:
{
  systemd.services.drangl-dashboard = {
    enable = true;
    description = "Dranglpak64 live dashboard";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      SyslogIdentifier = "drangl-dashboard";
      ExecStart =
        let
          dashboard = pkgs.writers.writePython3Bin "drangl-dashboard"
            {
              flakeIgnore = [ "E501" ];
            }
            (builtins.readFile ../dashboard.py);
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
