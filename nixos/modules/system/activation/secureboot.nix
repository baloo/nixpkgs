{ config, lib, pkgs, extendModules, noUserModules, ... }:

with lib;

let
  cfg = config.system.secureboot;
  efi = config.boot.loader.efi;

  kernelEfiImage =
    let
      kernel = "${config.boot.kernelPackages.kernel}/" +
        "${config.system.boot.loader.kernelFile}";
      initramfs = "${config.system.build.initialRamdisk}/" +
        "${config.system.boot.loader.initrdFile}";
    in pkgs.makeEFIImage {
      inherit kernel initramfs;
      inherit (config.boot) kernelParams;
    };

  signedEfiImage = pkgs.runCommand "signed-efi-image" {} ''
    mkdir $out
    ${pkgs.sbsigntool}/bin/sbsign \
      --key "${config.system.secureboot.privateKey}" \
      --cert "${config.system.secureboot.cert}" \
      --output $out/linux.efi \
      "${kernelEfiImage}/linux.efi"

    echo "OUTPUT KERNEL"
    echo $out
  '';

  efiImage = if config.system.secureboot.cert == null
    then kernelEfiImage
    else signedEfiImage;

  systemBuilder =
    ''
      mkdir $out

      ln -s ${efiImage}/linux.efi $out/kernel
      ln -s ${config.system.modulesTree} $out/kernel-modules
      ${optionalString (config.hardware.deviceTree.package != null) ''
        ln -s ${config.hardware.deviceTree.package} $out/dtbs
      ''}

      echo -n "$kernelParams" > $out/kernel-params

      ln -s ${config.hardware.firmware}/lib/firmware $out/firmware

      echo "$activationScript" > $out/activate
      echo "$dryActivationScript" > $out/dry-activate
      substituteInPlace $out/activate --subst-var out
      substituteInPlace $out/dry-activate --subst-var out
      chmod u+x $out/activate $out/dry-activate
      unset activationScript dryActivationScript

      ${if config.boot.initrd.systemd.enable then ''
        cp ${config.system.build.bootStage2} $out/prepare-root
        substituteInPlace $out/prepare-root --subst-var-by systemConfig $out
        # This must not be a symlink or the abs_path of the grub builder for the tests
        # will resolve the symlink and we end up with a path that doesn't point to a
        # system closure.
        cp "$systemd/lib/systemd/systemd" $out/init
      '' else ''
        cp ${config.system.build.bootStage2} $out/init
        substituteInPlace $out/init --subst-var-by systemConfig $out
      ''}

      ln -s ${config.system.build.etc}/etc $out/etc
      ln -s ${config.system.path} $out/sw
      ln -s "$systemd" $out/systemd

      echo -n "$configurationName" > $out/configuration-name
      echo -n "systemd ${toString config.systemd.package.interfaceVersion}" > $out/init-interface-version
      echo -n "$nixosLabel" > $out/nixos-version
      echo -n "${config.boot.kernelPackages.stdenv.hostPlatform.system}" > $out/system

      mkdir $out/bin
      export localeArchive="${config.i18n.glibcLocales}/lib/locale/locale-archive"
      substituteAll ${./switch-to-configuration.pl} $out/bin/switch-to-configuration
      chmod +x $out/bin/switch-to-configuration
      ${optionalString (false && pkgs.stdenv.hostPlatform == pkgs.stdenv.buildPlatform) ''
        if ! output=$($perl/bin/perl -c $out/bin/switch-to-configuration 2>&1); then
          echo "switch-to-configuration syntax is not valid:"
          echo "$output"
          exit 1
        fi
      ''}
    '';

  system = pkgs.stdenvNoCC.mkDerivation {
    name = "nixos-system-${config.system.name}-${config.system.nixos.label}";
    preferLocalBuild = true;
    allowSubstitutes = false;
    buildCommand = systemBuilder;

    inherit (pkgs) coreutils;
    systemd = config.systemd.package;
    shell = "${pkgs.bash}/bin/sh";
    su = "${pkgs.shadow.su}/bin/su";
    utillinux = pkgs.util-linux;

    activationScript = config.system.activationScripts.script;
    installBootLoader = config.system.build.installBootLoader;
    dryActivationScript = config.system.dryActivationScript;
    nixosLabel = config.system.nixos.label;
    kernelParams = config.boot.kernelParams;

    configurationName = config.boot.loader.grub.configurationName;

    # Needed by switch-to-configuration.
    perl = pkgs.perl.withPackages (p: with p; [ ConfigIniFiles FileSlurp ]);
  };

  systemdBootBuilder = pkgs.substituteAll {
    src = ./secureboot-systemd-boot-builder.py;
    isExecutable = true;

    inherit (pkgs) python3;

    systemd = config.systemd.package;

    nix = config.nix.package.out;

    timeout = if config.boot.loader.timeout != null then config.boot.loader.timeout else "";

    inherit (cfg) signedShim signedSystemd;

    inherit (efi) efiSysMountPoint canTouchEfiVariables;
  };

  dummyBootBuilder = pkgs.runCommand "systemd-boot" {
    nativeBuildInputs = [ pkgs.mypy ];
  } ''
    install -m755 ${systemdBootBuilder} $out
    mypy \
      --no-implicit-optional \
      --disallow-untyped-calls \
      --disallow-untyped-defs \
      $out
  '';

in {
  options = {
    system.secureboot = {
      enable = mkEnableOption ''
        Enables the secureboot to build a signed efi image.
      '';

      privateKey = mkOption {
        type = types.nullOr types.string;
        default = null;
        description = ''
          Path to the private key for signing the kernel initrd image
        '';
      };

      cert = mkOption {
        type = types.nullOr types.string;
        default = null;
      };

      signedShim = mkOption {
        type = types.nullOr types.path;
        default = null;
      };

      signedSystemd = mkOption {
        type = types.nullOr types.path;
        default = null;
      };
    };
  };

  config = mkIf cfg.enable {
    boot.loader.grub.enable = mkDefault false;

    system = {
      build.installBootLoader = dummyBootBuilder;
      build.toplevel = lib.mkForce system;
    };
  };
}

