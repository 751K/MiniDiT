#!/bin/sh
# Install an already built native CLI; does not change shell or MCP client configuration.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
BINARY=${1:-"$ROOT/.build/release/minidit"}
CLI_DIRECTORY=${MINIDIT_CLI_DIR:-"$HOME/.local/bin"}
if [ ! -x "$BINARY" ]; then
    echo "找不到可执行文件：$BINARY。请先运行 swift build -c release --product minidit。" >&2
    exit 1
fi
"$BINARY" --version
mkdir -p "$CLI_DIRECTORY"
CLI_TEMP=$(mktemp "$CLI_DIRECTORY/.minidit.XXXXXX")
trap 'rm -f "$CLI_TEMP"' EXIT HUP INT TERM
/usr/bin/install -m 755 "$BINARY" "$CLI_TEMP"
mv -f "$CLI_TEMP" "$CLI_DIRECTORY/minidit"
echo "已安装 $CLI_DIRECTORY/minidit"
