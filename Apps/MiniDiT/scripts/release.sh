#!/bin/sh
# 打一个可以发给别人的 MiniDiT：Developer ID 签名 → 公证 → 钉上公证结果 → DMG（DMG 也公证）→ 自动更新清单。
#
# 需要（登录钥匙串里，只做一次）：
#   · Developer ID Application 证书：不用事先建，导出时 Xcode 用已登录的账号自动申请（-allowProvisioningUpdates）
#   · 公证凭据：xcrun notarytool store-credentials minidit-notary --team-id HGXZB3UC25 --keychain ~/Library/Keychains/login.keychain-db
#     （按提示粘贴 appleid.apple.com 生成的 App 专用密码；脚本只用 minidit-notary 这个名字。）
#   · Sparkle 更新签名私钥：Sparkle 的 generate_keys 生成，公钥写在 Apps/MiniDiT/Info.plist
#
# 用法：
#   sh release.sh            版本号用工程里的 MARKETING_VERSION
#   VERSION=0.2 sh release.sh
#   NOTARIZE=0 sh release.sh 只签名打包，不公证（先检查签名用）
#   BUILD=42 sh release.sh   指定构建号（默认取提交数；没有 .git 时用日期时间）
# 结果在 Apps/MiniDiT/build/release：MiniDiT-<版本>.dmg、appcast.xml。之后用 publish-release.sh 发布。
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$DIR/build/release"
PROFILE=minidit-notary
# 公证凭据明确存在登录钥匙串文件里（不指定时 notarytool 的默认位置不好查，出过找不到的情况）。
NOTARY_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TEAM=HGXZB3UC25
IDENTITY="Developer ID Application"
cd "$DIR"

step() { echo "== $*"; }

# Developer ID 证书不必事先建：导出时用自动签名加 -allowProvisioningUpdates，
# Xcode 会用已登录的开发者账号申请一张并存进钥匙串（之后复用）。
if [ "${NOTARIZE:-1}" = 1 ]; then
    xcrun notarytool history --keychain-profile "$PROFILE" --keychain "$NOTARY_KEYCHAIN" >/dev/null 2>&1 || {
        echo "error: 没有找到公证凭据 $PROFILE。请先运行 xcrun notarytool store-credentials $PROFILE --team-id $TEAM --keychain $NOTARY_KEYCHAIN"
        exit 1
    }
fi

VERSION=${VERSION:-$(xcodebuild -project MiniDiT.xcodeproj -scheme MiniDiT -configuration Release -showBuildSettings 2>/dev/null | awk '/ MARKETING_VERSION =/ { print $3; exit }')}
# 构建号：仓库提交数（没有 .git 时用日期时间），每次发布单调递增。
BUILD=${BUILD:-$(git -C "$DIR" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)}
rm -rf "$OUT"; mkdir -p "$OUT"

step "编译打包 $VERSION ($BUILD)"
xcodebuild -project MiniDiT.xcodeproj -scheme MiniDiT -configuration Release \
    -derivedDataPath build/release-dd -archivePath "$OUT/MiniDiT.xcarchive" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    archive

# 打包时仍用开发证书；导出这一步按 Developer ID 重新签名（带安全时间戳）。
step "导出（Developer ID）"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$OUT/MiniDiT.xcarchive" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates
APP="$OUT/export/MiniDiT.app"

step "检查签名"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" >/dev/null
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID|flags=.*runtime|TeamIdentifier" || {
    echo "error: 签名不是 Developer ID 或没有开强化运行时"; exit 1; }

notarize() {
    step "公证 $(basename "$1")（一般几分钟）"
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --keychain "$NOTARY_KEYCHAIN" --wait --output-format plist > "$OUT/notary.plist"
    STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$OUT/notary.plist")
    ID=$(/usr/libexec/PlistBuddy -c "Print :id" "$OUT/notary.plist")
    echo "status: $STATUS ($ID)"
    if [ "$STATUS" != Accepted ]; then
        xcrun notarytool log "$ID" --keychain-profile "$PROFILE" --keychain "$NOTARY_KEYCHAIN"
        exit 1
    fi
}

if [ "${NOTARIZE:-1}" = 1 ]; then
    ditto -c -k --keepParent "$APP" "$OUT/MiniDiT.zip"
    notarize "$OUT/MiniDiT.zip"
    step "钉上公证结果（App）"
    xcrun stapler staple "$APP"
    rm "$OUT/MiniDiT.zip"
fi

step "制作 DMG"
DMG="$OUT/MiniDiT-$VERSION.dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MiniDiT.app"
ln -s /Applications "$STAGE/应用程序"
hdiutil create -volname "MiniDiT $VERSION" -srcfolder "$STAGE" -format UDZO -fs HFS+ -ov "$DMG" >/dev/null
rm -rf "$STAGE"
# Xcode 自动申请的是云端管理的证书（私钥在 Apple 那边），本机钥匙串里没有可用的身份，DMG 就不单独签名：
# 里面的 App 已签名，DMG 公证并钉上结果后，Gatekeeper 照样放行。钥匙串里有本地证书时再签。
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --sign "$IDENTITY" --timestamp "$DMG"
else
    echo "（本机没有 Developer ID 私钥，DMG 不单独签名）"
fi

if [ "${NOTARIZE:-1}" = 1 ]; then
    notarize "$DMG"
    step "钉上公证结果（DMG）"
    xcrun stapler staple "$DMG"
    step "Gatekeeper 检查"
    spctl -a -vv -t exec "$APP"
    xcrun stapler validate "$DMG"
fi

step "自动更新清单（appcast.xml）"
# 用登录钥匙串里的 Sparkle 私钥给 DMG 签名（generate_keys 生成的那把），写出只含这一版的更新清单。
# 发布到 GitHub Releases 后，旧版本从 releases/latest/download/appcast.xml 读到它。
SPARKLE_BIN=${SPARKLE_BIN:-$HOME/Tools/Sparkle-2.10.1/bin}
SIG=$("$SPARKLE_BIN/sign_update" "$DMG")   # 输出 sparkle:edSignature="…" length="…"
case "$SIG" in *edSignature=*) ;; *) echo "error: sign_update 没有给出签名：$SIG"; exit 1 ;; esac
NOTES=""
[ -f "$DIR/release-notes/$VERSION.html" ] && NOTES=$(cat "$DIR/release-notes/$VERSION.html")
URL="https://github.com/751K/MiniDiT/releases/download/v$VERSION/$(basename "$DMG")"
cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MiniDiT</title>
    <item>
      <title>MiniDiT $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
EOF
echo "$VERSION" > "$OUT/version.txt"

shasum -a 256 "$DMG"
step "完成：$DMG 和 $OUT/appcast.xml"
