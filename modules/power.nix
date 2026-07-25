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

  # Watchdog needs both the charger power_supply and a renegotiation hook.
  hasChargerWatchdog =
    device.charger.sysfsName != null && device.charger.renegotiateSysfsPath != null;

  powerd = pkgs.writeShellScript "remarkable-powerd" ''
    BAT=/sys/class/power_supply/${device.battery.sysfsName}
    ${lib.optionalString hasChargerWatchdog ''
      CHG=/sys/class/power_supply/${device.charger.sysfsName}
    ''}
    while :; do
      soc=$(cat "$BAT/capacity" 2>/dev/null || echo 100)
      status=$(cat "$BAT/status" 2>/dev/null || echo Unknown)
      ${lib.optionalString hasChargerWatchdog ''
        # Recover a stranded input-current limit: charger online but limit at
        # the 100 mA floor, or discharging on live input → renegotiate.
        if [ "$(cat "$CHG/online" 2>/dev/null)" = "1" ]; then
          cur=$(cat "$CHG/current_max" 2>/dev/null || echo 0)
          if [ "$cur" -le 100000 ] || [ "$status" = "Discharging" ]; then
            echo 1 > ${device.charger.renegotiateSysfsPath} 2>/dev/null || true
          fi
        fi
      ''}
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
    penChargeMinSoc = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Battery % at or above which the NFC pen charger stays powered through suspend (it always stays powered when on external power; ~8 mA suspend cost). null = only on external power.";
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

    # Power the WiFi/BT combo chip down across suspend (it otherwise stays
    # powered on SDIO). BT module out first, then WiFi; on resume WiFi loads
    # immediately and BT reloads in the background once the interface exists
    # (the combo chip's FW download races WiFi init otherwise).
    (lib.mkIf (device.wifi.kernelModules != []) {
      powerManagement.powerDownCommands = ''
        ${lib.optionalString (device.bluetooth.kernelModule != null) ''
          ${pkgs.kmod}/bin/rmmod ${device.bluetooth.kernelModule} 2>/dev/null || true
        ''}
        ${lib.concatMapStrings (m: ''
          ${pkgs.kmod}/bin/rmmod ${m} 2>/dev/null || true
        '')
        device.wifi.kernelModules}
      '';
      powerManagement.powerUpCommands = ''
        ${lib.concatMapStrings (m: ''
          ${pkgs.kmod}/bin/modprobe ${m} 2>/dev/null || true
        '') (lib.reverseList device.wifi.kernelModules)}
        ${lib.optionalString (device.bluetooth.kernelModule != null) ''
          ${pkgs.util-linux}/bin/setsid -f ${pkgs.writeShellScript "remarkable-bt-reload" ''
            for _ in $(seq 1 30); do [ -d /sys/class/net/${device.wifi.interface} ] && break; sleep 1; done
            ${pkgs.kmod}/bin/modprobe ${device.bluetooth.kernelModule} 2>/dev/null || true
          ''} >/dev/null 2>&1 || true
        ''}
      '';
    })

    # Devices with measurable suspend draw and no sleep role: unbind across
    # suspend, rebind on resume.
    (lib.mkIf (device.suspendUnbind != []) {
      powerManagement.powerDownCommands = lib.concatMapStrings (d: ''
        echo ${d.busDeviceId} > "${d.driverSysfsPath}/unbind" 2>/dev/null || true
      '')
      device.suspendUnbind;
      powerManagement.powerUpCommands = lib.concatMapStrings (d: ''
        echo ${d.busDeviceId} > "${d.driverSysfsPath}/bind" 2>/dev/null || true
      '')
      device.suspendUnbind;
    })

    # The NFC pen charger keeps polling through deep suspend; unbind it around
    # sleep unless we can afford it (on external power, or battery above
    # penChargeMinSoc). The pen always charges while the device is awake.
    (lib.mkIf (device.nfc.driverSysfsPath != null && device.nfc.busDeviceId != null) {
      powerManagement.powerDownCommands = ''
        keep_nfc=0
        ${lib.optionalString (device.charger.sysfsName != null) ''
          [ "$(cat /sys/class/power_supply/${device.charger.sysfsName}/online 2>/dev/null)" = "1" ] && keep_nfc=1
        ''}
        ${lib.optionalString (cfg.penChargeMinSoc != null) ''
          soc=$(cat /sys/class/power_supply/${device.battery.sysfsName}/capacity 2>/dev/null || echo 0)
          [ "$soc" -ge ${toString cfg.penChargeMinSoc} ] && keep_nfc=1
        ''}
        if [ "$keep_nfc" = "0" ]; then
          echo ${device.nfc.busDeviceId} > "${device.nfc.driverSysfsPath}/unbind" 2>/dev/null || true
        fi
      '';
      powerManagement.powerUpCommands = ''
        echo ${device.nfc.busDeviceId} > "${device.nfc.driverSysfsPath}/bind" 2>/dev/null || true
      '';
    })

    # The Type-C controller doesn't renegotiate input current on resume and
    # can leave it at the 100 mA floor; force a negotiation every resume.
    (lib.mkIf (device.charger.renegotiateSysfsPath != null) {
      powerManagement.resumeCommands = ''
        echo 1 > ${device.charger.renegotiateSysfsPath} 2>/dev/null || true
      '';
    })

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
