# E-ink lifecycle status screens.
#
# Shows a full-screen frame on the panel at each lifecycle moment (power-on:
# NixOS logo; sleeping, shutting down, rebooting, low battery: the vendor's
# artwork), by drawing through einkbridge with the tiny `eink-show` rm2fb
# client (source in the hardware layer). Frames are fed as RGB888 sized to
# the device profile's panel geometry.
#
# Proprietary line: the CLIENT is public; the vendor PNGs are NOT
# redistributable, so they come from `remarkable.eink.screens` (a path into
# the user's private tree), never vendored in a public repo.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.remarkable.eink;
  device = config.remarkable.device;
  einkSrc = "${device.hardwareLayer}/eink";
  geometry = "${toString device.panel.width}x${toString device.panel.height}";

  # The rm2fb "show a full-screen frame" client — libc only, no Qt/vendor libs.
  einkShow = pkgs.stdenv.mkDerivation {
    pname = "remarkable-eink-show";
    version = "1";
    src = "${einkSrc}/src";
    dontConfigure = true;
    buildPhase = "$CC -O2 -o chiappa-eink-show chiappa-eink-show.c";
    installPhase = "install -Dm755 chiappa-eink-show $out/bin/eink-show";
  };

  # Convert a PNG → headerless RGB888 raw sized to the panel, alpha flattened
  # onto white. Built on the host (raw pixels are arch-neutral).
  mkFrame = name: png:
    pkgs.runCommandLocal "eink-frame-${name}" {
      nativeBuildInputs = [pkgs.buildPackages.imagemagick];
    } ''
      magick ${png} -background white -flatten \
        -resize ${geometry} -extent ${geometry} -depth 8 rgb:$out
    '';

  # Power-on splash: the NixOS snowflake centered on white, from nixpkgs'
  # freely licensed nixos-icons — no vendor art involved.
  nixosSplash = pkgs.runCommandLocal "eink-frame-poweron" {
    nativeBuildInputs = [pkgs.buildPackages.imagemagick];
  } ''
    magick ${pkgs.nixos-icons}/share/icons/hicolor/1024x1024/apps/nix-snowflake.png \
      -background white -flatten -resize 600x600 \
      -gravity center -extent ${geometry} -depth 8 rgb:$out
  '';

  frames = {
    poweron = nixosSplash;
    suspend = mkFrame "suspend" "${cfg.screens}/suspended.png";
    poweroff = mkFrame "poweroff" "${cfg.screens}/poweroff.png";
    reboot = mkFrame "reboot" "${cfg.screens}/rebooting.png";
    lowbatt = mkFrame "lowbatt" "${cfg.screens}/batteryempty.png";
  };

  # Panel geometry injected per invocation (the C default is the Move; set
  # explicitly regardless so the system never relies on compiled-in values).
  geomEnv = "SWTFB_WIDTH=${toString device.panel.width} SWTFB_HEIGHT=${toString device.panel.height}";
  show = frame: "${geomEnv} ${einkShow}/bin/eink-show ${frame}";
in {
  options.remarkable.eink.screens = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = ''
      Directory of vendor lifecycle PNGs (suspended.png, poweroff.png,
      rebooting.png, batteryempty.png), extracted from the vendor rootfs
      (/usr/share/remarkable). Not redistributable — set to a path in your
      private config. Until set, the lifecycle screens are inactive (the
      power-on splash included: it draws through the same gated stack).
    '';
  };

  # Command that draws the low-battery frame — consumed by power.nix's battery
  # guard just before it powers off. null (default) when screens are disabled,
  # so power.nix simply skips it.
  options.remarkable.eink.lowBatteryShow = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    internal = true;
    description = "Internal: command to display the low-battery frame.";
  };

  config = lib.mkIf (cfg.enable && cfg.screens != null) {
    remarkable.eink.lowBatteryShow = show frames.lowbatt;

    systemd.services = {
      # KoReader starts only after the splash has drawn: without this it races
      # the splash (its first paint lands ~1 s after the draw and clobbers it),
      # and its early start-attempts restart-churn against the not-yet-ready
      # bridge anyway. After= on the oneshot means "after it exited (drew)".
      koreader.after = ["remarkable-screen-poweron.service"];

      # Power-on splash: replace the bridge boot banner with the NixOS logo
      # once the bridge is up. Stays until the first app draws.
      # `after=remarkable-eink.service` only orders after the unit STARTS, not
      # after the bridge has created /dev/shm/swtfb + /tmp/swtfb.ipc — so wait
      # for the socket first, or the draw races the bridge and fails.
      remarkable-screen-poweron = {
        description = "e-ink power-on splash";
        wantedBy = ["multi-user.target"];
        after = ["remarkable-eink.service"];
        requires = ["remarkable-eink.service"];
        serviceConfig = {
          Type = "oneshot";
          # Retry the DRAW, not just the socket's existence: the bridge binds
          # the socket before its Qt engine can render, so a draw right at
          # socket-appearance can fail; on a fresh store the engine takes ~10 s.
          # A failed splash leaves the stale bootloader image on the bistable
          # panel over a healthy system.
          ExecStart = pkgs.writeShellScript "remarkable-screen-poweron" ''
            for _ in $(seq 1 60); do
              [ -S /tmp/swtfb.ipc ] && ${show frames.poweron} && exit 0
              sleep 1
            done
            exit 1
          '';
        };
      };

      # Shutdown/reboot: ExecStop runs at teardown. Ordered After the bridge,
      # so systemd stops THIS first (reverse order) — the bridge is still
      # alive to draw. The panel is bistable, so the frame persists through
      # power-off.
      remarkable-screen-shutdown = {
        description = "e-ink shutdown/reboot screen";
        wantedBy = ["multi-user.target"];
        after = ["remarkable-eink.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
          ExecStop = pkgs.writeShellScript "remarkable-screen-shutdown" ''
            if ${config.systemd.package}/bin/systemctl list-jobs 2>/dev/null | grep -q 'reboot.target'; then
              ${show frames.reboot}
            else
              ${show frames.poweroff}
            fi
          '';
        };
      };

      # Sleep: draw the sleep frame on the way down, restore the app's frame
      # on resume. Three subtleties:
      #  - The show client returns once the update is QUEUED; the panel
      #    refresh takes ~1 s. This service is Before=sleep.target, so the
      #    settle sleep holds the suspend until the frame has physically
      #    landed (without it, the system freezes mid-refresh and the app
      #    stays on the panel).
      #  - The EPD regulator holds panel power for `vpdd_length` ms after
      #    every refresh (vendor engine sets 30000) and REFUSES to suspend
      #    while that timer runs ("Can't suspend, vpdd timer running" →
      #    -EAGAIN → suspend fails). Write vpdd_length=0 BEFORE the draw: the
      #    draw's enable path cancels any pending timer and val=0 arms no new
      #    one, so the suspend proceeds. ExecStop restores 30000 (VPDD hold
      #    keeps back-to-back page turns fast while reading).
      #  - The sleep frame clobbers the shared framebuffer, and the app
      #    doesn't know a suspend happened, so on resume ExecStop must put
      #    the saved frame back or the panel would keep showing the sleep
      #    art. StopWhenUnneeded stops the unit when sleep.target deactivates
      #    after resume.
      remarkable-screen-sleep = {
        description = "e-ink sleep screen";
        before = ["sleep.target"];
        wantedBy = ["sleep.target"];
        unitConfig.StopWhenUnneeded = true;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "remarkable-screen-sleep" ''
            V=${device.eink.vpddSysfsPath}
            cp /dev/shm/swtfb /run/swtfb.save 2>/dev/null || true
            echo 0 > "$V/vpdd_length" 2>/dev/null || true
            ${show frames.suspend}
            sleep 3
          '';
          ExecStop = pkgs.writeShellScript "remarkable-screen-wake" ''
            V=${device.eink.vpddSysfsPath}
            echo 30000 > "$V/vpdd_length" 2>/dev/null || true
            if [ -f /run/swtfb.save ]; then
              ${geomEnv} ${einkShow}/bin/eink-show /run/swtfb.save 2>/dev/null || true
              rm -f /run/swtfb.save
            fi
          '';
        };
      };
    };
  };
}
