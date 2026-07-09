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
  };

  outputs = {
    self,
    nixpkgs,
    chiappa,
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
      default = import ./modules;

      # Device modules: subsystems + that device's facts. Import ONE.
      chiappa = {
        imports = [
          self.nixosModules.default
          ./devices/chiappa
        ];
        _module.args.hardware-chiappa = chiappa;
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
  };
}
