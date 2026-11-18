#!/usr/bin/env python3
"""Swap X's Chirp fonts inside an IPA for Pretendard JP.

X loads Chirp from TwitterSharedResources_TFNUIAppResources.bundle by file name
and asks for it by its PostScript name. Pretendard JP (Korean, Japanese, Han,
Latin, Cyrillic) is renamed to those same names and put in the same files, so X
keeps using its own font code and never notices. Nothing is swapped at run time,
which is what made the in-app font picker crash.

Pretendard JP's vertical metrics match Chirp's exactly (0.952 / -0.241 em, no
line gap), so rows keep their heights.

The font is licensed under the SIL Open Font License 1.1 with the Reserved Font
Name "Pretendard JP". The renamed copies do not use that name; the copyright
notice is kept and the license is put next to the fonts.

usage: ipa_fonts.py <ipa_path>
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

PRETENDARD_URL = "https://github.com/orioncactus/pretendard/releases/download/v1.3.9/PretendardJP-1.3.9.zip"
PRETENDARD_SHA256 = "8dab678c371a1530106ca643b76b2b80d47653d5ba670b01265b48e4c6615d63"

BUNDLE = "TwitterSharedResources_TFNUIAppResources.bundle"

# X file -> (Pretendard source inside the zip, family, subfamily, PostScript name)
STATIC = {
    "Chirp-Light.otf": ("public/static/PretendardJP-Light.otf", "Chirp Light", "Regular", "Chirp-Light"),
    "Chirp-Regular.otf": ("public/static/PretendardJP-Regular.otf", "Chirp", "Regular", "Chirp-Regular"),
    "Chirp-Medium.otf": ("public/static/PretendardJP-Medium.otf", "Chirp Medium", "Regular", "Chirp-Medium"),
    "Chirp-Bold.otf": ("public/static/PretendardJP-Bold.otf", "Chirp", "Bold", "Chirp-Bold"),
    "Chirp-Heavy.otf": ("public/static/PretendardJP-ExtraBold.otf", "Chirp Heavy", "Regular", "Chirp-Heavy"),
}
VARIABLE_FILE = "Chirp-UI-VF-With-Overriden-Emoji-202601.ttf"
VARIABLE_SOURCE = "public/variable/PretendardJPVariable.ttf"
VARIABLE_FAMILY = "Chirp UI VF 202601"
VARIABLE_PS = "ChirpUIVF202601"
LICENSE_NAME = "PretendardJP-OFL.txt"

# Name IDs that carry the font's name. 0 (copyright), 7 (trademark), 8-14
# (maker, designer, description, URLs, license) are kept as they are.
NAME_IDS = (1, 2, 3, 4, 6, 16, 17, 18, 21, 22, 25)


class FontError(Exception):
    pass


def log(message):
    print(f"Fonts: {message}", flush=True)


def python_with_fonttools():
    """A cached venv with fontTools (plain pip install is refused on
    externally managed Pythons such as Homebrew's)."""
    try:
        import fontTools  # noqa: F401
        return Path(sys.executable)
    except ImportError:
        pass
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "neofreebird"
    venv = cache / "venv-fonts"
    python = venv / "bin" / "python3"
    check = [str(python), "-c", "import fontTools"]
    if python.is_file() and subprocess.run(check, capture_output=True).returncode == 0:
        return python
    log("setting up a Python venv with fontTools (one-time)")
    cache.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, "-m", "venv", "--clear", str(venv)], check=True)
    subprocess.run([str(python), "-m", "pip", "install", "--quiet", "fonttools"], check=True)
    return python


def download(workdir):
    target = workdir / "pretendard.zip"
    cached = Path(os.environ.get("NFB_PRETENDARD_ZIP", ""))
    if cached.is_file():
        shutil.copy(cached, target)
    else:
        log(f"downloading {PRETENDARD_URL}")
        with urllib.request.urlopen(PRETENDARD_URL) as response, open(target, "wb") as out:
            shutil.copyfileobj(response, out)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    if digest != PRETENDARD_SHA256:
        raise FontError(f"Pretendard JP zip has sha256 {digest}, expected {PRETENDARD_SHA256}")
    return target


def rename(font, family, subfamily, postscript):
    from fontTools.ttLib import TTFont  # noqa: F401  (only to fail early when missing)

    full = family if subfamily == "Regular" else f"{family} {subfamily}"
    values = {
        1: family,
        2: subfamily,
        3: f"{postscript};neofreebird",
        4: full,
        6: postscript,
        16: family,
        17: subfamily,
        25: postscript,
    }
    table = font["name"]
    for record in list(table.names):
        if record.nameID in values:
            record.string = values[record.nameID]
        elif record.nameID in NAME_IDS:
            table.removeNames(nameID=record.nameID)
        elif record.nameID >= 256 and "Pretendard" in record.toUnicode():
            record.string = record.toUnicode().replace("Pretendard JP", family).replace("PretendardJP", postscript)
    # Family-wide names some tools expect even when the source lacked them.
    for name_id in (1, 2, 4, 6):
        if table.getName(name_id, 3, 1, 0x409) is None:
            table.setName(values[name_id], name_id, 3, 1, 0x409)

    if "CFF " in font:
        cff = font["CFF "].cff
        top = cff[cff.fontNames[0]]
        cff.fontNames = [postscript]
        top.FullName = full
        top.FamilyName = family
        if hasattr(top, "Weight"):
            top.Weight = subfamily

    bold = subfamily == "Bold"
    os2 = font["OS/2"]
    selection = os2.fsSelection & ~(1 << 0) & ~(1 << 5) & ~(1 << 6)
    os2.fsSelection = selection | ((1 << 5) if bold else (1 << 6))
    head = font["head"]
    head.macStyle = (head.macStyle & ~0b11) | (0b1 if bold else 0)


def build_fonts(zip_path, outdir):
    from fontTools.ttLib import TTFont

    with zipfile.ZipFile(zip_path) as archive:
        for target, (source, family, subfamily, postscript) in STATIC.items():
            with archive.open(source) as handle:
                font = TTFont(handle)
            rename(font, family, subfamily, postscript)
            font.save(outdir / target)
            log(f"{target} <- {Path(source).name}")

        with archive.open(VARIABLE_SOURCE) as handle:
            font = TTFont(handle)
        rename(font, VARIABLE_FAMILY, "Regular", VARIABLE_PS)
        # Named instances: keep their weight names, give them Chirp PostScript names.
        if "fvar" in font:
            for instance in font["fvar"].instances:
                # IDs below 256 are the font's own names (Regular shares ID 6, the
                # PostScript name X asks for); leave those alone.
                if instance.postscriptNameID not in (0xFFFF, None) and instance.postscriptNameID >= 256:
                    style = font["name"].getDebugName(instance.subfamilyNameID) or "Instance"
                    font["name"].setName(f"{VARIABLE_PS}-{style.replace(' ', '')}",
                                         instance.postscriptNameID, 3, 1, 0x409)
        font.save(outdir / VARIABLE_FILE)
        log(f"{VARIABLE_FILE} <- {Path(VARIABLE_SOURCE).name}")

        with archive.open("LICENSE.txt") as handle:
            (outdir / LICENSE_NAME).write_bytes(handle.read())


def app_path_in(ipa):
    with zipfile.ZipFile(ipa) as archive:
        for name in archive.namelist():
            parts = name.split("/")
            if len(parts) >= 3 and parts[0] == "Payload" and parts[1].endswith(".app") and parts[2] == BUNDLE:
                return f"Payload/{parts[1]}/{BUNDLE}"
    raise FontError(f"{BUNDLE} not found in the IPA")


def swap(ipa):
    ipa = Path(ipa).resolve()
    if not ipa.is_file():
        raise FontError(f"IPA not found: {ipa}")
    python = python_with_fonttools()
    if Path(python) != Path(sys.executable):
        # Re-run this script with the interpreter that has fontTools.
        subprocess.run([str(python), __file__, str(ipa)], check=True)
        return

    workdir = Path(tempfile.mkdtemp())
    try:
        bundle = app_path_in(ipa)
        staging = workdir / "stage"
        outdir = staging / bundle
        outdir.mkdir(parents=True)
        build_fonts(download(workdir), outdir)
        # Replace just these entries in place (zip updates matching paths).
        names = sorted(str(Path(bundle) / p.name) for p in outdir.iterdir())
        subprocess.run(["zip", "-q", str(ipa)] + names, cwd=str(staging), check=True)
        log(f"swapped {len(names) - 1} fonts in {ipa.name}")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def main(argv):
    if len(argv) != 2:
        print("usage: ipa_fonts.py <ipa_path>", file=sys.stderr)
        return 2
    try:
        swap(argv[1])
    except (FontError, subprocess.CalledProcessError, OSError) as exc:
        print(f"Fonts: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
