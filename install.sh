#!/bin/bash
# Installs or updates DockDoor (DoubleGremlin181's Space Switcher fork) from the latest release:
#   curl -fsSL https://raw.githubusercontent.com/DoubleGremlin181/DockDoor/HEAD/install.sh | bash
# The build is signed but not notarized. curl downloads aren't quarantined, so Gatekeeper
# doesn't block the first launch; the signature is checked against the fork's team instead.
set -euo pipefail

REPO=DoubleGremlin181/DockDoor
BUNDLE_ID=io.github.doublegremlin181.DockDoor
TEAM_ID=MJNX467U93
APP_DIR=${DOCKDOOR_APP_DIR:-/Applications}

fail() {
    echo "Error: $*" >&2
    exit 1
}

[[ $(uname -s) == Darwin ]] || fail "DockDoor only runs on macOS."
(($(sw_vers -productVersion | cut -d. -f1) >= 13)) || fail "DockDoor needs macOS 13 or later."
if [[ ! -w $APP_DIR ]]; then
    APP_DIR=$HOME/Applications
    mkdir -p "$APP_DIR"
fi
target=$APP_DIR/DockDoor.app

if [[ -d $target ]]; then
    installed_id=$(defaults read "$target/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
    [[ $installed_id == "$BUNDLE_ID" ]] ||
        fail "$target is a different DockDoor ($installed_id). Quit and remove it first; the fork can't share its location."
fi

work=$(mktemp -d)
mountpoint=$work/mount
cleanup() {
    hdiutil detach -quiet "$mountpoint" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

echo "Downloading the latest DockDoor fork release…"
curl -fL --progress-bar -o "$work/DockDoor.dmg" "https://github.com/$REPO/releases/latest/download/DockDoor.dmg"
mkdir "$mountpoint"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mountpoint" "$work/DockDoor.dmg"

app=$mountpoint/DockDoor.app
[[ $(defaults read "$app/Contents/Info" CFBundleIdentifier) == "$BUNDLE_ID" ]] || fail "The download isn't the DockDoor fork."
codesign --verify --deep --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" "$app" ||
    fail "The download's code signature doesn't match the fork's signing team."
version=$(defaults read "$app/Contents/Info" CFBundleShortVersionString)

was_running=false
if pgrep -f "$target/Contents/MacOS/" >/dev/null; then
    was_running=true
    echo "Quitting the running DockDoor…"
    pkill -f "$target/Contents/MacOS/" || true
    sleep 1
fi

echo "Installing DockDoor $version into $APP_DIR…"
rm -rf "$target"
ditto "$app" "$target"
xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

echo "Installed DockDoor $version."
if [[ -z ${DOCKDOOR_NO_OPEN:-} ]]; then
    open "$target"
    $was_running || echo "Grant Accessibility and Screen Recording when DockDoor asks. It updates itself from now on."
fi
