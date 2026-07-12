#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Vendor/CSSH"
BUILD="$ROOT/build/cssh"
OPENSSL_VERSION="3.5.7"
LIBSSH2_VERSION="1.11.1"
IOS_MIN="16.0"

download_and_unpack() {
    local url="$1"
    local archive="$2"
    local destination="$3"
    if [[ -d "$destination" ]]; then
        return
    fi
    mkdir -p "$(dirname "$archive")" "$destination"
    curl --fail --location --silent --show-error "$url" --output "$archive"
    tar -xzf "$archive" -C "$destination" --strip-components=1
}

build_slice() {
    local name="$1"
    local sdk="$2"
    local openssl_target="$3"
    local minimum_flag="$4"
    local arch="$5"
    local slice="$BUILD/$name"
    local openssl_source="$slice/openssl-source"
    local libssh2_source="$slice/libssh2-source"
    local openssl_install="$slice/openssl-install"
    local libssh2_install="$slice/libssh2-install"
    local sdk_path
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

    mkdir -p "$slice"
    if [[ ! -f "$openssl_install/lib/libcrypto.a" ]]; then
        rm -rf "$openssl_source" "$openssl_install"
        mkdir -p "$openssl_source"
        cp -R "$BUILD/sources/openssl/." "$openssl_source"

        pushd "$openssl_source" >/dev/null
        export CC="$(xcrun --sdk "$sdk" -f clang) -isysroot $sdk_path -arch $arch $minimum_flag"
        ./Configure "$openssl_target" \
            --prefix="$openssl_install" \
            "$minimum_flag" \
            no-shared no-tests no-apps no-docs
        make -j"$(sysctl -n hw.ncpu)" build_libs >/dev/null
        make install_sw >/dev/null
        unset CC
        popd >/dev/null
    fi

    rm -rf "$libssh2_source" "$libssh2_install" "$slice/libssh2-build"
    mkdir -p "$libssh2_source"
    cp -R "$BUILD/sources/libssh2/." "$libssh2_source"

    pushd "$libssh2_source" >/dev/null
    export CC="$(xcrun --sdk "$sdk" -f clang)"
    export CFLAGS="-arch $arch -isysroot $sdk_path $minimum_flag"
    export CPPFLAGS="-arch $arch -isysroot $sdk_path $minimum_flag -I$openssl_install/include"
    export LDFLAGS="-arch $arch -isysroot $sdk_path $minimum_flag -L$openssl_install/lib"
    ./configure \
        --host=aarch64-apple-darwin \
        --prefix="$libssh2_install" \
        --disable-shared \
        --enable-static \
        --disable-examples-build \
        --without-libz \
        --with-crypto=openssl \
        --with-libssl-prefix="$openssl_install" >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
    make install >/dev/null
    unset CC CFLAGS CPPFLAGS LDFLAGS
    popd >/dev/null

    mkdir -p "$slice/Headers"
    cp "$libssh2_install/include/libssh2.h" "$slice/Headers/"
    cp "$libssh2_install/include/libssh2_publickey.h" "$slice/Headers/"
    cp "$libssh2_install/include/libssh2_sftp.h" "$slice/Headers/"
    xcrun --sdk "$sdk" libtool -static -D \
        -o "$slice/libssh2.a" \
        "$libssh2_install/lib/libssh2.a" \
        "$openssl_install/lib/libssl.a" \
        "$openssl_install/lib/libcrypto.a"
}

mkdir -p "$BUILD/sources"
download_and_unpack \
    "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" \
    "$BUILD/sources/openssl-$OPENSSL_VERSION.tar.gz" \
    "$BUILD/sources/openssl"
download_and_unpack \
    "https://github.com/libssh2/libssh2/releases/download/libssh2-$LIBSSH2_VERSION/libssh2-$LIBSSH2_VERSION.tar.gz" \
    "$BUILD/sources/libssh2-$LIBSSH2_VERSION.tar.gz" \
    "$BUILD/sources/libssh2"

build_slice \
    "iphoneos" "iphoneos" "ios64-xcrun" \
    "-miphoneos-version-min=$IOS_MIN" "arm64"
build_slice \
    "iphonesimulator" "iphonesimulator" "iossimulator-xcrun" \
    "-mios-simulator-version-min=$IOS_MIN" "arm64"

for headers in "$BUILD/iphoneos/Headers" "$BUILD/iphonesimulator/Headers"; do
    printf '%s\n' \
        'module CSSH {' \
        '    header "libssh2.h"' \
        '    header "libssh2_sftp.h"' \
        '    header "libssh2_publickey.h"' \
        '    export *' \
        '}' > "$headers/module.modulemap"
done

rm -rf "$OUT/CSSH.xcframework"
xcodebuild -create-xcframework \
    -library "$BUILD/iphoneos/libssh2.a" \
    -headers "$BUILD/iphoneos/Headers" \
    -library "$BUILD/iphonesimulator/libssh2.a" \
    -headers "$BUILD/iphonesimulator/Headers" \
    -output "$OUT/CSSH.xcframework"

printf 'libssh2=%s\nOpenSSL=%s\n' "$LIBSSH2_VERSION" "$OPENSSL_VERSION" > "$OUT/VERSIONS"
