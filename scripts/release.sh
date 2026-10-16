#!/bin/bash
# Готовит релиз: universal-сборка, подпись Developer ID, нотаризация Apple, DMG.
#
#   scripts/release.sh 1.0.0             — полный релиз (нужны сертификат и профиль нотаризации)
#   scripts/release.sh 1.0.0 --unsigned  — проверка без сертификата: ad-hoc подпись, без нотаризации
#
# Однократная подготовка — см. раздел «Release» в README.md:
#   SIGN_IDENTITY   "Developer ID Application: Имя (TEAMID)" (по умолчанию ищется в связке ключей)
#   NOTARY_PROFILE  имя профиля из `xcrun notarytool store-credentials` (по умолчанию Lidless)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Использование: scripts/release.sh <версия> [--unsigned]}"
UNSIGNED=false
[ "${2:-}" = "--unsigned" ] && UNSIGNED=true
NOTARY_PROFILE="${NOTARY_PROFILE:-Lidless}"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if $UNSIGNED; then
    SIGN_IDENTITY="-"
elif [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
    if [ -z "$SIGN_IDENTITY" ]; then
        echo "Нет сертификата «Developer ID Application» в связке ключей." >&2
        echo "Создайте его (README → «Release») или запустите с --unsigned для проверки." >&2
        exit 1
    fi
fi
echo "==> Подпись: $SIGN_IDENTITY"

notarize() {
    echo "==> Нотаризация $(basename "$1")…"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

echo "==> Сборка $VERSION"
VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh
APP=build/Lidless.app

if ! $UNSIGNED; then
    # Приложение нотаризуем отдельно, чтобы скрепить билет с ним самим: тогда оно
    # открывается без сети, даже если пользователь скопирует его куда-то из DMG.
    ZIP="$(mktemp -d)/Lidless.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    xcrun stapler staple "$APP"
    rm -rf "$(dirname "$ZIP")"
fi

mkdir -p dist
DMG="dist/Lidless-$VERSION.dmg"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Lidless $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"

if ! $UNSIGNED; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    echo "==> Проверка Gatekeeper"
    spctl --assess --type execute --verbose "$APP"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

# Копия без версии — для постоянной ссылки «Скачать».
cp "$DMG" dist/Lidless.dmg

echo "==> Готово: $(pwd)/$DMG (и dist/Lidless.dmg)"
shasum -a 256 "$DMG"
