#!/bin/bash
# Rebuild only Sparkle's Downloader XPC executable with TapSnap's session configuration.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
service="$1"
shift # The remaining arguments are the signing identity and optional --keychain.
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$service/Contents/Info.plist")
archive="$root/Vendor/Sparkle/Downloader-$version.tar.gz"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
tar -xzf "$archive"
patch -s -p1 < "$root/Vendor/Sparkle/update-session.patch"

network="$root/Sources/TapSnapUpdateNetwork"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -Os -fobjc-arc \
    -IDownloader -ISparkle -IAutoupdate -I"$network/include" \
    -DBUILDING_SPARKLE_SOURCES_EXTERNALLY=1 -DSPARKLE_BUNDLE_IDENTIFIER='"org.sparkle-project.Sparkle"' \
    '-DSPU_OBJC_DIRECT=__attribute__((objc_direct))' '-DSPU_OBJC_DIRECT_MEMBERS=__attribute__((objc_direct_members))' \
    Downloader/main.m Downloader/SPUDownloader.m Autoupdate/SUCodeSigningVerifier.m \
    Sparkle/{SPUDownloadData,SPULocalCacheDirectory,SUConstants,SULog}.m "$network/TSUpdateURLProtocol.m" \
    -framework Foundation -framework Security -framework CFNetwork -o DownloaderService

codesign --display --entitlements - --xml "$service" > entitlements.plist
install -m 755 DownloaderService "$service/Contents/MacOS/Downloader"
codesign --force --sign "$@" --options runtime --entitlements entitlements.plist "$service"
