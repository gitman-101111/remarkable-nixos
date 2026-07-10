# Power management: sleep/wake daemon, battery guard, combo-chip Bluetooth
# ordering, resume nudges.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.remarkable.power;
  device = config.remarkable.device;
  primaryUser = config.remarkable.primaryUser;

  # Power-button/cover → suspend daemon (source in the hardware layer):
  # event-driven sd-bus state machine on the pwrkey + hall-sensor evdev
  # devices and logind's PrepareForSleep. Owns the button because reader
  # apps' input layers don't reliably surface KEY_POWER; also re-suspends if
  # the cover is closed on wake (the folio wake source fires on any cover
  # edge) and structurally ignores the driver's replayed wake press.
  powerkey = pkgs.stdenv.mkDerivation {
    pname = "remarkable-powerkey";
    version = "2";
    src = "${device.hardwareLayer}/power";
    dontConfigure = true;
    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.systemd]; # sd-bus (logind PrepareForSleep + Suspend())
    buildPhase = "$CC -O2 -o chiappa-powerkey chiappa-powerkey.c $(pkg-config --cflags --libs libsystemd)";
    installPhase = "install -Dm755 chiappa-powerkey $out/bin/remarkable-powerkey";
  };

  lowBattShow = config.remarkable.eink.lowBatteryShow;

  powerd = pkgs.writeShellScript "remarkable-powerd" ''
    BAT=/sys/class/power_supply/${device.battery.sysfsName}
    while :; do
      soc=$(cat "$BAT/capacity" 2>/dev/null || echo 100)
      status=$(cat "$BAT/status" 2>/dev/null || echo Unknown)
      if [ "$soc" -le ${toString cfg.lowSoc} ] && [ "$status" = "Discharging" ]; then
        ${lib.optionalString (lowBattShow != null) ''
          # Show the battery-empty frame, then let it render before we go.
          ${lowBattShow} 2>/dev/null || true
          sleep 3
        ''}
        ${pkgs.systemd}/bin/systemctl poweroff
        exit 0
      fi
      sleep 30
    done
  '';
in {
  options.remarkable.power = {
    enable = lib.mkEnableOption "power management" // {default = true;};
    lowSoc = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "Battery %: graceful poweroff at or below this while discharging (ahead of the fuel gauge's hardware cliff).";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      systemd.services.remarkable-powerd = {
        description = "battery guard";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          ExecStart = powerd;
          Restart = "always";
        };
      };

      # Power button: deep suspend + power-button wake both work (dmesg:
      # `PM: suspend entry (deep)` → press → `PM: Triggering wakeup` →
      # `PM: suspend exit`). logind's default HandlePowerKey=poweroff consumes
      # the same press that wakes the kernel — the device wakes and instantly
      # shuts down. `ignore` leaves the press to the daemon (below); a long
      # hold still powers off cleanly.
      services.logind.settings.Login = {
        HandlePowerKey = lib.mkDefault "ignore";
        HandlePowerKeyLongPress = lib.mkDefault "poweroff";
      };

      # Reader apps run as systemd services (no login session), so
      # logind/polkit would deny their `systemctl suspend`. Allow the primary
      # user to suspend/poweroff regardless of session state.
      security.polkit.enable = true;
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if ((action.id == "org.freedesktop.login1.suspend" ||
               action.id == "org.freedesktop.login1.suspend-multiple-sessions" ||
               action.id == "org.freedesktop.login1.power-off" ||
               action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
               action.id == "org.freedesktop.login1.reboot" ||
               action.id == "org.freedesktop.login1.reboot-multiple-sessions") &&
              subject.user == "${primaryUser}") {
            return polkit.Result.YES;
          }
        });
      '';

      # System power-button handler: press or cover-close → suspend.
      systemd.services.remarkable-powerkey = {
        description = "power-button/cover → suspend";
        wantedBy = ["multi-user.target"];
        path = [pkgs.systemd];
        serviceConfig = {
          ExecStart = "${powerkey}/bin/remarkable-powerkey";
          Restart = "always";
          RestartSec = 2;
        };
      };
    }

    # On resume the WiFi chip has been powered down; NetworkManager's sleep
    # monitor normally re-associates, but nudge the radio on to guarantee it
    # (the interface has been seen still `down` right at resume). Idempotent
    # if already up.
    (lib.mkIf config.networking.networkmanager.enable {
      powerManagement.resumeCommands = ''
        ${pkgs.networkmanager}/bin/nmcli radio wifi on || true
      '';
    })

    # WiFi/BT combo chips: the BT module's boot-time autoload can race the
    # WiFi side's init — the BT FW download then times out, leaving the
    # host-wake GPIO storming and aborting every suspend. Block the autoload
    # and load ordered after WiFi exists instead.
    (lib.mkIf (device.bluetooth.kernelModule != null) {
      boot.blacklistedKernelModules = [device.bluetooth.kernelModule];
      systemd.services.remarkable-bluetooth = {
        description = "load Bluetooth after WiFi (combo-chip init order)";
        wantedBy = ["multi-user.target"];
        after = ["NetworkManager.service"];
        path = [pkgs.kmod];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          for _ in $(seq 1 60); do [ -d /sys/class/net/${device.wifi.interface} ] && break; sleep 1; done
          modprobe ${device.bluetooth.kernelModule}
        '';
      };
      # bluez for pairing/audio; pairings persist when /var/lib/bluetooth
      # lives on the persistent partition.
      hardware.bluetooth.enable = lib.mkDefault true;
    })
  ]);
}
