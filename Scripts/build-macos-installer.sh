#!/bin/bash
# Package an existing TapSnap.app as a macOS Installer product archive.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage  $0 TapSnap.app TapSnap.pkg" >&2
    exit 2
fi

app=$1
output=$2
plist="$app/Contents/Info.plist"
identity=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist")
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist")
minimum=$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$plist")
architectures=$(/usr/bin/lipo -archs "$app/Contents/MacOS/TapSnap" | tr ' ' ',')
package_id="$identity.installer"

case "$identity" in
    com.sensnap.app|com.sensnap.app.company) ;;
    *) echo "Unexpected TapSnap bundle identifier $identity" >&2; exit 2 ;;
esac
install_location=/Applications

/usr/bin/codesign --verify --deep --strict "$app"
stage=$(mktemp -d "${TMPDIR:-/tmp}/tapsnap-installer.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/payload" "$stage/resources"
/usr/bin/ditto "$app" "$stage/payload/TapSnap.app"

cat > "$stage/resources/conclusion.html" <<HTML
<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<p>在访达侧栏打开「应用程序」，按下列路径找到 TapSnap。</p>
<p><code>$install_location/TapSnap.app</code></p>
</html>
HTML

cat > "$stage/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>RootRelativeBundlePath</key>
        <string>TapSnap.app</string>
        <key>BundleIsRelocatable</key>
        <false/>
        <key>BundleHasStrictIdentifier</key>
        <true/>
        <key>BundleIsVersionChecked</key>
        <true/>
        <key>BundleOverwriteAction</key>
        <string>upgrade</string>
    </dict>
</array>
</plist>
PLIST

/usr/bin/pkgbuild --root "$stage/payload" --component-plist "$stage/components.plist" \
    --install-location "$install_location" --identifier "$package_id" --version "$version" \
    "$stage/TapSnapComponent.pkg"

cat > "$stage/Distribution" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
    <title>TapSnap</title>
    <options customize="never" require-scripts="false" hostArchitectures="$architectures"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <volume-check>
        <allowed-os-versions><os-version min="$minimum"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="app"/></choices-outline>
    <choice id="app" title="TapSnap" visible="false"><pkg-ref id="$package_id"/></choice>
    <pkg-ref id="$package_id">TapSnapComponent.pkg</pkg-ref>
</installer-gui-script>
XML

/usr/bin/productbuild --distribution "$stage/Distribution" --package-path "$stage" \
    --resources "$stage/resources" "$output"
