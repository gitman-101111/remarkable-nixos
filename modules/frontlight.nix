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
          ${lib.optionalString (device.frontlight.kernelModule != null) ''
            # Suspend handling is behind the driver's stop_on_suspend module
            # param (adds BL_CORE_SUSPENDRESUME: the backlight core blanks the
            # LED across suspend and restores it on resume). Default N = light
            # stays lit while asleep. Runtime-writable.
            echo 1 > /sys/module/${device.frontlight.kernelModule}/parameters/stop_on_suspend 2>/dev/null || true
          ''}
          echo ${toString cfg.defaultBrightness} > ${node}/brightness 2>/dev/null || true
        '';
      };
    };
  };
}
