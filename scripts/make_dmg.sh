#!/bin/zsh
# Сборка DMG-инсталлятора System Control.
# Использование: scripts/make_dmg.sh  (предварительно ./build.sh)
set -e
cd "$(dirname "$0")/.."

APP="dist/System Control.app"
VOLNAME="System Control"
[ -d "$APP" ] || { echo "Сначала ./build.sh"; exit 1 }

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
DMG="dist/SystemControl-${VERSION}.dmg"
DMG_RW="dist/.SystemControl-rw.dmg"

# Фон окна (1x + 2x → многодпишный tiff)
if [ ! -f Resources/dmg-background.tiff ]; then
  echo "→ generating dmg background"
  swift scripts/make_dmg_background.swift Resources
  tiffutil -cathidpicheck Resources/dmg-bg.png Resources/dmg-bg@2x.png \
    -out Resources/dmg-background.tiff
  rm -f Resources/dmg-bg.png Resources/dmg-bg@2x.png
fi

echo "→ staging"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"

echo "→ creating writable image"
rm -f "$DMG_RW" "$DMG"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
  -format UDRW -size 64m "$DMG_RW" -quiet
rm -rf "$STAGE"

echo "→ mounting for layout"
MOUNT_DIR="/Volumes/$VOLNAME"
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
hdiutil attach "$DMG_RW" -readwrite -noverify -noautoopen -quiet

# Раскладка окна через Finder (требует разрешения на Automation;
# при отказе DMG останется функциональным, просто без красивой раскладки)
echo "→ applying Finder layout"
osascript <<EOF || echo "  (Finder layout skipped)"
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 104
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "System Control.app" of container window to {165, 195}
    set position of item "Applications" of container window to {495, 195}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
sync

# Иконка тома — ПОСЛЕ Finder-раскладки: его манипуляции с окном
# затирали файл/флаг, если ставить иконку до
if [ -f Resources/AppIcon.icns ]; then
  echo "→ volume icon"
  cp Resources/AppIcon.icns "$MOUNT_DIR/.VolumeIcon.icns"
  SETFILE=$(xcrun -f SetFile 2>/dev/null || true)
  [ -n "$SETFILE" ] && "$SETFILE" -a C "$MOUNT_DIR" || true
  sync
fi

echo "→ compressing"
hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -f "$DMG_RW"
codesign --force -s - "$DMG" 2>/dev/null || true

echo "✓ $DMG"
