{ stdenvNoCC
, systemd
, binutils-unwrapped

, kernel, initramfs, kernelParams
}:

# TODO: replace linuxx64.efi with arch-specific name

stdenvNoCC.mkDerivation {
  name = "kernel.efi";

  nativeBuildInputs = [
    binutils-unwrapped
  ];
 
  dontUnpack = true;

  buildPhase = ''
    echo -n "${toString kernelParams}" > kernel-command-line.txt
    echo "nixos" > osrel

    # Here we're bundling both kernel, commandline and initrd in a single image
    # We want the whole content to be hashed, not just one part.
    ${binutils-unwrapped}/bin/objcopy \
          --add-section .osrel="osrel" --change-section-vma .osrel=0x20000 \
          --add-section .cmdline="kernel-command-line.txt" --change-section-vma .cmdline=0x30000 \
          --add-section .linux="${kernel}" --change-section-vma .linux=0x2000000 \
          --add-section .initrd="${initramfs}" --change-section-vma .initrd=0x3000000 \
          ${systemd.out}/lib/systemd/boot/efi/linuxx64.efi.stub \
          linux.efi
  '';

  installPhase = ''
    mkdir $out/
    install -m 644 linux.efi $out/
  '';
}
