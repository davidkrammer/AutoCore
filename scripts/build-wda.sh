#!/bin/zsh
# Builds and signs WebDriverAgent (touch control on the iPhone) with your
# Apple team, and puts the two archives the app bundles into Resources/:
#   WebDriverAgentProducts.zip  the signed runner for your registered iPhones
#   WebDriverAgentSource.zip    its source, to sign it for an iPhone added later
# Usage: scripts/build-wda.sh <TEAM_ID> [bundle ID prefix]
# Needs Xcode signed in with that team and at least one iPhone registered.
set -euo pipefail
TEAM=${1:?"Usage: scripts/build-wda.sh <TEAM_ID> [bundle ID prefix]"}
PREFIX=${2:-com.example}
VERSION=v16.15.3
ROOT=${0:A:h:h}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git clone --quiet --depth 1 --branch "$VERSION" https://github.com/appium/WebDriverAgent.git "$WORK/src"
rm -rf "$WORK/src/.git"
rm -f "$ROOT/Resources/WebDriverAgentSource.zip" "$ROOT/Resources/WebDriverAgentProducts.zip"
(cd "$WORK/src" && zip -qr "$ROOT/Resources/WebDriverAgentSource.zip" .)

xcodebuild build-for-testing \
    -project "$WORK/src/WebDriverAgent.xcodeproj" -scheme WebDriverAgentRunner -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$WORK/build" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
    PRODUCT_BUNDLE_IDENTIFIER="$PREFIX.autocore.WebDriverAgentRunner" -quiet
(cd "$WORK/build/Build" && zip -qry "$ROOT/Resources/WebDriverAgentProducts.zip" Products)
echo "WebDriverAgent $VERSION is ready in Resources/. Build the app again to bundle it."
