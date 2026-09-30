#!/bin/bash
# Builds, signs and packages a fork release into build/fork-release.noindex/out,
# and publishes it as a GitHub release when PUBLISH=1.
#
# CI passes SIGNING_CERT_P12 (base64), SIGNING_CERT_PASSWORD and SPARKLE_PRIVATE_KEY.
# Locally the signing identity comes from the login keychain and the Sparkle key from
# SPARKLE_KEY_FILE; run with UPSTREAM_REF=origin/main when origin is ejbills/DockDoor.
set -euo pipefail

REPO=${GITHUB_REPOSITORY:-DoubleGremlin181/DockDoor}
BUNDLE_ID=io.github.doublegremlin181.DockDoor
UPSTREAM_BUNDLE_ID=com.ethanbills.DockDoor
SIGNING_IDENTITY=${SIGNING_IDENTITY:-A921076DDD13F9B49B211A89DBA5B5FD21652580}
SPARKLE_PUBLIC_KEY=XtQjqGWfsPxT79XvHZB/jNRTnakwvwHNUEEx+uELVqE=
FEED_URL=https://github.com/$REPO/releases/latest/download/appcast.xml

cd "$(git rev-parse --show-toplevel)"
WORK=$PWD/build/fork-release.noindex
DERIVED=$WORK/DerivedData
OUT=$WORK/out
STAGE=$WORK/dmg
APP=$STAGE/DockDoor.app

version_info=$(.github/fork-release/version.sh)
eval "$version_info"

if [[ ${PUBLISH:-0} == 1 ]] && git tag --points-at HEAD | grep -q -- '-fork\.'; then
    echo "HEAD is already released as $(git tag --points-at HEAD | grep -- '-fork\.'); nothing to do."
    exit 0
fi
echo "Building $version (upstream $base + $upstream_ahead commits, previous release: ${previous_tag:-none})"

rm -rf "$OUT" "$STAGE" "$WORK/DockDoor.xcarchive"
mkdir -p "$OUT" "$STAGE"

codesign_args=(--force --sign "$SIGNING_IDENTITY" --options runtime --timestamp=none)
if [[ -n ${SIGNING_CERT_P12:-} ]]; then
    keychain=$WORK/signing.keychain-db
    keychain_password=$(openssl rand -hex 16)
    rm -f "$keychain"
    security create-keychain -p "$keychain_password" "$keychain"
    trap 'security delete-keychain "$keychain"' EXIT
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$keychain_password" "$keychain"
    base64 --decode <<<"$SIGNING_CERT_P12" >"$WORK/signing.p12"
    security import "$WORK/signing.p12" -k "$keychain" -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign
    rm "$WORK/signing.p12"
    curl -fsSL https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$WORK/wwdr.cer"
    security import "$WORK/wwdr.cer" -k "$keychain" || true
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
    # codesign builds the certificate chain from the search list, so the intermediate must be on it
    security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
    codesign_args+=(--keychain "$keychain")
fi

xcodebuild -project DockDoor.xcodeproj -scheme DockDoor -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
    -archivePath "$WORK/DockDoor.xcarchive" \
    -skipMacroValidation -skipPackagePluginValidation -quiet \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    archive
ditto "$WORK/DockDoor.xcarchive/Products/Applications/DockDoor.app" "$APP"

# The fork gets its own identity and update feed so it never installs upstream's builds.
plist=$APP/Contents/Info.plist
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    -c "Set :CFBundleShortVersionString $version" \
    -c "Set :CFBundleVersion $version" \
    -c "Set :SUFeedURL $FEED_URL" \
    -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_KEY" \
    "$plist"
codesign -d --entitlements - --xml "$APP" 2>/dev/null |
    sed "s/${UPSTREAM_BUNDLE_ID//./\\.}/$BUNDLE_ID/g" >"$WORK/entitlements.plist"
plutil -lint -s "$WORK/entitlements.plist"

# Sign nested code inside-out, then the app, all with the same identity.
main_executable=$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist")
while IFS= read -r -d '' path; do
    [[ $path == "$main_executable" ]] && continue
    if [[ -d $path ]]; then
        case $path in *.app | *.appex | *.framework | *.xpc) ;; *) continue ;; esac
    elif [[ $(file -b "$path") != *Mach-O* ]]; then
        continue
    fi
    codesign "${codesign_args[@]}" --preserve-metadata=entitlements "$path"
done < <(find "$APP/Contents" -depth ! -type l \( -type d -o -type f \( -perm -u+x -o -name '*.dylib' \) \) -print0)
codesign "${codesign_args[@]}" --entitlements "$WORK/entitlements.plist" "$APP"

codesign --verify --deep --strict "$APP"
requirement=$(codesign -d -r- "$APP" 2>&1 | grep designated)
if [[ $requirement == *cdhash* ]]; then
    echo "Designated requirement is cdhash-based, so permissions would reset on every update: $requirement" >&2
    exit 1
fi
echo "$requirement"

ln -s /Applications "$STAGE/Applications"
for attempt in 1 2 3; do
    hdiutil create -volname DockDoor -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov -quiet "$OUT/DockDoor.dmg" && break
    [[ $attempt == 3 ]] && exit 1
    sleep 5
done

if [[ -n ${SPARKLE_PRIVATE_KEY:-} ]]; then
    sparkle_key_file=$WORK/sparkle-key
    printf %s "$SPARKLE_PRIVATE_KEY" >"$sparkle_key_file"
else
    sparkle_key_file=${SPARKLE_KEY_FILE:-$HOME/.config/dockdoor-fork-release/sparkle-private-key.txt}
fi
enclosure_signature=$("$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" --ed-key-file "$sparkle_key_file" "$OUT/DockDoor.dmg")
[[ -n ${SPARKLE_PRIVATE_KEY:-} ]] && rm "$sparkle_key_file"

range=${previous_tag:-$upstream_sha}..HEAD
change_count=$(git rev-list --count --first-parent --no-merges "$range")
changes=$(git log -n 40 --first-parent --no-merges --format='%s (%h)' "$range")
upstream_line="Based on upstream DockDoor $base"
((upstream_ahead > 0)) && upstream_line+=" + $upstream_ahead commits"
upstream_line+=" (ejbills/DockDoor@${upstream_sha:0:7})."

{
    echo "$upstream_line"
    echo
    echo "## Changes${previous_tag:+ since $previous_tag}"
    [[ -n $changes ]] && sed 's/^/- /' <<<"$changes"
    ((change_count > 40)) && echo "- …and $((change_count - 40)) more"
    echo
    echo "## Install"
    echo "1. Run \`brew install --cask doublegremlin181/tap/dockdoor-fork\`, or download **DockDoor.dmg** below and drag DockDoor into Applications."
    echo "2. Open it. macOS says it can't verify the app: open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**."
    echo "3. Grant Accessibility and Screen Recording when asked."
    echo
    echo "Later versions install through the app's built-in updater, without step 2."
    echo "This fork has its own bundle ID, so it doesn't share settings or permissions with upstream DockDoor."
} >"$OUT/notes.md"

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
{
    echo "<p>$(html_escape <<<"$upstream_line")</p>"
    if [[ -n $changes ]]; then
        echo "<ul>"
        html_escape <<<"$changes" | sed 's|.*|<li>&</li>|'
        echo "</ul>"
    fi
} >"$WORK/description.html"

cat >"$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>DockDoor (DoubleGremlin181 fork)</title>
        <item>
            <title>$version</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$version</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist")</sparkle:minimumSystemVersion>
            <description><![CDATA[$(cat "$WORK/description.html")]]></description>
            <enclosure url="https://github.com/$REPO/releases/download/$version/DockDoor.dmg" $enclosure_signature type="application/octet-stream" />
        </item>
    </channel>
</rss>
EOF
xmllint --noout "$OUT/appcast.xml"

echo "Packaged $version into $OUT"

if [[ ${PUBLISH:-0} == 1 ]]; then
    gh release create "$version" "$OUT/DockDoor.dmg" "$OUT/appcast.xml" \
        --repo "$REPO" --target "$(git rev-parse HEAD)" --latest \
        --title "DockDoor $version" --notes-file "$OUT/notes.md"
fi
