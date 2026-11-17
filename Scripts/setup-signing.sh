#!/bin/bash
# 为 TapSnap 创建一个本地自签名的代码签名身份。
#
# 为什么需要它：
#   `codesign --sign -`（ad-hoc）签出来的 designated requirement 是
#   `cdhash H"..."`，也就是把当次二进制的哈希写死。每次重新构建哈希都变，
#   TCC 里「屏幕录制 / 辅助功能」的授权就失效——系统设置里开关还是开的，
#   但程序查到的却是未授权。
#   用固定证书签名后，DR 变成基于证书（identifier + certificate leaf），
#   重建多少次授权都保持有效。
#
# 用法：
#   Scripts/setup-signing.sh          # 创建（已存在则跳过）
#   Scripts/setup-signing.sh --force  # 删掉重建
#
# 证书只装进当前用户的登录钥匙串，不进系统信任库，仅供本机签名使用。
set -euo pipefail

# TapSnap 沿用更名前的本地签名身份，以保持已有系统授权。
IDENTITY="SenSnap Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ "${1:-}" = "--force" ]; then
  echo "==> 删除已有的「$IDENTITY」证书"
  security find-certificate -c "$IDENTITY" -a -Z "$KEYCHAIN" 2>/dev/null \
    | awk '/SHA-1 hash:/ {print $3}' \
    | while read -r sha; do
        security delete-certificate -Z "$sha" "$KEYCHAIN" >/dev/null 2>&1 || true
      done
fi

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "==> 已存在签名身份「$IDENTITY」，跳过创建"
  security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY"
  exit 0
fi

echo "==> 生成自签名证书"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$IDENTITY/O=TapSnap/C=CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

openssl pkcs12 -export \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$IDENTITY" -out "$WORK/identity.p12" -passout pass:sensnap 2>/dev/null

echo "==> 导入登录钥匙串"
# -T 允许 codesign / security 直接使用这把私钥，避免每次签名都弹授权框。
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P sensnap \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild >/dev/null

# 新版 macOS 还需要显式放开 partition list，否则签名时会弹「想要访问密钥」。
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || {
    echo "    提示：放开私钥访问权限失败（通常是因为钥匙串有密码）。"
    echo "    第一次签名时如果弹窗询问，请选择「始终允许」。"
  }

echo
echo "==> 完成。可用身份："
security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY"
echo
echo "现在运行 Scripts/build-app.sh 会用这个身份签名，"
echo "之后重新构建不需要再去系统设置里重新授权。"
