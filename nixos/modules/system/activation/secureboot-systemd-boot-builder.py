#! @python3@/bin/python3 -B
import argparse
import shutil
import os
import sys
import errno
import subprocess
import glob
import tempfile
import errno
import warnings
import ctypes
libc = ctypes.CDLL("libc.so.6")
import re
import datetime
import glob
import os.path
from typing import NamedTuple, List, Optional

class SystemIdentifier(NamedTuple):
    profile: Optional[str]
    generation: int
    specialisation: Optional[str]


def copy_if_not_exists(source: str, dest: str) -> None:
    if not os.path.exists(dest):
        shutil.copyfile(source, dest)


def generation_dir(profile: Optional[str], generation: int) -> str:
    if profile:
        return "/nix/var/nix/profiles/system-profiles/%s-%d-link" % (profile, generation)
    else:
        return "/nix/var/nix/profiles/system-%d-link" % (generation)

def system_dir(profile: Optional[str], generation: int, specialisation: Optional[str]) -> str:
    d = generation_dir(profile, generation)
    if specialisation:
        return os.path.join(d, "specialisation", specialisation)
    else:
        return d

BOOT_ENTRY = """title NixOS{profile}{specialisation}
version Generation {generation} {description}
efi {kernel}
"""

def generation_conf_filename(profile: Optional[str], generation: int, specialisation: Optional[str]) -> str:
    pieces = [
        "nixos",
        profile or None,
        "generation",
        str(generation),
        f"specialisation-{specialisation}" if specialisation else None,
    ]
    return "-".join(p for p in pieces if p) + ".conf"


def write_loader_conf(profile: Optional[str], generation: int, specialisation: Optional[str]) -> None:
    with open("@efiSysMountPoint@/loader/loader.conf.tmp", 'w') as f:
        if "@timeout@" != "":
            f.write("timeout @timeout@\n")
        f.write("default %s\n" % generation_conf_filename(profile, generation, specialisation))
        f.write("editor 0\n");
    os.rename("@efiSysMountPoint@/loader/loader.conf.tmp", "@efiSysMountPoint@/loader/loader.conf")


def profile_path(profile: Optional[str], generation: int, specialisation: Optional[str], name: str) -> str:
    return os.path.realpath("%s/%s" % (system_dir(profile, generation, specialisation), name))


def copy_from_profile(profile: Optional[str], generation: int, specialisation: Optional[str], name: str, dry_run: bool = False) -> str:
    store_file_path = profile_path(profile, generation, specialisation, name)
    suffix = os.path.basename(store_file_path)
    store_dir = os.path.basename(os.path.dirname(store_file_path))
    efi_file_path = "/efi/nixos/%s-%s.efi" % (store_dir, suffix)
    if not dry_run:
        copy_if_not_exists(store_file_path, "@efiSysMountPoint@%s" % (efi_file_path))
    return efi_file_path


def describe_generation(generation_dir: str) -> str:
    try:
        with open("%s/nixos-version" % generation_dir) as f:
            nixos_version = f.read()
    except IOError:
        nixos_version = "Unknown"

    kernel_dir = os.path.dirname(os.path.realpath("%s/kernel" % generation_dir))

    build_time = int(os.path.getctime(generation_dir))
    build_date = datetime.datetime.fromtimestamp(build_time).strftime('%F')

    description = "NixOS {}, Built on {}".format(
        nixos_version, build_date
    )

    return description


def write_entry(profile: Optional[str], generation: int, specialisation: Optional[str]) -> None:
    kernel = copy_from_profile(profile, generation, specialisation, "kernel")
    entry_file = "@efiSysMountPoint@/loader/entries/%s" % (
        generation_conf_filename(profile, generation, specialisation))
    generation_dir = os.readlink(system_dir(profile, generation, specialisation))
    tmp_path = "%s.tmp" % (entry_file)

    with open(tmp_path, 'w') as f:
        f.write(BOOT_ENTRY.format(profile=" [" + profile + "]" if profile else "",
                    specialisation=" (%s)" % specialisation if specialisation else "",
                    generation=generation,
                    kernel=kernel,
                    description=describe_generation(generation_dir)))
    os.rename(tmp_path, entry_file)


def mkdir_p(path: str) -> None:
    try:
        os.makedirs(path)
    except OSError as e:
        if e.errno != errno.EEXIST or not os.path.isdir(path):
            raise


def get_generations(profile: Optional[str] = None) -> List[SystemIdentifier]:
    gen_list = subprocess.check_output([
        "@nix@/bin/nix-env",
        "--list-generations",
        "-p",
        "/nix/var/nix/profiles/%s" % ("system-profiles/" + profile if profile else "system"),
        "--option", "build-users-group", ""],
        universal_newlines=True)
    gen_lines = gen_list.split('\n')
    gen_lines.pop()

    configurationLimit = 3 
    configurations = [
        SystemIdentifier(
            profile=profile,
            generation=int(line.split()[0]),
            specialisation=None
        )
        for line in gen_lines
    ]
    return configurations[-configurationLimit:]


def remove_old_entries(gens: List[SystemIdentifier]) -> None:
    rex_profile = re.compile("^@efiSysMountPoint@/loader/entries/nixos-(.*)-generation-.*\.conf$")
    rex_generation = re.compile("^@efiSysMountPoint@/loader/entries/nixos.*-generation-(.*)\.conf$")
    known_paths = []
    for gen in gens:
        known_paths.append(copy_from_profile(*gen, "kernel", True))
        known_paths.append(copy_from_profile(*gen, "initrd", True))
    for path in glob.iglob("@efiSysMountPoint@/loader/entries/nixos*-generation-[1-9]*.conf"):
        try:
            if rex_profile.match(path):
                prof = rex_profile.sub(r"\1", path)
            else:
                prof = "system"
            gen_number = int(rex_generation.sub(r"\1", path))
            if not (prof, gen_number) in gens:
                os.unlink(path)
        except ValueError:
            pass
    for path in glob.iglob("@efiSysMountPoint@/efi/nixos/*"):
        if not path in known_paths and not os.path.isdir(path):
            os.unlink(path)


def get_profiles() -> List[str]:
    if os.path.isdir("/nix/var/nix/profiles/system-profiles/"):
        return [x
            for x in os.listdir("/nix/var/nix/profiles/system-profiles/")
            if not x.endswith("-link")]
    else:
        return []

def main() -> None:
    parser = argparse.ArgumentParser(description='Update NixOS-related systemd-boot files')
    parser.add_argument('default_config', metavar='DEFAULT-CONFIG', help='The default NixOS config to boot')
    args = parser.parse_args()

    if os.getenv("NIXOS_INSTALL_BOOTLOADER") == "1":
        mkdir_p("@efiSysMountPoint@/EFI/BOOT")
        shutil.copyfile("@signedShim@", "@efiSysMountPoint@/EFI/BOOT/BOOTX64.EFI")
        shutil.copyfile("@signedSystemd@", "@efiSysMountPoint@/EFI/BOOT/systemd-bootx64.efi")
    else:
        raise Exception("Unsupported operation")

    mkdir_p("@efiSysMountPoint@/efi/nixos")
    mkdir_p("@efiSysMountPoint@/loader/entries")

    gens = get_generations()
    for profile in get_profiles():
        gens += get_generations(profile)
    remove_old_entries(gens)
    for gen in gens:
        try:
            write_entry(*gen)
            if os.readlink(system_dir(*gen)) == args.default_config:
                write_loader_conf(*gen)
        except OSError as e:
            profile = f"profile '{gen.profile}'" if gen.profile else "default profile"
            print("ignoring {} in the list of boot entries because of the following error:\n{}".format(profile, e), file=sys.stderr)

    for root, _, files in os.walk('@efiSysMountPoint@/efi/nixos/.extra-files', topdown=False):
        relative_root = root.removeprefix("@efiSysMountPoint@/efi/nixos/.extra-files").removeprefix("/")
        actual_root = os.path.join("@efiSysMountPoint@", relative_root)

        for file in files:
            actual_file = os.path.join(actual_root, file)

            if os.path.exists(actual_file):
                os.unlink(actual_file)
            os.unlink(os.path.join(root, file))

        if not len(os.listdir(actual_root)):
            os.rmdir(actual_root)
        os.rmdir(root)

    mkdir_p("@efiSysMountPoint@/efi/nixos/.extra-files")

    # Since fat32 provides little recovery facilities after a crash,
    # it can leave the system in an unbootable state, when a crash/outage
    # happens shortly after an update. To decrease the likelihood of this
    # event sync the efi filesystem after each update.
    rc = libc.syncfs(os.open("@efiSysMountPoint@", os.O_RDONLY))
    if rc != 0:
        print("could not sync @efiSysMountPoint@: {}".format(os.strerror(rc)), file=sys.stderr)


if __name__ == '__main__':
    main()
