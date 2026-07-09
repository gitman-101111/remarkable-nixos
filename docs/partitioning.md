# Partitioning a device for remarkable-nixos

reMarkable Paper Pro Move (codename *chiappa*), 64 GB eMMC. This is the one-time
step that reshapes the vendor's eMMC layout into the A/B-image + persistent-data
layout remarkable-nixos expects. The authoritative table is
[`install/partition-layout.sfdisk`](../install/partition-layout.sfdisk); this doc
is the how and why.

## Target layout

| Part | Name | Size | Filesystem | Use |
|------|------|------|------------|-----|
| `mmcblk0p1` | `data` | 100 MiB | ext4 | vendor scratch |
| `mmcblk0p2` | `root_a` | 8 GiB | ext4 | NixOS rootfs **slot A** |
| `mmcblk0p3` | `root_b` | 8 GiB | ext4 | NixOS rootfs **slot B** |
| `mmcblk0p4` | `home` | ~42.2 GiB (rest) | ext4 | `/persist` (persistent data + the whole-`/home` bind; survives A/B redeploys) |
| `mmcblk0boot0/1` | — | 4 MiB each | raw | **imx-boot / U-Boot A/B — NOT in this GPT** |

Sectors are contiguous and fill the disk (see the sfdisk file for exact
start/size). The two `mmcblk0bootN` hardware boot partitions are *separate* from
the GPT of the data area — repartitioning never touches them, so the boot chain
(ELE → SPL → ATF → U-Boot) is safe.

### Why this shape

- **8 GiB roots** (vendor ships ~4 GiB): a NixOS system closure + its FIT image
  don't fit comfortably in 4 GiB. 8 GiB leaves headroom for a generation or two.
- **No swap partition** (vendor has a 1.6 GiB dm-crypt swap on p4): zram
  instead — no eMMC wear, no fixed carve-out. **This frees p4.** The vendor
  U-Boot still hardcodes `swappart=4` and injects `dm-mod.create=…mmcblk0p4…`
  onto every kernel cmdline, so the remarkable-nixos kernel is built
  `CONFIG_DM_INIT=n` to ignore it; that is what lets p4 hold `/persist` instead.
  **Do not enable `DM_INIT` without moving `/persist` off p4.**
- **Persistent data on its own partition** (not a dir on the root slot): it
  survives A/B root redeploys, so user data, `/home`, SSH host keys, and any
  per-device secrets persist across image flashes.
- **ext4 everywhere**: uniform with the root slots; one fsck path.

### Names are load-bearing

Keep the GPT partition **names** exactly (`root_a`, `root_b`, `home`):
- U-Boot's `mmcargs` injects `dm-mod.waitfor="PARTLABEL=root_a"` — the kernel
  blocks boot until that name exists.
- remarkable-nixos resolves the persistent partition by GPT name
  (`by-partlabel`), deliberately never by filesystem label.

Partition and disk **UUIDs** don't matter (the sfdisk file omits them so each
device gets fresh ones).

## Why you can NOT dual-boot the vendor OS

Tempting idea — vendor OS on one slot, a minimal NixOS on the other, no
repartition — but the vendor layout leaves NixOS nowhere safe to live:

- The vendor OS keeps **all** of its user data on p5, an encrypted partition
  it expects exclusive ownership of. Erasing, reformatting, or hijacking p5
  in ANY way breaks the vendor install — observed failure modes range from a
  corrupted-filesystem "Repair and Restart" screen to persistent "Storage is
  almost full" errors, with the user data unrecoverable either way.
- Without repartitioning, p4 (the vendor's dm-crypt swap) and p5 are the only
  space a NixOS `/persist` could claim — i.e. there is no persistence home
  that isn't vendor-owned. Worse, p5's GPT name is `home`, the very name this
  layout uses for `/persist`, so a NixOS slot booted into the vendor layout
  resolves `by-partlabel/home` straight to the vendor's data partition.
- The stage-1 provisioning refuses to touch a non-ext4 filesystem, so the
  default outcome is "no persistence" rather than data loss — but that still
  isn't a usable system, and it's one misconfiguration away from eating the
  vendor's userdata.

The repartition is one-way **by design**: it deletes the vendor swap and
encrypted home. The way back to the vendor OS is its recovery flow
(`rm_recover` — see the `chiappa` repo's `docs/recovery.md`), not a parallel
install.

## The safe recipe (from the device itself, no external rescue)

The one invariant that makes this doable without a separate rescue environment:
**`root_a` (p2) keeps the vendor start sector** (both vendor and target place it
immediately after the 100 MiB `data` p1). So p2 only ever *grows in place* — its
data never moves — and you can rewrite the table while booted from it. Everything
else being reshaped (p3 moves; the vendor swap + encrypted /home are deleted) is
*not in use* in the steps below.

1. **Get a first NixOS onto the vendor slot A** and boot it. Flash the
   remarkable-nixos rootfs image to `mmcblk0p2` — over SDP-booted fastboot
   (`flash -raw2sparse root_a <img>`, see the `chiappa` repo's
   `recovery/uuu-scripts/sdp-flash-root-a.uuu`) or by `dd` from the vendor OS —
   then boot it. `/persist` is not yet on p4, so p4/p5 are untouched.

   > **Size trap:** the vendor slot is only ~4 GiB, and a full config's image
   > (reader app + vendor Qt runtime + firmware) is ~5 GiB and will NOT fit.
   > Build this FIRST image from a minimal config (the flake's
   > `example/chiappa.nix` without optional extras) — it fits comfortably.
   > Flash your full image after step 2 has grown the slots to 8 GiB.

2. **Rewrite the GPT** (p2 grows in place, p3 moves, vendor swap+home dropped,
   new `home` created). Booted from p2, with nothing on p3/p4/p5 mounted:
   ```sh
   sfdisk --label gpt /dev/mmcblk0 < install/partition-layout.sfdisk
   partprobe /dev/mmcblk0 || true      # or just reboot to re-read
   ```
   sfdisk may warn that it can't re-read the table because the disk is in use —
   expected. The write itself succeeds; a reboot picks it up.

3. **Grow the slot-A filesystem** into the enlarged partition:
   ```sh
   resize2fs /dev/mmcblk0p2            # online grow is safe (ext4)
   ```

4. **`/persist` (p4) auto-provisions** on the next boot: remarkable-nixos's
   stage-1 creates an ext4 there if p4 has no filesystem yet (it never
   reformats an existing one). If your config expects per-device secrets on it
   (e.g. an age key), place them afterward.

5. **Deploy slot B** (p3): flash the rootfs image over SDP (see the hardware
   layer's `recovery/uuu-scripts/`), or `dd` it onto the inactive slot from
   the running system.

### Alternative: from a RAM rescue / SDP

If you'd rather not stage through slot A, apply the sfdisk table from any Linux
where **none of mmcblk0's data partitions are mounted** (a rescue initramfs
booted over SDP, etc.). There the whole table can be rewritten in one shot with
no in-use caveat. A disko-based one-shot installer is a TODO for this flake.

## Safety net

- The `mmcblk0bootN` bootloaders are never touched by GPT edits, so the device
  always still enters U-Boot and its **SDP serial-download recovery**
  (hold power + USB). Full unbrick is always available — see the `chiappa`
  repo's `docs/recovery.md`.
- Never repartition in a way that changes `root_a`'s **start** while booted from
  it, or moves/shrinks a partition whose filesystem is mounted.
- The A/B error-counter rollback still protects you: a slot that fails to boot 3×
  rolls back to the other slot.
