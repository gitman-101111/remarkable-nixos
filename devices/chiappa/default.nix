# Device profile: reMarkable Paper Pro Move (codename chiappa).
# NXP i.MX 93 (2× Cortex-A55), 954×1696 Gallery 3 color e-ink, A/B eMMC slots.
# The reference device of this flake — extracted from a daily-driven system.
{hardware-chiappa, ...}: let
  # Board revs F–K ship a byte-identical DTB; one fdt image serves aliases
  # for all of them.
  boardRevs = ["f" "g" "h" "i" "j" "k"];
  confName = rev: "conf-freescale_chiappa-rev-${rev}.dtb";
in {
  imports = [./kernel.nix];

  remarkable.device = {
    codename = "chiappa";
    marketName = "reMarkable Paper Pro Move";

    panel = {
      width = 954;
      height = 1696;
    };

    dtbName = "chiappa-rev-h.dtb";

    boot = {
      kernelLoadAddr = "0x80400000";
      fitLoadAddr = "0x90000000";
      sdp = {
        # boot ROM (SDPS), SPL (SDPV), U-Boot fastboot
        usbIds = ["0x2edd:0x0140" "0x2edd:0x0141" "0x2edd:0x0142"];
        chip = "MX93";
      };
      fitConfigNames = map confName boardRevs;
      fitDefaultConfig = confName "h";
    };

    partitions = {
      rootA = "/dev/mmcblk0p2";
      rootB = "/dev/mmcblk0p3";
      persistPartlabel = "home";
    };

    hardwareLayer = hardware-chiappa;

    eink.vpddSysfsPath = "/sys/bus/i2c/devices/0-0048";
    battery.sysfsName = "max77818_battery";
    # fusb303b's write-only hook to re-run input-current negotiation (it only
    # negotiates on events and can strand the limit at 100 mA; see power.nix).
    charger.sysfsName = "max77818-charger";
    charger.renegotiateSysfsPath = "/sys/bus/i2c/devices/1-0021/queue_charging_negotiation";
    # ctn730 NFC pen charger draws ~8 mA through deep suspend (~40% of the
    # standby floor, measured); power.nix unbinds it across sleep.
    nfc.driverSysfsPath = "/sys/bus/i2c/drivers/nxp,ctn730-rm";
    nfc.busDeviceId = "4-0028";
    # NXP 88W8987 (BT side of the IW611 WiFi/BT combo): boot-time autoload
    # races the WiFi side's init and the FW download times out on a fraction
    # of boots, leaving the host-wake GPIO storming and aborting every
    # suspend. Loaded after wlan0 exists instead.
    bluetooth.kernelModule = "btnxpuart";
    # IW611 combo chip draws ~2.7 mA through deep suspend when left powered;
    # power.nix unloads these (BT module first) before sleep, reloads after.
    wifi.kernelModules = ["iw61x_sdw61x" "iw61x_mlan"];
    # lis2dw12 accelerometer: ~0.8 mA in suspend, nothing consumes it asleep.
    suspendUnbind = [
      {
        driverSysfsPath = "/sys/bus/i2c/drivers/st_lis2dw12_i2c";
        busDeviceId = "0-0019";
      }
    ];
    # The max77818 PMIC (charger + fuel gauge) is armed as a wakeup source, so
    # charger interrupts pull the device out of deep suspend — observed waking
    # a sleeping unit after 84 min on the charger ("PM: Triggering wakeup from
    # IRQ 29 (max77818 intsrc)"). Nothing needs a charge event while suspended:
    # the battery guard only polls awake, the long-standby shutdown is its own
    # RTC alarm, and Type-C renegotiation runs from resumeCommands on resume.
    disarmWakeup = [
      {
        subsystem = "i2c";
        kernel = "0-0066";
      }
      {
        subsystem = "power_supply";
        kernel = "max77818-charger";
      }
      {
        subsystem = "power_supply";
        kernel = "max77818_battery";
      }
    ];
    frontlight.kernelModule = "aw99703_bl";
    frontlight.sysfsName = "rm_frontlight";
    touch.udevRules = "${hardware-chiappa}/eink/60-chiappa-touch.rules";
  };
}
