# Vendor BSP kernel, built from a COMPLETE config via linuxManualConfig.
# Do NOT regenerate a device's config from a fragment: olddefconfig on a
# fragment silently drops platform options (on i.MX: CONFIG_ARCH_MXC and with
# it clocks, pinctrl, power domains, eMMC — everything).
#
# The device profile supplies source, config, patches, and toolchain via the
# remarkable.kernel.* options below (see devices/<codename>/kernel.nix).
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.remarkable.kernel;
  inherit (lib) mkOption types;
in {
  options.remarkable.kernel = {
    version = mkOption {
      type = types.str;
      description = "Kernel version string (matches the BSP source).";
    };
    modDirVersion = mkOption {
      type = types.str;
      description = "Full module dir version incl. CONFIG_LOCALVERSION suffix, so /lib/modules lines up.";
    };
    src = mkOption {
      type = types.package;
      description = "Kernel source (the vendor BSP tree/tarball).";
    };
    configFile = mkOption {
      type = types.path;
      description = "COMPLETE kernel config (vendor config + the device profile's deltas).";
    };
    patches = mkOption {
      type = types.listOf types.attrs;
      default = [];
      description = "kernelPatches list ({name, patch}) from the device's hardware layer.";
    };
    stdenv = mkOption {
      type = types.raw;
      default = pkgs.stdenv;
      defaultText = lib.literalExpression "pkgs.stdenv";
      description = "stdenv to build the kernel with (BSP kernels often need a specific gcc generation).";
    };
    initrdModules = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Exact module set stage 1 loads (replaces NixOS's defaults, which assume storage drivers a BSP kernel doesn't build).";
    };
  };

  config = {
    boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linuxManualConfig {
      inherit (cfg) version src stdenv;
      inherit (cfg) modDirVersion;
      configfile = cfg.configFile;
      # linuxManualConfig parses the config via IFD to derive kernel features.
      allowImportFromDerivation = true;
      kernelPatches = cfg.patches;
    });

    # These devices boot a FIT image (see boot-image.nix) with the DTB supplied
    # there; NixOS must not try to build/install DTBs itself.
    hardware.deviceTree.enable = lib.mkDefault false;

    # Storage for the root is built INTO the BSP kernel; NixOS's default initrd
    # module set pulls in ahci/nvme/etc. the kernel doesn't build, which fails
    # the module-shrink step. Ship exactly what the device profile asks for.
    boot.initrd.includeDefaultModules = false;
    boot.initrd.availableKernelModules = lib.mkForce cfg.initrdModules;
    boot.initrd.kernelModules = lib.mkForce cfg.initrdModules;
  };
}
