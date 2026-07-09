# Touch/pen controller quirks, as udev rules from the device's hardware layer.
# (Reference device: the elants_spi controller's runtime-PM autosuspend
# disables its IRQ and the resume path does not reliably restore scanning —
# the rule pins its runtime PM on.)
{
  config,
  lib,
  ...
}: let
  cfg = config.remarkable.touch;
  rules = config.remarkable.device.touch.udevRules;
in {
  options.remarkable.touch.enable =
    lib.mkEnableOption "touch-controller quirk rules" // {default = true;};

  config = lib.mkIf (cfg.enable && rules != null) {
    services.udev.extraRules = builtins.readFile rules;
  };
}
