# Device profiles

One directory per device, named by its vendor codename (`chiappa` = Paper Pro
Move, `ferrari` = Paper Pro, …). A profile sets the `remarkable.device.*`
options (see `modules/profile.nix`) — panel geometry, DTB name, boot/SDP
addresses, partition layout, and the small sysfs facts the subsystems need.
Subsystem modules never hardcode a device fact; if porting a device reveals a
new baked-in constant, widen the profile surface instead.

## Adding a device

1. Copy `chiappa/` and fill in your device's facts.
2. Provide a hardware layer: kernel config + patches and any device sources.
   Small files can live right here in the profile directory; larger trees
   (a kernel patch stack) are cleaner as your own repo added as a flake input
   (see how `chiappa` is wired in `flake.nix`).
3. Blobs (boot headers, display runtimes, waveforms, firmware) are **never**
   committed — they stay options the user points at their own extraction.
4. Add `nixosModules.<codename>` and an `example/<codename>.nix` in
   `flake.nix`, mirroring the chiappa entries.

Devices sharing the i.MX 93 BSP lineage (Paper Pro family) are expected to
reuse the boot/initrd/power stack nearly unchanged; the genuinely per-device
work is usually panel geometry, waveforms, DTB, input/backlight controllers,
and partition sizes.

## Scope

The boot-image and initrd modules assume the Paper Pro family's boot
architecture: A/B rootfs slots, a FIT loaded from the active slot's /boot,
and lpgpr error-counter rollback. Earlier devices with a single-plane
partition layout (e.g. reMarkable 2) are out of scope for those modules —
supporting one would mean a parallel boot-image/initrd pair, not a profile.
