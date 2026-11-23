#!/bin/bash
# 把 SPM 产物打包成可双击运行的 TapSnap.app。
#
# 用法：
#   Scripts/build-app.sh           # release 构建 + 打包 + 本机签名
#   Scripts/build-app.sh debug     # debug 构建
#   TAPSNAP_ALLOW_ADHOC_SIGNING=1 仅用于不保留系统授权的临时测试包。
#   TAPSNAP_VERSION 和 TAPSNAP_BUILD_NUMBER 可覆盖安装包中的版本号。
#   同时设置 TAPSNAP_UPDATE_FEED_URL 和 TAPSNAP_UPDATE_PUBLIC_KEY 可启用更新。
#   TAPSNAP_MAC_SIGNING_SHA1 指定签名证书指纹，TAPSNAP_MAC_SIGNING_KEYCHAIN 可指定钥匙串。
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UPDATE_FEED="${TAPSNAP_UPDATE_FEED_URL:-}"
UPDATE_KEY="${TAPSNAP_UPDATE_PUBLIC_KEY:-}"
if { [[ -n "$UPDATE_FEED" ]] && [[ -z "$UPDATE_KEY" ]]; } || { [[ -z "$UPDATE_FEED" ]] && [[ -n "$UPDATE_KEY" ]]; }; then
  echo "TAPSNAP_UPDATE_FEED_URL 和 TAPSNAP_UPDATE_PUBLIC_KEY 必须同时设置。" >&2
  exit 1
fi

LOOPBACK_FEED='^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/[^[:space:]]*)?$'
if [[ -n "$UPDATE_FEED" && "$UPDATE_FEED" != https://* && ! "$UPDATE_FEED" =~ $LOOPBACK_FEED ]]; then
  echo "更新地址需使用 HTTPS，本机回环地址可使用 HTTP。" >&2
  exit 1
fi

KEYCHAIN="${TAPSNAP_MAC_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
IDENTITY="${TAPSNAP_MAC_SIGNING_SHA1:-}"
if [[ -n "$IDENTITY" ]]; then
  if ! [[ "$IDENTITY" =~ ^[[:xdigit:]]{40}$ ]] || ! security find-identity -p codesigning "$KEYCHAIN" |
      awk -v pin="$IDENTITY" 'toupper($2) == toupper(pin) { found = 1 } END { exit !found }'; then
    echo "找不到指定的 macOS 代码签名身份，请核对证书指纹及对应的私钥。" >&2
    exit 1
  fi
elif security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q '"SenSnap Local"'; then
  IDENTITY="SenSnap Local"
elif [[ "${TAPSNAP_ALLOW_ADHOC_SIGNING:-0}" == 1 ]]; then
  IDENTITY=-
else
  echo "构建 TapSnap.app 需要固定签名。首次在本机开发请运行 Scripts/setup-signing.sh；分发更新请使用原签名证书（TAPSNAP_MAC_SIGNING_SHA1）。" >&2
  exit 1
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/dist/TapSnap.app"
PLIST="$APP/Contents/Info.plist"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/TapSnap" "$APP/Contents/MacOS/TapSnap"
cp "$ROOT/Resources/Info.plist" "$PLIST"
ditto "$BIN_DIR/Sparkle.framework" "$SPARKLE"

if [[ -n "${TAPSNAP_VERSION:-}" ]]; then
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$TAPSNAP_VERSION" "$PLIST"
fi
if [[ -n "${TAPSNAP_BUILD_NUMBER:-}" ]]; then
  /usr/bin/plutil -replace CFBundleVersion -string "$TAPSNAP_BUILD_NUMBER" "$PLIST"
fi
if [[ -n "$UPDATE_FEED" ]]; then
  /usr/bin/plutil -insert SUFeedURL -string "$UPDATE_FEED" "$PLIST"
  /usr/bin/plutil -insert SUPublicEDKey -string "$UPDATE_KEY" "$PLIST"
  if [[ "$UPDATE_FEED" =~ $LOOPBACK_FEED ]]; then
    /usr/bin/plutil -insert NSAppTransportSecurity -xml '<dict><key>NSAllowsLocalNetworking</key><true/></dict>' "$PLIST"
  else
    /usr/bin/plutil -insert SUEnableDownloaderService -bool true "$PLIST"
  fi
fi

cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/Resources/formula-requirements.txt" "$ROOT/Resources/formula-models.json" "$ROOT/Resources/verify_formula_models.py" "$APP/Contents/Resources/"
cp "$ROOT/Scripts/setup-formula.sh" "$APP/Contents/Resources/setup-formula.sh"
chmod +x "$APP/Contents/Resources/setup-formula.sh"
cp "$ROOT/Scripts/setup-formula.sh" "$ROOT/dist/Install Formula.command"
chmod +x "$ROOT/dist/Install Formula.command"
cp -R "$ROOT/Resources/KaTeX" "$APP/Contents/Resources/"
cp "$ROOT/Vendor/WebP/COPYING" "$APP/Contents/Resources/WebP-LICENSE"
cp "$ROOT/Vendor/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"
if [ -f "$ROOT/Resources/formula_recognize.py" ]; then
  cp "$ROOT/Resources/formula_recognize.py" "$APP/Contents/Resources/"
fi
printf 'APPL????'  > "$APP/Contents/PkgInfo"

# 语言资源（当前只有 zh_CN 的本地化占位，若存在则拷进去）
if [ -d "$ROOT/Resources/Localizable" ]; then
  cp -R "$ROOT/Resources/Localizable" "$APP/Contents/Resources/"
fi

echo "==> 签名 ($IDENTITY)"
SIGNER=("$IDENTITY")
if [[ "$IDENTITY" == - ]]; then
  echo "    临时签名的构建可能需要重新授权。本机开发可用 Scripts/setup-signing.sh 配置固定身份。"
else
  SIGNER+=(--keychain "$KEYCHAIN")
fi

# 由内向外签名，保留 Sparkle 下载服务的权限与辅助程序的 Hardened Runtime。
SPARKLE_VERSION="$SPARKLE/Versions/Current"
codesign --force --sign "${SIGNER[@]}" --options runtime "$SPARKLE_VERSION/XPCServices/Installer.xpc"
bash "$ROOT/Scripts/build-update-downloader.sh" "$SPARKLE_VERSION/XPCServices/Downloader.xpc" "${SIGNER[@]}"
codesign --force --sign "${SIGNER[@]}" --options runtime "$SPARKLE_VERSION/Autoupdate"
codesign --force --sign "${SIGNER[@]}" --options runtime "$SPARKLE_VERSION/Updater.app"
codesign --force --sign "${SIGNER[@]}" --options runtime "$SPARKLE"
codesign --force --sign "${SIGNER[@]}" "$APP"
if [[ -n "${TAPSNAP_MAC_SIGNING_SHA1:-}" ]]; then
  codesign --verify --strict -R "=identifier \"com.sensnap.app\" and certificate leaf = H\"$IDENTITY\"" "$APP"
fi

echo "==> 完成：$APP"
echo "    运行：open \"$APP\""
