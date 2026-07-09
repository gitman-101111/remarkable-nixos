# Persistent data across reflashes.
#
# The A/B root slots are EPHEMERAL — an image reflash replaces them wholesale.
# Everything that must survive an update lives on the persistent partition:
# user data via a whole-/home bind (/home = /persist/home), plus whatever
# system state your config binds there.
#
# This module provides the filesystem layout + SSH host-key placement; it
# deliberately does NOT pull in an impermanence-style bind-mount framework —
# add one in your own config if you want declarative /var/lib persistence
# (e.g. nix-community/impermanence with environment.persistence."/persist").
{
  config,
  lib,
  ...
}: let
  cfg = config.remarkable.persistence;
  device = config.remarkable.device;
in {
  options.remarkable.persistence.enable =
    lib.mkEnableOption "persistent /persist partition + whole-/home bind" // {default = true;};

  config = lib.mkIf cfg.enable {
    # (remarkable.persistence.enable also gates the stage-1 provisioning/
    # repair hook in initrd.nix. The layout is ext4-opinionated: the
    # provisioning tooling is mkfs.ext4/e2fsck.)

    # Referenced by GPT PARTLABEL, not fs LABEL: the partition table's name is
    # stable regardless of what mkfs labelled the filesystem. Do not switch to
    # by-label: a partition whose fs still carries a different label silently
    # nofail-skips the mount, and everything that depends on /persist wedges.
    # neededForBoot: mounted in stage 1 (before switch_root) so early stage-2
    # consumers (secrets, sshd-keygen) find it present. nofail keeps a bad
    # partition from blocking boot.
    fileSystems."/persist" = {
      device = "/dev/disk/by-partlabel/${device.partitions.persistPartlabel}";
      fsType = "ext4";
      neededForBoot = true;
      options = ["nofail"];
    };

    # Whole /home lives on the persistent partition as a bind of
    # /persist/home — the entire home is persistent, not just selected dirs.
    fileSystems."/home" = {
      device = "/persist/home";
      fsType = "none";
      neededForBoot = true;
      options = ["bind" "nofail"];
      depends = ["/persist"];
    };

    # SSH host keys live DIRECTLY on /persist — NOT via bind-mount frameworks.
    # Two traps this avoids:
    #  1. Persisting the whole /etc/ssh directory MASKS the NixOS-generated
    #     sshd_config / moduli / authorized_keys.d symlinks inside it → sshd
    #     has no config/keys and resets every connection at KEX.
    #  2. Persisting the key FILES via pre-created binds makes empty files,
    #     and `ssh-keygen -A` then SKIPS them (they "exist") → empty host
    #     keys.
    # Pointing services.openssh.hostKeys at /persist sidesteps both: the keys
    # are generated straight onto /persist (stable across reflashes) and
    # /etc/ssh keeps its generated contents. /persist is neededForBoot, so it
    # is mounted well before sshd-keygen runs in stage 2.
    services.openssh.hostKeys = [
      {
        path = "/persist/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
      {
        path = "/persist/ssh/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
    ];
  };
}
