{ lib, buildPythonPackage, fetchFromGitHub, pyyaml, fetchpatch }:

buildPythonPackage rec {
  pname = "ovmfvartool";
  version = "unstable-2022-09-04";

  src = fetchFromGitHub {
    owner = "hlandau";
    repo = pname;
    rev = "45e6b1e53967ee6590faae454c076febce096931";
    hash = "sha256-XbvcE/MXNj5S5N7A7jxdwgEE5yMuB82Xg+PYBsFRIm0=";
  };

  propagatedBuildInputs = [ pyyaml ];

  meta = with lib; {
    description = "Parse and generate OVMF_VARS.fd from Yaml";
    homepage = "https://github.com/hlandau/ovmfvartool";
    license = licenses.gpl3;
    maintainers = with maintainers; [ baloo raitobezarius ];
  };
}
