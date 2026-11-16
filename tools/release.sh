#!/usr/bin/env bash
# Eén commando voor een release: bouwt de iOS-app en zet hem op TestFlight
# én in Firebase App Distribution.
#
#   tools/release.sh                      # build +1, beide uploads
#   tools/release.sh --notes "Nieuwe urenregistratie"
#   tools/release.sh --version 1.2.0      # ook het versienummer ophogen
#   tools/release.sh --skip-firebase      # alleen TestFlight
#   tools/release.sh --skip-testflight    # alleen Firebase
#   tools/release.sh --no-checks          # analyze/test overslaan
#   tools/release.sh --reuse-archive      # bestaand archief opnieuw exporteren
#                                         # en uploaden (geen build, geen +1)
#
# Eenmalige instellingen staan in tools/release.env (zie
# tools/release.env.example). Dat bestand komt niet in git.
set -euo pipefail

cd "$(dirname "$0")/.."

NOTES="Nieuwe versie"
NEW_VERSION=""
DO_TESTFLIGHT=1
DO_FIREBASE=1
DO_CHECKS=1
REUSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --version) NEW_VERSION="$2"; shift 2 ;;
    --skip-testflight) DO_TESTFLIGHT=0; shift ;;
    --skip-firebase) DO_FIREBASE=0; shift ;;
    --no-checks) DO_CHECKS=0; shift ;;
    --reuse-archive) REUSE=1; DO_CHECKS=0; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Onbekende optie: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f tools/release.env ]]; then
  echo "tools/release.env ontbreekt. Kopieer tools/release.env.example en vul het in." >&2
  exit 1
fi
# shellcheck disable=SC1091
source tools/release.env

need() { command -v "$1" >/dev/null || { echo "'$1' niet gevonden. $2" >&2; exit 1; }; }
need flutter "Installeer Flutter."
need xcodebuild "Installeer Xcode."
if [[ $DO_FIREBASE -eq 1 ]]; then
  need firebase "Installeer met: npm install -g firebase-tools, en log in met: firebase login"
fi

if [[ $DO_TESTFLIGHT -eq 1 ]]; then
  : "${ASC_KEY_ID:?Zet ASC_KEY_ID in tools/release.env}"
  : "${ASC_ISSUER_ID:?Zet ASC_ISSUER_ID in tools/release.env}"
  if [[ ! -f "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" ]]; then
    echo "Sleutel niet gevonden: ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" >&2
    exit 1
  fi
fi
if [[ $DO_FIREBASE -eq 1 ]]; then
  : "${FIREBASE_APP_ID:?Zet FIREBASE_APP_ID in tools/release.env}"
  : "${FIREBASE_GROUPS:?Zet FIREBASE_GROUPS in tools/release.env}"
fi

if [[ -n "$(git status --porcelain -- lib ios pubspec.yaml 2>/dev/null)" ]]; then
  echo "Let op: er zijn niet-gecommitte wijzigingen. De build bevat ze wel."
  read -r -p "Doorgaan? [j/N] " ok
  [[ "$ok" == "j" || "$ok" == "J" ]] || exit 1
fi

if [[ $DO_CHECKS -eq 1 ]]; then
  echo "==> flutter analyze"
  flutter analyze --no-fatal-infos --no-fatal-warnings
  echo "==> flutter test"
  flutter test
fi

CURRENT=$(grep -E '^version:' pubspec.yaml | awk '{print $2}')
ARCHIEF=build/ios/archive/Runner.xcarchive
if [[ $REUSE -eq 1 ]]; then
  if [[ ! -d "$ARCHIEF" ]]; then
    echo "Geen archief gevonden in $ARCHIEF. Draai eerst zonder --reuse-archive." >&2
    exit 1
  fi
  NEXT="$CURRENT"
  echo "==> Bestaand archief hergebruiken (versie $NEXT)"
else
  # Versie en buildnummer ophogen in pubspec.yaml (formaat 1.1.0+3).
  NAME=${CURRENT%%+*}
  BUILD=${CURRENT##*+}
  [[ -n "$NEW_VERSION" ]] && NAME="$NEW_VERSION"
  NEXT="$NAME+$((BUILD + 1))"
  echo "==> Versie $CURRENT -> $NEXT"
  sed -i '' -E "s/^version:.*/version: $NEXT/" pubspec.yaml

  echo "==> iOS-archief bouwen"
  MARKER=$(mktemp)
  # flutter build ipa maakt eerst het archief en probeert daarna te exporteren.
  # Het exporteren doen we hieronder zelf (met automatische certificaten), dus
  # een fout in die laatste stap van flutter negeren we; het archief controleren
  # we wel.
  flutter build ipa --release \
    --export-options-plist=ios/ExportOptions-appstore.plist || true
  if [[ ! -d "$ARCHIEF" || ! "$ARCHIEF" -nt "$MARKER" ]]; then
    # Archief ouder dan deze run: de build zelf is mislukt.
    echo "Het archief is niet gemaakt. Zie de fouten hierboven." >&2
    rm -f "$MARKER"
    exit 1
  fi
  rm -f "$MARKER"
fi

# Xcode mag profielen zelf bijwerken. Standaard met het Apple ID waarmee je in
# Xcode (Settings > Accounts) bent ingelogd. Heb je een API-sleutel met de rol
# Admin, zet dan EXPORT_MET_API_SLEUTEL=1 in tools/release.env.
AUTH=(-allowProvisioningUpdates)
if [[ "${EXPORT_MET_API_SLEUTEL:-0}" == "1" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  AUTH+=(
    -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

if [[ $DO_TESTFLIGHT -eq 1 ]]; then
  echo "==> Exporteren voor de App Store"
  rm -rf build/ios/ipa-appstore
  xcodebuild -exportArchive \
    -archivePath "$ARCHIEF" \
    -exportOptionsPlist ios/ExportOptions-appstore.plist \
    -exportPath build/ios/ipa-appstore \
    "${AUTH[@]}"
  IPA_STORE=$(ls build/ios/ipa-appstore/*.ipa | head -n 1)
  echo "==> Uploaden naar TestFlight ($IPA_STORE)"
  # ASC_APPLE_ID (het numerieke Apple ID van de app, zie App Store Connect >
  # App-informatie) is optioneel; handig als altool de app niet vindt op
  # bundle-id.
  APPLE_ID_ARGS=()
  [[ -n "${ASC_APPLE_ID:-}" ]] && APPLE_ID_ARGS=(--apple-id "$ASC_APPLE_ID")
  xcrun altool --upload-app --type ios -f "$IPA_STORE" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
    ${APPLE_ID_ARGS[@]+"${APPLE_ID_ARGS[@]}"}
fi

if [[ $DO_FIREBASE -eq 1 ]]; then
  echo "==> Exporteren (ad-hoc) voor Firebase App Distribution"
  rm -rf build/ios/ipa-adhoc
  xcodebuild -exportArchive \
    -archivePath "$ARCHIEF" \
    -exportOptionsPlist ios/ExportOptions-adhoc.plist \
    -exportPath build/ios/ipa-adhoc \
    "${AUTH[@]}"
  IPA_ADHOC=$(ls build/ios/ipa-adhoc/*.ipa | head -n 1)
  echo "==> Uploaden naar Firebase App Distribution ($IPA_ADHOC)"
  firebase appdistribution:distribute "$IPA_ADHOC" \
    --app "$FIREBASE_APP_ID" \
    --groups "$FIREBASE_GROUPS" \
    --release-notes "$NOTES"
fi

echo "==> Klaar: versie $NEXT"
echo "    Vergeet niet de wijziging in pubspec.yaml te committen (en eventueel een tag)."
