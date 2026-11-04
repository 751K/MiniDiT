#!/bin/bash
# 从源码编译 OpenSSL + libssh2，打包成 Vendor/CLibssh2.xcframework（静态库）。
# 平台：iPhone 真机 (arm64)、iPhone 模拟器 (arm64)、macOS (arm64，用于 swift test)。
# 源码包会校验 SHA-256，校验不通过就停止。
#
# 用法（需要 Xcode）：Scripts/build-libssh2-xcframework.sh
set -euo pipefail

OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

LIBSSH2_VERSION=1.11.1
LIBSSH2_SHA256=d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7
LIBSSH2_URL="https://libssh2.org/download/libssh2-${LIBSSH2_VERSION}.tar.gz"

IOS_MIN=17.0
MACOS_MIN=14.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.ssh-build}"
OUT="$ROOT/Vendor/CLibssh2.xcframework"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$WORK/src"

fetch() { # url sha256 file
    local url=$1 sum=$2 file="$WORK/src/$3"
    if [ ! -f "$file" ]; then
        echo "下载 $url"
        curl -fL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    echo "$sum  $file" | shasum -a 256 -c - >/dev/null || { echo "校验失败：$file"; rm -f "$file"; exit 1; }
}

fetch "$OPENSSL_URL" "$OPENSSL_SHA256" "openssl-${OPENSSL_VERSION}.tar.gz"
fetch "$LIBSSH2_URL" "$LIBSSH2_SHA256" "libssh2-${LIBSSH2_VERSION}.tar.gz"

# 平台名 | OpenSSL Configure 目标 | SDK | 最低系统版本参数
PLATFORMS=(
    "ios|ios64-xcrun|iphoneos|-mios-version-min=$IOS_MIN"
    "ios-simulator|iossimulator-arm64-xcrun|iphonesimulator|-mios-simulator-version-min=$IOS_MIN"
    "macos|darwin64-arm64-cc|macosx|-mmacosx-version-min=$MACOS_MIN"
)

XCF_ARGS=()
for entry in "${PLATFORMS[@]}"; do
    IFS='|' read -r name target sdk minflag <<<"$entry"
    prefix="$WORK/out/$name"
    build="$WORK/build/$name"
    sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc="$(xcrun --sdk "$sdk" -f clang)"
    rm -rf "$build" "$prefix"
    mkdir -p "$build" "$prefix"

    echo "=== OpenSSL $OPENSSL_VERSION → $name"
    tar -xzf "$WORK/src/openssl-${OPENSSL_VERSION}.tar.gz" -C "$build"
    (
        cd "$build/openssl-${OPENSSL_VERSION}"
        CC="$cc" CFLAGS="-arch arm64 -isysroot $sdkpath $minflag" \
            ./Configure "$target" no-shared no-tests no-apps no-docs no-ui-console no-engine no-dso no-module \
            --prefix="$prefix" --libdir=lib "$minflag" >/dev/null
        make -j"$JOBS" build_libs >/dev/null
        make install_dev >/dev/null
    )

    echo "=== libssh2 $LIBSSH2_VERSION → $name"
    tar -xzf "$WORK/src/libssh2-${LIBSSH2_VERSION}.tar.gz" -C "$build"
    (
        cd "$build/libssh2-${LIBSSH2_VERSION}"
        CC="$cc" CFLAGS="-arch arm64 -isysroot $sdkpath $minflag -O2" \
            ./configure --host=aarch64-apple-darwin --prefix="$prefix" \
            --with-crypto=openssl --with-libssl-prefix="$prefix" --without-libz \
            --disable-shared --enable-static --disable-examples-build --disable-docker-tests \
            >/dev/null
        make -j"$JOBS" -C src >/dev/null
        make -C src install >/dev/null
        make install-includeHEADERS >/dev/null
    )

    # 合成一个静态库（libssh2 的 OpenSSL 后端只需要 libcrypto）。
    libdir="$WORK/xcf/$name"
    rm -rf "$libdir"; mkdir -p "$libdir/Headers"
    libtool -static -o "$libdir/libCLibssh2.a" "$prefix/lib/libssh2.a" "$prefix/lib/libcrypto.a"
    cp "$prefix/include/libssh2.h" "$prefix/include/libssh2_publickey.h" "$prefix/include/libssh2_sftp.h" "$libdir/Headers/"
    cat > "$libdir/Headers/module.modulemap" <<'EOF'
module CLibssh2 {
    header "libssh2.h"
    link "CLibssh2"
    export *
}
EOF
    XCF_ARGS+=(-library "$libdir/libCLibssh2.a" -headers "$libdir/Headers")
done

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$OUT" >/dev/null
cat > "$ROOT/Vendor/CLibssh2.VERSION" <<EOF
OpenSSL $OPENSSL_VERSION (sha256 $OPENSSL_SHA256)
libssh2 $LIBSSH2_VERSION (sha256 $LIBSSH2_SHA256)
iOS >= $IOS_MIN, macOS >= $MACOS_MIN, arm64
EOF
echo "完成：$OUT"
