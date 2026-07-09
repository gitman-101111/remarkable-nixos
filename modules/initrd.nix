# A/B boot-flow hooks. Stage 1 (systemd initrd): rescue-flag clear, /persist
# provisioning/repair, and overrides for the vendor U-Boot's baked cmdline
# (no init=, forced ro, spurious resume=). Stage 2: A/B error-counter clear
# after multi-user (the healthy-boot marker for U-Boot's slot rollback).
{
  config,
  lib,
  pkgs,
  ...
}: let
  device = config.remarkable.device;
  bb = "${pkgs.busybox}/bin";
  e2 = "${pkgs.e2fsprogs}/bin";
  hasPersist = config.remarkable.persistence.enable;

  # Rescue-flag clear (stage 1): recovery mode sets a persistent rescue flag
  # in SNVS (lpgpr) that injects `systemd.setenv=RESCUE=1` bootargs on every
  # subsequent boot, wedging stage 2 — so it must be cleared before stage 2
  # runs. The A/B error counters are deliberately NOT cleared here: they are
  # cleared by the errcnt service only after multi-user.target, so a boot
  # that fails anywhere before a fully working system still counts toward the
  # U-Boot 3-strike slot rollback.
  lpgprClear = pkgs.writeShellScript "initrd-lpgpr-clear" ''
    LP=${device.lpgprPath}
    echo 0 > "$LP/swu_recovery" 2>/dev/null || echo "remarkable: clear swu_recovery failed"
    echo regular > "$LP/boot_flow" 2>/dev/null || echo "remarkable: set boot_flow=regular failed"
    exit 0
  '';

  # Healthy-boot marker (stage 2): the vendor U-Boot increments the active
  # slot's error counter in SNVS (lpgpr) on every boot attempt and rolls to
  # the other slot at 3 strikes. Clearing only after multi-user.target makes
  # that rollback actually protective — any earlier failure leaves the count.
  errcntClear = pkgs.writeShellScript "remarkable-errcnt-clear" ''
    LP=${device.lpgprPath}
    for s in a b; do
      echo 0 > "$LP/root''${s}_errcnt" 2>/dev/null || echo "remarkable: clear root''${s}_errcnt failed"
    done
    exit 0
  '';

  # /persist auto-provision + repair, BEFORE sysroot-persist.mount.
  # Non-destructive: only formats a partition with no/non-ext4 filesystem; an
  # existing ext4 is preened, never reformatted.
  persistProvision = pkgs.writeShellScript "initrd-persist-provision" ''
    persistdev=/dev/disk/by-partlabel/${device.partitions.persistPartlabel}
    i=0
    while [ ! -e "$persistdev" ] && [ $i -lt 20 ]; do ${bb}/sleep 0.5; i=$((i + 1)); done
    [ -e "$persistdev" ] || exit 0
    fstype=$(${pkgs.util-linux}/bin/blkid -o value -s TYPE "$persistdev" 2>/dev/null); rc=$?
    if [ "$rc" = 2 ]; then
      echo "remarkable: /persist has no filesystem — creating ext4"
      ${e2}/mkfs.ext4 -F -L persist "$persistdev"
    elif [ "$rc" = 0 ] && [ "$fstype" != ext4 ]; then
      # Never reformat a foreign filesystem — worst case it is vendor-owned
      # user data (see docs/partitioning.md). nofail skips the mount.
      echo "remarkable: /persist partition holds '$fstype', not ext4 — refusing to touch it (repartition for this layout first; see docs/partitioning.md)"
    elif [ "$rc" = 0 ]; then
      ${bb}/timeout 120 ${e2}/e2fsck -p "$persistdev"; frc=$?
      if [ "$frc" -le 1 ]; then
        echo "remarkable: /persist ext4 healthy (e2fsck rc=$frc)"
      else
        echo "remarkable: WARNING /persist ext4 needs manual fsck (e2fsck rc=$frc) — leaving intact (nofail skips the mount)"
      fi
    fi
    # Ensure /persist/home exists for a /home bind mount.
    ${bb}/mkdir -p /mnt-persist
    if ${bb}/mount -t ext4 "$persistdev" /mnt-persist 2>/dev/null; then
      ${bb}/mkdir -p /mnt-persist/home
      ${bb}/sync
      ${bb}/umount /mnt-persist 2>/dev/null
    fi
    exit 0
  '';

  # No-op shadow for systemd-hibernate-resume-generator: the vendor U-Boot
  # injects resume=/dev/dm-1 on every cmdline, but with CONFIG_DM_INIT=n that
  # device never appears — the generated resume unit would stall boot on a
  # 90 s device timeout every cold boot. /etc generators shadow /usr/lib ones
  # by name.
  noopGenerator = pkgs.writeShellScript "systemd-hibernate-resume-generator" ''
    exit 0
  '';

  # Replacement closure finder: the stock initrd-find-nixos-closure requires
  # `init=` on the kernel cmdline and exits 1 without it, but the vendor
  # U-Boot's bootargs are baked and never carry init=. Falls back to the
  # system profile in the mounted sysroot. Output contract matches stock:
  # /nixos-closure symlink + /etc/switch-root.conf.
  findClosure = pkgs.writeScript "remarkable-find-nixos-closure" ''
    #!${pkgs.busybox}/bin/sh
    export PATH=${pkgs.busybox}/bin
    closure=
    for o in $(cat /proc/cmdline); do
      case $o in init=*) closure=''${o#init=}; closure=$(dirname "$closure");; esac
    done
    if [ -z "$closure" ]; then
      # Walk the profile symlink chain manually: busybox `readlink -f`
      # mis-resolves when the final target does not exist in the CURRENT root
      # (the store path only exists under /sysroot). Relative targets resolve
      # against the link's directory; absolute ones are sysroot-relative.
      p=/sysroot/nix/var/nix/profiles/system
      for _ in 1 2 3 4 5 6 7 8; do
        t=$(readlink "$p" 2>/dev/null) || break
        case "$t" in
          /*) p="/sysroot$t" ;;
          *) p="$(dirname "$p")/$t" ;;
        esac
      done
      closure=''${p#/sysroot}
      [ "$closure" != "$p" ] || { echo "remarkable find-closure: profile walk left sysroot: $p" >&2; exit 1; }
      [ -d "/sysroot$closure" ] || { echo "remarkable find-closure: closure not in sysroot: $closure" >&2; exit 1; }
    fi
    [ -n "$closure" ] || { echo "remarkable find-closure: no init= and no profile" >&2; exit 1; }
    ln -sf "$closure" /nixos-closure
    echo "NEW_INIT=" > /etc/switch-root.conf
  '';
in {
  # The stage-1 /persist provisioning below is gated on
  # remarkable.persistence.enable (declared in persistence.nix).
  config = lib.mkMerge [
    {
      boot.initrd.systemd = {
        contents."/etc/systemd/system-generators/systemd-hibernate-resume-generator".source = noopGenerator;

        services.initrd-find-nixos-closure.serviceConfig.ExecStart =
          lib.mkForce ["" "${findClosure}"];

        # The vendor U-Boot bakes `ro` into the cmdline, so the runtime-
        # generated sysroot.mount mounts the root read-only — but
        # initrd-nixos-activation chroots into sysroot and prepare-root MUST
        # write there (creates /etc); parse-etc and the sysroot-* mounts also
        # need mkdir. Drop-in on the generated unit (asDropin keeps the
        # generator's per-slot What= from root= and overrides only the
        # options): rw from the start.
        units."sysroot.mount" = {
          text = ''
            [Mount]
            Options=rw
          '';
          overrideStrategy = "asDropin";
        };

        services.remarkable-lpgpr = {
          description = "clear rescue flags (lpgpr)";
          wantedBy = ["initrd.target"];
          before = ["initrd-fs.target"];
          # No default deps: must run even when the boot never reaches
          # basic.target (lpgpr only needs sysfs, mounted before any unit).
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lpgprClear;
          };
        };

        # Everything the units execute must be listed explicitly — unit files
        # are generated, but their ExecStart closures are not scanned, and
        # missing entries fail as 203/EXEC.
        storePaths =
          [
            lpgprClear
            findClosure
            pkgs.busybox
          ]
          ++ lib.optionals hasPersist [
            persistProvision
            "${pkgs.e2fsprogs}/bin"
            "${pkgs.util-linux}/bin/blkid"
          ];
      };

      # Stage-2 counterpart of the lpgpr handling above: reset the A/B error
      # counters only once the system has proven itself.
      systemd.services.remarkable-errcnt-clear = {
        description = "clear A/B boot error counters after reaching multi-user";
        wantedBy = ["multi-user.target"];
        after = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = errcntClear;
        };
      };

      # No userspace fsck on the journaling root: fsck-at-boot can reboot-loop
      # or hang on a device with no console; ext4 recovers at mount time via
      # the kernel journal.
      fileSystems."/".noCheck = true;
    }

    (lib.mkIf hasPersist {
      boot.initrd.systemd.services.remarkable-persist-provision = {
        description = "provision/repair /persist before mount";
        wantedBy = ["initrd-fs.target"];
        before = ["sysroot-persist.mount"];
        after = ["remarkable-lpgpr.service"];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = persistProvision;
        };
      };

      # /persist gets an explicit e2fsck -p in the provision hook instead.
      fileSystems."/persist".noCheck = true;
    })
  ];
}
