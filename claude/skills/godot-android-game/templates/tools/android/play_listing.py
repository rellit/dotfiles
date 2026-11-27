#!/usr/bin/env python3
"""Put the store listing on Google Play: texts, phone screenshots and feature graphic.

Usage: tools/android/play_listing.py [options]
  --texts-only         only title, short and full description, no pictures
  --create-languages   create the languages of listing.md (de-DE, en-US) on Google Play where they are
                       missing (default: only update languages the app already has)
  --icon               also replace the icon with build/store/icon_512.png (512×512 PNG, at most 1 MB;
                       works with --texts-only too)
  --validate           do everything except publishing: Google checks the edit, then it is thrown away
  --replace-in-review  if other changes are still in review (a release, say), withdraw them and send
                       everything again together (default: stop with an error and change nothing)
  --no-review          commit without sending for review; send it from the Play Console later
  --check              only read and check the files, nothing goes to Google

Reads what tools/generate_store_assets.py wrote to build/store/: listing.md (sections "## de-DE" and
"## en-US" with title, short and full description) and <de|en>/phone_NN_*.png plus
feature_graphic.png. Every de-* listing language of the app gets the German version, every en-*
language the English one. Screenshots replace the ones on Google Play, in file order. Without --icon
the icon stays as it is. Credentials and API calls as in play_deploy.py (same service account).

New app: a fresh app has no listing languages yet, so run it with --create-languages --icon
(--validate first). The service account also needs "Manage store presence" for this app (Play Console,
Users and permissions; rights are granted per app). Without it the uploads go through, but checking
or committing the edit ends with HTTP 403.
"""
import argparse
import re
import struct
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from play_deploy import (ROOT, UPLOAD_API, ApiError, DeployError, Play, access_token, hint, http,  # noqa: E402
    load_key, package_name)

STORE = ROOT / "build" / "store"
LIMITS = {"title": 30, "shortDescription": 80, "fullDescription": 4000}
# Labels in listing.md per section language
LABELS = {
    "de": {"title": "Titel", "shortDescription": "Kurzbeschreibung", "fullDescription": "Beschreibung"},
    "en": {"title": "Title", "shortDescription": "Short description", "fullDescription": "Full description"},
}
MAX_SCREENSHOTS = 8
ICON_SIZE = 512
ICON_MAX_BYTES = 1024 * 1024


def listing_language(lang: str) -> str:
    """The full language code of the listing.md section, e.g. de-DE."""
    text = (STORE / "listing.md").read_text(encoding="utf-8")
    return re.search(rf"^## ({lang}-[A-Z]+)$", text, re.M).group(1)


def listing_texts(lang: str) -> dict[str, str]:
    path = STORE / "listing.md"
    if not path.is_file():
        raise DeployError(f"{path.relative_to(ROOT)} missing: run python3 tools/generate_store_assets.py")
    text = path.read_text(encoding="utf-8")
    section = re.search(rf"^## {lang}-[A-Z]+\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not section:
        raise DeployError(f"no '## {lang}-…' section in {path.name}")
    body = section.group(1)
    labels = LABELS[lang]
    title = re.search(rf"^{labels['title']}[^:\n]*:[ \t]*(.+)$", body, re.M)
    short = re.search(rf"^{labels['shortDescription']}[^:\n]*:\n(.+?)\n\n", body, re.M | re.S)
    full = re.search(rf"^{labels['fullDescription']}[^:\n]*:\n(.+)", body, re.M | re.S)
    if not (title and short and full):
        raise DeployError(f"{path.name} ({lang}): title, short or full description not found")
    texts = {"title": title.group(1).strip(), "shortDescription": short.group(1).strip(),
        "fullDescription": full.group(1).strip()}
    for field, limit in LIMITS.items():
        if len(texts[field]) > limit:
            raise DeployError(f"{lang} {field} has {len(texts[field])} characters, Google Play takes {limit}")
    return texts


def pictures(lang: str) -> tuple[list[Path], Path]:
    folder = STORE / lang
    shots = sorted(folder.glob("phone_*.png"))
    feature = folder / "feature_graphic.png"
    if not shots or not feature.is_file():
        raise DeployError(f"no screenshots or feature graphic in {folder.relative_to(ROOT)}: run "
            "python3 tools/generate_store_assets.py")
    if len(shots) > MAX_SCREENSHOTS:
        raise DeployError(f"{len(shots)} phone screenshots in {folder.name}/, Google Play takes {MAX_SCREENSHOTS}")
    return shots, feature


def store_icon() -> Path:
    path = STORE / "icon_512.png"
    if not path.is_file():
        raise DeployError(f"{path.relative_to(ROOT)} missing: run python3 tools/generate_store_assets.py")
    head = path.read_bytes()[:24]
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise DeployError(f"{path.name} is not a PNG")
    width, height = struct.unpack(">II", head[16:24])
    if (width, height) != (ICON_SIZE, ICON_SIZE):
        raise DeployError(f"{path.name} is {width}×{height}, Google Play takes {ICON_SIZE}×{ICON_SIZE}")
    if path.stat().st_size > ICON_MAX_BYTES:
        raise DeployError(f"{path.name} has {path.stat().st_size // 1024} KB, Google Play takes at most 1024 KB")
    return path


def upload_image(play: Play, edit: str, language: str, image_type: str, path: Path) -> None:
    url = f"{UPLOAD_API}/{play.package}/edits/{edit}/listings/{language}/{image_type}?" + \
        urllib.parse.urlencode({"uploadType": "media"})
    headers = {"Authorization": f"Bearer {play.token}", "Content-Type": "image/png",
        "Content-Length": str(path.stat().st_size)}
    with path.open("rb") as stream:
        http("POST", url, stream, headers, timeout=300)


def publish(args: argparse.Namespace, texts: dict[str, dict], images: dict[str, tuple], icon: Path | None) -> None:
    play = Play(access_token(load_key()), package_name())
    edit = play.call("POST", "edits", {})["id"]
    try:
        existing = [listing["language"] for listing in play.call("GET", f"edits/{edit}/listings").get("listings", [])]
        missing = [code for code in (listing_language(lang) for lang in texts) if code not in existing]
        if args.create_languages:
            languages = existing + missing
        else:
            languages = existing
            for code in missing:
                print(f"  {code}: not on Google Play, skipped (--create-languages adds it)")
        targets = [(language, language[:2]) for language in languages if language[:2] in texts]
        if not targets:
            raise DeployError(f"the app has no de-* or en-* listing on Google Play (found: {', '.join(existing) or 'none'}); "
                "for a new app: --create-languages --icon")
        for language, lang in targets:
            new = language not in existing
            # PUT creates a listing language, PATCH only changes one the app already has
            play.call("PUT" if new else "PATCH", f"edits/{edit}/listings/{language}", {"language": language} | texts[lang])
            print(f"  {language}: {'new language, ' if new else ''}texts", flush=True)
            if icon:
                play.call("DELETE", f"edits/{edit}/listings/{language}/icon")
                upload_image(play, edit, language, "icon", icon)
                print(f"  {language}: icon", flush=True)
            if args.texts_only:
                continue
            shots, feature = images[lang]
            play.call("DELETE", f"edits/{edit}/listings/{language}/phoneScreenshots")
            for shot in shots:
                upload_image(play, edit, language, "phoneScreenshots", shot)
            play.call("DELETE", f"edits/{edit}/listings/{language}/featureGraphic")
            upload_image(play, edit, language, "featureGraphic", feature)
            print(f"  {language}: {len(shots)} phone screenshots, feature graphic", flush=True)
        if args.validate:
            play.call("POST", f"edits/{edit}:validate")
            play.call("DELETE", f"edits/{edit}")
            print("OK: Google Play accepts the listing. Nothing was published (--validate).")
            return
        if args.no_review:
            params = {"changesNotSentForReview": "true"}
        else:
            params = {"changesInReviewBehavior": "CANCEL_IN_REVIEW_AND_SUBMIT" if args.replace_in_review else "ERROR_IF_IN_REVIEW"}
        play.call("POST", f"edits/{edit}:commit", params=params)
    except BaseException:
        try:
            play.call("DELETE", f"edits/{edit}")
        except DeployError:
            pass
        raise
    if args.no_review:
        print("Committed the listing; send it for review in the Play Console.")
    else:
        print("Sent the listing for review. Without managed publishing it goes live once Google approves it.")


def listing_hint(error: DeployError) -> str:
    if isinstance(error, ApiError) and error.status == 403 and "permission" in str(error).lower():
        return ("The service account needs \"Manage store presence\" for this app: Play Console, Users and "
            "permissions. Rights are granted per app, so a new app needs it added; it can take a while to arrive.")
    return hint(error)


def main() -> int:
    if {"-h", "--help"} & set(sys.argv[1:]):
        print(__doc__.strip())
        return 0
    parser = argparse.ArgumentParser(usage="tools/android/play_listing.py [options] (see --help)", add_help=False)
    for flag in ("--texts-only", "--create-languages", "--icon", "--validate", "--replace-in-review", "--no-review",
            "--check"):
        parser.add_argument(flag, action="store_true")
    args = parser.parse_args()
    try:
        texts = {lang: listing_texts(lang) for lang in LABELS}
        images = {} if args.texts_only else {lang: pictures(lang) for lang in LABELS}
        icon = store_icon() if args.icon else None
        print(f"Google Play listing: {package_name()}")
        for lang in LABELS:
            t = texts[lang]
            extra = "" if args.texts_only else f", {len(images[lang][0])} screenshots + feature graphic"
            print(f"  {listing_language(lang)}: \"{t['title']}\" / {len(t['shortDescription'])} / "
                f"{len(t['fullDescription'])} characters{extra}")
        if icon:
            print(f"  icon: {icon.relative_to(ROOT)} for every language")
        if args.create_languages:
            print("  languages missing on Google Play get created")
        if args.check:
            return 0
        publish(args, texts, images, icon)
    except DeployError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        extra = listing_hint(error)
        if extra:
            print(f"  {extra}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
