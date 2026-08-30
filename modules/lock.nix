# PIN lock screen (access deterrent — NOT encryption: disk contents remain
# readable over SDP / with physical eMMC access).
#
# swtfb-pinpad (hardware layer source) draws a numeric pad through einkbridge
# and reads the touchscreen directly; it blocks until the PIN matching the
# salted hash in pinFile is entered. With no pinFile present the lock is
# inactive. Set the PIN once, on the device:
#   sudo remarkable-lock-setpin <digits>
#
# Lock points: boot (before the reader UI starts) and resume from suspend.
# On resume the reader app is already running and repaints the panel, so the
# lock freezes it (SIGSTOP) while the pad is up and thaws it (SIGCONT) after —
# otherwise the app draws over the pad, leaving it invisible but still live.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.remarkable.lock;
  device = config.remarkable.device;
  systemctl = "${config.systemd.package}/bin/systemctl";
  geomEnv = ''
    export SWTFB_WIDTH=${toString device.panel.width}
    export SWTFB_HEIGHT=${toString device.panel.height}
  '';
  freezeCmds = op:
    lib.concatMapStrings (u: "${systemctl} kill -s ${op} ${u} 2>/dev/null || true\n") cfg.freezeUnits;

  pinpad = pkgs.stdenv.mkDerivation {
    pname = "swtfb-pinpad";
    version = "1";
    src = "${device.hardwareLayer}/eink/src";
    buildInputs = [pkgs.libxcrypt];
    dontConfigure = true;
    buildPhase = "$CC -O2 -o swtfb-pinpad swtfb-pinpad.c -lcrypt";
    installPhase = "install -Dm755 swtfb-pinpad $out/bin/swtfb-pinpad";
  };

  setpin = pkgs.writeShellScriptBin "remarkable-lock-setpin" ''
    [ -n "$1" ] || { echo "usage: remarkable-lock-setpin <digits>"; exit 2; }
    mkdir -p "$(dirname ${cfg.pinFile})"
    exec ${pinpad}/bin/swtfb-pinpad --set ${cfg.pinFile} "$1"
  '';

  lockScript = pkgs.writeShellScript "remarkable-lock" ''
    ${geomEnv}
    # Readiness needs BOTH bridge artifacts: the socket (renderer up) and the
    # shared framebuffer — during bridge startup they exist at different
    # moments.
    for _ in $(seq 1 60); do
      [ -S /tmp/swtfb.ipc ] && [ -e /dev/shm/swtfb ] && break
      sleep 1
    done
    # On resume, the sleep screen's ExecStop restores the saved app frame and
    # then deletes /run/swtfb.save — draw the pad only after that, or the
    # restore paints over it. At boot the file never exists (loop exits
    # immediately).
    for _ in $(seq 1 40); do
      [ ! -e /run/swtfb.save ] && break
      sleep 0.5
    done
    # The pad clobbers the shared framebuffer and the frozen app never learns
    # of it, so snapshot the app's frame first — same trick as the sleep screen
    # and the app launcher. Without this the panel keeps showing the pad after
    # unlock (it is bistable, and the app only repaints on input), so the
    # reader stays hidden until the screen is tapped.
    ${pkgs.coreutils}/bin/cp /dev/shm/swtfb /run/swtfb.lock.save 2>/dev/null || true
    # Freeze the reader app so it cannot repaint over the pad (a no-op at boot,
    # where it is not yet running); always thaw, even if the pad is killed.
    ${freezeCmds "STOP"}
    thaw() {
      if [ -f /run/swtfb.lock.save ]; then
        ${config.remarkable.eink.showPackage}/bin/eink-show /run/swtfb.lock.save 2>/dev/null || true
        ${pkgs.coreutils}/bin/rm -f /run/swtfb.lock.save
      fi
      ${freezeCmds "CONT"}
    }
    trap thaw EXIT
    # Retry transient failures (a bridge restart recreates both artifacts).
    # Exit 0 = unlocked or no PIN set; nonzero = could not run.
    for _ in 1 2 3; do
      ${pinpad}/bin/swtfb-pinpad ${cfg.pinFile} && exit 0
      sleep 2
    done
    exit 1
  '';

  # Only the timeout case suspends. A `systemctl stop` of this unit must not
  # become a suspend — power.nix issues one on the 24h wake while racing a
  # poweroff — and an exit-code failure has already thawed the reader, whose
  # own idle-suspend then covers it.
  resumeTimeoutAction = pkgs.writeShellScript "remarkable-lock-resume-timeout" ''
    [ "$SERVICE_RESULT" = timeout ] || exit 0
    ${systemctl} suspend
  '';
in {
  options.remarkable.lock = {
    enable = lib.mkEnableOption "PIN lock screen on boot and resume";
    pinFile = lib.mkOption {
      type = lib.types.str;
      default = "/persist/lock/pin";
      description = "Path of the salted PIN hash (crypt SHA-512). Absent file = lock inactive.";
    };
    freezeUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.optional config.remarkable.koreader.enable "koreader.service";
      defaultText = lib.literalExpression ''lib.optional config.remarkable.koreader.enable "koreader.service"'';
      description = "Systemd units SIGSTOP'd while the lock pad is shown (so the running app cannot repaint over it) and SIGCONT'd after unlock.";
    };
    resumeTimeout = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "5min";
      description = ''
        systemd time span after which an unanswered resume PIN pad gives up and
        the device suspends again, still locked. swtfb-pinpad otherwise blocks
        forever with the reader SIGSTOP'd behind it, so a wake nobody answers
        parks the device awake and its idle-suspend can never fire. null keeps
        the pad up indefinitely.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [setpin];

    # Boot: after the splash (drawn = bridge fully ready; the pad paints over
    # it — After= on the splash unit is a no-op when screens are disabled),
    # before the reader UI.
    systemd.services.remarkable-lock-boot = {
      description = "PIN lock (boot)";
      wantedBy = ["multi-user.target"];
      after = ["remarkable-eink.service" "remarkable-screen-poweron.service"];
      requires = ["remarkable-eink.service"];
      # Never re-run mid-session. switch-to-configuration otherwise restarts
      # this whenever the lock script changes, which re-locks an already
      # unlocked device, blocks the deploy on physical PIN entry (nothing
      # times this one out), and paints the pad over a live reader.
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lockScript;
      };
    };
    systemd.services.koreader.after = ["remarkable-lock-boot.service"];

    # Resume: runs after each suspend cycle completes.
    systemd.services.remarkable-lock-resume = {
      description = "PIN lock (resume)";
      wantedBy = ["suspend.target"];
      after = ["systemd-suspend.service"];
      serviceConfig =
        {
          Type = "oneshot";
          ExecStart = lockScript;
        }
        // lib.optionalAttrs (cfg.resumeTimeout != null) {
          TimeoutStartSec = cfg.resumeTimeout;
          ExecStopPost = resumeTimeoutAction;
        };
    };
  };
}
