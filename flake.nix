{
  description = "NixOS on reMarkable paper tablets — per-subsystem modules + per-device profiles";

  # SKELETON / WIP: modules are being extracted from a proven-working config
  # (reMarkable Paper Pro Move, fully daily-driven). The public interface —
  # per-subsystem nixosModules, `remarkable.*` options, `devices/<codename>/`
  # profiles — is settled here so downstream users have a stable shape to
  # target, and so new devices slot in beside the existing ones.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Distro-agnostic hardware layer for the Paper Pro Move (codename
    # chiappa): kernel source pin + patches + config, the e-ink bridge and
    # power-daemon sources, blob-extraction scripts, hardware docs.
    # flake=false: a plain source tree the modules read paths out of.
    # Other devices may add their own hardware-layer input alongside this one
    # (or vendor small files directly under devices/<codename>/).
    chiappa = {
      url = "github:gitman-101111/chiappa";
      flake = false;
    };

    # Kernel: a kernel.org release pinned together with chiappa's kernel/ series.
    linux-mainline = {
      url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.10.tar.xz";
      flake = false;
    };

    nxp-mwifiex = {
      url = "github:nxp-imx/mwifiex/lf-6.18.37-2.1.0";
      flake = false;
    };

    koreader = {
      url = "https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-remarkable-aarch64-v2026.07.1.zip";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    chiappa,
    linux-mainline,
    nxp-mwifiex,
    koreader,
    ...
  }: let
    system = "aarch64-linux";
    # Everything targets aarch64; x86_64 users cross-build or use binfmt.
    forSystem = f: nixpkgs.lib.genAttrs [system "x86_64-linux"] (s: f nixpkgs.legacyPackages.${s});
  in {
    # ── Subsystem modules ────────────────────────────────────────────────────
    # Each is independently importable and reads device facts from the
    # `remarkable.device.*` profile options — no subsystem hardcodes a device.
    # `default` aggregates all subsystems (still device-less: import a device
    # module below, which pulls in the subsystems AND the device's profile).
    nixosModules = {
      default = {
        imports = [./modules];
        remarkable.koreader.src = nixpkgs.lib.mkDefault koreader;
      };

      # Device modules: subsystems + that device's facts. Import ONE.
      chiappa = {
        imports = [
          self.nixosModules.default
          ./devices/chiappa
        ];
        _module.args.hardware-chiappa = chiappa;
        _module.args.linux-mainline = linux-mainline;
        _module.args.nxp-mwifiex = nxp-mwifiex;
      };
      # ferrari = ...   (reMarkable Paper Pro — contributions welcome; see
      #                  devices/README.md for what a device profile needs)
    };

    # ── Minimal reference config per device ──────────────────────────────────
    # The bare minimum to boot — no personal bits, no secrets. Copy
    # example/chiappa.nix as a starting point.
    nixosConfigurations.example-chiappa = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.chiappa
        ./example/chiappa.nix
      ];
    };

    formatter = forSystem (pkgs: pkgs.alejandra);

    checks.${system} = {
      kernel = self.nixosConfigurations.example-chiappa.config.boot.kernelPackages.kernel;
      koreader =
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.chiappa
            ./example/chiappa.nix
            {remarkable.koreader.enable = true;}
          ];
        }).config.remarkable.koreader.package;
    };
  };
}
