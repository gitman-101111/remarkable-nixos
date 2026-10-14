# chiappa kernel: upstream Linux plus the hardware layer's kernel/ series and
# complete config. WiFi (NXP IW611) is NXP's out-of-tree mwifiex, built as an
# external module package.
{
  config,
  pkgs,
  lib,
  hardware-chiappa,
  linux-mainline,
  nxp-mwifiex,
  ...
}: let
  kernelDir = "${hardware-chiappa}/kernel";
  makefile = builtins.readFile "${linux-mainline}/Makefile";
  field = name: lib.trim (lib.removePrefix "${name} =" (lib.findFirst (lib.hasPrefix "${name} =") "" (lib.splitString "\n" makefile)));
  version = "${field "VERSION"}.${field "PATCHLEVEL"}.${field "SUBLEVEL"}${field "EXTRAVERSION"}";

  # Re-store the patch and config bytes so the kernel only rebuilds when they
  # change, not on every hardware-layer bump.
  patchNames = lib.sort lib.lessThan (lib.filter (lib.hasSuffix ".patch") (builtins.attrNames (builtins.readDir kernelDir)));
  mkPatch = fname: {
    name = lib.removeSuffix ".patch" fname;
    patch = builtins.toFile fname (builtins.readFile "${kernelDir}/${fname}");
  };
  configFile = pkgs.writeText "chiappa-kernel.config" (builtins.readFile "${kernelDir}/config-chiappa-mainline.aarch64");

  kernel = config.boot.kernelPackages.kernel;

  # Only the SDIO IW61x (SD9177) path out of everything NXP's Makefile enables.
  iw61x = pkgs.stdenv.mkDerivation {
    pname = "nxp-mwifiex-iw61x";
    version = "${nxp-mwifiex.shortRev or "unstable"}-${kernel.version}";
    src = nxp-mwifiex;
    patches = map (f: builtins.toFile f (builtins.readFile "${kernelDir}/mwifiex/${f}")) (lib.filter (lib.hasSuffix ".patch") (builtins.attrNames (builtins.readDir "${kernelDir}/mwifiex")));
    nativeBuildInputs = kernel.moduleBuildDependencies;
    makeFlags =
      kernel.commonMakeFlags
      ++ [
        "KERNELDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
        "CONFIG_SD8978=n"
        "CONFIG_SD8987=n"
        "CONFIG_SD9098=n"
        "CONFIG_PCIE9098=n"
        "CONFIG_SDIW610=n"
        "CONFIG_USBIW610=n"
        "CONFIG_SDAW693=n"
        "CONFIG_PCIEAW693=n"
        "CONFIG_SD9177=y"
      ];
    buildFlags = ["build"];
    enableParallelBuilding = true;
    installPhase = ''
      runHook preInstall
      install -Dm644 -t $out/lib/modules/${kernel.modDirVersion}/extra bin_wlan/*.ko
      runHook postInstall
    '';
    meta.license = lib.licenses.gpl2Only;
  };
in {
  remarkable.kernel = {
    inherit version configFile;
    modDirVersion = "${version}-chiappa";
    src = linux-mainline;
    patches = map mkPatch patchNames;
    # eMMC, ext4 and the USB gadget are built in; stage 1 only needs the
    # Type-C chain that makes the headless USB link enumerate: fusb303b's
    # vbus-power-supply is the max77818 charger, so its probe defers until
    # that module is loaded.
    initrdModules = ["max77818_charger" "typec" "fusb303b"];
  };

  boot.extraModulePackages = [iw61x];
  # NXP's SDIO id table has no IW61x entry, so nothing autoloads it.
  boot.kernelModules = ["moal"];
}
