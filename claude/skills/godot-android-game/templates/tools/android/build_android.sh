#!/usr/bin/env bash
# Build a signed __NAME__ APK, or an AAB for Google Play.
#
# Usage: tools/android/build_android.sh [release|debug] [options]
#   release            signed with your release key (default; see create_keystore.sh)
#   debug              signed with Godot's debug key, for quick device testing
#   --aab              build an Android App Bundle (Play Store upload) via Godot's Gradle build
#   --version-code N   set the Android versionCode (must grow with every Play upload)
#   --bump             increase the current versionCode by one
#   --version-name X   set the visible version (default: application/config/version)
#   --skip-tests       do not run the headless test suites first
#   --install          install the APK on the connected device via adb afterwards (APK only)
#
# Release signing reads storeFile, storePassword and keyAlias from keystore.properties in the project root
# (git-ignored, see keystore.properties.example). Missing values fall back to the environment variables
# __ENV___KEYSTORE, __ENV___KEYSTORE_PASSWORD and __ENV___KEY_ALIAS (for CI); a missing password is
# prompted for.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRESET_FILE="$ROOT/export_presets.cfg"
APK_PRESET="Android"
AAB_PRESET="Android AAB"
GODOT="${GODOT:-godot}"
KEYSTORE_PROPERTIES="${__ENV___KEYSTORE_PROPERTIES:-$ROOT/keystore.properties}"
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"

MODE="release"
VERSION_CODE=""
VERSION_NAME=""
BUMP=0
RUN_TESTS=1
INSTALL=0
FORMAT="apk"

while [[ $# -gt 0 ]]; do
	case "$1" in
		release|debug) MODE="$1"; shift ;;
		--version-code) VERSION_CODE="$2"; shift 2 ;;
		--version-name) VERSION_NAME="$2"; shift 2 ;;
		--bump) BUMP=1; shift ;;
		--skip-tests) RUN_TESTS=0; shift ;;
		--install) INSTALL=1; shift ;;
		--aab) FORMAT="aab"; shift ;;
		-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
		*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# Read one key from a Java-style .properties file (plain key=value lines; never sourced as shell code)
read_property() {
	[[ -f "$KEYSTORE_PROPERTIES" ]] || return 0
	sed -n "s/^[[:space:]]*$1[[:space:]]*[=:][[:space:]]*//p" "$KEYSTORE_PROPERTIES" | tail -1 | sed 's/[[:space:]]*$//'
}

command -v "$GODOT" >/dev/null || fail "Godot not found (set GODOT=/path/to/godot)"
[[ "$FORMAT" == "apk" || $INSTALL -eq 0 ]] || fail "--install needs an APK; AABs are installed through Google Play"
BUILD_TOOLS="$(ls -d "$ANDROID_SDK"/build-tools/*/ 2>/dev/null | sort -V | tail -1)"
[[ -n "$BUILD_TOOLS" && -x "${BUILD_TOOLS}apksigner" ]] || fail "apksigner not found in $ANDROID_SDK/build-tools"
APKSIGNER="${BUILD_TOOLS}apksigner"

# ---- version
# Both presets carry the version; edits apply to all of them, reads take the first
current_code="$(sed -n 's/^version\/code=\([0-9]*\)$/\1/p' "$PRESET_FILE" | head -1)"
[[ -n "$current_code" ]] || fail "version/code missing in $PRESET_FILE"
if [[ $BUMP -eq 1 ]]; then
	VERSION_CODE=$((current_code + 1))
fi
if [[ -n "$VERSION_CODE" ]]; then
	[[ "$VERSION_CODE" =~ ^[0-9]+$ ]] || fail "--version-code must be a number"
	sed -i "s/^version\/code=.*/version\/code=$VERSION_CODE/" "$PRESET_FILE"
else
	VERSION_CODE="$current_code"
fi
if [[ -n "$VERSION_NAME" ]]; then
	sed -i "s/^version\/name=.*/version\/name=\"$VERSION_NAME\"/" "$PRESET_FILE"
else
	VERSION_NAME="$(sed -n 's/^version\/name="\(.*\)"$/\1/p' "$PRESET_FILE" | head -1)"
	# An empty preset name makes Godot use the project version
	[[ -n "$VERSION_NAME" ]] || VERSION_NAME="$(sed -n 's/^config\/version="\(.*\)"$/\1/p' "$ROOT/project.godot")"
fi

OUT="$ROOT/build/__SLUG__-${VERSION_NAME}-${VERSION_CODE}-${MODE}.${FORMAT}"
mkdir -p "$ROOT/build"
# Keeps Godot from importing (and exporting) anything that lands in build/
touch "$ROOT/build/.gdignore"

# ---- signing
if [[ "$MODE" == "release" ]]; then
	if [[ -f "$KEYSTORE_PROPERTIES" ]]; then
		perms="$(stat -c '%a' "$KEYSTORE_PROPERTIES")"
		[[ "$perms" =~ 00$ ]] || echo "WARNING: $KEYSTORE_PROPERTIES is readable by others (mode $perms); run: chmod 600 $KEYSTORE_PROPERTIES" >&2
	fi
	# keystore.properties wins, environment variables are the fallback
	store_file="$(read_property storeFile)"
	store_password="$(read_property storePassword)"
	key_alias="$(read_property keyAlias)"
	__ENV___KEYSTORE="${store_file:-${__ENV___KEYSTORE:-}}"
	__ENV___KEYSTORE_PASSWORD="${store_password:-${__ENV___KEYSTORE_PASSWORD:-}}"
	__ENV___KEY_ALIAS="${key_alias:-${__ENV___KEY_ALIAS:-__SLUG__}}"
	__ENV___KEYSTORE="${__ENV___KEYSTORE/#\~/$HOME}"

	[[ -n "$__ENV___KEYSTORE" ]] || fail "No release keystore configured: set storeFile in $KEYSTORE_PROPERTIES (see keystore.properties.example)."
	[[ -f "$__ENV___KEYSTORE" ]] || fail "Keystore not found: $__ENV___KEYSTORE"
	if [[ -z "$__ENV___KEYSTORE_PASSWORD" ]]; then
		[[ -t 0 ]] || fail "No storePassword in $KEYSTORE_PROPERTIES and no terminal to ask for it."
		read -rsp "Keystore password for $__ENV___KEYSTORE: " __ENV___KEYSTORE_PASSWORD; echo
	fi
	# Godot reads release signing credentials from these variables during export
	export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$__ENV___KEYSTORE"
	export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$__ENV___KEY_ALIAS"
	export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$__ENV___KEYSTORE_PASSWORD"
fi

echo "__NAME__ $VERSION_NAME (versionCode $VERSION_CODE), $MODE ${FORMAT^^}"

# ---- tests
if [[ $RUN_TESTS -eq 1 ]]; then
	step "Running tests"
	for test in "$ROOT"/tests/test_*.gd; do
		if "$GODOT" --headless --path "$ROOT" -s "$test" > "$ROOT/build/test.log" 2>&1; then
			echo "  ok   $(basename "$test")"
		else
			cat "$ROOT/build/test.log" >&2
			fail "$(basename "$test") failed"
		fi
	done
	rm -f "$ROOT/build/test.log"
fi

# ---- export
step "Importing assets"
"$GODOT" --headless --path "$ROOT" --import > /dev/null 2>&1 || fail "asset import failed"

PRESET="$APK_PRESET"
[[ "$FORMAT" == "apk" ]] || PRESET="$AAB_PRESET"
export_args=("--export-$MODE" "$PRESET" "$OUT")

export_godot() {
	rm -f "$OUT" "$OUT.idsig"
	"$GODOT" --headless --path "$ROOT" "$@" 2>&1 \
		| grep -vE '^\[ *[0-9]+% \]|^Godot Engine|cannot connect to daemon' || true
}

# True when the preset builds through Gradle (gradle_build/use_gradle_build in its options)
preset_uses_gradle() {
	[[ "$(awk -v want="name=\"$1\"" '$0 == want { found = 1 }
		found && /^gradle_build\/use_gradle_build=/ { print; exit }' "$PRESET_FILE")" == *=true ]]
}

# The template's activity is replaced by our own copy (tools/android/GodotApp.java: it ends the
# process instead of letting Godot tear itself down when Android destroys the activity). Only a
# Gradle build can carry it; the prebuilt template behind a plain APK always runs Godot's own.
ACTIVITY_SRC="$ROOT/tools/android/GodotApp.java"
ACTIVITY_DST="$ROOT/android/build/src/main/java/com/godot/game/GodotApp.java"
GRADLE=0
if preset_uses_gradle "$PRESET"; then
	GRADLE=1
	# The Gradle build needs Godot's Android build template in android/ (generated, not committed)
	template_version="$(cat "$ROOT/android/.build_version" 2>/dev/null || true)"
	godot_version="$("$GODOT" --version | cut -d. -f1-4)"
	# Our copy is written against one template version; a newer template has to be looked at before
	# it is overwritten, not silently replaced by an old file
	activity_version="$(sed -n 's|^// __NAME__: Godot build template ||p' "$ACTIVITY_SRC" | head -1)"
	[[ "$activity_version" == "$godot_version" ]] || fail "tools/android/GodotApp.java is written for the \
$activity_version build template, this is Godot $godot_version: compare it with the new template's \
GodotApp.java, carry onDestroy() over and update its first line"
	if [[ ! -d "$ROOT/android/build" || "$template_version" != "$godot_version" ]]; then
		# Godot only installs the template as part of an export, so that first export is thrown away:
		# it was built with the template's own activity
		step "Installing Android build template for $godot_version"
		rm -rf "$ROOT/android"
		export_godot --install-android-build-template "${export_args[@]}"
		[[ -f "$ACTIVITY_DST" ]] || fail "the build template was not installed (see Godot output above)"
	fi
	cp "$ACTIVITY_SRC" "$ACTIVITY_DST"
else
	echo "NOTE: preset \"$PRESET\" uses Godot's prebuilt template, so this ${FORMAT^^} runs Godot's own" \
		"activity without tools/android/GodotApp.java (fine for quick tests, not for players)"
fi

step "Exporting $OUT"
export_godot "${export_args[@]}"
[[ -f "$OUT" ]] || fail "export produced no ${FORMAT^^} (see Godot output above)"
[[ $GRADLE -eq 0 ]] || cmp -s "$ACTIVITY_SRC" "$ACTIVITY_DST" \
	|| fail "android/ lost tools/android/GodotApp.java during the export"

# ---- verify
# Fingerprints are compared as lowercase hex without colons; keytool output is forced to English
keytool_en() { keytool -J-Duser.language=en "$@"; }
normalize_fp() { sed -n 's/^.*SHA256: *//p' | head -1 | tr -d ':' | tr 'A-F' 'a-f'; }

step "Verifying signature"
if [[ "$FORMAT" == "apk" ]]; then
	certs="$("$APKSIGNER" verify --verbose --print-certs "$OUT")" || { rm -f "$OUT" "$OUT.idsig"; fail "APK signature does not verify"; }
	echo "$certs" | grep -E "Verified using v[0-9]|certificate DN|certificate SHA-256" | sed 's/^/  /'
	actual="$(echo "$certs" | sed -n 's/^.*certificate SHA-256 digest: *//p' | head -1)"
elif [[ "$MODE" == "debug" ]]; then
	# Godot leaves debug bundles unsigned; bundletool signs the APKs it builds from one
	echo "  debug AAB, unsigned (bundletool build-apks signs the APKs made from it)"
	actual=""
else
	# App bundles carry a JAR signature; Play re-signs the APKs it generates with the app signing key
	jarsigner -J-Duser.language=en -verify "$OUT" | grep -q "jar verified" || { rm -f "$OUT"; fail "AAB signature does not verify"; }
	certs="$(keytool_en -printcert -jarfile "$OUT")"
	echo "$certs" | grep -E "^Owner:|SHA256:" | head -2 | sed 's/^/  /'
	actual="$(echo "$certs" | normalize_fp)"
fi
if [[ "$MODE" == "release" ]]; then
	# The build must carry exactly the configured release certificate (not Godot's debug key)
	expected="$(keytool_en -list -v -keystore "$__ENV___KEYSTORE" -alias "$__ENV___KEY_ALIAS" \
		-storepass:env GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD 2>/dev/null | normalize_fp)"
	if [[ -z "$expected" || "$expected" != "$actual" ]]; then
		rm -f "$OUT" "$OUT.idsig"
		fail "${FORMAT^^} is not signed with the release key from $__ENV___KEYSTORE"
	fi
	echo "  matches release key $__ENV___KEYSTORE"
fi

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"

if [[ $INSTALL -eq 1 ]]; then
	step "Installing on device"
	adb install -r "$OUT"
fi
