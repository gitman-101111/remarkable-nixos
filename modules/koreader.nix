# KoReader — e-reader as an einkbridge client (and the reference rm2fb app).
#
# KoReader's reMarkable device build already knows this hardware and renders
# through /dev/fb0 mxcfb ioctls. These devices have no fbdev, so
# `einkbridge-fb-shim.so` (LD_PRELOAD, source in the hardware layer) fakes
# /dev/fb0 → einkbridge: open → /dev/shm/swtfb, MXCFB_SEND_UPDATE → the rm2fb
# socket.
#
# The fb stays at einkbridge's native 16bpp RGB565 (KO_DONT_SET_DEPTH=1 skips
# KoReader's 8bpp fbdepth pass) so color content renders in color on color
# panels.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.remarkable.koreader;
  device = config.remarkable.device;
  primaryUser = config.remarkable.primaryUser;

  # LD_PRELOAD /dev/fb0→einkbridge shim (libc-only).
  einkShim = pkgs.stdenv.mkDerivation {
    pname = "einkbridge-fb-shim";
    version = "1";
    src = "${device.hardwareLayer}/eink/src";
    dontConfigure = true;
    buildPhase = "$CC -O2 -shared -fPIC -o einkbridge-fb-shim.so einkbridge-fb-shim.c -ldl -lpthread";
    # Installed as *qtfb-shim* on purpose: KoReader's reMarkable backends gate
    # on `LD_PRELOAD:find("qtfb-shim")` (frontend/device/remarkable/device.lua)
    # as a "you have a framebuffer shim loaded" sanity check. Ours IS that shim
    # (it feeds the mxcfb backend into einkbridge); the name just satisfies the
    # check.
    installPhase = "install -Dm755 einkbridge-fb-shim.so $out/lib/einkbridge-qtfb-shim.so";
  };

  # KoReader reMarkable aarch64 device build (NOT nixpkgs' SDL desktop build).
  # Prebuilt binaries (luajit + bundled libs/) → autoPatchelf onto nixpkgs libs.
  koreader = pkgs.stdenvNoCC.mkDerivation {
    pname = "koreader-remarkable";
    version = cfg.version;
    src = pkgs.fetchurl {
      url = "https://github.com/koreader/koreader/releases/download/v${cfg.version}/koreader-remarkable-aarch64-v${cfg.version}.zip";
      hash = cfg.hash;
    };
    nativeBuildInputs = [pkgs.unzip pkgs.autoPatchelfHook];
    buildInputs = [
      (lib.getLib pkgs.stdenv.cc.cc) # libstdc++, libgcc_s
      pkgs.zlib
    ];
    # KoReader dlopens optional backends; don't fail the build on those.
    autoPatchelfIgnoreMissingDeps = true;
    unpackPhase = "unzip -q $src";
    installPhase = ''
      mkdir -p $out
      cp -r koreader $out/koreader
    '';
  };

  koDir = "${koreader}/koreader";

  launcher = pkgs.writeShellScriptBin "koreader" ''
    set -e
    export HOME="''${HOME:-/home/${primaryUser}}"
    export KOREADER_DIR="${koDir}"
    # KOREADER_DIR is the read-only nix store, so KoReader's data dir (cache,
    # settings, history) must be redirected to a writable path — KO_HOME wins
    # over its default of "." (the install dir). Make sure the parent exists
    # (KoReader only mkdirs the final component).
    export KO_HOME="$HOME/.local/share/koreader"
    mkdir -p "$HOME/.local/share" "$KO_HOME/patches"
    ${lib.optionalString (cfg.userPatches != null) ''
      # Refresh the shipped userpatches into the writable patches dir each launch.
      cp -f ${cfg.userPatches}/*.lua "$KO_HOME/patches/" 2>/dev/null || true
    ''}
    # Corrupt-cache guard: a hard power-off can damage KoReader's sqlite caches
    # (e.g. bookinfo_cache.sqlite3), and KoReader HANGS at startup reading one
    # instead of rebuilding it — blank screen, deaf to input. Quarantine any
    # DB that DEFINITIVELY fails an integrity check (KoReader recreates it).
    # Never touches a healthy DB, and any error here is non-fatal to the
    # launcher.
    for db in $(find "$KO_HOME" \( -name '*.sqlite3' -o -name '*.sqlite' \) 2>/dev/null); do
      res=$(${pkgs.sqlite}/bin/sqlite3 "$db" 'PRAGMA integrity_check;' 2>/dev/null | head -1)
      if [ -n "$res" ] && [ "$res" != "ok" ]; then
        echo "koreader-launcher: quarantining corrupt cache $db" >&2
        mv -f "$db" "$db.corrupt" 2>/dev/null || rm -f "$db" 2>/dev/null || true
      fi
    done
    export LC_ALL="en_US.UTF-8"
    export STARDICT_DATA_DIR="data/dict"
    export KO_DONT_GRAB_INPUT=1     # don't EVIOCGRAB — matches reMarkable
    export KO_DONT_SET_DEPTH=1      # keep einkbridge's 16bpp RGB565 (color)
    unset KO_USE_QTFB               # → mxcfb backend (the shim path)
    # KoReader's backend requires the qtfb-shim name (see einkShim) AND this mode.
    export QTFB_SHIM_MODE=N_RGB565
    # Panel geometry for the shim's fake /dev/fb0 (from the device profile).
    export SWTFB_WIDTH=${toString device.panel.width}
    export SWTFB_HEIGHT=${toString device.panel.height}
    export LD_PRELOAD="${einkShim}/lib/einkbridge-qtfb-shim.so"
    export LD_LIBRARY_PATH="${koDir}/libs''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    # Silence the "startup script has been updated" nag: KoReader's backend
    # compares md5(/tmp/koreader.sh) to the installed koreader.sh to detect an
    # OTA-updated launcher. reader.lua runs directly here (no koreader.sh), so
    # /tmp/koreader.sh is absent → mismatch → dialog. Mirror it so hashes match.
    cp -f "${koDir}/koreader.sh" /tmp/koreader.sh 2>/dev/null || true
    # Wait for the einkbridge socket (KoReader draws through it).
    for _ in $(seq 1 50); do [ -S /tmp/swtfb.ipc ] && break; sleep 0.2; done
    cd "${koDir}"
    exec ./luajit reader.lua "$@"
  '';
in {
  options.remarkable.koreader = {
    enable = lib.mkEnableOption "KoReader e-reader (einkbridge client)";
    autostart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start KoReader as a system service after the e-ink bridge.";
    };
    version = lib.mkOption {
      type = lib.types.str;
      default = "2026.03";
      description = "KoReader release version (reMarkable aarch64 build).";
    };
    hash = lib.mkOption {
      type = lib.types.str;
      default = "sha256-VmIdXuZq2U9PPi5tIE6MNL5zA0P5Fe3Da7B2oEOi5Gg=";
      description = "sha256 of the KoReader release zip (update together with version).";
    };
    userPatches = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Directory of KoReader userpatches (Lua monkey-patches loaded from
        KO_HOME/patches at startup), refreshed into the writable patches dir
        on every launch. Update-safe: survives KoReader release bumps.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [launcher];

    # Running KoReader as a systemd service (no login session) means logind's
    # per-session device ACLs are NOT applied, so it can't open /dev/input/*
    # (touch, pen). Grant the input group explicitly (video comes from the
    # frontlight module for the backlight).
    users.users.${primaryUser}.extraGroups = ["input"];

    # KoReader probes for reMarkable hardware by stat()-ing /usr/bin/xochitl
    # (the stock app) — it never executes it. NixOS has no /usr/bin, so drop
    # an empty marker there or KoReader falls back to the (missing) SDL
    # emulator and aborts.
    systemd.tmpfiles.rules = [
      "d /usr/bin 0755 root root -"
      "f /usr/bin/xochitl 0644 root root -"
    ];

    # Optional: run KoReader as the device's foreground app.
    systemd.services.koreader = lib.mkIf cfg.autostart {
      description = "KoReader e-reader";
      wantedBy = ["multi-user.target"];
      after = ["remarkable-eink.service"];
      requires = ["remarkable-eink.service"];
      # KoReader shells out to `systemctl suspend` (power button) and `nmcli`
      # (WiFi userpatch); a systemd service's PATH won't have them otherwise.
      path = [pkgs.systemd pkgs.networkmanager];
      serviceConfig = {
        User = primaryUser;
        ExecStart = "${launcher}/bin/koreader";
        Restart = "on-failure";
        RestartSec = 3;
      };
    };
  };
}
