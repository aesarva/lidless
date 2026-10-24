#!/bin/bash
# Готовит релиз: universal-сборка, подпись Developer ID, нотаризация Apple, DMG.
#
#   scripts/release.sh 1.0.0             — полный релиз (нужны сертификат и профиль нотаризации)
#   scripts/release.sh 1.0.0 --unsigned  — проверка без сертификата: ad-hoc подпись, без нотаризации
#
# Однократная подготовка — см. раздел «Releases» в CONTRIBUTING.md:
#   SIGN_IDENTITY   "Developer ID Application: Имя (TEAMID)" (по умолчанию ищется в связке ключей)
#   NOTARY_PROFILE  имя профиля из `xcrun notarytool store-credentials` (по умолчанию Lidless)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Использование: scripts/release.sh <версия> [--unsigned]}"
UNSIGNED=false
[ "${2:-}" = "--unsigned" ] && UNSIGNED=true
NOTARY_PROFILE="${NOTARY_PROFILE:-Lidless}"

# Лента от прошлого запуска не должна пережить новую сборку той же версии, даже если эта упадёт.
rm -f dist/appcast.xml

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if $UNSIGNED; then
    SIGN_IDENTITY="-"
elif grep -q LIDLESS_SPARKLE_PUBLIC_KEY_PLACEHOLDER App/Resources/Info.plist; then
    # Подписанный релиз без настоящего ключа обновлений выпустил бы приложение, которое не примет ни одной ленты.
    echo "В App/Resources/Info.plist всё ещё заглушка SUPublicEDKey." >&2
    echo "Создайте ключ (generate_keys --account lidless, CONTRIBUTING → «Releases») и впишите публичную часть." >&2
    exit 1
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
    spctl --assess --type execute --verbose "$APP" || { echo "spctl не принял приложение." >&2; exit 1; }
    spctl --assess --type open --context context:primary-signature --verbose "$DMG" \
        || { echo "spctl не принял DMG." >&2; exit 1; }

    # Лента только для подписанного релиза. Sparkle сверяет EdDSA, а «только наша команда»
    # гарантирует этот шаг: приложение, демон и Sparkle должны быть подписаны Team ID разработчика.
    TEAM_ID=6H45P75YYV
    echo "==> Проверка подписей перед лентой"
    for target in "$APP" "$APP/Contents/MacOS/LidlessHelper" "$APP/Contents/Frameworks/Sparkle.framework"; do
        SIG_INFO="$(codesign -dv "$target" 2>&1 || true)"
        if ! grep -q "^TeamIdentifier=$TEAM_ID\$" <<<"$SIG_INFO"; then
            echo "$target не подписан Team ID $TEAM_ID — ленту не создаю." >&2
            exit 1
        fi
    done
    echo "==> Лента обновлений"
    BUILD_NUMBER="$(git rev-list --count HEAD)"
    scripts/make-appcast.sh "$DMG" "$VERSION" "$BUILD_NUMBER" > dist/appcast.xml \
        || { rm -f dist/appcast.xml; exit 1; }
    xmllint --noout dist/appcast.xml
fi

# Копия без версии — для постоянной ссылки «Скачать».
cp "$DMG" dist/Lidless.dmg

echo "==> Готово: $(pwd)/$DMG (и dist/Lidless.dmg)"
if ! $UNSIGNED; then echo "    К релизу прикрепите ещё $(pwd)/dist/appcast.xml"; fi
shasum -a 256 "$DMG"
