# The device-profile option surface: every device-specific fact the subsystem
# modules consume. A device profile (devices/<codename>/) sets these; no
# subsystem module may hardcode a value that belongs here. Extend this surface
# when porting reveals another baked-in constant — never bake it into a
# subsystem instead.
{lib, ...}: let
  inherit (lib) mkOption types;
in {
  options.remarkable.device = {
    codename = mkOption {
      type = types.str;
      description = "Vendor codename (kernel/DTB/community name), e.g. \"chiappa\".";
    };
    marketName = mkOption {
      type = types.str;
      description = "Marketing name, e.g. \"reMarkable Paper Pro Move\".";
    };

    panel = {
      width = mkOption {
        type = types.ints.positive;
        description = "Panel width in pixels (portrait).";
      };
      height = mkOption {
        type = types.ints.positive;
        description = "Panel height in pixels (portrait).";
      };
    };

    dtbName = mkOption {
      type = types.str;
      description = "Device-tree blob name U-Boot selects, e.g. \"chiappa-rev-h.dtb\".";
    };

    boot = {
      kernelLoadAddr = mkOption {
        type = types.str;
        description = "FIT kernel load/entry address.";
      };
      fitLoadAddr = mkOption {
        type = types.str;
        description = "Address U-Boot loads the FIT to.";
      };
      sdp = {
        usbIds = mkOption {
          type = types.listOf types.str;
          description = "vid:pid pairs the boot ROM / SPL / fastboot enumerate as, for uuu CFG lines.";
        };
        chip = mkOption {
          type = types.str;
          description = "uuu -chip identifier for the SoC's serial-download mode.";
        };
      };
      fitConfigNames = mkOption {
        type = types.listOf types.str;
        description = ''
          Every FIT configuration name the device's U-Boot may select (derived
          from its fdtfile env, "freescale/<dtb>" with '/' -> '_'). Board
          revisions sharing a byte-identical DTB are served by aliases of one
          fdt image. A FIT without a matching name stalls U-Boot on the boot
          splash without ever loading the kernel.
        '';
      };
      fitDefaultConfig = mkOption {
        type = types.str;
        description = "The fitConfigNames entry to mark as the FIT's default configuration.";
      };
    };

    partitions = {
      rootA = mkOption {
        type = types.str;
        description = "Block device of A/B slot A's rootfs.";
      };
      rootB = mkOption {
        type = types.str;
        description = "Block device of A/B slot B's rootfs.";
      };
      persistPartlabel = mkOption {
        type = types.str;
        description = "GPT partlabel of the persistent data partition (referenced by partlabel, never fs label).";
      };
    };

    lpgprPath = mkOption {
      type = types.str;
      default = "/sys/devices/platform/lpgpr";
      description = "sysfs path of the vendor lpgpr driver (A/B slot state, error counters, rescue flags).";
    };

    hardwareLayer = mkOption {
      type = types.path;
      description = ''
        Root of the device's distro-agnostic hardware layer (kernel config +
        patches, eink/power sources, udev rules). Subsystems read conventional
        subpaths out of it: kernel/, eink/src/, eink/bridge.qml, power/.
      '';
    };

    eink.vpddSysfsPath = mkOption {
      type = types.str;
      description = "sysfs path of the EPD power regulator exposing vpdd_length (suspend interacts with its hold timer).";
    };

    battery.sysfsName = mkOption {
      type = types.str;
      description = "power_supply name of the battery/fuel gauge (under /sys/class/power_supply/).";
    };

    bluetooth.kernelModule = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Bluetooth kernel module whose boot-time autoload must be deferred until after WiFi (combo-chip init order), or null.";
    };

    wifi.interface = mkOption {
      type = types.str;
      default = "wlan0";
      description = "Name of the WiFi network interface (combo-chip init ordering waits on it).";
    };

    frontlight.kernelModule = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Backlight kernel module name (for suspend-blanking module params), or null if none.";
    };

    frontlight.sysfsName = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Backlight name under /sys/class/backlight/, or null if the device has no front light.";
    };

    touch.udevRules = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "udev rules file for touch-controller quirks (from the hardware layer), or null.";
    };
  };

  # Deployment-level (not a device fact): the unprivileged user the reader UI,
  # frontlight access, and suspend polkit rules target.
  options.remarkable.primaryUser = mkOption {
    type = types.str;
    example = "reader";
    description = "Name of the primary (unprivileged) user of the device.";
  };
}
