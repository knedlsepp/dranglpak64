{ pkgs, config, lib, ... }:
{
  environment.systemPackages = with pkgs; [ vim git htop strace sc64deployer ];

  systemd.services.sc64deployer = {
    enable = true;
    description = "sc64deployer ROM Upload Service with drink dispenser";
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      StartLimitIntervalSec = "0";
    };
    serviceConfig = {
      Type = "simple";
      SyslogIdentifier = "sc64deployer";
      ExecStart =
        let
          upload-rom = pkgs.writeShellApplication {
            name = "upload-rom";
            runtimeInputs = [ pkgs.sc64deployer ];
            text = ''
              until sc64deployer list; do sleep 2; done
              sc64deployer upload ${pkgs.nk64-rom}/mk64.eu.v11.z64
              # Prevent "[IS-Viewer 64]: Stopped listening" via 'tail -f /dev/null'
              exec tail -f /dev/null | sc64deployer debug --isv 0x03FF0000
            '';
          };
          drink-dispenser = pkgs.writers.writePython3Bin "drink-dispenser"
            {
              libraries = [ pkgs.python3.pkgs.libgpiod ];
              flakeIgnore = [ "E501" ];
            }
            (builtins.readFile ./drink-dispenser.py);
          sc64deployer = pkgs.writeShellScript "sc64deployer" ''
            set -euo pipefail
            # Wait for /dev/gpiochip0 to exist and be readable/writable (Poor man's systemd After)
            until [ -r "/dev/gpiochip0" ] && [ -w "/dev/gpiochip0" ]; do
              sleep 1
            done
            # FIXME: If drink-dispenser dies this script doesn't stop. (But it should!)
            ${upload-rom}/bin/upload-rom | ${drink-dispenser}/bin/drink-dispenser
          '';
        in
        sc64deployer;

      User = "sc64deployer";
      Group = "sc64deployer";
      Restart = "always";
      RestartSec = "1";
    };
  };




  # Create sc64deployer user and group
  users.users.sc64deployer = {
    isSystemUser = true;
    createHome = true;
    description = "sc64deployer service user";
    group = "sc64deployer";
    extraGroups = [
      "dialout" # Access to serial device
      "gpio" # Access to GPIO devices
    ];
  };

  users.groups.sc64deployer = { };
  users.groups.gpio = { };
  services.udev.extraRules = ''
    KERNEL=="gpiochip[0-9]*", GROUP="gpio", MODE="0660"
  '';


  # Live "Hall of Shame" at http://dranglpak64.local
  systemd.services.drangl-dashboard = {
    enable = true;
    description = "Dranglpak64 Hall of Shame dashboard";
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
            (builtins.readFile ./dashboard.py);
        in
        "${dashboard}/bin/drangl-dashboard ${./web}";
      DynamicUser = true;
      # Allow binding to port 80
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      StateDirectory = "drangl-dashboard";
      Restart = "always";
      RestartSec = "1";
    };
  };
  networking.firewall.allowedTCPPorts = [ 80 ];

  # Public Hall of Shame at https://dranglpak64.knedlsepp.at via Cloudflare
  # Tunnel (outbound only, works behind the phone hotspot). Credentials were
  # created with `cloudflared tunnel create dranglpak64`.
  age.secrets.cloudflared-dranglpak64.file = ./secrets/cloudflared-dranglpak64.json.age;
  # Account certificate from `cloudflared tunnel login`, to manage tunnels and
  # DNS routes with the cloudflared CLI on the Pi.
  age.secrets.cloudflared-cert.file = ./secrets/cloudflared-cert.pem.age;
  environment.variables.TUNNEL_ORIGIN_CERT = config.age.secrets.cloudflared-cert.path;
  services.cloudflared = {
    enable = true;
    tunnels."210907d3-ea55-4790-9e41-0d810ebcc889" = {
      credentialsFile = config.age.secrets.cloudflared-dranglpak64.path;
      ingress."dranglpak64.knedlsepp.at" = "http://localhost:80";
      default = "http_status:404";
    };
  };

  age.secrets.wireless.file = ./secrets/wireless.conf.age;

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
      ];
    };
  };
  # The built-in WiFi is the uplink (SSH), the USB WiFi stick (RTL8188CUS) is
  # the visitor hotspot. Give the stick a stable name regardless of USB port.
  systemd.network.links."10-wlan-hotspot" = {
    matchConfig.Driver = "rtl8192cu";
    linkConfig.Name = "wlanap";
  };

  # Open visitor hotspot. Every DNS name resolves to the Pi, so phones show
  # the Hall of Shame as captive portal page right after connecting.
  services.hostapd = {
    enable = true;
    radios.wlanap = {
      band = "2g";
      channel = 6;
      countryCode = "AT";
      wifi4.capabilities = [ "SHORT-GI-20" ];
      wifi5.enable = false;
      networks.wlanap = {
        ssid = "Dranglpak64 Hall of Shame";
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
  networking.firewall.interfaces.wlanap = {
    allowedUDPPorts = [ 53 67 ];
    allowedTCPPorts = [ 53 ];
  };
  # Every name resolves to the Pi, so phones and browsers also try HTTPS here.
  # Refuse it right away instead of silently dropping, or they hang until timeout.
  networking.firewall.extraCommands = ''
    iptables -I nixos-fw -i wlanap -p tcp --dport 443 -j REJECT --reject-with tcp-reset
  '';

  networking = {
    networkmanager.enable = lib.mkForce false;
    interfaces."wlan0".useDHCP = true;
    interfaces."wlanap" = {
      useDHCP = false;
      ipv4.addresses = [{ address = "192.168.64.1"; prefixLength = 24; }];
    };
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
  system.stateVersion = "25.11";
}
