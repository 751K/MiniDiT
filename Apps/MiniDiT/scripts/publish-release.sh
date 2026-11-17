#!/bin/sh
# 把 release.sh 打好的 DMG 和 appcast.xml 发布到 GitHub Releases（用 gh）。
# 发布后，装了 MiniDiT 的电脑从 releases/latest/download/appcast.xml 看到新版本。
# 仓库必须是公开的，App 才能下载到更新。
#
# 用法：sh Apps/MiniDiT/scripts/publish-release.sh            发布 Apps/MiniDiT/build/release 里打好的那一版
#       NOTES_FILE=notes.md sh …/publish-release.sh          用这个文件作为 GitHub 上的发布说明（默认 release-notes/<版本>.md）
set -eu
REPO=751K/MiniDiT
WORK=$(CDPATH= cd -- "$(dirname -- "$0")/../build/release" && pwd)

VERSION=$(cat "$WORK/version.txt")
DMG="MiniDiT-$VERSION.dmg"

# 发布前再确认一遍：DMG 已公证并钉上结果，清单里的地址指向这次的 tag。
xcrun stapler validate "$WORK/$DMG" >/dev/null
grep -q "releases/download/v$VERSION/$DMG" "$WORK/appcast.xml"
if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then
    echo "v$VERSION 已经发布过。要重新发布，先在 GitHub 上删掉这个 release 和 tag。" >&2
    exit 1
fi

[ "$(gh repo view "$REPO" --json visibility -q .visibility)" = PUBLIC ] ||
    echo "注意：$REPO 现在是私有仓库，已安装的 MiniDiT 读不到这次更新，公开后才能用。" >&2

set -- --title "MiniDiT $VERSION" --latest
# 发布说明：NOTES_FILE 指定的文件，否则用 release-notes/<版本>.md，都没有就只写版本号。
NOTES_FILE=${NOTES_FILE:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/release-notes/$VERSION.md}
if [ -f "$NOTES_FILE" ]; then set -- "$@" --notes-file "$NOTES_FILE"; else set -- "$@" --notes "MiniDiT $VERSION"; fi
gh release create "v$VERSION" -R "$REPO" --target main "$@" "$WORK/$DMG" "$WORK/appcast.xml"
echo "已发布：https://github.com/$REPO/releases/tag/v$VERSION"
