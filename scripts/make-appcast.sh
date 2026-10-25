#!/bin/bash
# Печатает ленту обновлений Sparkle (appcast.xml) для одного релиза.
#
#   scripts/make-appcast.sh dist/Lidless-0.4.0.dmg 0.4.0 120 > dist/appcast.xml
#
# DMG подписывается ключом EdDSA из связки ключей (sign_update из Sparkle, учётная запись «lidless»:
# у ochre свой ключ под именем по умолчанию). Файл прикрепляется к релизу на GitHub рядом с DMG:
# приложение читает его по ссылке releases/latest/download/appcast.xml.
#   DOWNLOAD_BASE  откуда качать DMG (по умолчанию релиз на GitHub); для локальной проверки,
#                  например DOWNLOAD_BASE=http://127.0.0.1:8000
#   SIGN_UPDATE    путь к sign_update (по умолчанию ищется в SwiftPM-артефактах Sparkle)
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:?Использование: scripts/make-appcast.sh <dmg> <версия> <номер сборки>}"
VERSION="${2:?нет версии}"
BUILD="${3:?нет номера сборки}"

REPO=https://github.com/aesarva/lidless
DOWNLOAD_BASE="${DOWNLOAD_BASE:-$REPO/releases/download/v$VERSION}"

SIGN_UPDATE="${SIGN_UPDATE:-$(find build/DerivedData/SourcePackages/artifacts -type f \
    -path '*/Sparkle/bin/sign_update' -not -path '*/old_dsa_scripts/*' 2>/dev/null | head -1 || true)}"
if [ -z "$SIGN_UPDATE" ] || [ ! -x "$SIGN_UPDATE" ]; then
    echo "Нет sign_update: сначала make app (Sparkle подтягивается как SwiftPM-артефакт)." >&2
    exit 1
fi
# Печатает атрибуты sparkle:edSignature="…" length="…" для <enclosure>.
SIG_ATTRS="$("$SIGN_UPDATE" --account lidless "$DMG")"
if [ -z "$SIG_ATTRS" ]; then
    echo "sign_update не вернул подпись для $DMG." >&2
    exit 1
fi

PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"

# Без releaseNotesLink: заметки не скачиваются; <link> элемента — страница релиза.
cat <<EOT
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Lidless</title>
    <link>$REPO</link>
    <item>
      <title>Lidless $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <link>$REPO/releases/tag/v$VERSION</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$DOWNLOAD_BASE/Lidless-$VERSION.dmg" type="application/octet-stream" $SIG_ATTRS/>
    </item>
  </channel>
</rss>
EOT
