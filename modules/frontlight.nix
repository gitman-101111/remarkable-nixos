# Front light — user access + sane default.
#
# The backlight driver's brightness/bl_power nodes are root-owned, so an app
# running as the user gets EACCES and can't drive the light. Grant the `video`
# group write access (the primary user is added to video), and set a sane
# brightness at boot (drivers can come up near-minimum, which looks "off").
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.remarkable.frontlight;
  device = config.remarkable.device;
  node = "/sys/class/backlight/${device.frontlight.sysfsName}";
in {
  options.remarkable.frontlight = {
    enable = lib.mkEnableOption "front light user access" // {default = true;};
    defaultBrightness = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = 800;
      description = "Brightness to set at boot; null leaves the driver default.";
    };
  };

  config = lib.mkIf (cfg.enable && device.frontlight.sysfsName != null) {
    users.users.${config.remarkable.primaryUser}.extraGroups = ["video"];

    # stop_on_suspend via modprobe.d, applied AT module load: the boot-time
    # sysfs write below races the module and can silently lose (observed:
    # LED stays lit through suspend).
    boot.extraModprobeConfig = lib.optionalString (device.frontlight.kernelModule != null) ''
      options ${device.frontlight.kernelModule} stop_on_suspend=1
    '';

    # Make the backlight writable by the video group so unprivileged apps can
    # set brightness. %k is the backlight name.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="${device.frontlight.sysfsName}", RUN+="${pkgs.coreutils}/bin/chgrp video /sys/class/backlight/%k/brightness /sys/class/backlight/%k/bl_power", RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/backlight/%k/brightness /sys/class/backlight/%k/bl_power"
    '';

    systemd.services.remarkable-frontlight = lib.mkIf (cfg.defaultBrightness != null) {
      description = "front light default brightness";
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "remarkable-frontlight" ''
          # The backlight device can appear after multi-user; wait for it.
          for _ in $(seq 1 30); do [ -e ${node}/brightness ] && break; sleep 1; done
          ${lib.optionalString (device.frontlight.kernelModule != null) ''
            # Belt for the modprobe.d option (suspend blanking via
            # BL_CORE_SUSPENDRESUME).
            echo 1 > /sys/module/${device.frontlight.kernelModule}/parameters/stop_on_suspend 2>/dev/null || true
          ''}
          echo ${toString cfg.defaultBrightness} > ${node}/brightness 2>/dev/null || true
        '';
      };
    };
  };
}
