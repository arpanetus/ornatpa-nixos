#!/usr/bin/env bash
set -e

dev=nvme0n1
efi=true
boot_fs=vfat
state_version="19.09"
profile="<nixpkgs/nixos/modules/installer/scan/not-detected.nix>"

prompt() {
    echo It is ok if it ends with OK
    echo
    trap '[ $? != 0 ] && echo NOT OK || finish' exit

    [[ "$@" = *"-f"* ]] || {
	echo 'This script prepares a machine for provision'
	echo 'And should be executed in the target environment'
	echo 'Please write uppercase YES to continue'
	echo 'Or Ctrl-C to exit'
	echo
	read yes
	[ "$yes" = "YES" ] || {
            echo 'Canceled'
            exit 1
	}
    }
}

init() {
    ## detecting profile
    ls -1 /dev/disk/by-id/ | grep -vi qemu > /dev/null 2>&1 || {
	profile="<nixpkgs/nixos/modules/profiles/qemu-guest.nix>"
    }

    ##

    ## detecting efi support
    efivar --list > /dev/null || {
	efi=false
	boot_fs=ext4
    }
}

begin() {
    init
    prompt

    umount -R /mnt              || true
    cryptsetup luksClose system || true
    cryptsetup luksClose key    || true
}

finish() {
    echo OK
    echo
    echo You could edit /mnt/etc/nixos/hardware-configuration.nix
    echo You could edit /mnt/etc/nixos/configuration.nix
    echo
    echo After that call nixos-install
    echo You will be prompted for password at the end of the process
    echo
}

uuid_of() {
    blkid "$1" | perl -p -e 's|^.*\sUUID="([0-9a-zA-Z-]+)".*$|\1|g'
}

##

begin

set -x

if [ "$efi" = "true" ]
then
    echo -e "x\nz\nY\nY\n" | gdisk /dev/${dev} > /dev/null
    echo -e echo -e "o\nY\nn\n\n\n+512M\nef00\n\nn\n\n\n+3600K\n\nn\n\n\n\n\n\nw\nY\n" \
        | gdisk /dev/${dev} > /dev/null
    mkfs.vfat /dev/${dev}p1
else
    dd if=/dev/zero of=/dev/${dev} bs=1M count=15 || true
    echo -e "o\nn\np\n\n\n+512M\n\nn\np\n\n\n+3600K\n\nn\np\n\n\n\n\na\n1\nw\n" \
        | fdisk /dev/${dev} > /dev/null
    mkfs.ext4 -L boot /dev/${dev}p1
fi

dd if=/dev/urandom of=/dev/${dev}p2 || true

cryptsetup luksFormat /dev/${dev}p2
cryptsetup luksOpen   /dev/${dev}p2 key

dd if=/dev/urandom of=/dev/mapper/key || true

cryptsetup -y luksFormat --key-file=/dev/mapper/key /dev/${dev}p3
cryptsetup    luksOpen   --key-file=/dev/mapper/key /dev/${dev}p3 system

mkfs.btrfs -L system /dev/mapper/system
mount /dev/mapper/system /mnt

mkdir /mnt/boot
mount /dev/${dev}p1 /mnt/boot


nixos-generate-config --root /mnt

cat <<EOF > /mnt/etc/nixos/configuration.nix
{ config, pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ];
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  services.openssh.enable = true;
  services.openssh.passwordAuthentication = true;
  services.openssh.permitRootLogin = "yes";
  system.stateVersion = "${state_version}";

}
EOF

cat <<EOF > /mnt/etc/nixos/hardware-configuration.nix
{ config
, lib ? (import <nixpkgs> { }).lib
, pkgs ? (import <nixpkgs> { }).pkgs
, ... }: let
  systemPartition = "system";
in {
 imports = [ $profile ];

  boot = {
    loader = {
      grub.device              = "/dev/${dev}";
      systemd-boot.enable      = ${efi};
      efi.canTouchEfiVariables = ${efi};
    };

    initrd.luks.devices = [
      {
        name = "key";
        device = "/dev/disk/by-uuid/$(uuid_of "/dev/${dev}p2")";
      }
      {
        name = "system";
        device = "/dev/disk/by-uuid/$(uuid_of "/dev/${dev}p3")";
        keyFile = "/dev/mapper/key";
      }
    ];

    initrd.postDeviceCommands = lib.mkAfter "cryptsetup luksClose key";
  };

  fileSystems."/" = {
    device = "/dev/mapper/system";
    fsType = "btrfs";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/$(uuid_of "/dev/${dev}p1")";
    fsType = "${boot_fs}";
  };

  powerManagement.cpuFreqGovernor = "ondemand";
}
EOF

set +x
