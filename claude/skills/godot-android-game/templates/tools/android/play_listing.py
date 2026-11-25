#!/usr/bin/env python3
"""Put the store listing on Google Play: texts, phone screenshots and feature graphic.

Usage: tools/android/play_listing.py [options]
  --texts-only         only title, short and full description, no pictures
  --validate           do everything except publishing: Google checks the edit, then it is thrown away
  --replace-in-review  if other changes are still in review (a release, say), withdraw them and send
                       everything again together (default: stop with an error and change nothing)
  --no-review          commit without sending for review; send it from the Play Console later
  --check              only read and check the files, nothing goes to Google

Reads what tools/generate_store_assets.py wrote to build/store/: listing.md (sections "## de-DE" and
"## en-US" with title, short and full description) and <de|en>/phone_NN_*.png plus
feature_graphic.png. Every de-* listing language of the app gets the German version, every en-*
language the English one. Screenshots replace the ones on Google Play, in file order. The icon stays
as it is. Credentials and API calls as in play_deploy.py (same service account).
"""
import argparse
import re
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


def upload_image(play: Play, edit: str, language: str, image_type: str, path: Path) -> None:
    url = f"{UPLOAD_API}/{play.package}/edits/{edit}/listings/{language}/{image_type}?" + \
        urllib.parse.urlencode({"uploadType": "media"})
    headers = {"Authorization": f"Bearer {play.token}", "Content-Type": "image/png",
        "Content-Length": str(path.stat().st_size)}
    with path.open("rb") as stream:
        http("POST", url, stream, headers, timeout=300)


def publish(args: argparse.Namespace, texts: dict[str, dict], images: dict[str, tuple]) -> None:
    play = Play(access_token(load_key()), package_name())
    edit = play.call("POST", "edits", {})["id"]
    try:
        languages = [listing["language"] for listing in play.call("GET", f"edits/{edit}/listings").get("listings", [])]
        targets = [(language, language[:2]) for language in languages if language[:2] in texts]
        if not targets:
            raise DeployError(f"the app has no de-* or en-* listing on Google Play (found: {', '.join(languages) or 'none'})")
        for language, lang in targets:
            play.call("PATCH", f"edits/{edit}/listings/{language}", {"language": language} | texts[lang])
            print(f"  {language}: texts", flush=True)
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


def main() -> int:
    if {"-h", "--help"} & set(sys.argv[1:]):
        print(__doc__.strip())
        return 0
    parser = argparse.ArgumentParser(usage="tools/android/play_listing.py [options] (see --help)", add_help=False)
    for flag in ("--texts-only", "--validate", "--replace-in-review", "--no-review", "--check"):
        parser.add_argument(flag, action="store_true")
    args = parser.parse_args()
    try:
        texts = {lang: listing_texts(lang) for lang in LABELS}
        images = {} if args.texts_only else {lang: pictures(lang) for lang in LABELS}
        print(f"Google Play listing: {package_name()}")
        for lang in LABELS:
            t = texts[lang]
            extra = "" if args.texts_only else f", {len(images[lang][0])} screenshots + feature graphic"
            print(f"  {lang}: \"{t['title']}\" / {len(t['shortDescription'])} / {len(t['fullDescription'])} characters{extra}")
        if args.check:
            return 0
        publish(args, texts, images)
    except DeployError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        extra = hint(error)
        if extra:
            print(f"  {extra}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
