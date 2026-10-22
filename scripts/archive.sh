#!/bin/zsh
# Archives the app and sends it to Apple to be notarized, from the command line: the same as Xcode's
# Product › Archive and then Organizer › Distribute App › Direct Distribution. Signing uses the developer
# account signed in to Xcode (Developer ID, team UYU5FM4LQ4). Apple takes a few minutes; then
# scripts/make-dmg.sh exports the notarized app from this archive and makes the installer.
#   scripts/archive.sh
set -euo pipefail
cd "${0:A:h}/.."
version=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' ImageViewer.xcodeproj/project.pbxproj | head -1)
archive=~/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/"AOK-ImageTool $version $(date +%H.%M.%S).xcarchive"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
print "Archiving AOK-ImageTool $version…"
xcodebuild -project ImageViewer.xcodeproj -scheme AOK-ImageTool -configuration Release -destination "generic/platform=macOS" \
  -archivePath "$archive" -allowProvisioningUpdates archive >"$scratch/archive.log" 2>&1 || { tail -30 "$scratch/archive.log" >&2; exit 1; }
cat > "$scratch/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>UYU5FM4LQ4</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
print "Sending it to Apple to be notarized…"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$scratch/ExportOptions.plist" \
  -exportPath "$scratch/export" -allowProvisioningUpdates >"$scratch/export.log" 2>&1 || { tail -30 "$scratch/export.log" >&2; exit 1; }
print "Sent: $archive"
print "When Apple has notarized it (usually a few minutes), run scripts/make-dmg.sh."
