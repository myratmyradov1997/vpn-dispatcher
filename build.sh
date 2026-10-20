#!/usr/bin/env bash
# build.sh — собрать VPNDispatcher.app в локальный ~/Applications (macOS arm64).
# Требования: Xcode Command Line Tools (swiftc).
set -euo pipefail
cd "$(dirname "$0")"

# ВАЖНО: -target задаёт min deployment (LC_BUILD_VERSION.minos). Без него свежие
# Swift-инструменты пишут minos выше текущей macOS → LaunchServices отказывается
# запускать app из Finder с «Данная версия программы не может быть использована
# с этой версией macOS» (прямой запуск бинарника при этом работает).
swiftc -target arm64-apple-macos14.0 main.swift -o VPNDispatcher -framework AppKit

APP="$HOME/Applications/VPNDispatcher.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp VPNDispatcher "$APP/Contents/MacOS/VPNDispatcher"
codesign --force --sign - "$APP"

echo "Собрано: $APP"
echo "Запуск:  open \"$APP\"  (или добавить в автозагрузку LaunchAgent'ом)"
