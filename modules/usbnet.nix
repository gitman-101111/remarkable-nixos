# USB ECM network gadget — brings the device up at a static address over USB
# so the host can reach it (this is the primary access path; no display login
# needed).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.remarkable.usbnet;
  setup = pkgs.writeShellScript "remarkable-usbnet-up" ''
    set -e
    modprobe libcomposite 2>/dev/null || true

    # Wait for a UDC to appear
    i=0
    while [ -z "$(ls /sys/class/udc 2>/dev/null)" ] && [ "$i" -lt 40 ]; do
      sleep 0.5; i=$((i+1))
    done

    G=/sys/kernel/config/usb_gadget/g1
    if [ ! -d "$G" ]; then
      mkdir -p "$G"
      echo 0x1d6b > "$G/idVendor"
      echo 0x0104 > "$G/idProduct"
      mkdir -p "$G/strings/0x409"
      echo "${config.remarkable.device.codename}" > "$G/strings/0x409/serialnumber"
      echo "reMarkable"                           > "$G/strings/0x409/manufacturer"
      echo "${config.remarkable.device.marketName}" > "$G/strings/0x409/product"
      mkdir -p "$G/functions/ecm.usb0"
      mkdir -p "$G/configs/c.1/strings/0x409"
      echo "ecm" > "$G/configs/c.1/strings/0x409/configuration"
      ln -sf "$G/functions/ecm.usb0" "$G/configs/c.1/"
      ls /sys/class/udc | head -1 > "$G/UDC"
    fi

    sleep 1
    ${pkgs.iproute2}/bin/ip addr add ${cfg.hostAddress}/24 dev usb0 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip link set usb0 up
  '';
  teardown = pkgs.writeShellScript "remarkable-usbnet-down" ''
    ${pkgs.iproute2}/bin/ip link set usb0 down 2>/dev/null || true
    G=/sys/kernel/config/usb_gadget/g1
    [ -d "$G" ] && echo "" > "$G/UDC" 2>/dev/null || true
  '';
in {
  options.remarkable.usbnet = {
    enable = lib.mkEnableOption "USB ECM network gadget" // {default = true;};
    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.11.99.1";
      description = "IPv4 the device presents on the USB link.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = ["libcomposite"];
    # configfs must be mounted for the gadget
    boot.specialFileSystems."/sys/kernel/config" = {
      device = "configfs";
      fsType = "configfs";
    };

    # Pin the gadget iface name: udev's default NamePolicy can rename usb0
    # (e.g. to an enX* path name), which silently breaks every name-matched
    # rule — NM's unmanaged list, firewall trustedInterfaces, this module's
    # `ip ... dev usb0`. A first-match .link with an explicit Name stops the
    # default policy.
    systemd.network.links."10-usb0" = {
      matchConfig.OriginalName = "usb0";
      linkConfig.Name = "usb0";
    };

    # Keep DHCP/connection managers off the gadget iface, and trust the
    # point-to-point dev link through the firewall.
    networking.networkmanager.unmanaged = lib.mkIf config.networking.networkmanager.enable ["interface-name:usb0"];
    networking.firewall.trustedInterfaces = ["usb0"];

    systemd.services.remarkable-usbnet = {
      description = "USB ECM network gadget";
      wantedBy = ["multi-user.target"];
      after = ["systemd-modules-load.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = setup;
        ExecStop = teardown;
      };
    };

    # sshd is the point of the link
    services.openssh.enable = lib.mkDefault true;
  };
}
