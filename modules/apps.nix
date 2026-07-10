# GUI apps on the e-ink panel, launched from KoReader.
#
# Architecture (no GPU on these SoCs — everything is software):
#   sway in kiosk trim (WLR_BACKENDS=libinput,headless, WLR_RENDERER=pixman;
#         generated per-app config sets the headless output to the panel
#         geometry, no borders, no bar, hidden cursor)
#     → swtfb-cast (wlr-screencopy client, source in the hardware layer)
#       converts damaged regions to RGB565 and feeds them to einkbridge
#       via the rm2fb protocol — e-ink refreshes only what changed
#     → wvkbd on-screen keyboard, started hidden; swtfb-imhint holds the
#       seat's input-method slot and signals it on text-field focus changes.
#       sway is used instead of cage for the layer-shell + virtual-keyboard
#       + input-method protocols.
#     → the app; when it exits the session runner calls `swaymsg exit`,
#       sway tears down, the saved framebuffer is restored and KoReader
#       carries on.
#
# Each entry in remarkable.apps becomes a `remarkable-app-<name>` wrapper on
# PATH and (when KoReader is enabled) an entry in an "Apps" menu inside
# KoReader. Launching from KoReader blocks its UI loop for the duration —
# that is intentional: KoReader neither repaints nor consumes input while the
# app owns the panel. An empty set disables everything.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.remarkable.apps;
  device = config.remarkable.device;
  primaryUser = config.remarkable.primaryUser;
  geomW = toString device.panel.width;
  geomH = toString device.panel.height;

  # Session tools from the hardware layer's source: the wlr-screencopy →
  # rm2fb caster and the input-method → OSK-signal watcher.
  sessionTools = pkgs.stdenv.mkDerivation {
    pname = "swtfb-session-tools";
    version = "1";
    src = "${device.hardwareLayer}/eink/src";
    nativeBuildInputs = [pkgs.wayland-scanner pkgs.pkg-config];
    buildInputs = [pkgs.wayland];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      SC_XML=${pkgs.wlr-protocols}/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml
      wayland-scanner client-header $SC_XML wlr-screencopy-unstable-v1-client-protocol.h
      wayland-scanner private-code  $SC_XML wlr-screencopy-unstable-v1-protocol.c
      IM_XML=${pkgs.wlroots.src}/protocol/input-method-unstable-v2.xml
      wayland-scanner client-header $IM_XML input-method-unstable-v2-client-protocol.h
      wayland-scanner private-code  $IM_XML input-method-unstable-v2-protocol.c
      $CC -O2 -I. -o swtfb-cast swtfb-cast.c wlr-screencopy-unstable-v1-protocol.c \
        $(pkg-config --cflags --libs wayland-client)
      $CC -O2 -I. -o swtfb-imhint swtfb-imhint.c input-method-unstable-v2-protocol.c \
        $(pkg-config --cflags --libs wayland-client)
      runHook postBuild
    '';
    installPhase = ''
      install -Dm755 swtfb-cast $out/bin/swtfb-cast
      install -Dm755 swtfb-imhint $out/bin/swtfb-imhint
    '';
  };

  # Runs INSIDE sway (its config exec's this): caster + on-screen keyboard +
  # the app; tear the session down when the app exits. sway kills remaining
  # clients (caster, keyboard) with the compositor.
  runner = name: app:
    pkgs.writeShellScript "app-session-${name}" ''
      ${sessionTools}/bin/swtfb-cast &
      # On-screen keyboard: wvkbd starts hidden; swtfb-imhint holds the
      # seat's input-method slot and signals it (SIGUSR2 show / SIGUSR1
      # hide) on text-field focus changes. imhint's failure mode is a
      # visible keyboard. wvkbd's layer-shell exclusive zone shrinks the
      # app above it while shown.
      ${pkgs.wvkbd}/bin/wvkbd-mobintl -H ${toString app.keyboardHeight} --hidden &
      kbd=$!
      ${sessionTools}/bin/swtfb-imhint "$kbd" &
      ${app.command}
      ${pkgs.sway}/bin/swaymsg exit
    '';

  swayConfig = name: app:
    pkgs.writeText "app-sway-${name}.conf" ''
      output HEADLESS-1 mode --custom ${geomW}x${geomH}
      xwayland disable
      default_border none
      hide_edge_borders both
      focus_follows_mouse no
      seat * hide_cursor 100
      exec ${runner name app}
    '';

  wrapperFor = name: app:
    pkgs.writeShellScriptBin "remarkable-app-${name}" ''
      # Launch contexts inherit their app's environment — KoReader's carries
      # LD_LIBRARY_PATH (its bundled libs shadow system ones: sway dies on a
      # pango/harfbuzz mismatch) and LD_PRELOAD (the fb shim, which would
      # inject into every session process). Clean slate.
      unset LD_LIBRARY_PATH LD_PRELOAD

      export SWTFB_WIDTH=${geomW}
      export SWTFB_HEIGHT=${geomH}
      export SWTFB_CAST_WAVEFORM=${toString app.waveform}
      export WLR_BACKENDS=libinput,headless
      export WLR_RENDERER=pixman
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      # Launch contexts like KoReader's service have no logind session; the
      # runtime dir normally exists via the primary user's linger (set below),
      # but never die for lack of it — sway needs SOME writable dir for its
      # socket.
      [ -d "$XDG_RUNTIME_DIR" ] || XDG_RUNTIME_DIR="$(mktemp -d /tmp/remarkable-app-rt.XXXXXX)"
      # Launch contexts like KoReader's service carry a minimal PATH; app
      # launcher scripts (e.g. Firefox's) need standard tools on it.
      export PATH=/run/current-system/sw/bin:$PATH

      # Save the panel content (KoReader's page) and restore it afterward —
      # same trick as the sleep screen.
      SAVE="$XDG_RUNTIME_DIR/app-saved-fb"
      cp /dev/shm/swtfb "$SAVE" 2>/dev/null || true

      # Session log (truncated per launch): sway + every child's stderr —
      # without it a failing app dies invisibly.
      ${pkgs.sway}/bin/sway -c ${swayConfig name app} \
        > "$XDG_RUNTIME_DIR/app-${name}.log" 2>&1
      rc=$?

      if [ -f "$SAVE" ]; then
        ${config.remarkable.eink.showPackage}/bin/eink-show "$SAVE" 2>/dev/null || true
        rm -f "$SAVE"
      fi
      exit $rc
    '';

  wrapperPkgs = lib.mapAttrs wrapperFor cfg;
  wrappers = lib.attrValues wrapperPkgs;

  # KoReader "Apps" menu (userpatch): one entry per app, running the wrapper
  # synchronously — KoReader stays frozen (by design) until the app exits,
  # then repaints. ABSOLUTE paths: KoReader's service PATH is minimal and
  # does not include the system profile.
  menuEntries = lib.concatStringsSep ",\n" (lib.mapAttrsToList (name: app: ''
        {
            text = ${builtins.toJSON app.label},
            callback = function()
                os.execute(${builtins.toJSON "${wrapperPkgs.${name}}/bin/remarkable-app-${name}"})
                local UIManager = require("ui/uimanager")
                UIManager:setDirty("all", "full")
            end,
        }'') cfg);

  appsMenuPatch = pkgs.writeTextDir "2-remarkable-apps-menu.lua" ''
    -- remarkable-nixos: adds an "Apps" menu with entries that hand the panel
    -- to a Wayland app session until it exits.
    local function add_apps_menu(MenuClass, order)
        if order and order.tools then
            table.insert(order.tools, 1, "remarkable_apps")
        end
        local orig = MenuClass.setUpdateItemTable
        MenuClass.setUpdateItemTable = function(self)
            self.menu_items.remarkable_apps = {
                text = "Apps",
                sub_item_table = {
    ${menuEntries}
                },
            }
            return orig(self)
        end
    end
    local ok_fm, fm_order = pcall(require, "ui/elements/filemanager_menu_order")
    local ok_fmm, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if ok_fmm then add_apps_menu(FileManagerMenu, ok_fm and fm_order or nil) end
    local ok_r_order, r_order = pcall(require, "ui/elements/reader_menu_order")
    local ok_rm, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if ok_rm then add_apps_menu(ReaderMenu, ok_r_order and r_order or nil) end
  '';
in {
  options.remarkable.apps = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        command = lib.mkOption {
          type = lib.types.str;
          description = "Command that runs as the session's single app (absolute path).";
        };
        label = lib.mkOption {
          type = lib.types.str;
          description = "Name shown in the KoReader Apps menu.";
        };
        waveform = lib.mkOption {
          type = lib.types.int;
          default = 2;
          description = "rm2fb waveform for this app's large updates (2 = GC16 full quality, 1 = DU fast 2-level).";
        };
        keyboardHeight = lib.mkOption {
          type = lib.types.ints.positive;
          default = 320;
          description = "On-screen keyboard height in pixels; its exclusive zone shrinks the app above it.";
        };
      };
    });
    default = {};
    example = lib.literalExpression ''
      { firefox = { command = "''${pkgs.firefox}/bin/firefox"; label = "Firefox"; }; }
    '';
    description = "GUI apps launchable on the panel (each becomes remarkable-app-<name> and a KoReader menu entry). Empty set = feature disabled.";
  };

  config = lib.mkIf (cfg != {}) {
    environment.systemPackages = wrappers;

    # sway's libinput backend needs a seat: seatd, with the primary user in
    # its group (input group access comes from the KoReader/frontlight
    # modules; add it here too so app sessions stand alone).
    services.seatd.enable = true;
    users.users.${primaryUser}.extraGroups = ["seat" "input"];

    # Sessionless launch contexts (KoReader's service) have no logind session,
    # so /run/user/<uid> would not exist without lingering — and the wrapper,
    # sway's socket, and the session log all live there. Lingering is enabled
    # the way `loginctl enable-linger` does it: a marker file logind reads.
    systemd.tmpfiles.rules = ["f /var/lib/systemd/linger/${primaryUser} 0644 root root -"];

    remarkable.koreader.extraPatchDirs =
      lib.mkIf config.remarkable.koreader.enable [appsMenuPatch];
  };
}
