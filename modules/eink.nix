# E-ink display stack.
#
# The panel has no conventional driver — the vendor's libqsgepaper waveform
# engine (proprietary) drives it via a Qt `epaper` platform plugin.
# `einkbridge` (source in the device's hardware layer) wraps that engine and
# exposes an rm2fb-compatible shared-memory + socket protocol so ordinary
# apps can draw.
#
# The proprietary bits (libqsgepaper.so + the epaper/qsgepaper plugins, and
# the per-lot waveform tables) are NOT redistributable — point the options
# below at a directory you extracted from your own device / firmware image
# (see the hardware layer's docs/obtaining-vendor-blobs.md).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.remarkable.eink;
  device = config.remarkable.device;
  einkSrc = "${device.hardwareLayer}/eink";

  # einkbridge, built FROM SOURCE — reproducible, so no prebuilt binary rides
  # in the vendor bundle. The catch: the vendor `epaper`/`qsgepaper` Qt
  # plugins have ABI deps on reMarkable's PATCHED Qt 6.8.2, and stock nixpkgs
  # Qt hard-segfaults them. So: COMPILE against nixpkgs Qt6 HEADERS (newer is
  # fine — the source avoids >6.8 APIs), but LINK against the VENDOR Qt 6.8.2
  # `.so` stubs in the bundle with `--allow-shlib-undefined`, so the binary
  # references only symbols that exist at runtime in vendor Qt 6.8.2.
  # Explicit -I/-L (no qt in buildInputs) keeps nixpkgs Qt libs OUT of the
  # link path. patchelf then repoints the ELF interpreter + rpath at the
  # nix-store bundle.
  einkbridge = pkgs.stdenv.mkDerivation {
    pname = "einkbridge";
    version = "3";
    src = "${einkSrc}/src";
    nativeBuildInputs = [pkgs.patchelf];
    dontWrapQtApps = true;
    buildPhase = ''
      runHook preBuild
      $CXX -O2 -fPIE -std=c++17 \
        -I${pkgs.qt6.qtbase}/include \
        -I${pkgs.qt6.qtbase}/include/QtCore \
        -I${pkgs.qt6.qtbase}/include/QtGui \
        -I${pkgs.qt6.qtdeclarative}/include \
        -I${pkgs.qt6.qtdeclarative}/include/QtQuick \
        -I${pkgs.qt6.qtdeclarative}/include/QtQml \
        -L${cfg.vendorRuntime}/lib \
        -Wl,--allow-shlib-undefined \
        einkbridge.cpp \
        -lQt6Core -lQt6Gui -lQt6Quick -lQt6Qml \
        -o einkbridge
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 einkbridge $out/bin/einkbridge
      patchelf --set-interpreter ${cfg.vendorRuntime}/lib/ld-linux-aarch64.so.1 \
               --set-rpath ${cfg.vendorRuntime}/lib $out/bin/einkbridge
      runHook postInstall
    '';
  };

  launcher = pkgs.writeShellScript "remarkable-eink-bridge" ''
    # Kill anything holding the DRM device (stale from an unclean exit).
    # fuser scans /proc in C; an equivalent per-fd shell loop costs ~8 s of
    # fork/exec on this CPU and dominated the bridge's start-to-render time.
    ${pkgs.psmisc}/bin/fuser -k /dev/dri/card* 2>/dev/null || true
    rm -f /tmp/epframebuffer.lock /tmp/swtfb.ipc /dev/shm/swtfb
    [ -f /tmp/epd.lock ] || { touch /tmp/epd.lock; chmod +x /tmp/epd.lock; }

    # Panel geometry from the device profile (the C default is the Move; set
    # explicitly regardless so the system never relies on compiled-in values).
    export SWTFB_WIDTH=${toString device.panel.width}
    export SWTFB_HEIGHT=${toString device.panel.height}

    # ALL Qt paths point into the vendor bundle (its own Qt 6.8.2 + plugins +
    # qml). Do NOT mix in nixpkgs Qt plugins/qml.
    export QT_QPA_PLATFORM=epaper
    export QT_QUICK_BACKEND=epaper
    export LD_LIBRARY_PATH=${cfg.vendorRuntime}/lib
    export QT_PLUGIN_PATH=${cfg.vendorRuntime}/plugins
    export QT_QPA_PLATFORM_PLUGIN_PATH=${cfg.vendorRuntime}/plugins/platforms
    export QML2_IMPORT_PATH=${cfg.vendorRuntime}/qml
    export QML_IMPORT_PATH=${cfg.vendorRuntime}/qml
    export QT_QPA_FONTDIR=${cfg.vendorRuntime}/fonts
    export RM_WAVEFORM_DIR=${cfg.waveforms}
    # libqsgepaper calls `devconfig serial_number_epd` via popen()
    export PATH=${cfg.vendorRuntime}/bin:$PATH
    exec ${einkbridge}/bin/einkbridge ${einkSrc}/bridge.qml
  '';
in {
  options.remarkable.eink = {
    enable = lib.mkEnableOption "e-ink display bridge" // {default = true;};

    vendorRuntime = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Directory holding the extracted vendor Qt/eink runtime:
        `lib/libqsgepaper.so` (+ Qt6 deps) and
        `plugins/platforms/libepaper.so` + `plugins/scenegraph/libqsgepaper.so`.
        Extract from your own device — not redistributable. Until set, the
        e-ink service stays inactive.
      '';
    };

    waveforms = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Directory with the panel's waveform / colortable tables (→ /usr/share/remarkable).";
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = einkbridge;
      description = "The built einkbridge package.";
    };

    showPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = pkgs.stdenv.mkDerivation {
        pname = "remarkable-eink-show";
        version = "1";
        src = "${einkSrc}/src";
        dontConfigure = true;
        buildPhase = "$CC -O2 -o chiappa-eink-show chiappa-eink-show.c";
        installPhase = "install -Dm755 chiappa-eink-show $out/bin/eink-show";
      };
      description = "The rm2fb full-frame show client (lifecycle screens, app-session frame restore).";
    };
  };

  config = lib.mkMerge [
    # Warn (don't fail) if enabled but the vendor blobs aren't wired up yet.
    (lib.mkIf (cfg.enable && (cfg.vendorRuntime == null || cfg.waveforms == null)) {
      warnings = [
        "remarkable.eink is enabled but remarkable.eink.vendorRuntime/waveforms are unset — the e-ink display will not start. Extract them from your device (see the hardware layer's docs/obtaining-vendor-blobs.md) and set the options."
      ];
    })

    (lib.mkIf (cfg.enable && cfg.vendorRuntime != null && cfg.waveforms != null) {
      # SWTCON hardcodes /usr/share/remarkable regardless of RM_WAVEFORM_DIR,
      # so symlink the waveform dir there.
      systemd.tmpfiles.rules = [
        "L+ /usr/share/remarkable - - - - ${cfg.waveforms}"
      ];

      # Warm the bridge's pages before/while it links: the vendor Qt runtime
      # is ~90 MB and demand-paging it during dynamic linking costs seconds of
      # random eMMC reads on a cold cache; one sequential pass through the
      # runtime + binary populates the page cache much faster. Runs in
      # parallel from local-fs — the bridge does not wait for it.
      systemd.services.remarkable-eink-readahead = {
        description = "e-ink bridge library readahead";
        wantedBy = ["multi-user.target"];
        after = ["local-fs.target"];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "remarkable-eink-readahead" ''
            ${pkgs.findutils}/bin/find -L ${cfg.vendorRuntime} ${einkbridge} \
              -type f -exec ${pkgs.coreutils}/bin/cat {} + > /dev/null 2>&1 || true
          '';
        };
      };

      systemd.services.remarkable-eink = {
        description = "e-ink display bridge";
        wantedBy = ["multi-user.target"];
        # Rate-limit restarts: a crash-looping bridge hammers the CPU and
        # drains the battery. Give up after 4 failures in 2 min.
        startLimitIntervalSec = 120;
        startLimitBurst = 4;
        serviceConfig = {
          ExecStart = launcher;
          Restart = "on-failure";
          RestartSec = 8;
          # SWTCON's generator thread wants SCHED_FIFO → needs CAP_SYS_NICE (run as root).
          User = "root";
        };
      };
    })
  ];
}
