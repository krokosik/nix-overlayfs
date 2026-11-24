#!/usr/bin/env python3
"""Mirror a native install layer into a package tree and patch it for NixOS.

Every directory is recreated and every file becomes a symlink into the
install layer, except the files the package has to change, which are copied:

- ELF files that need patching: dynamic executables (their interpreter), and
  ELF files with a dependency that the layer does not provide where the file
  looks for it, but one of --libs does.
- text files naming the install root by its placeholder, which is replaced
  by the package's path.
- executable scripts, for patchShebangs and because launcher scripts often
  locate their installation by resolving their own path (readlink -e "$0").
- files matching a --copy pattern (paths relative to the layer root), for
  other files whose resolved path a program uses to find its installation.

A dependency counts as provided by the layer when it is in a directory the
file searches: an $ORIGIN entry of its own RPATH/RUNPATH, one of
--library-dirs (the directories the application puts on LD_LIBRARY_PATH),
or the file's own directory.
Such dependencies are left to be found as on other distributions: the
original entries stay first in the new RUNPATH, and glibc's loader keeps a
symlink's own path, not its target, as $ORIGIN. Other dependencies get the
first directory of --libs that has them; executables also get
--runtime-dirs. Failing that, a copy elsewhere in the layer is used (vendors
rely on system libraries they also ship for other components). A dependency
found nowhere fails the build unless it matches an --ignore-missing pattern.
"""

import argparse
import fcntl
import fnmatch
import os
import shutil
import stat
import subprocess
import sys

from elftools.common.exceptions import ELFError
from elftools.elf.dynamic import DynamicSection
from elftools.elf.elffile import ELFFile


class Elf:
    def __init__(self, path):
        with open(path, "rb") as stream:
            elf = ELFFile(stream)
            self.machine = elf.header["e_machine"]
            self.elfclass = elf.elfclass
            self.interpreter = any(s["p_type"] == "PT_INTERP" for s in elf.iter_segments())
            self.needed = []
            self.rpath = None
            self.runpath = None
            for section in elf.iter_sections():
                if isinstance(section, DynamicSection):
                    for tag in section.iter_tags():
                        if tag.entry.d_tag == "DT_NEEDED":
                            self.needed.append(tag.needed)
                        elif tag.entry.d_tag == "DT_RPATH":
                            self.rpath = tag.rpath
                        elif tag.entry.d_tag == "DT_RUNPATH":
                            self.runpath = tag.runpath
                    break

    @property
    def search_path(self):
        value = self.runpath if self.runpath is not None else self.rpath
        return [entry for entry in (value or "").split(":") if entry]


FICLONE = 0x40049409


def copy(source, target):
    """Copy a file, sharing its extents (a reflink) where the file system can."""
    with open(source, "rb") as src, open(target, "wb") as dst:
        try:
            fcntl.ioctl(dst.fileno(), FICLONE, src.fileno())
            return True
        except OSError:
            shutil.copyfileobj(src, dst, 1 << 20)
            return False


def is_library_name(name):
    return name.endswith(".so") or ".so." in name


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--install", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--placeholder", required=True)
    parser.add_argument("--interpreter", required=True)
    parser.add_argument("--libc-dir", required=True)
    parser.add_argument("--libs", nargs="*", default=[])
    parser.add_argument("--runtime-dirs", nargs="*", default=[])
    parser.add_argument("--library-dirs", nargs="*", default=[])
    parser.add_argument("--ignore-missing", nargs="*", default=[])
    parser.add_argument("--copy", nargs="*", default=[])
    args = parser.parse_args()

    install = os.path.abspath(args.install)
    out = os.path.abspath(args.out)
    placeholder = args.placeholder.encode()
    out_bytes = out.encode()
    interpreter = Elf(args.interpreter)
    libc = set(os.listdir(args.libc_dir))

    # soname -> first directory of --libs that has it
    external = {}
    for directory in args.libs:
        if os.path.isdir(directory):
            for name in sorted(os.listdir(directory)):
                if is_library_name(name):
                    external.setdefault(name, directory)

    # soname -> directories of the layer that have it (the last resort)
    bundled = {}
    for directory, _, files in os.walk(install):
        for name in files:
            if is_library_name(name):
                bundled.setdefault(name, []).append(os.path.relpath(directory, install))
    for directories in bundled.values():
        directories.sort(key=lambda d: (d.count("/"), d))

    def in_layer(directory, name):
        return os.path.exists(os.path.join(install, directory, name))

    def resolve(relative_dir, elf):
        """New RUNPATH, or None if the file needs no patching; missing names."""
        # Its own directory too: not searched by the loader, but applications
        # load such libraries first (LibraryLink, plugin loaders).
        searched = [relative_dir] + list(args.library_dirs)
        for entry in elf.search_path:
            if "$ORIGIN" in entry or "${ORIGIN}" in entry:
                expanded = entry.replace("${ORIGIN}", "$ORIGIN").replace("$ORIGIN", relative_dir)
                searched.append(os.path.normpath(expanded))
        added, missing = [], []
        for name in elf.needed:
            if "/" in name or name in libc:
                continue
            if any(in_layer(directory, name) for directory in searched):
                continue
            if name in external:
                found = external[name]
            elif name in bundled:
                found = os.path.normpath(os.path.join(out, bundled[name][0]))
            else:
                missing.append(name)
                continue
            if found not in added:
                added.append(found)
        if not elf.interpreter and not added:
            return None, missing
        runpath = list(elf.search_path) + added
        if elf.interpreter:
            runpath += args.runtime_dirs
        return ":".join(dict.fromkeys(runpath)), missing

    copied = symlinked = patched = reflinked = 0
    missing_by_name = {}
    for directory, dirs, files in os.walk(install):
        relative_dir = os.path.relpath(directory, install)
        target_dir = os.path.normpath(os.path.join(out, relative_dir))
        os.makedirs(target_dir, exist_ok=True)
        # os.walk lists symlinks to directories among dirs; mirror them as links.
        for name in list(dirs) + files:
            source = os.path.join(directory, name)
            target = os.path.join(target_dir, name)
            info = os.lstat(source)
            if stat.S_ISLNK(info.st_mode):
                os.symlink(os.readlink(source).replace(args.placeholder, out), target)
                continue
            if not stat.S_ISREG(info.st_mode):
                continue

            mode, runpath, elf = "link", None, None
            with open(source, "rb") as stream:
                head = stream.read(4)
            if head == b"\x7fELF":
                try:
                    elf = Elf(source)
                except ELFError:
                    elf = None
                if elf and elf.machine == interpreter.machine and elf.elfclass == interpreter.elfclass:
                    runpath, missing = resolve(relative_dir, elf)
                    for soname in missing:
                        missing_by_name.setdefault(soname, []).append(os.path.join(relative_dir, name))
                    if runpath is not None:
                        mode = "patch"
            else:
                with open(source, "rb") as stream:
                    content = stream.read()
                if placeholder in content:
                    mode = "replace"
                elif head[:2] == b"#!" and info.st_mode & 0o111:
                    mode = "copy"
            if mode == "link" and any(
                fnmatch.fnmatch(os.path.normpath(os.path.join(relative_dir, name)), pattern)
                for pattern in args.copy
            ):
                mode = "copy"

            if mode == "link":
                os.symlink(source, target)
                symlinked += 1
                continue
            if mode == "replace":
                with open(target, "wb") as stream:
                    stream.write(content.replace(placeholder, out_bytes))
            else:
                reflinked += copy(source, target)
            os.chmod(target, stat.S_IMODE(info.st_mode) | stat.S_IWUSR)
            copied += 1
            if mode == "patch":
                command = ["patchelf"]
                if elf.interpreter:
                    command += ["--set-interpreter", args.interpreter]
                # DT_RPATH also applies to the dependencies' dependencies; keep it.
                if elf.runpath is None and elf.rpath is not None:
                    command.append("--force-rpath")
                command += ["--set-rpath", runpath, target]
                subprocess.run(command, check=True)
                patched += 1

    print(
        f"mirror: {symlinked} files linked, {copied} copied ({reflinked} as reflinks), "
        f"{patched} ELF files patched",
        file=sys.stderr,
    )
    fatal = False
    for soname, users in sorted(missing_by_name.items()):
        ignored = any(fnmatch.fnmatch(soname, pattern) for pattern in args.ignore_missing)
        fatal |= not ignored
        print(
            f"{'ignoring missing' if ignored else 'error: missing'} {soname}, needed by "
            + ", ".join(users[:3])
            + (f" and {len(users) - 3} more" if len(users) > 3 else ""),
            file=sys.stderr,
        )
    if fatal:
        sys.exit("mirror: add the missing libraries to `libraries` or `ignoreMissingDeps`")


if __name__ == "__main__":
    main()
