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
    boot.initrd.systemd.enable = mkForce false;
    boot.loader.efi.canTouchEfiVariables = true;
    environment.systemPackages = [ pkgs.efibootmgr pkgs.sbsigntool pkgs.sbctl];
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

      machine.succeed("sbctl create-keys")
      machine.succeed("sbctl enroll-keys --yes-this-might-brick-my-machine")

      machine.shutdown()

      machine.dump_efi_vars()

      # Now we cannot reboot because we did not sign our boot files!
      machine.start()
      # Test for EDK2 to reject the payload
      machine.wait_for_console_text('Access Denied')
    '';
  };

  # https://uefi.org/sites/default/files/resources/1_-_UEFI_Summit_Deploying_Secure_Boot_July_2012_0.pdf
  # TODO:
  #  get edk2 in the SECURE_BOOT_DEPLOYED state
  #  See figure 32-4 Secure Boot Modes from UEFI Specification 2.9
  shim = let
    genKey = name: rec {
      private = pkgs.runCommand "${name}-private-key" {} ''
        mkdir $out
        # Microsoft requires rsa keys to be at least 2048 to be cross signed
        # unclear if they would allow ecdsa
        ${pkgs.openssl}/bin/openssl genrsa -out $out/key 2048
      '';
      cert = pkgs.runCommand "${name}-cert" {} ''
        mkdir $out
        ${pkgs.openssl}/bin/openssl req -new -x509 -sha256 -subj "/C=US/CN=snakeoil${name}/" -key ${private}/key -out $out/cert.der -days 3650 -outform DER
        ${pkgs.openssl}/bin/openssl x509 -in $out/cert.der -out $out/cert.pem -inform DER -outform PEM
      '';
    };

    keys = {
      manufacturerPK = genKey "PK"; 
      kek = genKey "KEK"; 
      microsoftKey = genKey "db"; 

      vendor = genKey "vendor";
    };
    guid = "fc38144d-edd8-4595-8399-1cb1ec278bf7";

    genSigList = name: key: pkgs.runCommand "${name}-siglist" {} ''
      ${pkgs.sbsigntool}/bin/sbsiglist --owner "${guid}" --type x509 --output "$out" "${key.cert}/cert.der"
    '';

    signatureLists = {
      pk = genSigList "pk" keys.manufacturerPK;
      kek = genSigList "kek" keys.kek;
      db = genSigList "db" keys.microsoftKey;
    };

    genSignedUpdate = name: signatureList: signingKey: pkgs.runCommand "${name}-signedupdate" {} ''
      ${pkgs.sbsigntool}/bin/sbvarsign \
        --key "${signingKey.private}/key" --cert "${signingKey.cert}/cert.pem" \
        --output "$out" \
        "${name}" \
        "${signatureList}"
    '';

    signedUpdates = {
      pk = genSignedUpdate "PK" signatureLists.pk keys.manufacturerPK;
      kek = genSignedUpdate "KEK" signatureLists.kek keys.manufacturerPK;
      db = genSignedUpdate "db" signatureLists.db keys.kek;
    };

    shim = pkgs.shim {
      vendorCertFile = "${keys.vendor.cert}/cert.der";
      defaultLoader = "systemd-bootx64.efi";
    };

    # Get Microsoft to sign our shim
    signedShim = pkgs.runCommand "signed-shim" {} ''
      mkdir $out
      ${pkgs.sbsigntool}/bin/sbsign \
        --key "${keys.microsoftKey.private}/key" \
        --cert "${keys.microsoftKey.cert}/cert.pem" \
        --output $out/shimx64.efi \
        "${shim}/shimx64.efi"
    '';

    signedSystemd = pkgs.runCommand "signed-systemd" {} ''
      mkdir $out
      ${pkgs.sbsigntool}/bin/sbsign \
        --key "${keys.vendor.private}/key" \
        --cert "${keys.vendor.cert}/cert.pem" \
        --output $out/systemd-bootx64.efi \
        "${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootx64.efi"
    '';
  in makeTest {
    name = "secureboot-shim-demo";
    meta.maintainers = with pkgs.lib.maintainers; [ baloo ];

    nodes.machine = common // {
      system.secureboot = {
        privateKey = "${keys.vendor.private}/key";
        cert = "${keys.vendor.cert}/cert.pem";
        enable = true;

        signedShim = "${signedShim}/shimx64.efi";
        signedSystemd = "${signedSystemd}/systemd-bootx64.efi";
      };

      boot.loader.systemd-boot.enable = pkgs.lib.mkForce false;
    };

    testScript = ''
      print("${keys.manufacturerPK.cert}")
      print("${keys.kek.cert}")
      print("${keys.microsoftKey.cert}")

      print("${signatureLists.pk}")
      print("${signedUpdates.pk}")

      print("${shim}")
      print("${signedShim}")

      machine.create_efi_vars()
      machine.dump_efi_vars()

      from test_driver.efi import EfiVariable, EfiGuid
      from typing import List

      Flags = EfiVariable.Flags
      State = EfiVariable.State

      add: List[EfiVariable] = []

      add.append(
          EfiVariable(
              vendor_uuid=EfiGuid.gEfiCustomModeEnableGuid,
              name="CustomMode",
              state=State.VAR_HEADER_VALID_ONLY | State.VAR_ADDED,
              flags=0, # TODO default that
              data=b"\0",
          )
      )

      with open("${signatureLists.db}", "rb") as f:
          add.append(
              EfiVariable(
                  vendor_uuid=EfiGuid.gEfiImageSecurityDatabaseGuid,
                  name="db",
                  state=State.VAR_HEADER_VALID_ONLY | State.VAR_ADDED,
                  flags=0, # default that
                  data=f.read(),
              )
          )

      with open("${signatureLists.kek}", "rb") as f:
          add.append(
              EfiVariable(
                  vendor_uuid=EfiGuid.gEfiGlobalVariableGuid,
                  name="KEK",
                  state=State.VAR_HEADER_VALID_ONLY | State.VAR_ADDED,
                  flags=0, # TODO default that
                  data=f.read(),
              )
          )

      with open("${signatureLists.pk}", "rb") as f:
          add.append(
              EfiVariable(
                  vendor_uuid=EfiGuid.gEfiGlobalVariableGuid,
                  name="PK",
                  state=State.VAR_HEADER_VALID_ONLY | State.VAR_ADDED,
                  flags=0, # TODO default that
                  data=f.read(),
              )
          )

      add.append(
          EfiVariable(
              vendor_uuid=EfiGuid.gEfiCertDbGuid,
              name="certdb",
              state=State.VAR_HEADER_VALID_ONLY | State.VAR_ADDED,
              flags=0,
              data=b"\4\0\0\0",
          )
      )

      add.append(
          EfiVariable(
              vendor_uuid=EfiGuid.gEfiVendorKeysNvGuid,
              name="VendorKeysNv",
              state=State.VAR_HEADER_VALID_ONLY | State.VAR_ADDED,
              flags=0,
              data=b"\1",
          )
      )

      add.append(
          EfiVariable(
              vendor_uuid=EfiGuid.gMtcVendorGuid,
              name="MTC",
              state=State.VAR_HEADER_VALID_ONLY | State.VAR_ADDED,
              flags=0,
              data=b"\2\0\0\0",
          )
      )


      machine.write_efi_vars(add)
      machine.dump_efi_vars()

      machine.start()
      machine.wait_for_unit("multi-user.target")

      machine.shutdown()
      machine.dump_efi_vars()

      machine.start()
      machine.wait_for_unit("multi-user.target")

      assert(False)
    '';

  };
}
