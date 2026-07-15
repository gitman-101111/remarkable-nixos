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
    # KO_HOME lives on /persist and survives A/B reflashes, so patches shipped by
    # a PREVIOUS generation linger here forever (KoReader never prunes). A patch
    # we've since renamed or dropped (e.g. the old per-feature menu patches folded
    # into 2-remarkable-menu-commands.lua) would keep loading and shadow the new
    # one. Make the patch set declarative: wipe it, then re-copy the current
    # generation's patches so KO_HOME/patches always matches the running config.
    rm -f "$KO_HOME/patches"/*.lua 2>/dev/null || true
    ${lib.optionalString (cfg.userPatches != null) ''
      # Refresh the shipped userpatches into the writable patches dir each launch.
      cp -f ${cfg.userPatches}/*.lua "$KO_HOME/patches/" 2>/dev/null || true
    ''}
    ${lib.concatMapStrings (d: ''
      cp -f ${d}/*.lua "$KO_HOME/patches/" 2>/dev/null || true
    '') cfg.extraPatchDirs}
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
    # STARDICT_DATA_DIR left unset: KoReader then uses KO_HOME/data/dict, which it
    # creates and can write. A value is taken relative to cwd (the read-only store).
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

  # menuCommands → a userpatch adding shell-command entries to KoReader's menu
  # (also the mechanism behind the Apps launcher — see apps.nix). Each
  # command/checkedCommand becomes a shell script (no lua escaping), and the
  # lua just os.execute()s the script path; exit-0 of the check script shows a
  # checkmark. os.execute returns the exit status on LuaJIT (Lua 5.1). Entries
  # with a `group` nest under a submenu of that name; others are top-level.
  menuCmds = lib.imap0 (i: c: {
    inherit (c) label group fullRefresh;
    cmd = pkgs.writeShellScript "koreader-menucmd-${toString i}" c.command;
    check =
      if c.checkedCommand != null
      then pkgs.writeShellScript "koreader-menucheck-${toString i}" c.checkedCommand
      else null;
    key = "remarkable_cmd_${toString i}";
  }) cfg.menuCommands;

  # A menu-item table literal (used both top-level and inside a submenu).
  itemLiteral = e: ''{
            text = ${builtins.toJSON e.label},
            ${lib.optionalString (e.check != null) ''checked_func = function() return os.execute("${e.check}") == 0 end,''}
            callback = function()
                os.execute("${e.cmd}")
                require("ui/uimanager"):setDirty("all", ${
      if e.fullRefresh
      then "\"full\""
      else "\"ui\""
    })
            end,
        }'';

  topLevel = lib.filter (e: e.group == null) menuCmds;
  groups = lib.imap0 (i: g: {
    name = g;
    key = "remarkable_group_${toString i}";
    entries = lib.filter (e: e.group == g) menuCmds;
  }) (lib.unique (lib.filter (g: g != null) (map (e: e.group) menuCmds)));

  orderKeys = (map (e: e.key) topLevel) ++ (map (g: g.key) groups);
  menuOrderInserts = lib.concatMapStrings (k: ''
        if order and order.tools then table.insert(order.tools, 1, "${k}") end
  '') orderKeys;

  menuItemDefs =
    (lib.concatMapStrings (e: ''
        self.menu_items.${e.key} = ${itemLiteral e}
    '')
    topLevel)
    + (lib.concatMapStrings (g: ''
        self.menu_items.${g.key} = {
            text = ${builtins.toJSON g.name},
            sub_item_table = {
    ${lib.concatStringsSep ",\n" (map itemLiteral g.entries)}
            },
        }
    '')
    groups);

  # Neutralize KoReader's built-in OTA updater. This build ships from the
  # read-only Nix store, so the in-app updater can't overwrite the install —
  # and real updates come from a Nix rebuild + redeploy, not from KoReader. The
  # reMarkable device profile sets hasOTAUpdates=true, which is what makes the
  # "Update" entry appear: filemanagermenu.lua rebuilds the menu with
  # `dofile(common_info_menu_table.lua)` on every open, and that file adds
  # `ota_update` only `if Device:hasOTAUpdates()`. Flipping it false at startup
  # means every rebuild sees false, so the entry never appears.
  #
  # MUST be priority 2 (late), NOT early (1-): an early patch runs BEFORE
  # reader.lua requires the device module, so require("device") here would load
  # device.lua too soon — before G_reader_settings exists — and that half-load
  # makes the real require fail fatally ("loop or previous error loading module
  # 'device'"), crash-looping KoReader (this exact bug shipped once). At late,
  # device is already loaded, so require returns the ready singleton and we just
  # flip the method. Shipped unconditionally: every Nix-managed install wants it.
  otaPatch = pkgs.writeTextDir "2-remarkable-disable-ota.lua" ''
    -- remarkable-nixos: read-only Nix-store install → the in-app OTA updater
    -- can't apply updates (those come from a Nix rebuild + redeploy). Flip
    -- hasOTAUpdates() false so the "Update" menu entry never appears. Loaded at
    -- the "late" priority: the device module is already required by then, so
    -- this returns the singleton (requiring it earlier crashes KoReader).
    local Device = require("device")
    Device.hasOTAUpdates = function() return false end
  '';

  # KoReader's file manager execl()s /bin/mv and /bin/cp (filemanager.lua, the
  # non-Android branch) for rename/copy/paste. Neither exists on NixOS and execl
  # does not search PATH, so those operations fail. Repoint both at coreutils.
  fileBinsPatch = pkgs.writeTextDir "2-remarkable-file-bins.lua" ''
    local FileManager = require("apps/filemanager/filemanager")
    FileManager.mv_bin = "${pkgs.coreutils}/bin/mv"
    FileManager.cp_bin = "${pkgs.coreutils}/bin/cp"
  '';

  # WiFi driver override: KoReader's reMarkable profile assumes wpa_supplicant,
  # but this stack runs NetworkManager, so its WiFi menu is inert without this
  # (overrides NetworkMgr's device primitives to shell out to nmcli). Shipped
  # whenever NetworkManager is enabled; loaded at priority 2 so it wins over the
  # wpa methods. Note the ''' below (an escaped '' — POSIX single-quote quoting)
  # and ${device.wifi.interface} interpolation.
  wifiPatch = pkgs.writeTextDir "2-nmcli-wifi.lua" ''
    -- Drive KoReader's WiFi via NetworkManager (nmcli). KoReader's reMarkable
    -- profile hardcodes a wpa_supplicant backend, so its WiFi menu is inert on
    -- this stack; override NetworkMgr's device primitives to use nmcli instead.
    local NetworkMgr = require("ui/network/manager")
    local logger = require("logger")

    local function run(cmd)
        local h = io.popen(cmd)
        if not h then return "" end
        local out = h:read("*a") or ""
        h:close()
        return out
    end
    local function trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
    -- single-quote a shell argument (SSID/password may contain anything)
    local function sq(s) return "'" .. tostring(s):gsub("'", "'\\'''") .. "'" end
    -- split one `nmcli -t` line, honoring `\:` (escaped colon) inside fields
    local function terse(line)
        local f, buf, i, n = {}, "", 1, #line
        while i <= n do
            local c = line:sub(i, i)
            if c == "\\" then buf = buf .. line:sub(i + 1, i + 1); i = i + 2
            elseif c == ":" then f[#f + 1] = buf; buf = ""; i = i + 1
            else buf = buf .. c; i = i + 1 end
        end
        f[#f + 1] = buf
        return f
    end

    function NetworkMgr:turnOnWifi(complete_callback, interactive)
        os.execute("nmcli radio wifi on")
        return self:reconnectOrShowNetworkMenu(complete_callback, interactive)
    end

    function NetworkMgr:turnOffWifi(complete_callback)
        os.execute("nmcli radio wifi off")
        if complete_callback then complete_callback() end
    end

    function NetworkMgr:isWifiOn()
        return trim(run("nmcli radio wifi 2>/dev/null")) == "enabled"
    end

    function NetworkMgr:isConnected()
        for line in run("nmcli -t -f DEVICE,STATE device 2>/dev/null"):gmatch("[^\n]+") do
            local f = terse(line)
            if f[1] == "${device.wifi.interface}" and f[2] == "connected" then return true end
        end
        return false
    end

    function NetworkMgr:getCurrentNetwork()
        local name = trim((run("nmcli -t -f GENERAL.CONNECTION device show ${device.wifi.interface} 2>/dev/null")
            :match("GENERAL.CONNECTION:(.-)\n")) or "")
        if name == "" or name == "--" then return nil end
        return { ssid = name, bssid = "any" }
    end

    function NetworkMgr:getNetworkList()
        os.execute("nmcli device wifi rescan 2>/dev/null")
        local list, seen = {}, {}
        for line in run("nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY,BSSID device wifi list 2>/dev/null"):gmatch("[^\n]+") do
            local f = terse(line)
            local inuse, ssid, signal, sec, bssid = f[1], f[2], f[3], f[4], f[5]
            if ssid and ssid ~= "" and not seen[ssid] then
                seen[ssid] = true
                list[#list + 1] = {
                    ssid = ssid,
                    signal_quality = tonumber(signal) or 0,
                    bssid = bssid or "",
                    flags = (sec and sec ~= "" and sec ~= "--") and ("[" .. sec .. "]") or "",
                    connected = (inuse == "*"),
                }
            end
        end
        return list
    end

    function NetworkMgr:authenticateNetwork(network)
        local cmd = "nmcli device wifi connect " .. sq(network.ssid)
        if network.password and #network.password > 0 then
            cmd = cmd .. " password " .. sq(network.password)
        end
        local out = run(cmd .. " 2>&1")
        if out:match("successfully activated") then return true end
        return false, trim(out)
    end

    function NetworkMgr:disconnectNetwork(network)
        os.execute("nmcli device disconnect ${device.wifi.interface} 2>/dev/null")
    end

    -- NetworkManager owns DHCP (done on connect), so these are no-ops.
    function NetworkMgr:obtainIP() end
    function NetworkMgr:releaseIP() end

    logger.info("[nmcli-wifi] NetworkMgr overridden to use NetworkManager (nmcli)")
  '';

  # Priority 2 ("late") — applied once UIManager is ready, which is when the
  # menu tables exist to hook. KoReader ONLY runs applyPatches for priorities
  # 0/1/2/8 (early_once/early/late/before_exit); 3–7 are reserved and NEVER
  # applied, so a "3-…" name would be silently dead. Keep this at 2.
  menuCommandsPatch = pkgs.writeTextDir "2-remarkable-menu-commands.lua" ''
    -- remarkable-nixos: shell-command menu entries (VPN toggle, the Apps
    -- launcher, …). Each runs a script with KoReader's PATH; a checkedCommand
    -- exit-0 shows a check; grouped entries nest under a submenu.
    local function add(MenuClass, order)
    ${menuOrderInserts}
        local orig = MenuClass.setUpdateItemTable
        MenuClass.setUpdateItemTable = function(self)
    ${menuItemDefs}
            return orig(self)
        end
    end
    local ok_fm, fm_order = pcall(require, "ui/elements/filemanager_menu_order")
    local ok_fmm, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if ok_fmm then add(FileManagerMenu, ok_fm and fm_order or nil) end
    local ok_r_order, r_order = pcall(require, "ui/elements/reader_menu_order")
    local ok_rm, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if ok_rm then add(ReaderMenu, ok_r_order and r_order or nil) end
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
    menuCommands = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          label = lib.mkOption {
            type = lib.types.str;
            description = "Menu entry text (in KoReader's tools/main menu).";
          };
          command = lib.mkOption {
            type = lib.types.str;
            description = "Shell command run when the entry is tapped. Runs with KoReader's PATH (systemd, networkmanager).";
          };
          checkedCommand = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Shell command whose exit-0 shows a checkmark on the entry (for toggles/status), re-run on every menu draw.";
          };
          group = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Submenu to place the entry under (entries sharing a group nest together); null = top-level menu entry.";
          };
          fullRefresh = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Do a full-screen e-ink refresh after the command (needed when the command took over the panel, e.g. launching an app); a plain toggle leaves this false.";
          };
        };
      });
      default = [];
      example = lib.literalExpression ''
        [ { label = "VPN"; command = "nmcli connection up nj || nmcli connection down nj";
            checkedCommand = "nmcli -t -f NAME connection show --active | grep -qx nj"; } ]
      '';
      description = "Shell-command entries added to KoReader's menu — e.g. a VPN toggle. checkedCommand drives a checkmark for toggle/status state.";
    };
    extraPatchDirs = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [];
      internal = true;
      description = "Additional userpatch directories contributed by other modules (e.g. the Apps launcher menu).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [launcher];

    remarkable.koreader.extraPatchDirs =
      [otaPatch fileBinsPatch]
      ++ (lib.optional (cfg.menuCommands != []) menuCommandsPatch)
      ++ (lib.optional config.networking.networkmanager.enable wifiPatch);

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
