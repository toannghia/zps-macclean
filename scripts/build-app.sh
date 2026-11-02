#!/bin/zsh
# Build bản release và đóng gói thành dist/ZPS MacClean.app.
# Đổi logo hoặc icon thì chạy scripts/make-assets.py trước.
# Thêm --install để chép vào ~/Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
# Build chung cho chip Apple và Intel.
swift build -c release --arch arm64 --arch x86_64

app="dist/ZPS MacClean.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/apple/Products/Release/ZPSMacClean "$app/Contents/MacOS/ZPSMacClean"
cp Assets/AppIcon.icns Assets/logo.png Assets/Fonts/*.ttf "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ZPS MacClean</string>
  <key>CFBundleDisplayName</key><string>ZPS MacClean</string>
  <key>CFBundleIdentifier</key><string>vn.zenpos.macclean</string>
  <key>CFBundleExecutable</key><string>ZPSMacClean</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "Đã tạo: $app"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/ZPS MacClean.app"
  cp -R "$app" "$HOME/Applications/"
  echo "Đã cài: $HOME/Applications/ZPS MacClean.app"
fi
