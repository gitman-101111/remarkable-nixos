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
    # NXP 88W8987 (BT side of the IW611 WiFi/BT combo): boot-time autoload
    # races the WiFi side's init and the FW download times out on a fraction
    # of boots, leaving the host-wake GPIO storming and aborting every
    # suspend. Loaded after wlan0 exists instead.
    bluetooth.kernelModule = "btnxpuart";
    frontlight.kernelModule = "aw99703_bl";
    frontlight.sysfsName = "rm_frontlight";
    touch.udevRules = "${hardware-chiappa}/eink/60-chiappa-touch.rules";
  };
}
