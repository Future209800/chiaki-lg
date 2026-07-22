#!/usr/bin/env bash
# build-webos.sh — Cross-compile chiaki-webos for webOS TV
# Riscritto e ottimizzato per la compatibilità nativa con webOS NDK (Yocto/OpenEmbedded)

set -eo pipefail # Rimosso 'u' per tollerare le variabili vuote dell'ambiente Yocto

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHIAKI_NG_DIR="$(realpath "${1:-$SCRIPT_DIR/../chiaki-ng}")"
BUILD_DIR="$SCRIPT_DIR/build-webos"
OUR_STAGING="/tmp/webos-staging"

# ── 1. Validate toolchain & Source Yocto environment ──────────────────────────
export TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-/opt/webos-sdk}"
if [[ ! -d "$TOOLCHAIN_DIR" ]]; then
    echo "ERROR: TOOLCHAIN_DIR non trovata in $TOOLCHAIN_DIR"
    echo "Assicurati di aver installato l'NDK."
    exit 1
fi

ENV_SETUP=$(ls "$TOOLCHAIN_DIR"/environment-setup-* 2>/dev/null | head -n 1)
if [[ -z "$ENV_SETUP" ]]; then
    echo "ERROR: Script environment-setup non trovato in $TOOLCHAIN_DIR"
    exit 1
fi
source "$ENV_SETUP"

TOOLCHAIN_FILE=$(find "$TOOLCHAIN_DIR" -name "OEToolchainConfig.cmake" | head -n 1)
if [[ -z "$TOOLCHAIN_FILE" ]]; then
    echo "ERROR: OEToolchainConfig.cmake non trovato in $TOOLCHAIN_DIR"
    exit 1
fi

# Yocto definisce il sysroot in questa variabile nativa
SYSROOT="${OECORE_TARGET_SYSROOT}"
if [[ -z "$SYSROOT" || ! -d "$SYSROOT" ]]; then
    echo "ERROR: SYSROOT non trovato o variabile OECORE_TARGET_SYSROOT non impostata."
    exit 1
fi

export STAGING_DIR="$OUR_STAGING"
mkdir -p "$OUR_STAGING/bin"

# ── 2. The Auto-Wrapper Magic (Fix per compatibilità Yocto vs Buildroot) ──────
# Yocto inietta il sysroot e le flag architetturali direttamente nella variabile $CC.
# Buildroot invece le ha integrate nel compilatore stesso. 
# Creiamo dei wrapper per comportarci come Buildroot senza sporcare le configurazioni.

CLEAN_CC=$(echo "${CC:-arm-webos-linux-gnueabi-gcc}" | awk '{print $1}')
CC_FLAGS=$(echo "${CC:-}" | cut -d' ' -f2-)
CLEAN_CXX=$(echo "${CXX:-arm-webos-linux-gnueabi-g++}" | awk '{print $1}')
CXX_FLAGS=$(echo "${CXX:-}" | cut -d' ' -f2-)

REAL_CC_PATH=$(which "$CLEAN_CC")
REAL_CXX_PATH=$(which "$CLEAN_CXX")

# Mettiamo i nostri finti compilatori in cima al PATH
export PATH="$OUR_STAGING/bin:/usr/bin:/usr/local/bin:$PATH"

# Generiamo i wrapper che iniettano automaticamente le sysroot di Yocto
cat > "$OUR_STAGING/bin/${CLEAN_CC}" << EOF
#!/usr/bin/env bash
exec "$REAL_CC_PATH" $CC_FLAGS "\$@"
EOF
chmod +x "$OUR_STAGING/bin/${CLEAN_CC}"

cat > "$OUR_STAGING/bin/${CLEAN_CXX}" << EOF
#!/usr/bin/env bash
exec "$REAL_CXX_PATH" $CXX_FLAGS "\$@"
EOF
chmod +x "$OUR_STAGING/bin/${CLEAN_CXX}"

CROSS_PREFIX="${CLEAN_CC%-gcc}-"
export CC="${CLEAN_CC}"
export CXX="${CLEAN_CXX}"
export AR="${CROSS_PREFIX}ar"
export STRIP="${CROSS_PREFIX}strip"
export RANLIB="${CROSS_PREFIX}ranlib"

# ── 3. Pkg-config e System settings ───────────────────────────────────────────
SYSROOT_PKGCONFIG="$SYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_PATH="$OUR_STAGING/lib/pkgconfig:$SYSROOT_PKGCONFIG"
export PKG_CONFIG_LIBDIR="$OUR_STAGING/lib/pkgconfig:$SYSROOT_PKGCONFIG"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
REAL_PKG_CONFIG=$(which "${CROSS_PREFIX}pkg-config" 2>/dev/null || which pkg-config)

PKG_CONFIG_WRAPPER="$OUR_STAGING/bin/pkg-config-wrapper"
SYSROOT_STAGING_PREFIX="$SYSROOT/tmp/webos-staging"

cat > "$PKG_CONFIG_WRAPPER" << WRAPPER_EOF
#!/usr/bin/env bash
"$REAL_PKG_CONFIG" "\$@" | sed "s|${SYSROOT_STAGING_PREFIX}|/tmp/webos-staging|g"
WRAPPER_EOF
chmod +x "$PKG_CONFIG_WRAPPER"
export PKG_CONFIG="$PKG_CONFIG_WRAPPER"

echo "-- Toolchain: CC=$CC  PREFIX=$CROSS_PREFIX"
echo "-- Staging:   $OUR_STAGING"
echo "-- Sysroot:   $SYSROOT"
echo ""

mkdir -p "$BUILD_DIR"
NJOBS=$(nproc)

# ── OpenSSL ───────────────────────────────────────────────────────────────────
build_openssl() {
    local ver="3.2.1"
    local src="/tmp/openssl-$ver"
    [[ -f "$OUR_STAGING/lib/libssl.a" ]] && { echo "-- OpenSSL: skip"; return; }
    echo "-- Building OpenSSL $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/openssl-$ver.tar.gz" \
            "https://github.com/openssl/openssl/releases/download/openssl-$ver/openssl-$ver.tar.gz"
        tar xf "/tmp/openssl-$ver.tar.gz" -C /tmp
    fi
    rm -f "$src/Makefile"
    pushd "$src"
    unset CC CXX AR LD RANLIB NM STRIP
    ./Configure linux-armv4 --prefix="$OUR_STAGING" \
        no-shared no-tests no-docs \
        --cross-compile-prefix="$CROSS_PREFIX"
    make -j"$NJOBS" build_sw
    make install_sw
    export CC="${CROSS_PREFIX}gcc" CXX="${CROSS_PREFIX}g++"
    export AR="${CROSS_PREFIX}ar"  LD="${CROSS_PREFIX}ld"
    export RANLIB="${CROSS_PREFIX}ranlib" NM="${CROSS_PREFIX}nm"
    export STRIP="${CROSS_PREFIX}strip"
    popd
}

# ── Opus ──────────────────────────────────────────────────────────────────────
build_opus() {
    local ver="1.4"
    local src="/tmp/opus-$ver"
    [[ -f "$OUR_STAGING/lib/libopus.a" ]] && { echo "-- Opus: skip"; return; }
    echo "-- Building Opus $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/opus-$ver.tar.gz" \
            "https://downloads.xiph.org/releases/opus/opus-$ver.tar.gz"
        tar xf "/tmp/opus-$ver.tar.gz" -C /tmp
    fi
    pushd "$src"
    ./configure --host=arm-webos-linux-gnueabi --prefix="$OUR_STAGING" \
        --enable-static --disable-shared --disable-doc --disable-extra-programs
    make -j"$NJOBS" && make install
    popd
}

# ── FFmpeg ────────────────────────────────────────────────────────────────────
build_ffmpeg() {
    local ver="6.1.1"
    local src="/tmp/ffmpeg-$ver"
    [[ -f "$OUR_STAGING/lib/libavcodec.a" ]] && { echo "-- FFmpeg: skip"; return; }
    echo "-- Building FFmpeg $ver"
    rm -f "$src/config.mak" "$src/config.h"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/ffmpeg-$ver.tar.gz" "https://ffmpeg.org/releases/ffmpeg-$ver.tar.gz"
        tar xf "/tmp/ffmpeg-$ver.tar.gz" -C /tmp
    fi
    pushd "$src"
    ./configure \
        --prefix="$OUR_STAGING" \
        --enable-cross-compile --cross-prefix="$CROSS_PREFIX" \
        --arch=arm --cpu=cortex-a15 --target-os=linux \
        --enable-static --disable-shared \
        --disable-programs --disable-doc --disable-network --disable-avdevice \
        --disable-avformat --disable-swresample \
        --enable-avcodec --enable-avutil --enable-swscale \
        --enable-decoder=h264,hevc \
        --disable-decoder=mlp,truehd \
        --enable-parser=h264,hevc --disable-parser=mlp \
        --enable-demuxer=h264,hevc \
        --extra-cflags="-I$OUR_STAGING/include" \
        --extra-ldflags="-L$OUR_STAGING/lib"
    make -j"$NJOBS" && make install
    popd
}

# ── json-c ────────────────────────────────────────────────────────────────────
build_jsonc() {
    local ver="0.17"
    local src="/tmp/json-c-$ver"
    [[ -f "$OUR_STAGING/lib/libjson-c.a" ]] && { echo "-- json-c: skip"; return; }
    echo "-- Building json-c $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/json-c-$ver.tar.gz" \
            "https://github.com/json-c/json-c/archive/json-c-$ver-20230812.tar.gz"
        tar xf "/tmp/json-c-$ver.tar.gz" -C /tmp
        mv "/tmp/json-c-json-c-$ver-20230812" "$src"
    fi
    local bdir="$src/build"; mkdir -p "$bdir"
    cmake -B "$bdir" -S "$src" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DCMAKE_INSTALL_PREFIX="$OUR_STAGING" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF
    cmake --build "$bdir" -j"$NJOBS"
    cmake --install "$bdir"
}

# ── miniupnpc ─────────────────────────────────────────────────────────────────
build_miniupnpc() {
    local ver="2.2.7"
    local src="/tmp/miniupnpc-$ver"
    [[ -f "$OUR_STAGING/lib/libminiupnpc.a" ]] && { echo "-- miniupnpc: skip"; return; }
    echo "-- Building miniupnpc $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/miniupnpc-$ver.tar.gz" \
            "https://miniupnp.tuxfamily.org/files/miniupnpc-$ver.tar.gz"
        tar xf "/tmp/miniupnpc-$ver.tar.gz" -C /tmp
    fi
    local bdir="$src/build"; mkdir -p "$bdir"
    cmake -B "$bdir" -S "$src" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DCMAKE_INSTALL_PREFIX="$OUR_STAGING" \
        -DBUILD_SHARED_LIBS=OFF \
        -DUPNPC_BUILD_STATIC=ON -DUPNPC_BUILD_SHARED=OFF \
        -DUPNPC_BUILD_TESTS=OFF -DUPNPC_BUILD_SAMPLE=OFF
    cmake --build "$bdir" -j"$NJOBS"
    cmake --install "$bdir"
}

# ── cURL ──────────────────────────────────────────────────────────────────────
build_curl() {
    local ver="8.7.1"
    local src="/tmp/curl-$ver"
    if [[ -f "$OUR_STAGING/lib/libcurl.a" ]] && \
        grep -q "CURLOPT_WS_OPTIONS" "$OUR_STAGING/include/curl/curl.h" 2>/dev/null; then
        echo "-- cURL: skip (WebSocket enabled)"; return
    fi
    [[ -f "$OUR_STAGING/lib/libcurl.a" ]] && echo "-- cURL: rebuilding to add --enable-websockets"
    echo "-- Building cURL $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/curl-$ver.tar.gz" "https://curl.se/download/curl-$ver.tar.gz"
        tar xf "/tmp/curl-$ver.tar.gz" -C /tmp
    fi
    pushd "$src"
    ./configure \
        --host=arm-webos-linux-gnueabi --prefix="$OUR_STAGING" \
        --enable-static --disable-shared \
        --with-openssl="$OUR_STAGING" \
        --enable-websockets \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict \
        --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
        --disable-smb --disable-smtp --disable-gopher --disable-mqtt \
        --disable-manual --disable-docs \
        --without-libidn2 --without-librtmp --without-brotli --without-zstd
    make -j"$NJOBS" && make install
    popd
}

# ── GF-Complete ───────────────────────────────────────────────────────────────
build_gf_complete() {
    local src="/tmp/gf-complete-src"
    if [[ -f "$OUR_STAGING/lib/libgf_complete.a" ]]; then
        echo "-- GF-Complete: skip"; return
    fi
    echo "-- Building GF-Complete (manual compile)"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/gf-complete.tar.gz"             "https://github.com/ceph/gf-complete/archive/refs/heads/master.tar.gz"
        mkdir -p "$src"
        tar xf "/tmp/gf-complete.tar.gz" -C "$src" --strip-components=1
    fi

    local inc="$OUR_STAGING/include"
    local lib="$OUR_STAGING/lib"
    mkdir -p "$inc" "$lib"
    cp "$src"/include/*.h "$inc/" 2>/dev/null || true

    local obj_dir="/tmp/gf-complete-obj"
    mkdir -p "$obj_dir"
    local objects=()
    for f in "$src"/src/*.c; do
        [[ -f "$f" ]] || continue
        local obj="$obj_dir/$(basename "${f%.c}").o"
        echo "   CC $(basename $f)"
        "${CROSS_PREFIX}gcc" -O2 -fPIC             -I"$src/include"             -c "$f" -o "$obj"
        objects+=("$obj")
    done
    "${CROSS_PREFIX}ar" rcs "$lib/libgf_complete.a" "${objects[@]}"
    echo "-- GF-Complete built: ${#objects[@]} objects"
}

# ── Jerasure ─────────────────────────────────────────────────────────────────
build_jerasure() {
    local src="/tmp/jerasure-src"
    if [[ -f "$OUR_STAGING/lib/libJerasure.a" ]]; then
        echo "-- Jerasure: skip"; return
    fi
    echo "-- Building Jerasure 2.0 (manual compile)"
    if [[ ! -d "$src" ]]; then
        local dl_ok=0
        for url in \
            "https://github.com/ceph/jerasure/archive/refs/heads/master.tar.gz" \
            "https://github.com/tsuraan/Jerasure/archive/refs/heads/master.tar.gz" \
            "https://github.com/tsuraan/Jerasure/archive/refs/tags/v2.0.tar.gz"
        do
            echo "-- Trying Jerasure: $url"
            wget -qO "/tmp/jerasure.tar.gz" "$url" && dl_ok=1 && break || true
        done
        if [[ $dl_ok -eq 0 ]]; then
            echo "ERROR: All Jerasure download URLs failed"
            exit 1
        fi
        mkdir -p "$src"
        tar xf "/tmp/jerasure.tar.gz" -C "$src" --strip-components=1
    fi

    echo "-- Jerasure source layout:"
    find "$src" -name "*.c" -o -name "*.h" | sort | sed 's|^|   |'

    local inc="$OUR_STAGING/include"
    local lib="$OUR_STAGING/lib"

    for hdir in "$src/include" "$src/Headers" "$src"; do
        if ls "$hdir"/*.h &>/dev/null; then
            cp "$hdir"/*.h "$inc/"
            echo "-- Copied headers from $hdir"
            break
        fi
    done

    local obj_dir="/tmp/jerasure-obj"
    mkdir -p "$obj_dir"
    local objects=()

    local search_dirs=("$src/src" "$src/Examples" "$src")
    for d in "${search_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*.c; do
            [[ -f "$f" ]] || continue
            local base; base="$(basename "$f")"
            [[ "$base" == example* ]] && continue
            [[ "$base" == test* ]]    && continue
            [[ "$base" == decoder* ]] && continue
            [[ "$base" == encoder* ]] && continue
            local obj="$obj_dir/${base%.c}.o"
            echo "   CC $base"
            "${CROSS_PREFIX}gcc" -O2 -fPIC                 -I"$inc"                 -c "$f" -o "$obj"
            objects+=("$obj")
        done
        [[ ${#objects[@]} -gt 0 ]] && break
    done

    if [[ ${#objects[@]} -eq 0 ]]; then
        echo "ERROR: No compilable Jerasure source files found"
        exit 1
    fi

    "${CROSS_PREFIX}ar" rcs "$lib/libJerasure.a" "${objects[@]}"
    echo "-- Jerasure built: ${#objects[@]} objects"
}

# ── libevent ──────────────────────────────────────────────────────────────────
build_libevent() {
    local ver="2.1.12-stable"
    local src="/tmp/libevent-$ver"
    [[ -f "$OUR_STAGING/lib/libevent.a" ]] && { echo "-- libevent: skip"; return; }
    echo "-- Building libevent $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/libevent-$ver.tar.gz" \
            "https://github.com/libevent/libevent/releases/download/release-$ver/libevent-$ver.tar.gz"
        tar xf "/tmp/libevent-$ver.tar.gz" -C /tmp
    fi
    local bdir="$src/build"; mkdir -p "$bdir"
    cmake -B "$bdir" -S "$src" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DCMAKE_INSTALL_PREFIX="$OUR_STAGING" \
        -DBUILD_SHARED_LIBS=OFF \
        -DEVENT__DISABLE_TESTS=ON \
        -DEVENT__DISABLE_SAMPLES=ON \
        -DEVENT__DISABLE_OPENSSL=ON \
        -DEVENT__LIBRARY_TYPE=STATIC
    cmake --build "$bdir" -j"$NJOBS"
    cmake --install "$bdir"
}

build_openssl
build_opus
build_jsonc
build_miniupnpc
build_curl
build_gf_complete
build_jerasure
build_libevent

# ── Clone ss4s ────────────────────────────────────────────────────────────────
SS4S_DIR="$SCRIPT_DIR/third-party/ss4s"
if [[ ! -f "$SS4S_DIR/CMakeLists.txt" ]]; then
    echo "-- Cloning ss4s..."
    mkdir -p "$SCRIPT_DIR/third-party"
    git clone --depth=1 https://github.com/mariotaku/ss4s.git "$SS4S_DIR"
else
    echo "-- ss4s: already present ($(git -C "$SS4S_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown'))"
fi

# ── Patch all staging .pc files ───────────────────────────────────────────────
echo ""
echo "=== Patching staging .pc files to use hardcoded absolute paths ==="
for pc in "$OUR_STAGING"/lib/pkgconfig/*.pc; do
    [[ -f "$pc" ]] || continue
    sed -i "/^prefix=/d"                                              "$pc"
    sed -i "/^exec_prefix=/d"                                         "$pc"
    sed -i "s|^includedir=.*|includedir=$OUR_STAGING/include|"       "$pc"
    sed -i "s|^libdir=.*|libdir=$OUR_STAGING/lib|"                   "$pc"
    sed -i "s|\${prefix}|$OUR_STAGING|g"                             "$pc"
    sed -i "s|\${exec_prefix}|$OUR_STAGING|g"                        "$pc"
done
COUNT=$(ls "$OUR_STAGING/lib/pkgconfig/"*.pc 2>/dev/null | wc -l)
echo "-- Patched $COUNT .pc files"

# Verify the json-c and miniupnpc .pc files look correct
for pkg in json-c miniupnpc; do
    PC="$OUR_STAGING/lib/pkgconfig/$pkg.pc"
    [[ -f "$PC" ]] && echo "-- $pkg.pc includedir: $(grep includedir "$PC")"
done

# ── Write cmake helper module dir ─────────────────────────────────────────────
CMAKE_MODULES_DIR="$SCRIPT_DIR/cmake"
mkdir -p "$CMAKE_MODULES_DIR"
cat > "$CMAKE_MODULES_DIR/FindNanopb.cmake" << 'FINDNANOPB_EOF'
set(_nanopb_src "@NANOPB_SRC@")
list(APPEND CMAKE_MODULE_PATH "${_nanopb_src}/extra")
include("${_nanopb_src}/extra/FindNanopb.cmake" OPTIONAL RESULT_VARIABLE _found)
if(NOT _found)
    if(NOT TARGET nanopb)
        add_subdirectory("${_nanopb_src}" nanopb_build EXCLUDE_FROM_ALL)
    endif()
endif()
if(TARGET nanopb AND NOT TARGET Nanopb::nanopb)
    add_library(Nanopb::nanopb ALIAS nanopb)
endif()
if(TARGET Nanopb::nanopb)
    set(Nanopb_FOUND TRUE)
    set(NANOPB_FOUND TRUE)
endif()
FINDNANOPB_EOF
sed -i "s|@NANOPB_SRC@|$CHIAKI_NG_DIR/third-party/nanopb|g" "$CMAKE_MODULES_DIR/FindNanopb.cmake"

# ── Check chiaki-ng submodules ─────────────────────────────────────────────────
echo ""
echo "=== Checking chiaki-ng header API ==="
echo "-- Relevant ChiakiRegisteredHost fields:"
grep -E 'rp_regist_key|rp_key|account_id|psn_' "$CHIAKI_NG_DIR/lib/include/chiaki/regist.h" 2>/dev/null | head -20 || true
echo "-- ChiakiAudioSink fields:"
grep -E 'frame_cb|header_cb|ChiakiAudio' "$CHIAKI_NG_DIR/lib/include/chiaki/audio.h" 2>/dev/null | head -20 || true
echo "-- ChiakiRegistInfo fields:"
grep -E 'ps5|target|account_id|psn_' "$CHIAKI_NG_DIR/lib/include/chiaki/regist.h" 2>/dev/null | grep -v '//' | head -20 || true
echo ""
echo "=== Checking chiaki-ng submodules ==="

if [[ ! -f "$CHIAKI_NG_DIR/third-party/nanopb/CMakeLists.txt" ]]; then
    echo "-- nanopb submodule CMakeLists.txt missing, attempting git init..."
    git -C "$CHIAKI_NG_DIR" submodule update --init third-party/nanopb 2>&1 | tail -5 || true
fi

if [[ ! -f "$CHIAKI_NG_DIR/third-party/nanopb/CMakeLists.txt" ]]; then
    echo "-- ERROR: nanopb submodule CMakeLists.txt missing and git init failed."
    exit 1
fi

echo "-- Installing/verifying nanopb pip package (for generator)..."
if python3 -c "import nanopb" 2>/dev/null; then
    echo "-- nanopb pip package: already installed"
else
    pip3 install nanopb --break-system-packages -q 2>&1 | tail -3 || \
    pip3 install nanopb -q 2>&1 | tail -3 || true
    python3 -c "import nanopb; print('-- nanopb pip package: OK')" 2>/dev/null \
        || echo "-- nanopb pip package: install failed"
fi

# ── Patch chiaki-ng sources for webOS compatibility ──────────────────────────
echo ""
echo "=== Patching chiaki-ng sources for webOS ==="

THREAD_C="$CHIAKI_NG_DIR/lib/src/thread.c"
if grep -q 'pthread_clockjoin_np' "$THREAD_C" 2>/dev/null; then
    sed -i 's/pthread_clockjoin_np(\(.*\), CLOCK_MONOTONIC, \(&timeout\))/pthread_timedjoin_np(\1, \2)/' \
        "$THREAD_C"
    if grep -q 'pthread_clockjoin_np' "$THREAD_C"; then
        echo "-- WARNING: pthread_clockjoin_np patch may have failed"
    else
        echo "-- thread.c: patched pthread_clockjoin_np → pthread_timedjoin_np"
    fi
else
    echo "-- thread.c: no pthread_clockjoin_np"
fi

# ── Generate cmake toolchain extension ────────────────────────────────────────
HINTS_FILE="$BUILD_DIR/chiaki_hints.cmake"
mkdir -p "$BUILD_DIR"

cat > "$HINTS_FILE" << 'ENDOFHINTS'
if(NOT TARGET CURL::libcurl)
    add_library(CURL::libcurl STATIC IMPORTED GLOBAL)
    set_target_properties(CURL::libcurl PROPERTIES
        IMPORTED_LOCATION             "@@STAGING@@/lib/libcurl.a"
        INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include"
        INTERFACE_LINK_LIBRARIES      "OpenSSL::SSL;OpenSSL::Crypto;z;pthread"
    )
    set(CURL_FOUND        TRUE)
    set(CURL_LIBRARIES    "@@STAGING@@/lib/libcurl.a")
    set(CURL_INCLUDE_DIRS "@@STAGING@@/include")
    set(CURL_VERSION_STRING "8.7.1")
endif()

set(PYTHON_EXECUTABLE  "/usr/bin/python3" CACHE FILEPATH "Host Python" FORCE)
set(Python3_EXECUTABLE "/usr/bin/python3" CACHE FILEPATH "Host Python 3" FORCE)
set(Python_EXECUTABLE  "/usr/bin/python3" CACHE FILEPATH "Host Python" FORCE)

if(NOT TARGET GF-Complete::GF-Complete)
    add_library(GF-Complete::GF-Complete STATIC IMPORTED GLOBAL)
    set_target_properties(GF-Complete::GF-Complete PROPERTIES
        IMPORTED_LOCATION             "@@STAGING@@/lib/libgf_complete.a"
        INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include"
    )
endif()

if(NOT TARGET Jerasure::Jerasure)
    add_library(Jerasure::Jerasure STATIC IMPORTED GLOBAL)
    set_target_properties(Jerasure::Jerasure PROPERTIES
        IMPORTED_LOCATION             "@@STAGING@@/lib/libJerasure.a"
        INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include"
        INTERFACE_LINK_LIBRARIES      "GF-Complete::GF-Complete"
    )
endif()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL cmake_language EVAL CODE [[
    foreach(_t PkgConfig::json-c PkgConfig::MINIUPNPC PkgConfig::miniupnpc PkgConfig::libevent PkgConfig::LIBEVENT PkgConfig::libevent_core PkgConfig::libevent_pthreads)
        if(TARGET ${_t})
            set_property(TARGET ${_t} PROPERTY
                INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include")
            message(STATUS "chiaki_hints: fixed include dir on ${_t}")
        endif()
    endforeach()
    if(TARGET nanopb AND NOT TARGET Nanopb::nanopb)
        add_library(Nanopb::nanopb ALIAS nanopb)
        message(STATUS "chiaki_hints: created Nanopb::nanopb alias")
    endif()
]])
ENDOFHINTS

sed -i "s|@@STAGING@@|$OUR_STAGING|g"          "$HINTS_FILE"
sed -i "s|@@NANOPB@@|$CHIAKI_NG_DIR/third-party/nanopb|g" "$HINTS_FILE"

echo ""
echo "=== Installing host protobuf Python package ==="
if ! python3 -c "import google.protobuf" 2>/dev/null; then
    pip3 install protobuf --break-system-packages 2>&1 | tail -3 || \
    python3 -m pip install protobuf --break-system-packages 2>&1 | tail -3 || true
fi

echo ""
echo "=== Configuring chiaki-webos ==="
set -x  # trace all commands from here so failures are visible

rm -f "$BUILD_DIR/CMakeCache.txt"
rm -rf "$BUILD_DIR/CMakeFiles"

cmake -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWEBOS_BUILD=ON \
    -DWEBOS_STAGING_DIR="$OUR_STAGING" \
    -DCHIAKI_SOURCE_DIR="$CHIAKI_NG_DIR" \
    -DCMAKE_INSTALL_PREFIX="/app" \
    -DOPENSSL_ROOT_DIR="$OUR_STAGING" \
    -DOPENSSL_INCLUDE_DIR="$OUR_STAGING/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$OUR_STAGING/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$OUR_STAGING/lib/libssl.a" \
    -DCHIAKI_ENABLE_CLI=OFF \
    -DCHIAKI_ENABLE_TESTS=OFF \
    -DCHIAKI_ENABLE_GUI=OFF \
    -DNANOPB_SRC_ROOT_FOLDER="$CHIAKI_NG_DIR/third-party/nanopb" \
    -DCMAKE_MODULE_PATH="$CMAKE_MODULES_DIR;$CHIAKI_NG_DIR/third-party/nanopb/extra" \
    -DCMAKE_PREFIX_PATH="$OUR_STAGING;$SYSROOT/usr" \
    -DCMAKE_FIND_ROOT_PATH="$OUR_STAGING;$SYSROOT" \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_EXE_LINKER_FLAGS="-L$OUR_STAGING/lib -L$SYSROOT/usr/lib -Wl,-rpath,\$ORIGIN/lib" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$OUR_STAGING/lib -L$SYSROOT/usr/lib -lm" \
    -DPKG_CONFIG_EXECUTABLE="$PKG_CONFIG" \
    -DCMAKE_PROJECT_INCLUDE="$HINTS_FILE" \
    -DPYTHON_EXECUTABLE="$(which python3 || which python)" \
    -DPython3_EXECUTABLE="$(which python3 || which python)" \
    -DNDL_DIRECTMEDIA_FOUND=ON \
    -DNDL_DIRECTMEDIA_INCLUDE_DIRS="$SYSROOT/usr/include" \
    -DNDL_DIRECTMEDIA_LIBRARIES="NDL_directmedia" \
    -DSS4S_MODULE_LIBRARY_OUTPUT_DIRECTORY="$BUILD_DIR/lib" \
    -DSS4S_ENABLE_TESTS=OFF \
    -DSS4S_ENABLE_SAMPLES=OFF \
    -DSS4S_COMPILE_CHECK_STRICT=OFF \
    -DSS4S_MODULE_DISABLE_NDL_ESPLAYER=ON \
    -DSS4S_MODULE_DISABLE_NDL_WEBOS4=OFF \
    -DSS4S_MODULE_DISABLE_NDL_WEBOS5=OFF
    -DSS4S_MODULE_DISABLE_SMP=ON \
    -DSS4S_MODULE_DISABLE_MEDIAAPIS=ON

echo ""
echo "=== Pre-generating takion.pb after configure ==="
PROTO_OUT="$BUILD_DIR/chiaki_lib/protobuf"
TAKION_PROTO="$CHIAKI_NG_DIR/lib/protobuf/takion.proto"
mkdir -p "$PROTO_OUT"

NANOPB_GEN=""
NANOPB_GEN="$(python3 -c '
import sys
try:
    import nanopb, os
    gen = os.path.join(os.path.dirname(nanopb.__file__), "nanopb_generator.py")
    if os.path.isfile(gen): print(gen)
except: pass
' 2>/dev/null)"

if [[ -z "$NANOPB_GEN" ]]; then
    for candidate in \
        "$CHIAKI_NG_DIR/third-party/nanopb/nanopb_generator.py" \
        "$CHIAKI_NG_DIR/third-party/nanopb/generator/nanopb_generator.py"; do
        if [[ -f "$candidate" ]]; then
            NANOPB_GEN="$candidate"
            break
        fi
    done
fi

if [[ -z "$NANOPB_GEN" ]]; then
    echo "-- ERROR: Cannot find nanopb_generator.py anywhere. Aborting."
    exit 1
fi

python3 "$NANOPB_GEN" \
    --output-dir="$PROTO_OUT" \
    --proto-path="$CHIAKI_NG_DIR/lib/protobuf" \
    "$TAKION_PROTO" 2>&1 | sed 's/^/  /'

if [[ -f "$PROTO_OUT/takion.pb.c" && -f "$PROTO_OUT/takion.pb.h" ]]; then
    echo "-- takion.pb.c: ready"
else
    echo "-- ERROR: takion.pb generation failed!"
    exit 1
fi

CHIAKI_PB_MAKE="$BUILD_DIR/chiaki_lib/protobuf/CMakeFiles/chiaki-pb.dir/build.make"
if [[ -f "$CHIAKI_PB_MAKE" ]]; then
    python3 << PYEOF
path = "$CHIAKI_PB_MAKE"
with open(path, "r", errors="replace") as f:
    lines = f.readlines()
changed = 0
out = []
for line in lines:
    if line.startswith("\t") and "-E env" in line and "PATH=" in line:
        out.append("\t@true  # recipe disabled: pre-generated by build-webos.sh\n")
        changed += 1
    else:
        out.append(line)
with open(path, "w") as f:
    f.writelines(out)
print(f"-- Patched {changed} recipe line(s) in build.make" if changed else "")
PYEOF
fi

echo ""
echo "=== Building ==="
cmake --build "$BUILD_DIR" -j"$NJOBS"

echo ""
echo "=== Packaging IPK ==="
cmake --build "$BUILD_DIR" --target ipk

echo ""
echo "=== Done! ==="
ls "$BUILD_DIR"/*.ipk 2>/dev/null || echo "(check $BUILD_DIR for output)"
