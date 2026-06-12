#!/bin/zsh
# Сборка System Control.app
set -e
cd "$(dirname "$0")"

echo "→ swift build (release)"
swift build -c release

APP="dist/System Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/SystemControl "$APP/Contents/MacOS/SystemControl"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Иконка: генерируем один раз, дальше переиспользуем
if [ ! -f Resources/AppIcon.icns ]; then
  echo "→ generating app icon"
  swift scripts/make_icon.swift Resources \
    && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns \
    && rm -rf Resources/AppIcon.iconset \
    || echo "  (icon generation skipped)"
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force -s - "$APP" 2>/dev/null

echo "✓ Built $APP"
echo "  Запуск:    open \"$APP\""
echo "  Установка: cp -R \"$APP\" /Applications/"
