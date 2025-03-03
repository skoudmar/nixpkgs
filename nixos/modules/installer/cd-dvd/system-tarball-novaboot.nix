# This module contains the basic configuration for building a NixOS
# tarball for the novaboot.

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

    load kernel console=ttyAMA0,115200 8250.nr_uarts=1 console=ttyS0,115200 ip=dhcp loglevel=8 init=${initLocation} nfsPrefix=$NB_NFSROOT nfsOptions=$NB_NFSOPTS allowShell=1 
    load initrd
    load bcm2711-rpi-4-b.dtb

    UBOOT_CMD=booti ''${kernel_addr_r} ''${ramdisk_addr_r} ''${fdt_addr_r}
  '';
  

  initrdRepack = pkgs.runCommand 
    "initrdRepack" 
    {
      inherit (pkgs) ubootTools zstd;
      inherit (config.system.build) initialRamdisk;
      inherit (config.system.boot.loader) initrdFile;
      repackName = "nixos-initrd-repack";
    }
    ''
      RAW=$(mktemp)
      initrd=$initialRamdisk/$initrdFile

      while [ -L "$initrd" ]; do
        initrd=$(readlink -n $initrd)
      done

      set -ex

      $zstd/bin/unzstd -fo "$RAW" "$initrd"
      $ubootTools/bin/mkimage -A arm64 -T ramdisk -C zstd -n "$repackName" -O linux -d "$RAW" "$out"

      rm -f "$RAW"

      set +ex
    '';

  # if rootPath starts with single '/' prepend it with another '/'.
  parseRootPath = rootPath: if ((builtins.substring 0 1 rootPath) == "/") && ((builtins.substring 0 2 rootPath) != "//")
                              then "/" + rootPath
                              else rootPath;
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
      default = null;
      description = ''
        Address of the NFS server hosting the root filesystem.

        Keep null if you intend to use nfsPrefix argument on kernel command line.
      '';
    };

    novaboot.nfs.server.rootPath = mkOption {
      type = with types; path;
      example = "/nfsroot";
      default = "/";
      description = ''
        Exported path on the NFS server to be mounted as '/'.

        Prefix provided as nfsPrefix to the kernel command line will be prepended
        to this path.
      '';
    };

    novaboot.nfs.server.nfsPort = mkOption {
      type = with types; nullOr port;
      default = null;
      description = ''
        Port for NFS protocol of NFS server hosting the root directory.

        Do not specify if you intend to supply this in nfsOptions on the kernel command line.
      '';
    };

    novaboot.nfs.server.mountPort = mkOption {
      type = with types; nullOr port;
      default = config.novaboot.nfs.server.nfsPort;
      description = ''
        Port for MOUNT protocol of NFS server hosting the root directory.

        Do not specify if you intend to supply this in nfsOptions on the kernel command line.
      '';
    };

    novaboot.nfs.server.options = mkOption {
      type = with types; listOf str;
      default = [ ];
      example = literalExpression ''[ "nolock" "tcp" ]'';
      description = ''
        Additional options passed to mount durring mounting of the root directory.

        This options will be appended by nfsOptions on the kernel command line.
      '';
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
      address = config.novaboot.nfs.server.address;
      rootPath = parseRootPath config.novaboot.nfs.server.rootPath;
    in {
      neededForBoot = true;
      device = if (address != null) then "${address}:${rootPath}" else "${rootPath}";
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
          BCMGENET y
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
