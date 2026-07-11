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
    # Freeze the reader app so it cannot repaint over the pad (a no-op at boot,
    # where it is not yet running); always thaw, even if the pad is killed.
    ${freezeCmds "STOP"}
    thaw() { ${freezeCmds "CONT"} }
    trap thaw EXIT
    # Retry transient failures (a bridge restart recreates both artifacts).
    # Exit 0 = unlocked or no PIN set; nonzero = could not run.
    for _ in 1 2 3; do
      ${pinpad}/bin/swtfb-pinpad ${cfg.pinFile} && exit 0
      sleep 2
    done
    exit 1
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
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lockScript;
      };
    };
  };
}
