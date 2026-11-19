# Uploads the nk64 ROM to the SummerCart64 and turns its game events into
# pumping: drink-dispenser.py reads them from `sc64deployer debug` and switches
# the relays via GPIO.
{ pkgs, ... }:
{
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
            runtimeInputs = [ pkgs.sc64deployer pkgs.socat ];
            text = ''
              # Only the debug output goes to drink-dispenser, the rest to the journal
              until sc64deployer list >&2; do sleep 0.5; done
              sc64deployer upload ${pkgs.nk64-rom}/mk64.eu.v11.z64 >&2
              # Lines on its stdin get sent to the game: commands from drangl-dashboard
              # arrive as UDP datagrams. (An open stdin also prevents
              # "[IS-Viewer 64]: Stopped listening".)
              # It's exec'd rather than piped into, so the service restarts when it
              # dies, e.g. when the N64 is switched off and the SC64 loses the ROM.
              exec sc64deployer debug --isv 0x03FF0000 < <(socat -u UDP-RECV:6465,bind=127.0.0.1 STDOUT)
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

  # The SC64's USB serial driver. Loaded on demand it only came after 19 s,
  # together with all the other drivers, delaying the ROM upload.
  boot.initrd.kernelModules = [ "ftdi_sio" ];

  users.groups.sc64deployer = { };
  users.groups.gpio = { };
  services.udev.extraRules = ''
    KERNEL=="gpiochip[0-9]*", GROUP="gpio", MODE="0660"
  '';
}
