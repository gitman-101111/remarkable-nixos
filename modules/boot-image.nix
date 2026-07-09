# Boot image: the vendor U-Boot loads /boot/fitImage.ahab from the active
# rootfs slot. That file is [8 KB AHAB header][FIT(kernel + dtb + initrd)].
#
# On an unlocked (OEM-Open) device the AHAB header is not verified, but U-Boot
# still expects the FIT to parse at offset 0x2000 — so an 8 KB header extracted
# from a vendor fitImage.ahab is prepended (user-provided; not redistributable).
#
# NixOS's normal bootloader installers do not apply here: installBootLoader is
# a loud no-op and the FIT ships inside the flashable rootfs image.
{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}: let
  cfg = config.remarkable.boot;
  device = config.remarkable.device;
  inherit (lib) mkOption types;

  kernelImage = "${config.boot.kernelPackages.kernel}/Image";
  # Optionally gzip the kernel inside the FIT (U-Boot decompresses at bootm);
  # roughly halves the kernel's share of the FIT.
  kernelImageGz = pkgs.runCommand "Image.gz" {} ''
    ${pkgs.gzip}/bin/gzip -9nc ${kernelImage} > $out
  '';
  kernelData =
    if cfg.compressKernel
    then kernelImageGz
    else kernelImage;
  kernelComp =
    if cfg.compressKernel
    then "gzip"
    else "none";

  # Prefer the vendor-shipped DTB over the kernel-tree one: on the reference
  # device the kernel-tree DTB hangs early in boot; every boot that has ever
  # worked used the vendor DTB.
  dtb =
    if cfg.vendorDtb != null
    then cfg.vendorDtb
    else "${config.boot.kernelPackages.kernel}/dtbs/freescale/${device.dtbName}";
  initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";

  # U-Boot picks the FIT configuration BY NAME, derived from its fdtfile env
  # ("freescale/<dtb>" with '/' -> '_'). A FIT whose configs aren't named like
  # that (e.g. a generic "conf-1") makes U-Boot stall on the boot splash
  # without ever loading the kernel. The device profile lists every config
  # name its board revisions can ask for (revisions sharing a byte-identical
  # DTB are served by aliases of one fdt image).
  #
  # No hash node in config entries — hashes live in the image nodes; FITs that
  # provably boot these devices have bare configs, match that exactly.
  configurations = lib.concatMapStrings (name: ''
    ${name} {
        description = "${name}";
        kernel = "kernel-1";
        fdt = "fdt-1";
        ramdisk = "ramdisk-1";
    };
  '') device.boot.fitConfigNames;

  its = pkgs.writeText "${device.codename}.its" ''
    /dts-v1/;
    / {
        description = "${device.codename} (NixOS)";
        #address-cells = <1>;
        images {
            kernel-1 {
                description = "Linux kernel";
                data = /incbin/("${kernelData}");
                type = "kernel";
                arch = "arm64";
                os = "linux";
                compression = "${kernelComp}";
                load = <${device.boot.kernelLoadAddr}>;
                entry = <${device.boot.kernelLoadAddr}>;
                hash-1 { algo = "sha256"; };
            };
            fdt-1 {
                description = "${device.codename} DTB";
                data = /incbin/("${dtb}");
                type = "flat_dt";
                arch = "arm64";
                compression = "none";
                hash-1 { algo = "sha256"; };
            };
            ramdisk-1 {
                description = "NixOS initrd";
                data = /incbin/("${initrd}");
                type = "ramdisk";
                arch = "arm64";
                os = "linux";
                compression = "none";
                hash-1 { algo = "sha256"; };
            };
        };
        configurations {
            default = "${device.boot.fitDefaultConfig}";
            ${configurations}
        };
    };
  '';

  fitImage =
    if cfg.ahabHeader == null
    then throw "remarkable.boot.ahabHeader is unset — provide an 8 KB AHAB header from a vendor fitImage.ahab before building system.build.fitImage (see the hardware layer's docs/fitimage.md)."
    else
      pkgs.runCommand "${device.codename}-fitImage.ahab" {
        nativeBuildInputs = [pkgs.ubootTools pkgs.dtc];
      } ''
        mkimage -f ${its} fit.itb
        # Prepend the 8 KB AHAB header so the FIT parses at 0x2000.
        cat ${cfg.ahabHeader} fit.itb > $out
      '';

  # A raw ext4 image of the whole system, ready to flash onto an A/B slot
  # partition (SDP/uuu, or dd from a running system onto the INACTIVE slot).
  # Contains the closure, the registered `system` profile, and the FIT at
  # /boot/fitImage.ahab (where U-Boot's ext4load looks). No on-device Nix is
  # needed to deploy — the device just receives a filesystem.
  rootfsImage = pkgs.callPackage "${toString modulesPath}/../lib/make-ext4-fs.nix" {
    storePaths = [config.system.build.toplevel];
    volumeLabel = "nixos";
    populateImageCommands = ''
      mkdir -p ./files/nix/var/nix/profiles
      ln -sf ${config.system.build.toplevel} ./files/nix/var/nix/profiles/system-1-link
      ln -sf system-1-link ./files/nix/var/nix/profiles/system
      # Mountpoints for the stage-1 sysroot mounts, baked into the image so
      # mounting never depends on the root being writable.
      mkdir -p ./files/persist ./files/home ./files/run
      mkdir -p ./files/boot
      cp ${fitImage} ./files/boot/fitImage.ahab
      # The vendor U-Boot sets root= (active slot) but no init=. NixOS's initrd
      # defaults to the system profile when init= is absent (see initrd.nix),
      # and a stable /init -> profile symlink covers scripted stage-1 fallbacks
      # too. The symlink follows the profile, so redeploys just update the
      # target.
      ln -sf /nix/var/nix/profiles/system/init ./files/init
      # Persistent journal from the very first boot: journald flushes to disk
      # when /var/log/journal exists, so even a wedged early boot's log
      # survives for a later boot (or offline mount) to read — the no-UART
      # debug channel.
      mkdir -p ./files/var/log/journal
    '';
  };
in {
  options.remarkable.boot = {
    compressKernel = mkOption {
      type = types.bool;
      default = true;
      description = "gzip the kernel inside the FIT (U-Boot decompresses at bootm), shrinking the FIT substantially.";
    };
    vendorDtb = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Vendor-shipped DTB to embed in the FIT (extract from a vendor
        fitImage.ahab or recovery image; not redistributable). When null,
        falls back to the kernel-tree DTB (remarkable.device.dtbName) — known
        to hang the reference device; only useful for experiments.
      '';
    };
    ahabHeader = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to an 8 KB AHAB header extracted from a vendor fitImage.ahab
        (`dd if=vendor-fitImage.ahab bs=8192 count=1`). Not redistributable —
        provide your own. Building system.build.fitImage without it throws.
      '';
    };
    fitImage = mkOption {
      type = types.package;
      readOnly = true;
      description = "The built fitImage.ahab, ready to deploy to a slot's /boot.";
    };
    rootfsImage = mkOption {
      type = types.package;
      readOnly = true;
      description = "Raw ext4 image of the system, to flash onto an A/B slot partition.";
    };
  };

  config = {
    remarkable.boot.fitImage = fitImage;
    remarkable.boot.rootfsImage = rootfsImage;
    system.build.fitImage = fitImage;
    system.build.rootfsImage = rootfsImage;

    # Root is whichever A/B slot the vendor U-Boot put on the cmdline (systemd
    # stage-1 honors root= per slot); this entry registers the fs and grows a
    # freshly flashed slot's image-sized fs to fill its partition on boot.
    fileSystems."/" = {
      device = lib.mkDefault device.partitions.rootA;
      fsType = "ext4";
      autoResize = true;
    };

    # slot switching + fs tools for on-device work
    environment.systemPackages = [pkgs.mmc-utils pkgs.e2fsprogs];

    # No NixOS-installable bootloader — the FIT ships inside the flashed
    # image. Replace the installer with a loud no-op so profile updates work
    # without touching boot.
    system.build.installBootLoader = pkgs.writeShellScript "remarkable-no-install-bootloader" ''
      echo "--------------------------------------------------------------------------------"
      echo "remarkable-nixos: bootloader install skipped."
      echo "The system closure (rootfs) was updated. If the kernel or initrd changed,"
      echo "rebuild and deploy the FIT:  system.build.fitImage -> <slot>/boot/fitImage.ahab"
      echo "--------------------------------------------------------------------------------"
      exit 0
    '';
    boot.loader.grub.enable = lib.mkForce false;
    boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
  };
}
