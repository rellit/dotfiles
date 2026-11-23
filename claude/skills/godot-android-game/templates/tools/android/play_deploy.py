#!/usr/bin/env python3
"""Upload a release AAB to Google Play, write its release notes and send it for review.

Usage: tools/android/play_deploy.py [AAB] [options]
  AAB                  the bundle to upload (default: build/<slug>-<version>-<code>-release.aab for the
                       version in export_presets.cfg / project.godot)
  --track T            production (default, alias prod), beta (open testing, alias open), alpha
                       (closed testing, alias closed), internal, or the name of a custom closed track
  --rollout F          staged rollout to the fraction F (0 < F < 1) instead of everyone
  --validate           do everything except publishing: Google checks the edit, then it is thrown away
  --replace-in-review  if other changes are still in review, withdraw them and send everything again
                       (default: stop with an error and change nothing)
  --no-review          commit without sending for review; send it from the Play Console later
  --check              only check what can be checked offline: service account key and release notes
  --version-code N, --version-name X
                       with --check: the version to check (default: taken from the AAB name)

Release notes come from the changelog entry whose "build" is the AAB's versionCode: English from the
game controller (changelog_entries() or changelog()), German from locale/de.po. Every de-* listing
language gets the German text, every en-* language the English one. At most 500 characters each.

Credentials: the JSON key of a Google Cloud service account that is invited in the Play Console
(Users and permissions) with release rights for the app. Path: $PLAY_SERVICE_ACCOUNT_JSON, default
~/.android-keystores/play-service-account.json (mode 600, never inside a repository).
Uses only the Python standard library and openssl.
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_API = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
DEFAULT_KEY = Path.home() / ".android-keystores" / "play-service-account.json"
NOTES_LIMIT = 500
TRACK_ALIASES = {"prod": "production", "open": "beta", "closed": "alpha"}


class DeployError(Exception):
    pass


class ApiError(DeployError):
    def __init__(self, status: int, body: str):
        self.status = status
        self.body = body
        message = body.strip()
        try:
            data = json.loads(body)
            error = data.get("error")
            if isinstance(error, dict):
                message = error.get("message") or message
            elif error:
                message = f"{error}: {data.get('error_description', '')}".rstrip(": ")
        except ValueError:
            pass
        super().__init__(f"HTTP {status}: {message}")


# ---- project files

def preset_value(key: str) -> str:
    # Both presets carry the same values; the first one counts, like in build_android.sh
    text = (ROOT / "export_presets.cfg").read_text(encoding="utf-8")
    match = re.search(rf"^{re.escape(key)}=(.*)$", text, re.M)
    return match.group(1).strip().strip('"') if match else ""


def package_name() -> str:
    name = preset_value("package/unique_name")
    if not name:
        raise DeployError("package/unique_name missing in export_presets.cfg")
    return name


def project_version() -> tuple[int, str]:
    code = preset_value("version/code")
    name = preset_value("version/name")
    if not name:
        # An empty preset name makes Godot use the project version
        match = re.search(r'^config/version="(.*)"$', (ROOT / "project.godot").read_text(encoding="utf-8"), re.M)
        name = match.group(1) if match else ""
    if not code.isdigit() or not name:
        raise DeployError("no version/code or version name in export_presets.cfg / project.godot")
    return int(code), name


AAB_NAME = re.compile(r"(?P<slug>[^-]+)-(?P<name>.+)-(?P<code>\d+)-release\.aab")


def default_aab() -> Path:
    code, name = project_version()
    found = sorted((ROOT / "build").glob(f"*-{name}-{code}-release.aab"))
    if len(found) != 1:
        raise DeployError(f"no release AAB for {name} ({code}) in build/; build it with "
            "tools/android/build_android.sh release --aab, or name the file")
    return found[0]


def aab_version(aab: Path) -> tuple[int, str]:
    match = AAB_NAME.fullmatch(aab.name)
    if not match:
        raise DeployError(f"{aab.name} is not a release AAB from build_android.sh (<slug>-<version>-<code>-release.aab)")
    return int(match["code"]), match["name"]


# ---- release notes

def unescape(text: str) -> str:
    # GDScript string literals and PO strings share the C escapes that matter here
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), text)


def find_changelog() -> tuple[Path, str]:
    start = re.compile(r"^(?:static\s+)?func\s+(?:changelog_entries|changelog)\s*\(", re.M)
    for path in sorted((ROOT / "scripts").rglob("*.gd")):
        source = path.read_text(encoding="utf-8")
        match = start.search(source)
        if match:
            rest = source[match.end():]
            end = re.search(r"^(?:static\s+)?func\s", rest, re.M)
            return path, rest[:end.start()] if end else rest
    raise DeployError("no changelog_entries() or changelog() in scripts/")


def list_strings(source: str, pos: int) -> list[str]:
    """String literals from pos up to the ] that closes the list, whether wrapped in tr() or not."""
    strings, depth, i = [], 0, pos
    while i < len(source):
        char = source[i]
        if char == '"':
            end = i + 1
            while source[end] != '"':
                end += 2 if source[end] == "\\" else 1
            strings.append(unescape(source[i + 1:end]))
            i = end
        elif char == "#":
            i = source.find("\n", i)
            if i < 0:
                break
        elif char in "[(":
            depth += 1
        elif char in ")]":
            if depth == 0:
                return strings
            depth -= 1
        i += 1
    raise DeployError("the changes list in the changelog is not closed")


def changelog_changes(code: int, name: str) -> list[str]:
    path, body = find_changelog()
    where = path.relative_to(ROOT)
    entries = list(re.finditer(r'\{\s*"version"\s*:\s*"([^"]*)"\s*,\s*"build"\s*:\s*(\d+)', body))
    for index, entry in enumerate(entries):
        if int(entry[2]) != code:
            continue
        if entry[1] != name:
            raise DeployError(f'the changelog entry with "build": {code} in {where} is version {entry[1]}, the build is {name}')
        end = entries[index + 1].start() if index + 1 < len(entries) else len(body)
        changes = re.search(r'"changes"\s*:\s*\[', body[entry.end():end])
        texts = list_strings(body, entry.end() + changes.end()) if changes else []
        if not texts:
            raise DeployError(f'the changelog entry for {name} ({code}) in {where} has no changes')
        return texts
    raise DeployError(f'no changelog entry with "build": {code} in {where} (release checklist: version, changelog, de.po)')


def po_translations(path: Path) -> dict[str, str]:
    entries, current, field = [], {}, None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("#~"):
            continue
        has_text = any(key.startswith("msgstr") for key in current)
        if not line or line.startswith("#"):
            if has_text:
                entries.append(current)
                current, field = {}, None
            if line.startswith("#,") and "fuzzy" in line:
                current["fuzzy"] = True
            continue
        match = re.match(r'(msgctxt|msgid_plural|msgid|msgstr(?:\[\d+\])?)\s+"(.*)"$', line)
        if match:
            if match[1] in ("msgctxt", "msgid") and has_text:
                entries.append(current)
                current = {}
            field = match[1]
            current[field] = current.get(field, "") + match[2]
        elif line.startswith('"') and field:
            current[field] += line[1:-1]
    if any(key.startswith("msgstr") for key in current):
        entries.append(current)
    # Godot skips fuzzy entries; texts with a context are not plain tr() calls
    return {unescape(e["msgid"]): unescape(e["msgstr"]) for e in entries
        if e.get("msgstr") and "msgctxt" not in e and not e.get("fuzzy") and "msgid" in e}


def notes_text(changes: list[str]) -> str:
    return changes[0] if len(changes) == 1 else "\n".join(f"• {change}" for change in changes)


def release_notes(code: int, name: str) -> dict[str, str]:
    english = changelog_changes(code, name)
    po = ROOT / "locale" / "de.po"
    german_texts = po_translations(po) if po.is_file() else {}
    missing = [text for text in english if not german_texts.get(text)]
    if missing:
        raise DeployError("no German translation in locale/de.po for:\n  " + "\n  ".join(missing))
    notes = {"en": notes_text(english), "de": notes_text([german_texts[text] for text in english])}
    for language, text in notes.items():
        if len(text) > NOTES_LIMIT:
            raise DeployError(f"the {language} release notes have {len(text)} characters, Google Play takes "
                f"{NOTES_LIMIT}; shorten the changelog entry for {name} ({code})")
    return notes


# ---- Google authentication (service account JWT, signed by openssl)

def key_path() -> Path:
    return Path(os.environ.get("PLAY_SERVICE_ACCOUNT_JSON") or DEFAULT_KEY).expanduser()


def load_key() -> dict:
    path = key_path()
    if not path.is_file():
        raise DeployError(f"no service account key at {path} (set PLAY_SERVICE_ACCOUNT_JSON, setup: "
            "see the godot-android-game skill, section 14)")
    if path.stat().st_mode & 0o077:
        print(f"WARNING: {path} is readable by others; run: chmod 600 {path}", file=sys.stderr)
    try:
        key = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        key = {}
    if key.get("type") != "service_account" or not key.get("client_email") or not key.get("private_key"):
        raise DeployError(f"{path} is not the JSON key of a service account")
    return key


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def sign_rs256(data: bytes, private_key_pem: str) -> bytes:
    # The key reaches openssl through a pipe, so it is never written to disk
    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, private_key_pem.encode())
        os.close(write_fd)
        write_fd = -1
        result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", f"/dev/fd/{read_fd}"],
            input=data, capture_output=True, pass_fds=(read_fd,))
    finally:
        os.close(read_fd)
        if write_fd >= 0:
            os.close(write_fd)
    if result.returncode != 0 or not result.stdout:
        raise DeployError("openssl could not sign with the service account key: " + result.stderr.decode(errors="replace").strip())
    return result.stdout


def access_token(key: dict) -> str:
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = b64url(json.dumps({"iss": key["client_email"], "scope": SCOPE, "aud": TOKEN_URL,
        "iat": now, "exp": now + 3600}).encode())
    signature = b64url(sign_rs256(f"{header}.{claims}".encode(), key["private_key"]))
    body = urllib.parse.urlencode({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": f"{header}.{claims}.{signature}"}).encode()
    return http("POST", TOKEN_URL, body, {"Content-Type": "application/x-www-form-urlencoded"})["access_token"]


def http(method: str, url: str, data=None, headers: dict | None = None, timeout: int = 60) -> dict:
    request = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        raise ApiError(error.code, error.read().decode(errors="replace")) from None
    except urllib.error.URLError as error:
        raise DeployError(f"{url.split('?')[0]} not reachable: {error.reason}") from None
    return json.loads(body) if body.strip() else {}


# ---- Google Play Developer API

class Play:
    def __init__(self, token: str, package: str):
        self.token = token
        self.package = package

    def call(self, method: str, path: str, body=None, params=None, upload: Path | None = None) -> dict:
        url = f"{UPLOAD_API if upload else API}/{self.package}/{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        headers = {"Authorization": f"Bearer {self.token}"}
        if upload:
            headers |= {"Content-Type": "application/octet-stream", "Content-Length": str(upload.stat().st_size)}
            with upload.open("rb") as stream:
                # Google recommends a long timeout for bundle uploads
                return http(method, url, stream, headers, timeout=900)
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        return http(method, url, data, headers)


def notes_for_listings(play: Play, edit: str, notes: dict[str, str]) -> list[dict]:
    languages = [listing["language"] for listing in play.call("GET", f"edits/{edit}/listings").get("listings", [])]
    default = play.call("GET", f"edits/{edit}/details").get("defaultLanguage")
    if default and default not in languages:
        languages.append(default)
    result = []
    for language in languages:
        if language.startswith("de"):
            result.append({"language": language, "text": notes["de"]})
        elif language.startswith("en") or language == default:
            result.append({"language": language, "text": notes["en"]})
    return result


def deploy(aab: Path, track: str, args: argparse.Namespace, notes: dict[str, str]) -> None:
    package = package_name()
    code, name = aab_version(aab)
    play = Play(access_token(load_key()), package)
    edit = play.call("POST", "edits", {})["id"]
    try:
        release_notes_list = notes_for_listings(play, edit, notes)
        print(f"  release notes for {', '.join(n['language'] for n in release_notes_list) or 'no language'}")
        print(f"  uploading {aab.name} ({aab.stat().st_size / 1e6:.0f} MB) …", flush=True)
        bundle = play.call("POST", f"edits/{edit}/bundles", params={"uploadType": "media"}, upload=aab)
        if int(bundle.get("versionCode", -1)) != code:
            raise DeployError(f"Google Play read versionCode {bundle.get('versionCode')} from the bundle, the file name says {code}")
        release = {"name": f"{code} ({name})", "versionCodes": [str(code)], "status": "completed",
            "releaseNotes": release_notes_list}
        if args.rollout:
            release |= {"status": "inProgress", "userFraction": args.rollout}
        play.call("PUT", f"edits/{edit}/tracks/{track}", {"track": track, "releases": [release]})
        if args.validate:
            play.call("POST", f"edits/{edit}:validate")
            play.call("DELETE", f"edits/{edit}")
            print(f"OK: Google Play accepts {name} ({code}) for {track}. Nothing was published (--validate).")
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
    rollout = f", rollout to {args.rollout:.0%}" if args.rollout else ""
    if args.no_review:
        print(f"Committed {name} ({code}) to {track}{rollout}; send it for review in the Play Console.")
    else:
        print(f"Sent {name} ({code}) to {track}{rollout} for review. Without managed publishing it goes "
            "live once Google approves it.")


def hint(error: DeployError) -> str:
    text = str(error)
    lower = text.lower()
    if "already have changes in review" in lower or "changes_already_in_review" in lower:
        return "Other changes are still in review. To withdraw them and send everything again: --replace-in-review"
    if "sent for review automatically" in lower or "changesnotsentforreview" in lower:
        return ("Google does not take this for review automatically (e.g. after a rejection). Commit with --no-review "
            "and send it for review in the Play Console.")
    if "version code" in lower and "already" in lower:
        return "This versionCode is already on Google Play: raise it (build_android.sh --bump) and build again."
    if "draft app" in lower:
        return "The app has never been published: the first release goes through the Play Console."
    if isinstance(error, ApiError) and error.status in (401, 403):
        return ("Is the service account invited in the Play Console (Users and permissions) with release rights for "
            "this app, and the Google Play Android Developer API enabled in its Cloud project? New rights can take "
            "a while to arrive.")
    return ""


def main() -> int:
    if {"-h", "--help"} & set(sys.argv[1:]):
        print(__doc__.strip())
        return 0
    parser = argparse.ArgumentParser(usage="tools/android/play_deploy.py [AAB] [options] (see --help)", add_help=False)
    parser.add_argument("aab", nargs="?", type=Path)
    parser.add_argument("--track", default="production")
    parser.add_argument("--rollout", type=float)
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--replace-in-review", action="store_true")
    parser.add_argument("--no-review", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--version-code", type=int)
    parser.add_argument("--version-name")
    args = parser.parse_args()
    track = TRACK_ALIASES.get(args.track, args.track)
    try:
        if args.rollout is not None and not 0 < args.rollout < 1:
            raise DeployError("--rollout takes a fraction between 0 and 1, e.g. 0.2")
        if args.check and args.version_code is not None and args.version_name:
            aab, (code, name) = None, (args.version_code, args.version_name)
        else:
            aab = (args.aab or default_aab()).resolve()
            if not aab.is_file():
                raise DeployError(f"{aab} not found")
            code, name = aab_version(aab)
        package = package_name()
        notes = release_notes(code, name)
        key = load_key()
        print(f"Google Play: {package} {name} ({code}) → {track}")
        print(f"  service account {key['client_email']}")
        for language, text in notes.items():
            print(f"  {language}: " + text.replace("\n", "\n      "))
        if args.check:
            return 0
        deploy(aab, track, args, notes)
    except DeployError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        extra = hint(error)
        if extra:
            print(f"  {extra}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
