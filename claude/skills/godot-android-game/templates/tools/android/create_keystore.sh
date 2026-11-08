#!/usr/bin/env bash
# Create the release signing key for __NAME__ (run once, then back the keystore up!).
#
# Usage: tools/android/create_keystore.sh [--keystore PATH] [--alias NAME] [--dname "CN=..., O=..."]
#
# The password is read from __ENV___KEYSTORE_PASSWORD or prompted for. The script then writes
# keystore.properties (git-ignored, mode 600) in the project root, which build_android.sh reads.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEYSTORE="${HOME}/.android-keystores/__SLUG__-release.keystore"
ALIAS="__SLUG__"
DNAME="CN=__NAME__, O=__NAME__"
KEYSTORE_PROPERTIES="${__ENV___KEYSTORE_PROPERTIES:-${ROOT}/keystore.properties}"

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

if [[ -z "${__ENV___KEYSTORE_PASSWORD:-}" ]]; then
	read -rsp "New keystore password (min. 6 characters): " __ENV___KEYSTORE_PASSWORD; echo
	read -rsp "Repeat password: " repeat; echo
	if [[ "$__ENV___KEYSTORE_PASSWORD" != "$repeat" ]]; then
		echo "Passwords do not match." >&2
		exit 1
	fi
fi
if [[ ${#__ENV___KEYSTORE_PASSWORD} -lt 6 ]]; then
	echo "Password must have at least 6 characters." >&2
	exit 1
fi
export __ENV___KEYSTORE_PASSWORD

mkdir -p "$(dirname "$KEYSTORE")"
chmod 700 "$(dirname "$KEYSTORE")"

# PKCS12 keystores use one password for store and key, which is what Godot expects
keytool -genkeypair -v \
	-keystore "$KEYSTORE" -storetype PKCS12 \
	-alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
	-dname "$DNAME" \
	-storepass:env __ENV___KEYSTORE_PASSWORD
chmod 600 "$KEYSTORE"

if [[ -e "$KEYSTORE_PROPERTIES" ]]; then
	echo "Keeping existing $KEYSTORE_PROPERTIES - point storeFile/keyAlias at the new keystore yourself."
else
	# Create with restrictive permissions before the password goes in
	(umask 077 && cat > "$KEYSTORE_PROPERTIES" <<EOF
# Release signing for tools/android/build_android.sh - machine-local, never commit (git-ignored).
storeFile=$KEYSTORE
storePassword=$__ENV___KEYSTORE_PASSWORD
keyAlias=$ALIAS
EOF
	)
fi

echo
echo "Created $KEYSTORE (alias '$ALIAS') and $KEYSTORE_PROPERTIES."
keytool -list -keystore "$KEYSTORE" -alias "$ALIAS" -storepass:env __ENV___KEYSTORE_PASSWORD | grep -i "SHA-256" || true
echo
echo "IMPORTANT: back up the keystore and its password somewhere safe."
echo "Without them you can never publish an update to an installed / published __NAME__ app."
