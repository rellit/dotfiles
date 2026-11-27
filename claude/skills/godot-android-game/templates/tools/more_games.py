#!/usr/bin/env python3
""""More games" and "Share with friends": bring the list of the other rellit games up to date.

The same file in every rellit game (template: skill godot-android-game, templates/tools/).
tools/android/build_android.sh runs it before the tests, so every build ships the current list
and says when a game is missing. By hand: python3 tools/more_games.py [--check]

Source of truth is the app registry of the website, rellit.de/packages/theme/src/data/apps.ts:
every entry with kind "game" and published: true, except this game itself, ends up on the
"More games" page; this game's own entry gives the text for "Share with friends". The banner of a
game is its Google Play feature graphic (build/store/<de|en>/feature_graphic.png in that game's
project folder, as written by tools/generate_store_assets.py).

Writes (both committed, so a build without rellit.de next to it still has the list):
  scripts/more_games_catalog.gd          SELF and GAMES, generated - never edit by hand
  assets/more_games/<slug>_<de|en>.webp  banners, 768x375, with an .import for lossy compression

Looks for missing games and prints a warning for each (the build goes on):
  - a published game whose banner is nowhere on this machine (it is left out)
  - a game project next to this one (Godot, with a release AAB) that apps.ts does not list
  - a game the Play Leitstand sees live in production that apps.ts still calls unpublished,
    or the other way round
  - this game itself not published yet (the shared link leads nowhere until it is)

Options:
  --check        change nothing; exit 1 if the list in this project is out of date
  --rellit DIR   the rellit.de repository (default: $RELLIT_DIR, else next to this project)
  --project DIR  the Godot project (default: the folder above tools/, or its godot/ subfolder)

Needs Python 3.10+ and Pillow (like tools/generate_icon.py). Exit code 0 also with warnings;
1 if apps.ts cannot be read and the project has no list yet, or with --check if it is stale.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import subprocess
import sys
from pathlib import Path

OUT_DIR = "assets/more_games"
CATALOG = "scripts/more_games_catalog.gd"
APPS_TS = "packages/theme/src/data/apps.ts"
LEITSTAND = Path.home() / ".local/share/play-leitstand/snapshot.json"
LANGS = ("de", "en")
# Half the feature graphic (1024x500) and a bit: sharp on the page's ~600 px wide cards
BANNER_SIZE = (768, 375)
WEBP_QUALITY = 88
# Godot imports the banners lossy; lossless would make each one several hundred KB in the APK
IMPORT_TEMPLATE = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://{path}"

[params]

compress/mode=1
compress/lossy_quality=0.8
mipmaps/generate=false
"""


def note(message: str) -> None:
    print(f"  {message}")


def warn(message: str) -> None:
    print(f"  WARNING: {message}")


# ---- apps.ts

def parse_apps_ts(text: str) -> list[dict]:
    """The `apps` array of apps.ts as Python data.

    apps.ts is TypeScript, but the array is a plain object literal: strings, true/false, nested
    objects, comments and trailing commas. A small tokenizer turns that into JSON, so no Node is
    needed for the build.
    """
    start = text.index("export const apps")
    i = text.index("[", text.index("=", start))
    tokens: list[str] = []
    depth = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
        elif text.startswith("//", i):
            i = text.find("\n", i)
            i = n if i < 0 else i
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
        elif c in "\"'`":
            value, i = read_string(text, i)
            tokens.append(json.dumps(value, ensure_ascii=False))
        elif c.isalpha() or c in "_$":
            m = re.match(r"[A-Za-z_$][\w$]*", text[i:])
            word = m.group(0)
            tokens.append(word if word in ("true", "false", "null") else json.dumps(word))
            i += len(word)
        elif c.isdigit() or c == "-":
            m = re.match(r"-?\d+(\.\d+)?", text[i:])
            tokens.append(m.group(0))
            i += len(m.group(0))
        elif c in "[{":
            tokens.append(c)
            depth += 1
            i += 1
        elif c in "]}":
            if tokens and tokens[-1] == ",":
                tokens.pop()  # trailing comma
            tokens.append(c)
            depth -= 1
            i += 1
            if depth == 0:
                break
        elif c in ",:":
            tokens.append(c)
            i += 1
        else:
            raise ValueError(f"unexpected {c!r} in apps.ts at offset {i}")
    return json.loads("".join(tokens))


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0"}


def read_string(text: str, i: int) -> tuple[str, int]:
    """A JS string literal starting at text[i]: its value and the offset after it."""
    quote = text[i]
    j = i + 1
    out = []
    while text[j] != quote:
        if text[j] == "\\":
            follow = text[j + 1]
            if follow == "u":
                out.append(chr(int(text[j + 2:j + 6], 16)))
                j += 6
            else:
                out.append(ESCAPES.get(follow, follow))
                j += 2
        else:
            out.append(text[j])
            j += 1
    return "".join(out), j + 1


def find_rellit(project: Path, given: str | None) -> Path | None:
    # An explicit folder is taken as it is; only without one the usual places are tried
    explicit = given or os.environ.get("RELLIT_DIR")
    candidates = [Path(explicit).expanduser()] if explicit else [
        project.parent / "rellit.de",
        project.parent.parent / "rellit.de",
        Path.home() / "Entwicklung/rellit.de",
    ]
    for candidate in candidates:
        if (candidate / APPS_TS).is_file():
            return candidate
    return None


# ---- the other projects on this machine

def index_projects(workspace: Path) -> dict[str, Path]:
    """Package name -> project folder, for every Android project next to this one."""
    found: dict[str, Path] = {}
    for preset in sorted(workspace.glob("*/export_presets.cfg")) + sorted(workspace.glob("*/godot/export_presets.cfg")):
        m = re.search(r'package/unique_name="([^"]+)"', preset.read_text(errors="ignore"))
        if m:
            folder = preset.parent.parent if preset.parent.name == "godot" else preset.parent
            found.setdefault(m.group(1), folder)
    for gradle in sorted(workspace.glob("*/app/build.gradle*")):
        m = re.search(r'applicationId\s*=?\s*"([^"]+)"', gradle.read_text(errors="ignore"))
        if m:
            found.setdefault(m.group(1), gradle.parent.parent)
    return found


def banner_source(folder: Path | None, lang: str) -> Path | None:
    if folder is None:
        return None
    for sub in ("build/store", "dist/store"):
        for want in (lang, *LANGS):
            path = folder / sub / want / "feature_graphic.png"
            if path.is_file():
                return path
    return None


def has_release_build(folder: Path) -> bool:
    return any(folder.glob("build/*-release.aab")) or any(folder.glob("dist/*.aab"))


def leitstand_live() -> dict[str, bool] | None:
    """Package -> live in production, as the Play Leitstand saw it last (None: no Leitstand here)."""
    try:
        data = json.loads(LEITSTAND.read_text())
    except (OSError, ValueError):
        return None
    live = {}
    for app in data.get("apps", []):
        states = [t.get("state") for t in app.get("lifecycle") or [] if t.get("track") == "production"]
        live[app.get("pkg", "")] = "PUBLISHED" in states
    return live


# ---- output

def gd_value(value, indent: int = 0) -> str:
    pad = "\t" * indent
    if isinstance(value, dict):
        if not value:
            return "{}"
        inner = ",\n".join(f'{pad}\t"{k}": {gd_value(v, indent + 1)}' for k, v in value.items())
        return "{\n" + inner + f",\n{pad}}}"
    if isinstance(value, list):
        if not value:
            return "[]"
        inner = ",\n".join(f"{pad}\t{gd_value(v, indent + 1)}" for v in value)
        return "[\n" + inner + f",\n{pad}]"
    if isinstance(value, bool):
        return "true" if value else "false"
    return json.dumps(value, ensure_ascii=False)


def render_catalog(own: dict, games: list[dict]) -> str:
    return (
        "# Generated by tools/more_games.py from rellit.de (packages/theme/src/data/apps.ts) - do not edit,\n"
        "# the next build overwrites it. SELF is this game (text for \"Share with friends\"), GAMES are the\n"
        "# other published rellit games for \"More games\", newest first.\n"
        "extends RefCounted\n\n"
        f"const SELF := {gd_value(own)}\n\n"
        f"const GAMES := {gd_value(games)}\n"
    )


def entry(app: dict) -> dict:
    return {
        "slug": app["slug"],
        "package": app["packageName"],
        "name": app["name"],
        "tag": {lang: app["tag"][lang] for lang in LANGS},
        "description": {lang: app["description"][lang] for lang in LANGS},
    }


def encode_banner(source: Path) -> bytes:
    from PIL import Image  # only needed when a banner is (re)built

    with Image.open(source) as image:
        image = image.convert("RGB").resize(BANNER_SIZE, Image.LANCZOS)
        out = io.BytesIO()
        image.save(out, "WEBP", quality=WEBP_QUALITY, method=6)
        return out.getvalue()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--rellit")
    parser.add_argument("--project")
    args = parser.parse_args()

    project = Path(args.project).resolve() if args.project else Path(__file__).resolve().parent.parent
    if not (project / "project.godot").is_file() and (project / "godot/project.godot").is_file():
        project = project / "godot"
    presets = (project / "export_presets.cfg").read_text(errors="ignore")
    own_package = re.search(r'package/unique_name="([^"]+)"', presets).group(1)
    catalog_path = project / CATALOG
    out_dir = project / OUT_DIR

    rellit = find_rellit(project, args.rellit)
    if rellit is None:
        if catalog_path.is_file():
            warn("rellit.de not found (set RELLIT_DIR) - keeping the list of other games from the last build")
            return 0
        print("ERROR: rellit.de not found (set RELLIT_DIR) and there is no list of other games yet", file=sys.stderr)
        return 1
    apps = parse_apps_ts((rellit / APPS_TS).read_text())
    by_package = {a["packageName"]: a for a in apps}
    workspace = rellit.parent
    projects = index_projects(workspace)

    own_app = by_package.get(own_package)
    if own_app is None:
        warn(f"{own_package} is not in {APPS_TS} - add it there; until then sharing has no description")
        name = re.search(r'config/name="([^"]+)"', (project / "project.godot").read_text())
        own = {"slug": own_package.rsplit(".", 1)[-1], "package": own_package,
               "name": name.group(1) if name else own_package, "tag": {}, "description": {}}
    else:
        own = entry(own_app)
        if not own_app.get("published"):
            warn(f"{own_app['name']} is not published in apps.ts - the shared Play link leads nowhere until it is")

    # ---- banners
    changes: list[str] = []
    games: list[dict] = []
    wanted_files: set[str] = set()
    for app in apps:
        if app.get("kind") != "game" or not app.get("published") or app["packageName"] == own_package:
            continue
        game = entry(app)
        banners = {}
        for lang in LANGS:
            file_name = f"{app['slug']}_{lang}.webp"
            target = out_dir / file_name
            source = banner_source(projects.get(app["packageName"]), lang)
            if source is not None:
                data = encode_banner(source)
                if not target.is_file() or target.read_bytes() != data:
                    changes.append(f"banner {file_name}")
                    if not args.check:
                        out_dir.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(data)
            if target.is_file() or (args.check and source is not None):
                banners[lang] = f"res://{OUT_DIR}/{file_name}"
                wanted_files.add(file_name)
        if len(banners) < len(LANGS):
            warn(f"no Play feature graphic for {app['name']} on this machine "
                 f"(build/store/<de|en>/feature_graphic.png in its project) - it is missing from More games")
            continue
        game["banner"] = banners
        games.append(game)

    if out_dir.is_dir():
        for path in sorted(out_dir.iterdir()):
            stem = path.name.removesuffix(".import")
            if path.suffix in (".webp", ".import") and stem not in wanted_files:
                changes.append(f"removed {path.name}")
                if not args.check:
                    path.unlink()
    for file_name in sorted(wanted_files):
        import_file = out_dir / f"{file_name}.import"
        if not import_file.is_file():
            changes.append(f"import settings {import_file.name}")
            if not args.check:
                import_file.write_text(IMPORT_TEMPLATE.format(path=f"{OUT_DIR}/{file_name}"))

    text = render_catalog(own, games)
    old = catalog_path.read_text() if catalog_path.is_file() else ""
    if text != old:
        before = set(re.findall(r'"name": "([^"]+)"', old.split("const GAMES", 1)[-1])) if old else set()
        after = {g["name"] for g in games}
        changes.append("list: " + (", ".join([f"+{n}" for n in sorted(after - before)] +
                                             [f"-{n}" for n in sorted(before - after)]) or "texts changed"))
        if not args.check:
            catalog_path.write_text(text)

    # ---- is a game missing?
    for package, folder in sorted(projects.items()):
        if package == own_package or package in by_package or not package.startswith("de.timhaller."):
            continue
        if (folder / "project.godot").is_file() or (folder / "godot/project.godot").is_file():
            if has_release_build(folder):
                warn(f"game {package} ({folder.name}) has release builds but is not in {APPS_TS}")
    live = leitstand_live()
    if live is not None:
        for package, is_live in sorted(live.items()):
            app = by_package.get(package)
            if app is None:
                if is_live and package in projects and (projects[package] / "project.godot").is_file():
                    warn(f"{package} is live on Google Play but not in {APPS_TS}")
            elif app.get("kind") == "game" and is_live and not app.get("published"):
                warn(f"{app['name']} is live on Google Play, but apps.ts says published: false - "
                     "so it is missing from More games (set published: true in rellit.de)")
            elif app.get("kind") == "game" and app.get("published") and not is_live:
                warn(f"{app['name']} is published in apps.ts, but the Play Leitstand sees no live production release")

    names = ", ".join(g["name"] for g in games) or "none"
    print(f"  More games: {len(games)} ({names})")
    if not changes:
        return 0
    if args.check:
        for change in changes:
            note(f"out of date: {change}")
        return 1
    for change in changes:
        note(f"updated: {change}")
    note(f"commit {OUT_DIR}/ and {CATALOG}")
    # New banners have to be imported before the tests can load them. Godot writes dest_files into
    # the .import file once it has; a first scan of a project now and then skips files, so a second
    # run picks up what the first one left.
    godot = os.environ.get("GODOT", "godot")
    for _attempt in range(2):
        try:
            subprocess.run([godot, "--headless", "--path", str(project), "--import"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, timeout=600)
        except (OSError, subprocess.TimeoutExpired):
            break
        pending = [f for f in wanted_files if "dest_files=" not in (out_dir / f"{f}.import").read_text()]
        if not pending:
            return 0
    warn("Godot did not import the banners - run: godot --headless --path . --import")
    return 0


if __name__ == "__main__":
    sys.exit(main())
