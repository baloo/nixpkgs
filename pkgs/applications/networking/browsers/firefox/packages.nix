{ stdenv, lib, callPackage, fetchurl, fetchpatch, nixosTests, buildMozillaMach }:

rec {
  firefox = buildMozillaMach rec {
    pname = "firefox";
    version = "102.0";
    src = fetchurl {
      url = "mirror://mozilla/firefox/releases/${version}/source/firefox-${version}.source.tar.xz";
      sha512 = "c7dd6d8d74c46573b16d097a5e5d230669e5778cd680b3b6f30510e989d21543138ced3bb013998b76614aa380b28efd8542450c591d8b724e03bd163d012057";
    };

    meta = {
      description = "A web browser built from Firefox source tree";
      homepage = "http://www.mozilla.com/en-US/firefox/";
      maintainers = with lib.maintainers; [ lovesegfault hexa ];
      platforms = lib.platforms.unix;
      badPlatforms = lib.platforms.darwin;
      broken = stdenv.buildPlatform.is32bit; # since Firefox 60, build on 32-bit platforms fails with "out of memory".
                                             # not in `badPlatforms` because cross-compilation on 64-bit machine might work.
      maxSilent = 14400; # 4h, double the default of 7200s (c.f. #129212, #129115)
      license = lib.licenses.mpl20;
    };
    tests = [ nixosTests.firefox ];
    updateScript = callPackage ./update.nix {
      attrPath = "firefox-unwrapped";
    };
  };

  firefox-esr-91 = buildMozillaMach rec {
    pname = "firefox-esr";
    version = "91.9.1esr";
    applicationName = "Mozilla Firefox ESR";
    src = fetchurl {
      url = "mirror://mozilla/firefox/releases/${version}/source/firefox-${version}.source.tar.xz";
      sha512 = "d432d559f2c5f4b0bc66a755db7d61585e24a727cd8d18630854b3fb8633d54baf61ed65b580345b13d52b66288aa15ca8ca5cfcde8231e88108241f0b007683";
    };

    meta = {
      description = "A web browser built from Firefox Extended Support Release source tree";
      homepage = "http://www.mozilla.com/en-US/firefox/";
      maintainers = with lib.maintainers; [ hexa ];
      platforms = lib.platforms.unix;
      badPlatforms = lib.platforms.darwin;
      broken = stdenv.buildPlatform.is32bit; # since Firefox 60, build on 32-bit platforms fails with "out of memory".
                                             # not in `badPlatforms` because cross-compilation on 64-bit machine might work.
      license = lib.licenses.mpl20;
    };
    tests = [ nixosTests.firefox-esr-91 ];
    updateScript = callPackage ./update.nix {
      attrPath = "firefox-esr-91-unwrapped";
      versionSuffix = "esr";
    };
  };
}
