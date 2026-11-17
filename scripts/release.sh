#!/bin/sh
# Build, sign, verify and publish the version in project.yml as a GitHub release.
# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml first, then commit and push.
#   scripts/release.sh [--dry-run] <release-notes.md>
# --dry-run does everything except creating the GitHub release.
# Needs the "Tone Local Signing" identity (make identity). The in-app updater only
# accepts builds signed by the same certificate as the installed app.
set -eu

cd "$(dirname "$0")/.."
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; shift; fi
NOTES=${1:?usage: scripts/release.sh [--dry-run] <release-notes.md>}
[ -f "$NOTES" ] || { echo "No release notes at $NOTES" >&2; exit 1; }
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\([0-9.]*\)".*/\1/p' project.yml)
TAG="v$VERSION"
REPO=Sowyu/Tone
APP=build/DerivedData/Build/Products/Release/Tone.app
DMG=build/Tone.dmg

[ -n "$VERSION" ] || { echo "MARKETING_VERSION not found in project.yml." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first." >&2; exit 1; }
git fetch -q --tags origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "Push main first." >&2; exit 1; }
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "$TAG is already released. Bump MARKETING_VERSION in project.yml." >&2
    exit 1
fi

make check
rm -rf build/installer "$DMG"
make sign
codesign --verify --deep --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep -q 'certificate leaf = H"' || { echo "Tone.app is not signed with the stable identity." >&2; exit 1; }
[ "$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)" = "$VERSION" ] || { echo "Built app is not $VERSION." >&2; exit 1; }

mkdir build/installer
cp -R "$APP" build/installer/
ln -s /Applications build/installer/Applications
hdiutil create -volname Tone -srcfolder build/installer -format UDZO "$DMG" -quiet
hdiutil verify "$DMG" -quiet

# Ask the current release's own installer code whether it accepts this build,
# then let it install this build over a copy of that release and wait for a healthy start.
PREVIOUS=$(gh release view -R "$REPO" --json tagName --jq .tagName 2>/dev/null || true)
if [ -n "$PREVIOUS" ]; then
    WORK=$(mktemp -d)
    gh release download "$PREVIOUS" -R "$REPO" -p Tone.dmg -D "$WORK"
    MOUNT=$(hdiutil attach -nobrowse -readonly "$WORK/Tone.dmg" | tail -1 | awk -F'\t' '{print $NF}')
    mkdir "$WORK/Apps"
    cp -R "$MOUNT/Tone.app" "$WORK/Apps/Tone.app"
    hdiutil detach -quiet "$MOUNT"
    git show "$PREVIOUS:Tone/Services/Updates.swift" > "$WORK/Updates.swift"
    git show "$PREVIOUS:Tone/Services/UpdateInstaller.swift" > "$WORK/UpdateInstaller.swift"
    cat > "$WORK/e2e.swift" <<SWIFT
import CryptoKit
import Foundation
@main struct EndToEnd { static func main() throws {
    let destination = URL(fileURLWithPath: "$WORK/Apps/Tone.app")
    try UpdateInstaller.validateCandidate(URL(fileURLWithPath: "$PWD/$APP"), version: "$VERSION", matching: destination)
    let copy = URL(fileURLWithPath: "$WORK/Update.dmg")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "$PWD/$DMG"), to: copy)
    let data = try Data(contentsOf: copy)
    let update = AppUpdate(version: "$TAG", downloadURL: URL(string: "https://example.invalid/Tone.dmg")!,
                           sha256: SHA256.hash(data: data).map { String(format: "%02x", \$0) }.joined(), downloadSize: data.count)
    let plan = try UpdateInstaller.prepare(update, image: UpdateInstaller.Image(url: copy), destination: destination,
                                           helperSource: destination.appendingPathComponent("Contents/MacOS/Tone"),
                                           parentPID: getpid())
    try UpdateInstaller.replace(plan)
    guard try UpdateInstaller.appVersion(destination) == "$VERSION" else { throw CocoaError(.fileWriteUnknown) }
}}
SWIFT
    # If the previous release's installer API changed, adapt the harness above rather than skipping it.
    swiftc -parse-as-library "$WORK/Updates.swift" "$WORK/UpdateInstaller.swift" "$WORK/e2e.swift" -o "$WORK/e2e"
    "$WORK/e2e"
    pkill -f "$(basename "$WORK")/Apps/Tone.app" || true
    echo "The $PREVIOUS installer accepts $VERSION, installs it, and $VERSION starts."
    rm -rf "$WORK"
else
    echo "No earlier release on GitHub, so there is no previous installer to test against."
fi

shasum -a 256 "$DMG"
if [ "$DRY_RUN" = 1 ]; then
    echo "Dry run: $DMG is ready. Would run: gh release create $TAG $DMG --title \"Tone $VERSION\" --notes-file $NOTES --latest"
    exit 0
fi
gh release create "$TAG" "$DMG" -R "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Tone $VERSION" --notes-file "$NOTES" --latest
gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[] | "\(.name) \(.size) \(.digest)"'
