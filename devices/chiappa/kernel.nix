# chiappa kernel: reMarkable's fork of the NXP i.MX 6.12.49 BSP, built with
# the vendor's COMPLETE config plus the deltas below. Config + patches come
# from the chiappa hardware layer (flake input); the source tarball is fetched
# from reMarkable's GitHub (git-lfs raw).
{
  pkgs,
  hardware-chiappa,
  ...
}: let
  version = "6.12.49";

  # Content-address each kernel patch by reading its bytes and re-storing them
  # (same trick the config below uses via readFile/toFile). This decouples the
  # kernel derivation from the FULL hardware-layer input hash: touching
  # anything else in it (eink sources, docs, tooling) no longer changes the
  # patch store paths, so the kernel only rebuilds when a patch's actual
  # content changes.
  mkPatch = fname: builtins.toFile fname (builtins.readFile "${hardware-chiappa}/kernel/${fname}");

  # Promote the i.MX ChipIdea USB controller + glue from =m to built-in =y.
  # Done as an in-place rewrite of the base config (single assignment), NOT an
  # appended override: this kernel's config processing takes the FIRST
  # assignment for a duplicated symbol, so a trailing `CONFIG_..=y` after the
  # base `=m` is silently ignored. Built-in means the USB ECM gadget comes up
  # with no module-load step or version-matched .ko, so the headless SSH link
  # doesn't depend on modprobe timing/ordering.
  #
  # USB_CHIPIDEA is a tristate that depends on USB_EHCI_HCD (&& USB_GADGET);
  # a tristate can't be built-in while a dependency is =m, so EHCI must be
  # promoted too or Kconfig silently demotes CHIPIDEA back to =m.
  #
  # DM_INIT off: the vendor U-Boot unconditionally appends
  #   dm-mod.create="swap-encrypted-disk,,1,rw,0 3145728 crypt aes-xts-plain64
  #     :32:logon:lpgpr:bootkey 0 /dev/mmcblk0p4 0 0"
  #   dm-mod.waitfor="PARTLABEL=root_a"
  # to the kernel cmdline (its mmcswap/mmcargs env — swappart=4 is hardcoded).
  # DM_INIT is what honors those args: it overlays a rw crypt mapping on the
  # first 1.5 GiB of p4 and holds p4 open EXCLUSIVELY, so once p4 is
  # repurposed as the persistent data partition, every mount/mkfs of it fails
  # EBUSY and any write through the mapping would scribble AES garbage over
  # the filesystem. With DM_INIT off the kernel ignores dm-mod.* entirely.
  # The vendor slot boots its own kernel, so it keeps its encrypted-swap
  # behavior — this only changes what THIS kernel does.
  baseConfig =
    builtins.replaceStrings
    [
      "CONFIG_USB_EHCI_HCD=m"
      "CONFIG_USB_EHCI_HCD_PLATFORM=m"
      "CONFIG_USB_CHIPIDEA=m"
      "CONFIG_USB_CHIPIDEA_IMX=m"
      "CONFIG_DM_INIT=y"
    ]
    [
      "CONFIG_USB_EHCI_HCD=y"
      "CONFIG_USB_EHCI_HCD_PLATFORM=y"
      "CONFIG_USB_CHIPIDEA=y"
      "CONFIG_USB_CHIPIDEA_IMX=y"
      "# CONFIG_DM_INIT is not set"
    ]
    (builtins.readFile "${hardware-chiappa}/kernel/config-remarkable-chiappa.aarch64");

  configFile = builtins.toFile "chiappa-nixos-kernel.config" (
    baseConfig
    + ''

      # NixOS deltas
      CONFIG_BLK_DEV_INITRD=y
      CONFIG_DMIID=y

      # Disable ARM64 features nixpkgs' newer toolchain auto-selects that the
      # i.MX93's Cortex-A55 (ARMv8.2) does not implement; with them enabled
      # the kernel panics before any console output (the vendor/pmOS config
      # has both off):
      #  - PTR_AUTH_KERNEL builds the whole kernel with -mbranch-protection=
      #    pac-ret; the wrong return encoding is undefined on a non-PAC core.
      #  - MTE is an ARMv8.5 memory-tagging feature the A55 doesn't implement.
      # CONFIG_ARM64_PTR_AUTH_KERNEL is not set
      # CONFIG_ARM64_MTE is not set

      # nftables firewall. The vendor BSP kernel ships only legacy
      # iptables/xtables (NF_TABLES unset, NFNETLINK absent entirely), so
      # NixOS's nftables-based firewall dies with "Unable to initialize Netlink
      # socket: Protocol not supported". Build the nftables core in; the
      # expression modules are auto-loaded by the firewall service at runtime.
      # (Important on a device that roams onto untrusted/public wifi.)
      CONFIG_NETFILTER_NETLINK=y
      CONFIG_NF_TABLES=y
      CONFIG_NF_TABLES_INET=y
      CONFIG_NF_TABLES_IPV4=y
      CONFIG_NF_TABLES_IPV6=y
      CONFIG_NFT_CT=m
      CONFIG_NFT_COUNTER=m
      CONFIG_NFT_LOG=m
      CONFIG_NFT_LIMIT=m
      CONFIG_NFT_REJECT=m
      CONFIG_NFT_REJECT_INET=m
      CONFIG_NFT_FIB=m
      CONFIG_NFT_FIB_INET=m
      CONFIG_NFT_FIB_IPV4=m
      CONFIG_NFT_FIB_IPV6=m
      CONFIG_NFT_NAT=m
      CONFIG_NFT_MASQ=m
      CONFIG_NFT_COMPAT=m

      # WireGuard (e.g. syncing books from a home NAS over the WiFi link).
      # Not in the vendor config; CONFIG_WIREGUARD selects the crypto library
      # primitives (curve25519/chacha20poly1305/blake2s), whose generic
      # implementations are already present. TUN is added for userspace VPN
      # tools too. The tunnel itself (keys, peer, allowed IPs) is per-user
      # config, not shipped here.
      CONFIG_WIREGUARD=m
      CONFIG_TUN=m
      CONFIG_CRYPTO_LIB_CURVE25519=m
      CONFIG_CRYPTO_LIB_CHACHA20POLY1305=m
    ''
  );
in {
  remarkable.kernel = {
    inherit version configFile;
    # matches CONFIG_LOCALVERSION so /lib/modules paths line up
    modDirVersion = "${version}+git+122eda1b63d9";

    src = pkgs.fetchurl {
      url = "https://github.com/reMarkable/linux-imx-rm/raw/rmpp_6.12.49_v3.26.x/linux-imx-rel-5.6-vc-3.26.0.68-122eda1b63d9.tar.gz";
      hash = "sha256-6ZaWkM5ZOY8cs7FKuUbOfpQnRMdp3t+ikaK+ADuLthw=";
    };

    # Build with gcc 14, NOT nixpkgs' default. This is a 2024-era BSP kernel;
    # gcc 15 miscompiles it into a kernel that panics before any console
    # output. pmOS's kernel — same source, same config — boots because Alpine
    # built it with gcc 14.
    stdenv = pkgs.gcc14Stdenv;

    patches = [
      {
        name = "panel-cumulus-select-videomode-helpers";
        patch = mkPatch "0001-drm-panel-remarkable-cumulus-select-VIDEOMODE_HELPERS.patch";
      }
      {
        name = "vkms-default-mode-954x1696";
        patch = mkPatch "0002-drm-vkms-set-default-mode-to-954x1696-for-chiappa-panel.patch";
      }
      {
        name = "vkms-allow-cloning-virtual-writeback-encoders";
        patch = mkPatch "0003-drm-vkms-allow-cloning-virtual-and-writeback-encoder.patch";
      }
    ];

    # eMMC/ext4/USB-gadget are built INTO the kernel, so stage 1 needs no
    # storage modules — but the USB-C data port (usb@4c100000) is behind a
    # FUSB303B Type-C port controller on i2c-1 (1-0021), and the headless USB
    # link needs this exact =m chain loaded (kernel boots + UDC binds
    # regardless, but nothing enumerates without them):
    #   - typec / fusb303b : the Type-C port controller. Without it port0
    #     never negotiates the *device* role, so the ChipIdea D+ pull-up
    #     never engages.
    #   - max77818_charger : fusb303b's DT `vbus-power-supply` is the
    #     max77818 charger power_supply; its probe DEFERS ("VBUS supply not
    #     ready") until the charger registers. MFD_MAX77818 and
    #     BATTERY_MAX77818 are =y, but CHARGER_MAX77818 is =m — so without
    #     it fusb303b hangs deferred forever.
    initrdModules = ["max77818_charger" "typec" "fusb303b"];
  };
}
