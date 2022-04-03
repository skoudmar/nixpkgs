# This module contains the basic configuration for building a NixOS
# tarball for the sheevaplug.

{ config, lib, pkgs, ... }:

with lib;

let

  pkgs2storeContents = l : map (x: { object = x; symlink = "none"; }) l;

  # Stage 2 init script location
  initLocation = "${config.system.build.toplevel}/init";

  initLocationFile = pkgs.writeText "stage2InitLocation.txt" ''
    init=${initLocation}
  '';

  versionFile = pkgs.writeText "nixos-label" config.system.nixos.label;

  novabootScript = pkgs.writeScript "novabootScript" ''
    #!/usr/bin/env novaboot

    load kernel console=ttyAMA0,115200 8250.nr_uarts=1 console=ttyS0,115200 ip=dhcp loglevel=8 allowShell=1 init=${initLocation}
    load initrd
    load bcm2711-rpi-4-b.dtb

    UBOOT_CMD=booti ''${kernel_addr_r} ''${ramdisk_addr_r} ''${fdt_addr_r}
  '';
  

  initrdRepack = pkgs.runCommand 
    "initrdRepack" 
    {
      inherit (pkgs) ubootTools zstd;
      initrd = config.system.build.initialRamdisk + "/" + config.system.boot.loader.initrdFile;
      repackName = "nixos-initrd-repack";
    }
    ''
      RAW=$(mktemp)

      while [ -L "$initrd" ]; do
        initrd=$(readlink -n $initrd)
      done

      set -ex

      $zstd/bin/unzstd -fo "$RAW" "$initrd"
      $ubootTools/bin/mkimage -A arm64 -T ramdisk -C zstd -n "$repackName" -O linux -d "$RAW" "$out"

      rm -f "$RAW"

      set +ex
    '';

in

{
  options = {
    novaboot.tarball.contents = mkOption {
      example = literalExpression ''
        [ { source = pkgs.memtest86 + "/memtest.bin";
            target = "boot/memtest.bin";
          }
        ]
      '';
      description = ''
        This option lists files to be copied to fixed locations in the
        generated tarball.
      '';
    };

    novaboot.tarball.storeContents = mkOption {
      example = literalExpression "[ pkgs.stdenv ]";
      description = ''
        This option lists additional derivations to be included in the
        Nix store in the generated tarball.
      '';
    };

    novaboot.nfs.server.address = mkOption {
      type = with types; nullOr str;
      example = literalExpression "1.2.3.4";
      description = ''
        Address of the NFS server hosting the root filesystem.
      '';
    };

    novaboot.nfs.server.rootPath = mkOption {
      type = with types; path;
      example = "/nfsroot";
    };

    novaboot.nfs.server.nfsPort = mkOption {
      type = with types; nullOr port;
      default = null;
    };

    novaboot.nfs.server.mountPort = mkOption {
      type = with types; nullOr port;
      default = config.novaboot.nfs.server.nfsPort;
    };

    novaboot.nfs.server.options = mkOption {
      type = with types; listOf str;
      default = [ ];
      example = literalExpression ''[ "nolock" ]'';
    };

  };

  imports = [
    ../../profiles/base.nix
    ../../profiles/all-hardware.nix
  ];

  config = {

    fileSystems."/" = 
    let 
      mkOptionIfNotEmpty = option: optionName: if (option == null) then "" else "${optionName}=${option}";
      nfsPort = mkOptionIfNotEmpty config.novaboot.nfs.server.nfsPort "port";
      mountPort = mkOptionIfNotEmpty config.novaboot.nfs.server.mountPort "mountport";
      nfsOptions = config.novaboot.nfs.server.options;
      inherit (config.novaboot.nfs.server) address rootPath;
    in {
      neededForBoot = true;
      device = "${address}:${rootPath}";
      fsType = "nfs";
      options = nfsOptions ++ (builtins.filter (x: x != "") [ "${nfsPort}" "${mountPort}" ]);
    };

    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = true;
    boot.kernelParams = ["console=ttyS0,115200n8" "console=ttyAMA0,115200n8" "console=tty0" "8250.nr_uarts=1"];

    # To speed up further installation of packages, include the complete stdenv
    # in the Nix store of the tarball.
    novaboot.tarball.storeContents = pkgs2storeContents [ pkgs.stdenv ] ++ [
      {
        object = config.system.build.toplevel;
        symlink = "/run/current-system";
      }
    ];


    novaboot.tarball.contents = [
      { source = initrdRepack;
        target = "/boot/" + config.system.boot.loader.initrdFile;
      }
      { source = initLocationFile;
        target = "/boot/stage2InitLocation.txt";
      }
      { source = versionFile;
        target = "/nixos-version.txt";
      }
      {
        source = novabootScript;
        target = "/boot/boot-rpi4";
      }
      {
        source = pkgs.raspberrypifw + "/share/raspberrypi/boot/bcm2711-rpi-4-b.dtb";
        target = "/boot/bcm2711-rpi-4-b.dtb";
      }
      {
        source = "${config.boot.kernelPackages.kernel}/" +
        "${config.system.boot.loader.kernelFile}";
        target = "/boot/kernel";
      }
    ];


    system.build.novabootTarball = import ../../../lib/make-system-tarball.nix {
      inherit (pkgs) stdenv closureInfo pixz;

      inherit (config.novaboot.tarball) contents storeContents;

      compressCommand = "cat";
      compressionExtension = "";
      extraInputs = [ ];
    };

    # enable NFS support in kernel
    boot.kernelPatches = [
      {
        name = "nfsroot";
        patch = null;
        extraConfig = ''
          IP_PNP y
          IP_PNP_DHCP y
          NFS_FS y
          NFS_V3 y
          ROOT_NFS y
        '';
      }
    ];

    boot.postBootCommands =
      ''
        # After booting, register the contents of the Nix store on the
        # CD in the Nix database in the tmpfs.
        if [ -f /nix-path-registration ]; then
          ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration &&
          rm /nix-path-registration
        fi

        # nixos-rebuild also requires a "system" profile and an
        # /etc/NIXOS tag.
        touch /etc/NIXOS
        ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
      '';
  };
}
