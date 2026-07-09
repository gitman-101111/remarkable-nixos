# Minimal reference config — the bare minimum to boot NixOS on a reMarkable
# Paper Pro Move. No secrets, no personal tooling: extract the vendor blobs
# from your own unit, set your own user + SSH key, flash, boot.
{...}: {
  networking.hostName = "rmppm";
  system.stateVersion = "26.05";

  # ── vendor-proprietary blobs (extract from YOUR device) ────────────────────
  # See the hardware layer's docs/obtaining-vendor-blobs.md. NOT redistributable.
  # Option names track the modules as they are ported; current surface:
  # remarkable.boot.ahabHeader = ./artifacts/ahab-header.bin;  # 8 KB pad from a vendor fitImage.ahab
  # remarkable.boot.vendorDtb = ./artifacts/chiappa-rev-h.dtb; # your PCBA revision's DTB
  # remarkable.eink.vendorRuntime = ./artifacts/eink-runtime;  # vendor Qt + epaper engine
  # remarkable.eink.waveforms = ./artifacts/waveforms;         # panel waveform tables
  # remarkable.eink.screens = ./artifacts/screens;             # lifecycle art PNGs (optional)

  # ── your user ──────────────────────────────────────────────────────────────
  # An authorized SSH key is all that's needed to log in — no secrets machinery.
  remarkable.primaryUser = "you";
  users.users.you = {
    isNormalUser = true;
    extraGroups = ["wheel" "video" "input" "dialout"];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA...replace-with-your-public-key... you@host"
    ];
  };

  # The modules bring up a USB ECM gadget + sshd. After flashing, log in over
  # USB:  ssh you@10.11.99.1
  #
  # Deploy: flash the built rootfs image over SDP (the boot-ROM USB download
  # mode) with uuu — scripts and walkthrough live in the hardware layer's
  # recovery/ and docs/booting-a-custom-os.md.
}
