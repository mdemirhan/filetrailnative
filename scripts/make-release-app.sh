#!/bin/bash
# Port of apps/desktop/scripts/make-macos-app.sh, without what is about Electron.
# Makes the app people download, under build/release/; see usage below.
set -Eeuo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This script only supports macOS." >&2
    exit 1
fi

DEFAULT_SIGN_CERT="${HOME}/Documents/Apple Developer Certificates/developerID_application.cer"
DEFAULT_NOTARY_PROFILE="filetrail"

usage() {
    cat <<USAGE
Usage: make-release-app.sh [--notarize]

Builds File Trail.app for Apple Silicon under build/release/ and signs it with the Developer ID
Application certificate.

  --notarize  Also have Apple notarize the app, and make a ZIP and a disk image of it to share; the
              disk image is notarized too, and the tickets are stapled. Other Macs open a downloaded
              app only once it is notarized.

The output of the tools each step runs goes to build/release/make-release-app.log; the end of it is
shown when a step fails.

Environment:
  MACOS_SIGN_CERT       The Developer ID Application certificate (.cer). Its private key must be in
                        the keychain. Default:
                        ${DEFAULT_SIGN_CERT}
  MACOS_SIGN_IDENTITY   A keychain identity (name or SHA-1) to sign with instead of the certificate file.
  MACOS_NOTARY_PROFILE  The notarytool keychain profile --notarize uses. Default:
                        ${DEFAULT_NOTARY_PROFILE}. Create it once with:
                        xcrun notarytool store-credentials ${DEFAULT_NOTARY_PROFILE} --apple-id <email>
                          --team-id <team ID> (it asks for an app-specific password)
USAGE
}

NOTARIZE=0
for arg in "$@"; do
    case "${arg}" in
        --notarize) NOTARIZE=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument '${arg}'." >&2
            usage >&2
            exit 1
            ;;
    esac
done
NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-${DEFAULT_NOTARY_PROFILE}}"

# File Trail ships for Apple Silicon only, and the build makes what the machine runs. A shell under Rosetta reports x86_64
# here as well.
ARCH="arm64"
if [[ "$(uname -m)" != "${ARCH}" ]]; then
    echo "File Trail builds for Apple Silicon only. Build on an Apple Silicon Mac, outside Rosetta." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# The signing identity is settled before building, so a missing certificate fails in seconds.
if [[ -n "${MACOS_SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="${MACOS_SIGN_IDENTITY}"
    echo "Signing as: ${SIGN_IDENTITY}"
else
    SIGN_CERT="${MACOS_SIGN_CERT:-${DEFAULT_SIGN_CERT}}"
    if [[ ! -f "${SIGN_CERT}" ]]; then
        echo "Signing certificate not found: ${SIGN_CERT}" >&2
        echo "Set MACOS_SIGN_CERT to the Developer ID Application .cer." >&2
        exit 1
    fi
    SIGN_CERT_SUBJECT="$(openssl x509 -inform der -in "${SIGN_CERT}" -noout -subject)"
    if [[ "${SIGN_CERT_SUBJECT}" != *"Developer ID Application:"* ]]; then
        echo "${SIGN_CERT} is not a Developer ID Application certificate:" >&2
        echo "  ${SIGN_CERT_SUBJECT}" >&2
        exit 1
    fi
    if ! openssl x509 -inform der -in "${SIGN_CERT}" -noout -checkend 0 >/dev/null; then
        echo "The certificate in ${SIGN_CERT} has expired." >&2
        exit 1
    fi
    # codesign takes the certificate's SHA-1 as the identity, which picks this certificate even when the keychain holds
    # others with the same name. The private key never leaves the keychain: the .cer only says which identity to use.
    SIGN_IDENTITY="$(openssl x509 -inform der -in "${SIGN_CERT}" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
    if [[ "$(security find-identity -v -p codesigning)" != *"${SIGN_IDENTITY}"* ]]; then
        if [[ "$(security find-identity -p codesigning)" == *"${SIGN_IDENTITY}"* ]]; then
            echo "The keychain has the Developer ID identity, but macOS does not trust it yet." >&2
            echo "Install Apple's \"Developer ID - G2\" intermediate certificate from" >&2
            echo "https://www.apple.com/certificateauthority/ and run this again." >&2
        else
            echo "The Developer ID identity is not in the keychain." >&2
            echo "Double-click ${SIGN_CERT} to add it to the login keychain. Its private key must be" >&2
            echo "there too: it is made on the Mac that created the certificate signing request." >&2
            echo "On another Mac, import a .p12 exported from that Mac's keychain instead." >&2
        fi
        exit 1
    fi
    SIGN_CERT_NAME="${SIGN_CERT_SUBJECT#*CN=}"
    echo "Signing as: ${SIGN_CERT_NAME%%,*}"
fi

OUT_DIR="${ROOT_DIR}/build/release"
APP_NAME="File Trail"
APP_SLUG="FileTrail"
APP_BUNDLE="${OUT_DIR}/${APP_NAME}.app"
ZIP_PATH="${OUT_DIR}/${APP_SLUG}-${ARCH}.zip"
DMG_PATH="${OUT_DIR}/${APP_SLUG}-${ARCH}.dmg"
ENTITLEMENTS_PLIST="${ROOT_DIR}/Resources/FileTrail.entitlements"

mkdir -p "${OUT_DIR}"
# An older ZIP or disk image must not pass for this build's.
rm -f "${ZIP_PATH}" "${DMG_PATH}"
LOG_FILE="${OUT_DIR}/make-release-app.log"
STEP_COUNT=2
if [[ "${NOTARIZE}" == 1 ]]; then
    STEP_COUNT=5
fi
# shellcheck source=lib/steps.sh
source "${ROOT_DIR}/scripts/lib/steps.sh"

step "Building the app"
run scripts/build-app.sh release --out "${OUT_DIR}"
# The build recorded the version from the release tag on this commit, or else the last release before it (scripts/version.sh).
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :FTVersion" "${APP_BUNDLE}/Contents/Info.plist")"
step_done "${APP_VERSION}"

step "Signing with the Developer ID"
# The hardened runtime and a secure timestamp are both required for notarization. Inside out, as Apple asks (no --deep): the
# bundled fd first, then the app, which seals it.
sign() {
    run codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "$@"
}
sign "${APP_BUNDLE}/Contents/Helpers/fd"
sign --entitlements "${ENTITLEMENTS_PLIST}" "${APP_BUNDLE}"
run codesign --verify --deep --strict "${APP_BUNDLE}"
# Before notarization spctl still refuses the app, but it already names the source: the Developer ID.
ASSESSMENT="$(spctl --assess --type execute -vv "${APP_BUNDLE}" 2>&1 || true)"
echo "${ASSESSMENT}" >>"${LOG_FILE}"
if [[ "${ASSESSMENT}" != *"source="*"Developer ID"* ]]; then
    fail "spctl does not take the app for a Developer ID app:
${ASSESSMENT}"
fi
step_done "signed and verified"

# notarize <file> [<target>]: sends a signed zip or disk image to Apple, waits for the result, and staples the ticket to
# <target> (the file itself when not given).
notarize() {
    local result status id
    RUNNING="notarytool submit $(basename "$1")"
    RUN_LOG_START="$(stat -f %z "${LOG_FILE}")"
    # notarytool's exit status does not say whether Apple accepted the file; the status does.
    result="$(xcrun notarytool submit "$1" --keychain-profile "${NOTARY_PROFILE}" --wait \
        --output-format json 2>>"${LOG_FILE}")" || true
    RUNNING=""
    echo "${result}" >>"${LOG_FILE}"
    status="$(plutil -extract status raw -o - - <<<"${result}" 2>/dev/null)" || status=""
    if [[ -z "${status}" ]]; then
        fail "notarytool could not submit $(basename "$1") with keychain profile '${NOTARY_PROFILE}'." log
    fi
    if [[ "${status}" != "Accepted" ]]; then
        id="$(plutil -extract id raw -o - - <<<"${result}")"
        fail "Apple did not accept $(basename "$1"): ${status}. For the reasons, run:
  xcrun notarytool log ${id} --keychain-profile ${NOTARY_PROFILE}"
    fi
    run xcrun stapler staple "${2:-$1}"
}

# assess_notarized <spctl arguments...>: where Gatekeeper is turned off spctl accepts anything ("override=security disabled"),
# so its verdict alone proves nothing. The source it names does.
assess_notarized() {
    local assessment
    assessment="$(spctl --assess -vv "$@" 2>&1 || true)"
    echo "${assessment}" >>"${LOG_FILE}"
    if [[ "${assessment}" != *": accepted"* || "${assessment}" != *"source=Notarized Developer ID"* ]]; then
        fail "spctl does not take this for a notarized Developer ID build:
${assessment}"
    fi
}

if [[ "${NOTARIZE}" == 1 ]]; then
    step "Notarizing the app (a few minutes)"
    NOTARIZE_ZIP="${OUT_DIR}/${APP_SLUG}-${ARCH}-notarize.zip"
    run ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${NOTARIZE_ZIP}"
    notarize "${NOTARIZE_ZIP}" "${APP_BUNDLE}"
    rm -f "${NOTARIZE_ZIP}"
    assess_notarized --type execute "${APP_BUNDLE}"
    step_done "accepted and stapled"

    # Only a notarized build is shared, so only it gets a ZIP and a disk image.
    step "Building the ZIP and the disk image"
    run ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"
    run hdiutil create -volname "${APP_NAME}" -srcfolder "${APP_BUNDLE}" -ov -format UDZO "${DMG_PATH}"
    # Gatekeeper checks a downloaded disk image before it looks at the app inside.
    run codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
    step_done

    step "Notarizing the disk image (a few minutes)"
    notarize "${DMG_PATH}"
    assess_notarized --type open --context context:primary-signature "${DMG_PATH}"
    step_done "accepted and stapled"
fi

echo
if [[ "${NOTARIZE}" == 1 ]]; then
    echo "Built, signed and notarized: ready to share."
else
    echo "Built and signed, not notarized: other Macs will not open it from a download."
    echo "Use 'scripts/make-release-app.sh --notarize' for a build to share."
fi
echo "  ${APP_BUNDLE} (version ${APP_VERSION})"
if [[ "${NOTARIZE}" == 1 ]]; then
    echo "  ${ZIP_PATH}"
    echo "  ${DMG_PATH}"
fi
