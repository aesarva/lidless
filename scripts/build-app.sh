#!/bin/bash
# Собирает build/Lidless.app (Release).
#   ARCHS          архитектуры (по умолчанию "arm64 x86_64" — universal)
#   VERSION        версия для CFBundleShortVersionString (по умолчанию — MARKETING_VERSION из project.yml)
#   SIGN_IDENTITY  сертификат подписи, например "Developer ID Application: Имя (TEAMID)";
#                  по умолчанию "-" — подпись ad-hoc для локального запуска
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# Номер сборки растёт с каждым коммитом — macOS сравнивает версии по нему.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

XCODE_ARGS=(
    -project Lidless.xcodeproj -scheme Lidless -configuration Release
    -derivedDataPath build/DerivedData
    ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)
if [ -n "${VERSION:-}" ]; then XCODE_ARGS+=(MARKETING_VERSION="$VERSION"); fi

xcodegen generate --quiet
xcodebuild "${XCODE_ARGS[@]}" build -quiet

APP=build/Lidless.app
rm -rf "$APP"
ditto build/DerivedData/Build/Products/Release/Lidless.app "$APP"

# Переподписываем готовый бандл нужным сертификатом. Hardened runtime обязателен
# для нотаризации; включаем его и в ad-hoc сборке, чтобы локально проверять
# то же поведение, что получат пользователи.
SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then SIGN_FLAGS+=(--timestamp); fi
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict "$APP"
echo "$(pwd)/$APP"
