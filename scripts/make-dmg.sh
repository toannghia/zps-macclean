#!/bin/zsh
# Tạo dist/ZPS-MacClean-<phiên bản>.dmg, kéo app vào Applications để cài.
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build-app.sh

app="dist/ZPS MacClean.app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="dist/ZPS-MacClean-$version.dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "ZPS MacClean" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
echo "Đã tạo: $dmg"
