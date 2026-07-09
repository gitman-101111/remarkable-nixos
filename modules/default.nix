# Subsystem aggregator (SKELETON — porting in progress).
#
# Each subsystem below is extracted from a proven daily-driven reference
# config, with personal bits (user, secrets, hostname, wifi) stripped and
# every device-specific constant lifted into the remarkable.device.* profile
# (see profile.nix). Subsystem map:
#
#   kernel.nix         BSP kernel via linuxManualConfig: vendor config +
#                      NixOS deltas (built-in ChipIdea USB, nftables,
#                      DM_INIT=n, ARM64 features the SoC lacks).
#   boot-image.nix     FIT/AHAB assembly (8 KB vendor header + FIT, gzipped
#                      kernel) + flashable ext4 rootfsImage with baked
#                      mountpoints, /init profile symlink, journal dir.
#   initrd.nix         systemd stage-1 hooks for the vendor U-Boot's baked
#                      cmdline: profile-fallback closure finder (no init=),
#                      sysroot rw drop-in (forced ro), no-op hibernate-resume
#                      generator (spurious resume=), rescue-flag clear,
#                      persist provisioning; stage-2 errcnt clear after
#                      multi-user (arms the U-Boot 3-strike slot rollback).
#   usbnet.nix         USB ECM gadget + pinned iface name; primary access.
#   eink.nix           einkbridge over the vendor Qt epaper engine (blob
#                      options: vendorRuntime, waveforms) + library readahead.
#   eink-screens.nix   lifecycle frames (power-on splash, sleep/shutdown/
#                      low-battery art) through the bridge.
#   power.nix          sleep/wake: power-key + folio-cover daemon (built from
#                      the hardware layer's sources), logind/polkit wiring,
#                      EPD suspend interactions, battery guard.
#   touch.nix          touch controller quirks (udev).
#   koreader.nix       KoReader as the reader UI (optional).
#   persistence.nix    /persist + whole-/home bind pattern (optional).
#
# Blob interface (all vendor-proprietary, extracted from the user's own
# unit — never shipped): AHAB header, vendor DTB, eink runtime, waveforms,
# lifecycle art. Null defaults + warnings, so everything evals without them.
{...}: {
  imports = [
    ./profile.nix
    ./kernel.nix
    ./boot-image.nix
    ./initrd.nix
    ./usbnet.nix
    ./eink.nix
    ./eink-screens.nix
    ./frontlight.nix
    ./power.nix
    ./touch.nix
    ./koreader.nix
    ./persistence.nix
  ];
}
