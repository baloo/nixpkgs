{ stdenv
, fetchFromGitHub
, lib
, elfutils
, vendorCertFile
, defaultLoader ? null
, ...}:

let
  gnu-efi-src= fetchFromGitHub {
    owner = "rhboot";
    repo = "gnu-efi";
    rev = "03670e14f263ad571bf0f39dffa9b8d23535f4d3";
    hash = "sha256-iw+cwaceMaHILmbQXVXOFxlsLWGv0M+x7aVzc8puTDA=";
  };
in stdenv.mkDerivation rec {
  pname = "shim";
  version = "15.6";

  src = fetchFromGitHub {
    owner = "rhboot";
    repo = pname;
    rev = version;
    hash = "sha256-EWFwQIvhMVU1J8GzvTZfpgIIFeT7AS8hcv4dr4EWhpU=";
  };

  postPatch = ''
    cp -a ${gnu-efi-src}/* gnu-efi/
    '';

  buildInputs = [
    elfutils
  ];

  NIX_CFLAGS_COMPILE = [
    "-I${toString elfutils.dev}/include"
  ];

  makeFlags = [
    "VENDOR_CERT_FILE=${vendorCertFile}"
    "shimx64.efi"
  ] ++ lib.optional (defaultLoader != null) "DEFAULT_LOADER=${defaultLoader}";

  installPhase = ''
    mkdir $out
    cp shimx64.efi $out/
  '';

  meta = with lib; {
    description = "UEFI shim loader";
    homepage = "https://github.com/rhboot/shim";
    license = licenses.unfreeRedistributable;
    maintainers = with maintainers; [ baloo ];
  };

  preferLocalBuild = true;
  allowSubstitutes = false;
}
