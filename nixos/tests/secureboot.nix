{ system ? builtins.currentSystem,
  config ? {},
  pkgs ? import ../.. { inherit system config; }
}:

with import ../lib/testing-python.nix { inherit system pkgs; };
with pkgs.lib;

let
  common = {
    virtualisation.useBootLoader = true;
    virtualisation.useEFIBoot = true;
    virtualisation.useSecureBoot = true;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.blacklistedKernelModules = [ "bochs_drm" ];
    boot.kernelParams = [ "nomodeset" "console=tty0" "console=ttyS0,115200" "debug" ];
    environment.systemPackages = [ pkgs.efibootmgr pkgs.sbsigntool pkgs.sbctl ];
  };
in
{
  basic = makeTest {
    name = "secureboot-installation-prevent-reboot";
    meta.maintainers = with pkgs.lib.maintainers; [ raitobezarius ];

    nodes.machine = common;

    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")

      machine.succeed("sbctl status")
    '';
  };
}
