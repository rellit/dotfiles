---
name: "android-build-tools"
description: "Legt in nativen Android-Projekten (Gradle/Kotlin, nicht Godot) tools/android/ mit build_android.sh und create_keystore.sh, version.properties, Signing und .gitignore an."
---

# android-build-tools

Abgespeckte Variante des Build-Teils aus `godot-android-game`, für native Android-Apps
(Gradle/AGP, Kotlin). Sorgt nur dafür, dass das Projekt dieses Gerüst hat:

```
tools/android/build_android.sh      # signiertes APK/AAB bauen, Version setzen, Signatur prüfen
tools/android/create_keystore.sh    # Release-Key einmalig anlegen + keystore.properties schreiben
keystore.properties.example         # Vorlage (committet)
keystore.properties                 # echte Werte (git-ignoriert, chmod 600)
version.properties                  # versionCode / versionName (committet)
dist/                               # Ausgabe: <slug>-<versionName>-<versionCode>-<mode>.<apk|aab>
```

Alles andere (App-Code, Icons, Store-Assets, Werbung) gehört nicht zu diesem Skill.

## Ablauf

1. **Platzhalter festlegen** (aus CLAUDE.md/README/applicationId ableiten, sonst den Nutzer fragen):
   - `__APP_NAME__` – sichtbarer Name, z. B. `Wasserwaage`
   - `__SLUG__` – Kleinbuchstaben ohne Leerzeichen, für Dateinamen, Key-Alias, Keystore-Datei
   - `__PREFIX__` – Env-Präfix in Großbuchstaben, z. B. `WASSERWAAGE` (ergibt `WASSERWAAGE_KEYSTORE`, …)
2. **Nichts überschreiben.** Existiert `tools/android/` schon, nur Abweichungen melden und gezielt
   ergänzen. Einen vorhandenen Keystore oder eine vorhandene `keystore.properties` nie anfassen.
3. **Dateien schreiben**: die beiden Skripte unten mit ersetzten Platzhaltern
   (`sed -e 's/__PREFIX__/X/g; s/__SLUG__/y/g; s/__APP_NAME__/Z/g'`), dann `chmod +x tools/android/*.sh`.
4. **`version.properties`** im Projektstamm anlegen, falls nicht vorhanden:
   ```properties
   versionCode=1
   versionName=1.0.0
   ```
5. **`keystore.properties.example`** anlegen:
   ```properties
   # Copy to keystore.properties (git-ignored, chmod 600) and fill in the password.
   # tools/android/create_keystore.sh writes this file for you when it creates a new key.
   # Missing values fall back to __PREFIX___KEYSTORE / __PREFIX___KEYSTORE_PASSWORD / __PREFIX___KEY_ALIAS (CI).
   storeFile=~/.android-keystores/__SLUG__-release.keystore
   storePassword=
   keyAlias=__SLUG__
   ```
6. **Gradle anbinden** in `app/build.gradle.kts` (Version aus `version.properties`, Release-Signing aus den
   Umgebungsvariablen, die `build_android.sh` setzt – so liegt kein Passwort in Gradle-Dateien):
   ```kotlin
   import java.util.Properties

   val versionProps = Properties().apply {
       rootProject.file("version.properties").inputStream().use { load(it) }
   }
   val releaseStoreFile: String? = System.getenv("ANDROID_RELEASE_STORE_FILE")

   android {
       defaultConfig {
           versionCode = versionProps.getProperty("versionCode").toInt()
           versionName = versionProps.getProperty("versionName")
       }
       signingConfigs {
           if (releaseStoreFile != null) {
               create("release") {
                   storeFile = file(releaseStoreFile)
                   storePassword = System.getenv("ANDROID_RELEASE_STORE_PASSWORD")
                   keyAlias = System.getenv("ANDROID_RELEASE_KEY_ALIAS")
                   keyPassword = System.getenv("ANDROID_RELEASE_STORE_PASSWORD") // PKCS12: identisch
               }
           }
       }
       buildTypes {
           release {
               signingConfigs.findByName("release")?.let { signingConfig = it }
           }
       }
   }
   ```
   Ohne die Variablen (z. B. Build aus Android Studio) entsteht ein unsigniertes Release – das Skript
   erkennt das bei der Signaturprüfung und bricht ab.
7. **`.gitignore`** ergänzen (nur fehlende Zeilen):
   ```gitignore
   # Build output
   dist/
   # Signing material - never commit
   *.keystore
   *.jks
   keystore.properties
   ```
8. **Dokumentieren**: in CLAUDE.md bzw. README einen Abschnitt „Build & Release“ mit den Befehlen unten.
9. **Prüfen**: `bash -n tools/android/*.sh`, `shellcheck -S warning tools/android/*.sh` falls vorhanden,
   dann `tools/android/build_android.sh debug --skip-tests` (sobald das Projekt baut).

`create_keystore.sh` **nicht selbst ausführen** – es fragt interaktiv nach dem Passwort, und der Key ist
unersetzlich. Dem Nutzer den Befehl nennen; danach Keystore + Passwort extern sichern lassen.

## Benutzung (für die Projektdoku)

```bash
tools/android/create_keystore.sh                      # einmalig: Release-Key + keystore.properties
tools/android/build_android.sh debug --install        # schnell aufs Gerät
tools/android/build_android.sh release                # signiertes APK in dist/
tools/android/build_android.sh release --aab --bump   # Play-Upload: versionCode +1, AAB in dist/
tools/android/build_android.sh release --aab --version-name 1.1.0 --bump
```

Voraussetzungen: `gradlew` im Projektstamm, JDK 17+ (`keytool`, `jarsigner`), Android SDK mit
build-tools (`apksigner`) unter `$ANDROID_HOME`, `$ANDROID_SDK_ROOT` oder `~/Android/Sdk`.
Vor dem Build laufen `:app:testDebugUnitTest` und `:app:lint<Mode>`; `--skip-tests` überspringt beide.
Anderes App-Modul: `APP_MODULE=mobile tools/android/build_android.sh …`.

Was das Build-Skript garantiert: `versionCode` schrumpft nie; ein Release-Artefakt trägt genau das
Zertifikat aus dem konfigurierten Keystore (SHA-256-Vergleich), sonst wird es gelöscht; die
`keystore.properties` wird nie als Shell-Code gesourct und muss mode 600 haben (sonst Warnung).

## tools/android/build_android.sh

```bash
#!/usr/bin/env bash
# Build a signed __APP_NAME__ APK, or an AAB for Google Play.
#
# Usage: tools/android/build_android.sh [release|debug] [options]
#   release            signed with your release key (default; see create_keystore.sh)
#   debug              signed with the Android debug key, for quick device testing
#   --aab              build an Android App Bundle (Play Store upload)
#   --version-code N   set the Android versionCode (must grow with every Play upload)
#   --bump             increase the current versionCode by one
#   --version-name X   set the visible version (versionName)
#   --skip-tests       do not run unit tests and lint first
#   --install          install the APK on the connected device via adb afterwards (APK only)
#
# Version lives in version.properties (versionCode/versionName), app/build.gradle.kts reads it.
# Release signing reads storeFile, storePassword and keyAlias from keystore.properties in the project root
# (git-ignored, see keystore.properties.example). Missing values fall back to the environment variables
# __PREFIX___KEYSTORE, __PREFIX___KEYSTORE_PASSWORD and __PREFIX___KEY_ALIAS (for CI); a missing password is
# prompted for. Output goes to dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_FILE="$ROOT/version.properties"
GRADLEW="$ROOT/gradlew"
APP_MODULE="${APP_MODULE:-app}"
SLUG="__SLUG__"
KEYSTORE_PROPERTIES="${__PREFIX___KEYSTORE_PROPERTIES:-$ROOT/keystore.properties}"
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
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# Read one key from a Java-style .properties file (plain key=value lines; never sourced as shell code)
read_property() {
	local file="$1" key="$2"
	[[ -f "$file" ]] || return 0
	sed -n "s/^[[:space:]]*${key}[[:space:]]*[=:][[:space:]]*//p" "$file" | tail -1 | sed 's/[[:space:]]*$//'
}
write_property() {
	local file="$1" key="$2" value="$3"
	if grep -qE "^[[:space:]]*${key}[[:space:]]*[=:]" "$file"; then
		sed -i -E "s|^[[:space:]]*${key}[[:space:]]*[=:].*|$key=$value|" "$file"
	else
		echo "$key=$value" >> "$file"
	fi
}

[[ -x "$GRADLEW" ]] || fail "gradlew not found or not executable in $ROOT"
[[ -f "$VERSION_FILE" ]] || fail "version.properties missing in $ROOT"
[[ "$FORMAT" == "apk" || $INSTALL -eq 0 ]] || fail "--install needs an APK; AABs are installed through Google Play"
BUILD_TOOLS="$(ls -d "$ANDROID_SDK"/build-tools/*/ 2>/dev/null | sort -V | tail -1)"
[[ -n "$BUILD_TOOLS" && -x "${BUILD_TOOLS}apksigner" ]] || fail "apksigner not found in $ANDROID_SDK/build-tools"
APKSIGNER="${BUILD_TOOLS}apksigner"

# ---- version
current_code="$(read_property "$VERSION_FILE" versionCode)"
[[ "$current_code" =~ ^[0-9]+$ ]] || fail "versionCode missing or not a number in $VERSION_FILE"
if [[ $BUMP -eq 1 ]]; then
	VERSION_CODE=$((current_code + 1))
fi
if [[ -n "$VERSION_CODE" ]]; then
	[[ "$VERSION_CODE" =~ ^[0-9]+$ ]] || fail "--version-code must be a number"
	[[ "$VERSION_CODE" -ge "$current_code" ]] || fail "versionCode must not shrink ($current_code -> $VERSION_CODE)"
	write_property "$VERSION_FILE" versionCode "$VERSION_CODE"
else
	VERSION_CODE="$current_code"
fi
if [[ -n "$VERSION_NAME" ]]; then
	write_property "$VERSION_FILE" versionName "$VERSION_NAME"
else
	VERSION_NAME="$(read_property "$VERSION_FILE" versionName)"
	[[ -n "$VERSION_NAME" ]] || fail "versionName missing in $VERSION_FILE"
fi

DIST="$ROOT/dist"
OUT="$DIST/${SLUG}-${VERSION_NAME}-${VERSION_CODE}-${MODE}.${FORMAT}"
mkdir -p "$DIST"

# ---- signing
if [[ "$MODE" == "release" ]]; then
	if [[ -f "$KEYSTORE_PROPERTIES" ]]; then
		perms="$(stat -c '%a' "$KEYSTORE_PROPERTIES")"
		[[ "$perms" =~ 00$ ]] || echo "WARNING: $KEYSTORE_PROPERTIES is readable by others (mode $perms); run: chmod 600 $KEYSTORE_PROPERTIES" >&2
	fi
	# keystore.properties wins, environment variables are the fallback
	store_file="$(read_property "$KEYSTORE_PROPERTIES" storeFile)"
	store_password="$(read_property "$KEYSTORE_PROPERTIES" storePassword)"
	key_alias="$(read_property "$KEYSTORE_PROPERTIES" keyAlias)"
	__PREFIX___KEYSTORE="${store_file:-${__PREFIX___KEYSTORE:-}}"
	__PREFIX___KEYSTORE_PASSWORD="${store_password:-${__PREFIX___KEYSTORE_PASSWORD:-}}"
	__PREFIX___KEY_ALIAS="${key_alias:-${__PREFIX___KEY_ALIAS:-__SLUG__}}"
	__PREFIX___KEYSTORE="${__PREFIX___KEYSTORE/#\~/$HOME}"

	[[ -n "$__PREFIX___KEYSTORE" ]] || fail "No release keystore configured: set storeFile in $KEYSTORE_PROPERTIES (see keystore.properties.example)."
	[[ -f "$__PREFIX___KEYSTORE" ]] || fail "Keystore not found: $__PREFIX___KEYSTORE"
	if [[ -z "$__PREFIX___KEYSTORE_PASSWORD" ]]; then
		[[ -t 0 ]] || fail "No storePassword in $KEYSTORE_PROPERTIES and no terminal to ask for it."
		read -rsp "Keystore password for $__PREFIX___KEYSTORE: " __PREFIX___KEYSTORE_PASSWORD; echo
	fi
	# app/build.gradle.kts reads release signing from these variables (PKCS12: key password = store password)
	export ANDROID_RELEASE_STORE_FILE="$__PREFIX___KEYSTORE"
	export ANDROID_RELEASE_KEY_ALIAS="$__PREFIX___KEY_ALIAS"
	export ANDROID_RELEASE_STORE_PASSWORD="$__PREFIX___KEYSTORE_PASSWORD"
fi

echo "__APP_NAME__ $VERSION_NAME (versionCode $VERSION_CODE), $MODE ${FORMAT^^}"

# ---- tests
if [[ $RUN_TESTS -eq 1 ]]; then
	step "Running unit tests and lint"
	"$GRADLEW" -p "$ROOT" --console=plain -q ":$APP_MODULE:testDebugUnitTest" ":$APP_MODULE:lint${MODE^}" \
		|| fail "tests or lint failed (see Gradle output above)"
fi

# ---- build
Mode="${MODE^}"
if [[ "$FORMAT" == "aab" ]]; then
	task=":$APP_MODULE:bundle$Mode"
	built="$ROOT/$APP_MODULE/build/outputs/bundle/$MODE/$APP_MODULE-$MODE.aab"
else
	task=":$APP_MODULE:assemble$Mode"
	built="$ROOT/$APP_MODULE/build/outputs/apk/$MODE/$APP_MODULE-$MODE.apk"
fi

step "Building $task"
rm -f "$built" "$OUT" "$OUT.idsig"
"$GRADLEW" -p "$ROOT" --console=plain "$task" || fail "Gradle build failed"
[[ -f "$built" ]] || fail "build produced no ${FORMAT^^} at $built"
cp "$built" "$OUT"

# ---- verify
# Fingerprints are compared as lowercase hex without colons; keytool output is forced to English
keytool_en() { keytool -J-Duser.language=en "$@"; }
normalize_fp() { sed -n 's/^.*SHA256: *//p' | head -1 | tr -d ':' | tr 'A-F' 'a-f'; }

step "Verifying signature"
if [[ "$FORMAT" == "apk" ]]; then
	certs="$("$APKSIGNER" verify --verbose --print-certs "$OUT")" || { rm -f "$OUT"; fail "APK signature does not verify (unsigned? check signingConfig in $APP_MODULE/build.gradle.kts)"; }
	echo "$certs" | grep -E "Verified using v[0-9]|certificate DN|certificate SHA-256" | sed 's/^/  /'
	actual="$(echo "$certs" | sed -n 's/^.*certificate SHA-256 digest: *//p' | head -1)"
else
	# App bundles carry a JAR signature; Play re-signs the APKs it generates with the app signing key
	jarsigner -J-Duser.language=en -verify "$OUT" | grep -q "jar verified" || { rm -f "$OUT"; fail "AAB signature does not verify"; }
	certs="$(keytool_en -printcert -jarfile "$OUT")"
	echo "$certs" | grep -E "^Owner:|SHA256:" | head -2 | sed 's/^/  /'
	actual="$(echo "$certs" | normalize_fp)"
fi
if [[ "$MODE" == "release" ]]; then
	# The build must carry exactly the configured release certificate (not the debug key)
	expected="$(keytool_en -list -v -keystore "$__PREFIX___KEYSTORE" -alias "$__PREFIX___KEY_ALIAS" \
		-storepass:env ANDROID_RELEASE_STORE_PASSWORD 2>/dev/null | normalize_fp)"
	if [[ -z "$expected" || "$expected" != "$actual" ]]; then
		rm -f "$OUT"
		fail "${FORMAT^^} is not signed with the release key from $__PREFIX___KEYSTORE"
	fi
	echo "  matches release key $__PREFIX___KEYSTORE"
fi

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"

if [[ $INSTALL -eq 1 ]]; then
	step "Installing on device"
	adb install -r "$OUT"
fi
```

## tools/android/create_keystore.sh

```bash
#!/usr/bin/env bash
# Create the release signing key for __APP_NAME__ (run once, then back the keystore up!).
#
# Usage: tools/android/create_keystore.sh [--keystore PATH] [--alias NAME] [--dname "CN=..., O=..."]
#
# The password is read from __PREFIX___KEYSTORE_PASSWORD or prompted for. The script then writes
# keystore.properties (git-ignored, mode 600) in the project root, which build_android.sh reads.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEYSTORE="${HOME}/.android-keystores/__SLUG__-release.keystore"
ALIAS="__SLUG__"
DNAME="CN=__APP_NAME__, O=__APP_NAME__"
KEYSTORE_PROPERTIES="${__PREFIX___KEYSTORE_PROPERTIES:-${ROOT}/keystore.properties}"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--keystore) KEYSTORE="$2"; shift 2 ;;
		--alias) ALIAS="$2"; shift 2 ;;
		--dname) DNAME="$2"; shift 2 ;;
		-h|--help) sed -n '2,8p' "$0"; exit 0 ;;
		*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done

if [[ -e "$KEYSTORE" ]]; then
	echo "Keystore already exists: $KEYSTORE" >&2
	echo "Refusing to overwrite it - an app signed with it can only be updated with the same key." >&2
	exit 1
fi

if [[ -z "${__PREFIX___KEYSTORE_PASSWORD:-}" ]]; then
	read -rsp "New keystore password (min. 6 characters): " __PREFIX___KEYSTORE_PASSWORD; echo
	read -rsp "Repeat password: " repeat; echo
	if [[ "$__PREFIX___KEYSTORE_PASSWORD" != "$repeat" ]]; then
		echo "Passwords do not match." >&2
		exit 1
	fi
fi
if [[ ${#__PREFIX___KEYSTORE_PASSWORD} -lt 6 ]]; then
	echo "Password must have at least 6 characters." >&2
	exit 1
fi
export __PREFIX___KEYSTORE_PASSWORD

mkdir -p "$(dirname "$KEYSTORE")"
chmod 700 "$(dirname "$KEYSTORE")"

# PKCS12 keystores use one password for store and key; build.gradle.kts relies on that
keytool -genkeypair -v \
	-keystore "$KEYSTORE" -storetype PKCS12 \
	-alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
	-dname "$DNAME" \
	-storepass:env __PREFIX___KEYSTORE_PASSWORD
chmod 600 "$KEYSTORE"

if [[ -e "$KEYSTORE_PROPERTIES" ]]; then
	echo "Keeping existing $KEYSTORE_PROPERTIES - point storeFile/keyAlias at the new keystore yourself."
else
	# Create with restrictive permissions before the password goes in
	(umask 077 && cat > "$KEYSTORE_PROPERTIES" <<PROPS
# Release signing for tools/android/build_android.sh - machine-local, never commit (git-ignored).
storeFile=$KEYSTORE
storePassword=$__PREFIX___KEYSTORE_PASSWORD
keyAlias=$ALIAS
PROPS
	)
fi

echo
echo "Created $KEYSTORE (alias '$ALIAS') and $KEYSTORE_PROPERTIES."
keytool -list -v -keystore "$KEYSTORE" -alias "$ALIAS" -storepass:env __PREFIX___KEYSTORE_PASSWORD | grep -i "SHA256:" || true
echo
echo "IMPORTANT: back up the keystore and its password somewhere safe."
echo "Without them you can never publish an update to an installed / published __APP_NAME__ app."
```