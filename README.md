# remarkable-nixos

Run **NixOS** on reMarkable paper tablets.

A Nix flake of per-subsystem NixOS modules (boot image, kernel, stage-1 hooks,
USB networking, e-ink, power/sleep, reader UI) driven by per-device profiles
under [`devices/`](devices/). The reference device is the **reMarkable Paper
Pro Move** (codename *chiappa*, NXP i.MX 93), extracted from a daily-driven
system; other devices — the Paper Pro (*ferrari*) being the natural next — add
a profile beside it. Bring your own (extracted) vendor blobs and an SSH key.

> **Status: working.** All subsystem modules are extracted from — and daily
> drive — the reference device (boot, e-ink, sleep/wake, KoReader,
> persistence). Interfaces (`remarkable.*` options, device profiles) may still
> move before a tagged release.

## Layering

```
chiappa           distro-agnostic hardware layer for the Paper Pro Move —
  (upstream)      kernel source pin + patches + config, e-ink bridge and
                  power-daemon sources, blob-extraction scripts, hardware/
                  boot/recovery docs. Usable by any distro.
     ▲
     │ inputs (flake=false; modules read paths out of it — other devices
     │         wire in their own hardware layer the same way)
     │
remarkable-nixos  the NixOS integration — subsystem modules parameterized by
  (this repo)     a device profile (remarkable.device.*), one profile per
                  device under devices/<codename>/.
     ▲
     │ your flake imports nixosModules.<codename>
     │
your config       your user + SSH key + the vendor blobs extracted from your
  (private)       own unit. Blobs never ship in any public repo.
```

## Usage (planned)

```nix
{
  inputs.remarkable-nixos.url = "github:gitman-101111/remarkable-nixos";

  outputs = {nixpkgs, remarkable-nixos, ...}: {
    nixosConfigurations.mytablet = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";                    # build on aarch64 or via binfmt
      modules = [
        remarkable-nixos.nixosModules.chiappa      # subsystems + device profile
        ./my-config.nix                            # your user + extracted blobs
      ];
    };
  };
}
```

See [`example/chiappa.nix`](example/chiappa.nix) for the minimum.

## What you must provide

The vendor's firmware/runtime is **proprietary and not redistributable**, so
you extract it from your own unit. The
[chiappa](https://github.com/gitman-101111/chiappa) hardware layer documents
and scripts the whole process —
[`docs/obtaining-vendor-blobs.md`](https://github.com/gitman-101111/chiappa/blob/main/docs/obtaining-vendor-blobs.md)
walks it end to end (the recommended route needs only reMarkable's public
recovery image, via `recovery/fetch-recovery-image.sh` +
`firmware/extract.sh`; no running vendor OS required). Point the options at
the results:

| Option | What to extract |
|--------|-----------------|
| `remarkable.boot.ahabHeader` | 8 KB AHAB header: `dd if=vendor-fitImage.ahab bs=8192 count=1` |
| `remarkable.boot.vendorDtb` | your PCBA revision's DTB (from the vendor FIT/recovery image) |
| `remarkable.eink.vendorRuntime` | the vendor Qt + `libqsgepaper` e-ink runtime bundle |
| `remarkable.eink.waveforms` | panel waveform/colortable tables (`/usr/share/remarkable`) |
| `remarkable.eink.screens` | (optional) vendor lifecycle art PNGs |
| `hardware.firmware` | WiFi/BT/NFC/touch firmware → wire into `/lib/firmware` |

No secrets machinery is assumed — a normal user with an authorized SSH key is
enough to boot and log in.

## Quickstart

1. Enable **Developer Mode** on the device (unlocks unsigned-FIT boot).
2. Extract the vendor blobs (table above; scripts + docs in
   [chiappa](https://github.com/gitman-101111/chiappa)).
3. Repartition once for the A/B + `/persist` layout —
   [`docs/partitioning.md`](docs/partitioning.md). Mind the size trap noted
   there: your FIRST image (pre-repartition) must be minimal to fit the
   vendor-sized 4 GiB slot.
4. Write your config from [`example/chiappa.nix`](example/chiappa.nix) and
   build the flashable image:
   `nix build .#nixosConfigurations.<yours>.config.remarkable.boot.rootfsImage`
5. Flash it over SDP with `uuu` (scripts in chiappa's `recovery/uuu-scripts/`)
   and boot. Updates are new images flashed the same way; `/persist` carries
   your data across them.

## Prerequisites

- **Developer Mode** enabled on the device (moves it to AHAB OEM-Open so
  unsigned FITs boot). See
  [`docs/booting-a-custom-os.md`](https://github.com/gitman-101111/chiappa/blob/main/docs/booting-a-custom-os.md).
- An aarch64 builder (native, or x86_64 with `boot.binfmt.emulatedSystems`).
- The vendor recovery path as an unbrick fallback —
  [`docs/recovery.md`](https://github.com/gitman-101111/chiappa/blob/main/docs/recovery.md).

## Install flow (planned)

1. Build the flashable rootfs image (kernel + closure + FIT baked in).
2. Flash it over SDP (the boot-ROM USB download mode) with `uuu` — scripts in
   the hardware layer's `recovery/`.
3. Boot. The persistent data partition provisions itself on first boot.

## Adding a device

See [`devices/README.md`](devices/README.md).

## Credit

Built on the [`chiappa`](https://github.com/gitman-101111/chiappa)
hardware-layer project. Community effort to keep this genuinely-nice hardware
open.
