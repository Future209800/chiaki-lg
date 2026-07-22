#!/usr/bin/env bash
# build-webos.sh — Cross-compile chiaki-webos for webOS TV
# Versione Ottimizzata: unisce i fix upstream con la compatibilità Yocto/SDK Open Source

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHIAKI_NG_DIR="$(realpath "${1:-$SCRIPT_DIR/../chiaki-ng}")"
BUILD_DIR="$SCRIPT_DIR/build-webos"
OUR_STAGING="/tmp/webos-staging"

# ── 1. Validate toolchain & Source Yocto environment ──────────────────────────
export TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-/opt/webos-sdk}"
if [[ ! -d "$TOOLCHAIN_DIR" ]]; then
    echo "ERROR: TOOLCHAIN_DIR non trovata in $TOOLCHAIN_DIR"
    exit 1
fi

ENV_SETUP=$(ls "$TOOLCHAIN_DIR"/environment-setup-* 2>/dev/null | head -n 1)
if [[ -z "$ENV_SETUP" ]]; then
    echo "ERROR: Script environment-setup non trovato"
    exit 1
fi
source "$ENV_SETUP"

TOOLCHAIN_FILE=$(find "$TOOLCHAIN_DIR" -name "OEToolchainConfig.cmake" | head -n 1)
SYSROOT="${OECORE_TARGET_SYSROOT}"
if [[ -z "$TOOLCHAIN_FILE" || -z "$SYSROOT" ]]; then
    echo "ERROR: File toolchain Yocto o SYSROOT mancanti."
    exit 1
fi

export STAGING_DIR="$OUR_STAGING"
mkdir -p "$OUR_STAGING/bin"

# ── 2. The Auto-Wrapper Magic (Fix Yocto) ─────────────────────────────────────
CLEAN_CC=$(echo "${CC:-arm-webos-linux-gnueabi-gcc}" | awk '{print $1}')
CC_FLAGS=$(echo "${CC:-}" | cut -d' ' -f2-)
CLEAN_CXX=$(echo "${CXX:-arm-webos-linux-gnueabi-g++}" | awk '{print $1}')
CXX_FLAGS=$(echo "${CXX:-}" | cut -d' ' -f2-)

REAL_CC_PATH=$(which "$CLEAN_CC")
REAL_CXX_PATH=$(which "$CLEAN_CXX")

export PATH="$OUR_STAGING/bin:/usr/bin:/usr/local/bin:$PATH"

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

mkdir -p "$BUILD_DIR"
NJOBS=$(nproc)

# ── Build Libraries ───────────────────────────────────────────────────────────
build_openssl() {
    local src="/tmp/openssl-3.2.1"
    [[ -f "$OUR_STAGING/lib/libssl.a" ]] && return
    wget -qO "$src.tar.gz" "https://github.com/openssl/openssl/releases/download/openssl-3.2.1/openssl-3.2.1.tar.gz"
    tar xf "$src.tar.gz" -C /tmp; pushd "$src"
    unset CC CXX AR LD RANLIB NM STRIP
    ./Configure linux-armv4 --prefix="$OUR_STAGING" no-shared no-tests no-docs --cross-compile-prefix="$CROSS_PREFIX"
    make -j"$NJOBS" build_sw && make install_sw
    export CC="${CROSS_PREFIX}gcc" CXX="${CROSS_PREFIX}g++" AR="${CROSS_PREFIX}ar" RANLIB="${CROSS_PREFIX}ranlib" STRIP="${CROSS_PREFIX}strip"
    popd
}

build_opus() {
    local src="/tmp/opus-1.4"
    [[ -f "$OUR_STAGING/lib/libopus.a" ]] && return
    wget -qO "$src.tar.gz" "https://downloads.xiph.org/releases/opus/opus-1.4.tar.gz"
    tar xf "$src.tar.gz" -C /tmp; pushd "$src"
    ./configure --host=arm-webos-linux-gnueabi --prefix="$OUR_STAGING" --enable-static --disable-shared --disable-doc --disable-extra-programs --with-pic
    make -j"$NJOBS" && make install; popd
}

build_ffmpeg() {
    local src="/tmp/ffmpeg-6.1.1"
    [[ -f "$OUR_STAGING/lib/libavcodec.a" ]] && return
    wget -qO "$src.tar.gz" "https://ffmpeg.org/releases/ffmpeg-6.1.1.tar.gz"
    tar xf "$src.tar.gz" -C /tmp; pushd "$src"
    ./configure --prefix="$OUR_STAGING" --enable-cross-compile --cross-prefix="$CROSS_PREFIX" \
        --arch=arm --cpu=cortex-a15 --target-os=linux --enable-static --disable-shared \
        --disable-programs --disable-doc --disable-network --disable-avdevice \
        --disable-avformat --disable-swresample --enable-avcodec --enable-avutil --enable-swscale \
        --enable-decoder=h264,hevc --disable-decoder=mlp,truehd \
        --enable-parser=h264,hevc --disable-parser=mlp --enable-demuxer=h264,hevc \
        --extra-cflags="-I$OUR_STAGING/include" --extra-ldflags="-L$OUR_STAGING/lib"
    make -j"$NJOBS" && make install; popd
}

build_jsonc() {
    local src="/tmp/json-c-0.17"
    [[ -f "$OUR_STAGING/lib/libjson-c.a" ]] && return
    wget -qO "$src.tar.gz" "https://github.com/json-c/json-c/archive/json-c-0.17-20230812.tar.gz"
    tar xf "$src.tar.gz" -C /tmp; mv "/tmp/json-c-json-c-0.17-20230812" "$src"
    local bdir="$src/build"; cmake -B "$bdir" -S "$src" -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" -DCMAKE_INSTALL_PREFIX="$OUR_STAGING" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF
    cmake --build "$bdir" -j"$NJOBS" && cmake --install "$bdir"
}

build_miniupnpc() {
    local src="/tmp/miniupnpc-2.2.7"
    [[ -f "$OUR_STAGING/lib/libminiupnpc.a" ]] && return
    wget -qO "$src.tar.gz" "https://miniupnp.tuxfamily.org/files/miniupnpc-2.2.7.tar.gz"
    tar xf "$src.tar.gz" -C /tmp
    local bdir="$src/build"; cmake -B "$bdir" -S "$src" -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" -DCMAKE_INSTALL_PREFIX="$OUR_STAGING" -DBUILD_SHARED_LIBS=OFF -DUPNPC_BUILD_STATIC=ON -DUPNPC_BUILD_SHARED=OFF -DUPNPC_BUILD_TESTS=OFF -DUPNPC_BUILD_SAMPLE=OFF
    cmake --build "$bdir" -j"$NJOBS" && cmake --install "$bdir"
}

build_curl() {
    local src="/tmp/curl-8.7.1"
    if [[ -f "$OUR_STAGING/lib/libcurl.a" ]] && grep -q "CURLOPT_WS_OPTIONS" "$OUR_STAGING/include/curl/curl.h" 2>/dev/null; then return; fi
    wget -qO "$src.tar.gz" "https://curl.se/download/curl-8.7.1.tar.gz"
    tar xf "$src.tar.gz" -C /tmp; pushd "$src"
    ./configure --host=arm-webos-linux-gnueabi --prefix="$OUR_STAGING" --enable-static --disable-shared --with-openssl="$OUR_STAGING" --enable-websockets \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
        --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-manual --disable-docs --without-libidn2 --without-librtmp --without-brotli --without-zstd
    make -j"$NJOBS" && make install; popd
}

build_gf_complete() {
    local src="/tmp/gf-complete-src"
    [[ -f "$OUR_STAGING/lib/libgf_complete.a" ]] && return
    wget -qO "/tmp/gf-complete.tar.gz" "https://github.com/ceph/gf-complete/archive/refs/heads/master.tar.gz"
    mkdir -p "$src"; tar xf "/tmp/gf-complete.tar.gz" -C "$src" --strip-components=1
    mkdir -p "$OUR_STAGING/include" "$OUR_STAGING/lib"
    cp "$src"/include/*.h "$OUR_STAGING/include/" 2>/dev/null || true
    local obj_dir="/tmp/gf-complete-obj"; mkdir -p "$obj_dir"
    local objects=()
    for f in "$src"/src/*.c; do
        [[ -f "$f" ]] || continue
        local obj="$obj_dir/$(basename "${f%.c}").o"
        "${CROSS_PREFIX}gcc" -O2 -fPIC -I"$src/include" -c "$f" -o "$obj"
        objects+=("$obj")
    done
    "${CROSS_PREFIX}ar" rcs "$OUR_STAGING/lib/libgf_complete.a" "${objects[@]}"
}

build_jerasure() {
    local src="/tmp/jerasure-src"
    [[ -f "$OUR_STAGING/lib/libJerasure.a" ]] && return
    wget -qO "/tmp/jerasure.tar.gz" "https://github.com/tsuraan/Jerasure/archive/refs/tags/v2.0.tar.gz" || \
    wget -qO "/tmp/jerasure.tar.gz" "https://github.com/ceph/jerasure/archive/refs/heads/master.tar.gz"
    mkdir -p "$src"; tar xf "/tmp/jerasure.tar.gz" -C "$src" --strip-components=1
    for hdir in "$src/include" "$src/Headers" "$src"; do
        if ls "$hdir"/*.h &>/dev/null; then cp "$hdir"/*.h "$OUR_STAGING/include/"; break; fi
    done
    local obj_dir="/tmp/jerasure-obj"; mkdir -p "$obj_dir"
    local objects=()
    for d in "$src/src" "$src/Examples" "$src"; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*.c; do
            local base="$(basename "$f")"
            [[ "$base" == example* || "$base" == test* || "$base" == decoder* || "$base" == encoder* ]] && continue
            local obj="$obj_dir/${base%.c}.o"
            "${CROSS_PREFIX}gcc" -O2 -fPIC -I"$OUR_STAGING/include" -c "$f" -o "$obj"
            objects+=("$obj")
        done
        [[ ${#objects[@]} -gt 0 ]] && break
    done
    "${CROSS_PREFIX}ar" rcs "$OUR_STAGING/lib/libJerasure.a" "${objects[@]}"
}

build_libevent() {
    local src="/tmp/libevent-2.1.12-stable"
    [[ -f "$OUR_STAGING/lib/libevent.a" ]] && return
    wget -qO "$src.tar.gz" "https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz"
    tar xf "$src.tar.gz" -C /tmp
    local bdir="$src/build"; cmake -B "$bdir" -S "$src" -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" -DCMAKE_INSTALL_PREFIX="$OUR_STAGING" -DBUILD_SHARED_LIBS=OFF -DEVENT__DISABLE_TESTS=ON -DEVENT__DISABLE_SAMPLES=ON -DEVENT__DISABLE_OPENSSL=ON -DEVENT__LIBRARY_TYPE=STATIC
    cmake --build "$bdir" -j"$NJOBS" && cmake --install "$bdir"
}

build_openssl; build_opus; build_ffmpeg; build_jsonc; build_miniupnpc; build_curl; build_gf_complete; build_jerasure; build_libevent

# ── Dependencies Fixes ────────────────────────────────────────────────────────
SS4S_DIR="$SCRIPT_DIR/third-party/ss4s"
if [[ ! -f "$SS4S_DIR/CMakeLists.txt" ]]; then
    mkdir -p "$SCRIPT_DIR/third-party"
    git clone --depth=1 https://github.com/mariotaku/ss4s.git "$SS4S_DIR"
fi

for pc in "$OUR_STAGING"/lib/pkgconfig/*.pc; do
    [[ -f "$pc" ]] || continue
    sed -i -e "/^prefix=/d" -e "/^exec_prefix=/d" -e "s|^includedir=.*|includedir=$OUR_STAGING/include|" -e "s|^libdir=.*|libdir=$OUR_STAGING/lib|" -e "s|\${prefix}|$OUR_STAGING|g" -e "s|\${exec_prefix}|$OUR_STAGING|g" "$pc"
done

CMAKE_MODULES_DIR="$SCRIPT_DIR/cmake"
mkdir -p "$CMAKE_MODULES_DIR"
cat > "$CMAKE_MODULES_DIR/FindNanopb.cmake" << 'EOF'
set(_nanopb_src "@NANOPB_SRC@")
list(APPEND CMAKE_MODULE_PATH "${_nanopb_src}/extra")
include("${_nanopb_src}/extra/FindNanopb.cmake" OPTIONAL RESULT_VARIABLE _found)
if(NOT _found AND NOT TARGET nanopb)
    add_subdirectory("${_nanopb_src}" nanopb_build EXCLUDE_FROM_ALL)
endif()
if(TARGET nanopb AND NOT TARGET Nanopb::nanopb)
    add_library(Nanopb::nanopb ALIAS nanopb)
endif()
if(TARGET Nanopb::nanopb)
    set(Nanopb_FOUND TRUE)
    set(NANOPB_FOUND TRUE)
endif()
EOF
sed -i "s|@NANOPB_SRC@|$CHIAKI_NG_DIR/third-party/nanopb|g" "$CMAKE_MODULES_DIR/FindNanopb.cmake"

if [[ ! -f "$CHIAKI_NG_DIR/third-party/nanopb/CMakeLists.txt" ]]; then
    git -C "$CHIAKI_NG_DIR" submodule update --init third-party/nanopb 2>/dev/null || true
fi
if ! python3 -c "import nanopb" 2>/dev/null; then pip3 install nanopb --break-system-packages -q 2>/dev/null || true; fi

THREAD_C="$CHIAKI_NG_DIR/lib/src/thread.c"
if grep -q 'pthread_clockjoin_np' "$THREAD_C" 2>/dev/null; then
    sed -i 's/pthread_clockjoin_np(\(.*\), CLOCK_MONOTONIC, \(&timeout\))/pthread_timedjoin_np(\1, \2)/' "$THREAD_C"
fi

HINTS_FILE="$BUILD_DIR/chiaki_hints.cmake"
mkdir -p "$BUILD_DIR"
cat > "$HINTS_FILE" << 'EOF'
if(NOT TARGET CURL::libcurl)
    add_library(CURL::libcurl STATIC IMPORTED GLOBAL)
    set_target_properties(CURL::libcurl PROPERTIES IMPORTED_LOCATION "@@STAGING@@/lib/libcurl.a" INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include" INTERFACE_LINK_LIBRARIES "OpenSSL::SSL;OpenSSL::Crypto;z;pthread")
    set(CURL_FOUND TRUE)
    set(CURL_LIBRARIES "@@STAGING@@/lib/libcurl.a")
    set(CURL_INCLUDE_DIRS "@@STAGING@@/include")
    set(CURL_VERSION_STRING "8.7.1")
endif()
set(PYTHON_EXECUTABLE "/usr/bin/python3" CACHE FILEPATH "Host Python" FORCE)
set(Python3_EXECUTABLE "/usr/bin/python3" CACHE FILEPATH "Host Python 3" FORCE)
set(Python_EXECUTABLE "/usr/bin/python3" CACHE FILEPATH "Host Python" FORCE)
if(NOT TARGET GF-Complete::GF-Complete)
    add_library(GF-Complete::GF-Complete STATIC IMPORTED GLOBAL)
    set_target_properties(GF-Complete::GF-Complete PROPERTIES IMPORTED_LOCATION "@@STAGING@@/lib/libgf_complete.a" INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include")
endif()
if(NOT TARGET Jerasure::Jerasure)
    add_library(Jerasure::Jerasure STATIC IMPORTED GLOBAL)
    set_target_properties(Jerasure::Jerasure PROPERTIES IMPORTED_LOCATION "@@STAGING@@/lib/libJerasure.a" INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include" INTERFACE_LINK_LIBRARIES "GF-Complete::GF-Complete")
endif()
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL cmake_language EVAL CODE [[
    foreach(_t PkgConfig::json-c PkgConfig::MINIUPNPC PkgConfig::miniupnpc PkgConfig::libevent PkgConfig::LIBEVENT PkgConfig::libevent_core PkgConfig::libevent_pthreads)
        if(TARGET ${_t})
            set_property(TARGET ${_t} PROPERTY INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include")
        endif()
    endforeach()
    if(TARGET nanopb AND NOT TARGET Nanopb::nanopb)
        add_library(Nanopb::nanopb ALIAS nanopb)
    endif()
]])
EOF
sed -i "s|@@STAGING@@|$OUR_STAGING|g" "$HINTS_FILE"

if ! python3 -c "import google.protobuf" 2>/dev/null; then pip3 install protobuf --break-system-packages 2>/dev/null || true; fi

# ── HACK SDK OPEN SOURCE ──────────────────────────────────────────────────────
mkdir -p "$CHIAKI_NG_DIR/third-party/ss4s/modules/webos/smp/wrapper"
echo "" > "$CHIAKI_NG_DIR/third-party/ss4s/modules/webos/smp/CMakeLists.txt"
echo "" > "$CHIAKI_NG_DIR/third-party/ss4s/modules/webos/smp/wrapper/StarfishMediaAPIs_C.cpp"
mkdir -p "$CHIAKI_NG_DIR/third-party/ss4s/modules/webos/lgnc"
echo "" > "$CHIAKI_NG_DIR/third-party/ss4s/modules/webos/lgnc/CMakeLists.txt"

touch ndl_stub.c
${CC:-arm-webos-linux-gnueabi-gcc} --sysroot=$SYSROOT -shared -fPIC ndl_stub.c -o libNDL_directmedia.so
cp libNDL_directmedia.so $SYSROOT/usr/lib/

# ── Configuring chiaki-webos ──────────────────────────────────────────────────
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
    -DCMAKE_EXE_LINKER_FLAGS="-L$OUR_STAGING/lib -L$SYSROOT/usr/lib -Wl,-rpath,\$ORIGIN/lib -Wl,--unresolved-symbols=ignore-all" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$OUR_STAGING/lib -L$SYSROOT/usr/lib -lm -Wl,--unresolved-symbols=ignore-all" \
    -DCMAKE_MODULE_LINKER_FLAGS="-Wl,--unresolved-symbols=ignore-all" \
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
    -DSS4S_MODULE_DISABLE_NDL_WEBOS4=ON \
    -DSS4S_MODULE_DISABLE_NDL_WEBOS5=OFF

# ── Pre-generating takion.pb ──────────────────────────────────────────────────
PROTO_OUT="$BUILD_DIR/chiaki_lib/protobuf"
TAKION_PROTO="$CHIAKI_NG_DIR/lib/protobuf/takion.proto"
mkdir -p "$PROTO_OUT"

NANOPB_GEN="$(python3 -c 'import sys; import nanopb, os; gen = os.path.join(os.path.dirname(nanopb.__file__), "nanopb_generator.py"); print(gen) if os.path.isfile(gen) else None' 2>/dev/null || true)"
if [[ -z "$NANOPB_GEN" ]]; then
    for candidate in "$CHIAKI_NG_DIR/third-party/nanopb/nanopb_generator.py" "$CHIAKI_NG_DIR/third-party/nanopb/generator/nanopb_generator.py"; do
        if [[ -f "$candidate" ]]; then NANOPB_GEN="$candidate"; break; fi
    done
fi

python3 "$NANOPB_GEN" --output-dir="$PROTO_OUT" --proto-path="$CHIAKI_NG_DIR/lib/protobuf" "$TAKION_PROTO" 2>/dev/null || true

CHIAKI_PB_MAKE="$BUILD_DIR/chiaki_lib/protobuf/CMakeFiles/chiaki-pb.dir/build.make"
if [[ -f "$CHIAKI_PB_MAKE" ]]; then
    python3 -c "
import sys
with open('$CHIAKI_PB_MAKE', 'r', errors='replace') as f: lines = f.readlines()
with open('$CHIAKI_PB_MAKE', 'w') as f:
    f.writelines(['\t@true\n' if '\t' in l and '-E env' in l and 'PATH=' in l else l for l in lines])
"
fi

# ── Building and Packaging ────────────────────────────────────────────────────
cmake --build "$BUILD_DIR" -j"$NJOBS"
cmake --build "$BUILD_DIR" --target ipk
ls "$BUILD_DIR"/*.ipk 2>/dev/null || true
