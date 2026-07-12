#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

ROOT="${HOME}/kernel_workspace"
BUILDER="Local"
BUILD_HOST="Local"
CONFIG_SOURCE="reference"
CLEAN_MODE="all"
BOOTSTRAP_MODE="auto"
INSTALL_DEPS=false
TIMESTAMP_MODE="none"
BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970"
FAKETIME_VALUE="@2025-05-25 13:00:00"
FAKESTAT_VALUE="2025-05-25 12:00:00"
LOG_ENABLED=true
DIST_ROOT=""
JOBS="$(nproc 2>/dev/null || echo 8)"
CCACHE_ENABLED=false
SYMTYPES_ENABLED=false
VERIFY_SYMVERS="auto"
INCLUDE_VMLINUX=false

SOURCE_URL="https://github.com/cctv18/android_gki_kernel_common/archive/refs/heads/android16-6.12-2025-06.zip"
CLANG_URL="https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang19-r536225/clang-r536225.zip"
RUST_URL="https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang19-r536225/rust.zip"
BUILD_TOOLS_URL="https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang19-r536225/build-tools.zip"

SOURCE_SHA256="${SOURCE_SHA256:-}"
CLANG_SHA256="${CLANG_SHA256:-}"
RUST_SHA256="${RUST_SHA256:-}"
BUILD_TOOLS_SHA256="${BUILD_TOOLS_SHA256:-}"

usage() {
  cat <<'EOF'
Android 16 GKI 6.12.23 本地一键配置与编译

用法：
  build_gki.sh [选项]

核心选项：
  --root PATH                 kernel_workspace，默认 ~/kernel_workspace
  --builder NAME              构建者，默认 Local
  --build-host NAME           构建主机名，默认 Local
  --config reference|gki|PATH 配置来源，默认 reference
  --clean none|config|out|all 默认 all
  --bootstrap auto|on|off     自动搭建源码和工具链，默认 auto
  --install-deps              使用 apt 安装宿主依赖
  --dist-dir PATH             产物目录；不会作为 Kbuild O= 路径
  --jobs N                    并行数

时间选项：
  --timestamp-mode none|fixed|fake
      none   不固定时间
      fixed  仅固定 KBUILD_BUILD_TIMESTAMP
      fake   同时用 libfaketime/libfakestat 劫持编译器和链接器时间
  --timestamp STRING          KBUILD 时间，默认 Unix epoch 显示时间
  --fake-time STRING          FAKETIME，默认 @2025-05-25 13:00:00
  --fake-stat STRING          FAKESTAT，默认 2025-05-25 12:00:00

行为选项：
  --log on|off                保存完整日志，默认 on
  --ccache on|off             使用安全模式 ccache，默认 off
  --symtypes on|off           生成 .symtypes，默认 off
  --verify-symvers auto|on|off
                              校验 reference-workflow/vmlinux.symvers
  --include-vmlinux           在输出中包含完整 vmlinux
  --source-url URL            覆盖源码压缩包 URL
  --clang-url URL             覆盖 Clang 压缩包 URL
  --rust-url URL              覆盖 Rust 压缩包 URL
  --build-tools-url URL       覆盖 build-tools 压缩包 URL
  -h, --help                  显示帮助

示例：
  # 使用现有环境和参考配置，全量干净构建
  ./scripts/build_gki.sh

  # 自定义构建者和输出目录
  ./scripts/build_gki.sh --builder MI --dist-dir /mnt/f/gki-output

  # 复现工作流时间环境
  ./scripts/build_gki.sh --timestamp-mode fake

  # 首次机器自动安装依赖并搭建全部环境
  sudo -E ./scripts/build_gki.sh --install-deps --bootstrap on
EOF
}

bool_value() {
  case "${1,,}" in
    on|true|1|yes) echo true ;;
    off|false|0|no) echo false ;;
    *) echo "布尔值无效：$1" >&2; exit 2 ;;
  esac
}

while (($#)); do
  case "$1" in
    --root) ROOT="${2:?}"; shift 2 ;;
    --builder) BUILDER="${2:?}"; shift 2 ;;
    --build-host) BUILD_HOST="${2:?}"; shift 2 ;;
    --config) CONFIG_SOURCE="${2:?}"; shift 2 ;;
    --clean) CLEAN_MODE="${2:?}"; shift 2 ;;
    --bootstrap) BOOTSTRAP_MODE="${2:?}"; shift 2 ;;
    --install-deps) INSTALL_DEPS=true; shift ;;
    --timestamp-mode) TIMESTAMP_MODE="${2:?}"; shift 2 ;;
    --timestamp) BUILD_TIMESTAMP="${2:?}"; shift 2 ;;
    --fake-time) FAKETIME_VALUE="${2:?}"; shift 2 ;;
    --fake-stat) FAKESTAT_VALUE="${2:?}"; shift 2 ;;
    --log) LOG_ENABLED="$(bool_value "${2:?}")"; shift 2 ;;
    --dist-dir) DIST_ROOT="${2:?}"; shift 2 ;;
    --jobs) JOBS="${2:?}"; shift 2 ;;
    --ccache) CCACHE_ENABLED="$(bool_value "${2:?}")"; shift 2 ;;
    --symtypes) SYMTYPES_ENABLED="$(bool_value "${2:?}")"; shift 2 ;;
    --verify-symvers) VERIFY_SYMVERS="${2:?}"; shift 2 ;;
    --include-vmlinux) INCLUDE_VMLINUX=true; shift ;;
    --source-url) SOURCE_URL="${2:?}"; shift 2 ;;
    --clang-url) CLANG_URL="${2:?}"; shift 2 ;;
    --rust-url) RUST_URL="${2:?}"; shift 2 ;;
    --build-tools-url) BUILD_TOOLS_URL="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() {
  echo "错误：$*" >&2
  exit 1
}
section() {
  printf '\n========== %s ==========\n' "$*"
}
sanitize() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._+-' '_'
}

case "$CLEAN_MODE" in none|config|out|all) ;; *) fail "--clean 值无效" ;; esac
case "$BOOTSTRAP_MODE" in auto|on|off) ;; *) fail "--bootstrap 值无效" ;; esac
case "$TIMESTAMP_MODE" in none|fixed|fake) ;; *) fail "--timestamp-mode 值无效" ;; esac
case "$VERIFY_SYMVERS" in auto|on|off) ;; *) fail "--verify-symvers 值无效" ;; esac
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "--jobs 必须是正整数"
[[ "$BUILDER" != *$'\n'* && "$BUILD_HOST" != *$'\n'* ]] || fail "构建者名称不能包含换行"

ROOT="$(realpath -m "$ROOT")"
SRC="$ROOT/common"
OUT="$SRC/out"             # 固定相对布局，绝不使用 dist 作为 O=
REF_DIR="$ROOT/reference-workflow"
CACHE_DIR="${DOWNLOAD_CACHE_DIR:-$ROOT/.cache/downloads}"
DIST_ROOT="${DIST_ROOT:-$ROOT/dist}"
LOG_DIR="$ROOT/logs"
RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$$"
LOG_FILE="$LOG_DIR/build-$RUN_ID.log"

mkdir -p "$ROOT" "$CACHE_DIR" "$DIST_ROOT" "$LOG_DIR"

install_dependencies() {
  command -v apt-get >/dev/null 2>&1 || fail "当前系统没有 apt-get"
  if [[ "$EUID" -eq 0 ]]; then
    SUDO=()
  else
    command -v sudo >/dev/null 2>&1 || fail "安装依赖需要 root 或 sudo"
    SUDO=(sudo)
  fi
  "${SUDO[@]}" apt-get update
  DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y --no-install-recommends \
    aria2 bc binutils bison ca-certificates cpio curl file flex git \
    libdw-dev libelf-dev libssl-dev lz4 make perl pkg-config \
    python-is-python3 python3 rsync unzip zip zstd
  if [[ "$CCACHE_ENABLED" == true ]]; then
    DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y --no-install-recommends ccache
  fi
}

download_archive() {
  local url="$1" output="$2" expected="$3"
  local part="${output}.part"

  if [[ -s "$output" ]]; then
    if [[ -n "$expected" ]]; then
      actual="$(sha256sum "$output" | awk '{print $1}')"
      if [[ "$actual" == "$expected" ]]; then
        echo "使用缓存：$output"
        return
      fi
      echo "缓存哈希不匹配，重新下载：$output"
      rm -f "$output"
    else
      if unzip -tq "$output" >/dev/null 2>&1; then
        echo "使用已校验缓存：$output"
        return
      fi
      rm -f "$output"
    fi
  fi

  rm -f "$part"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c \
      --continue=true \
      --max-connection-per-server=8 \
      --split=8 \
      --min-split-size=4M \
      --file-allocation=none \
      --retry-wait=5 \
      --max-tries=10 \
      --timeout=60 \
      --dir="$(dirname "$part")" \
      --out="$(basename "$part")" \
      "$url"
  else
    curl -fL \
      --retry 8 \
      --retry-all-errors \
      --connect-timeout 30 \
      --output "$part" \
      "$url"
  fi

  unzip -tq "$part" >/dev/null
  if [[ -n "$expected" ]]; then
    actual="$(sha256sum "$part" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] ||
      fail "下载文件哈希错误：$part；实际 $actual，期望 $expected"
  fi
  mv "$part" "$output"
}

extract_component() {
  local archive="$1" target="$2" probe="$3"
  local temp
  temp="$(mktemp -d "$ROOT/.extract.XXXXXX")"
  unzip -q "$archive" -d "$temp"

  candidate=""
  if [[ -e "$temp/$probe" ]]; then
    candidate="$temp"
  else
    # 压缩包可能带一层顶级目录。选择路径最短的匹配，避免源码树中
    # 其他嵌套 Makefile 被误判为源码根目录。
    found="$(
      find "$temp" -type f -path "*/$probe" -printf '%p\n' |
        awk '{ print length($0) "\t" $0 }' |
        LC_ALL=C sort -n -k1,1 |
        cut -f2- |
        head -n1
    )"
    [[ -n "$found" ]] && candidate="${found%/$probe}"
  fi

  [[ -n "$candidate" && -e "$candidate/$probe" ]] ||
    fail "压缩包 $archive 中未找到 $probe"

  rm -rf "$target"
  mkdir -p "$(dirname "$target")"
  if [[ "$candidate" == "$temp" ]]; then
    mv "$temp" "$target"
  else
    mv "$candidate" "$target"
    rm -rf "$temp"
  fi
}

bootstrap_environment() {
  section "搭建源码与工具链"
  mkdir -p "$CACHE_DIR"

  if [[ ! -f "$SRC/Makefile" ]]; then
    [[ "$BOOTSTRAP_MODE" != off ]] || fail "缺少源码目录，且 bootstrap=off"
    archive="$CACHE_DIR/common.zip"
    download_archive "$SOURCE_URL" "$archive" "$SOURCE_SHA256"
    extract_component "$archive" "$SRC" "Makefile"
  fi

  if [[ ! -x "$ROOT/clang/bin/clang" && ! -x "$ROOT/clang19/bin/clang" ]]; then
    [[ "$BOOTSTRAP_MODE" != off ]] || fail "缺少 Clang，且 bootstrap=off"
    archive="$CACHE_DIR/clang-r536225.zip"
    download_archive "$CLANG_URL" "$archive" "$CLANG_SHA256"
    extract_component "$archive" "$ROOT/clang" "bin/clang"
  fi

  if [[ ! -x "$ROOT/rust/bin/rustc" ]]; then
    [[ "$BOOTSTRAP_MODE" != off ]] || fail "缺少 Rust，且 bootstrap=off"
    archive="$CACHE_DIR/rust.zip"
    download_archive "$RUST_URL" "$archive" "$RUST_SHA256"
    extract_component "$archive" "$ROOT/rust" "bin/rustc"
  fi

  if [[ ! -x "$ROOT/build-tools/bin/pahole" ]]; then
    [[ "$BOOTSTRAP_MODE" != off ]] || fail "缺少 build-tools，且 bootstrap=off"
    archive="$CACHE_DIR/build-tools.zip"
    download_archive "$BUILD_TOOLS_URL" "$archive" "$BUILD_TOOLS_SHA256"
    extract_component "$archive" "$ROOT/build-tools" "bin/pahole"
  fi
}

clean_inherited_environment() {
  section "清理继承环境"
  unset \
    CC CXX CPP LD AR AS NM STRIP OBJCOPY OBJDUMP OBJSIZE READELF \
    HOSTCC HOSTCXX HOSTLD CROSS_COMPILE CROSS_COMPILE_ARM32 \
    CLANG_TRIPLE CLANG_PREBUILT_BIN BUILD_CONFIG \
    SKIP_MRPROPER SKIP_DEFCONFIG KBUILD_OUTPUT KBUILD_ABS_SRCTREE \
    KBUILD_BUILD_USER KBUILD_BUILD_HOST KBUILD_BUILD_VERSION \
    KBUILD_BUILD_TIMESTAMP KBUILD_SYMTYPES \
    KBUILD_GENDWARFKSYMS_STABLE SOURCE_DATE_EPOCH \
    KCFLAGS KCPPFLAGS KAFLAGS CFLAGS CPPFLAGS LDFLAGS \
    LD_PRELOAD FAKETIME FAKESTAT PRELOAD_LIBS \
    CCACHE_LOGFILE CCACHE_PREFIX CCACHE_BASEDIR CCACHE_COMPILERCHECK \
    CCACHE_DISABLE RUSTFLAGS RUSTFLAGS_KERNEL MAKEFLAGS || true
  hash -r
}

clean_configuration() {
  section "清理配置和输出"
  case "$CLEAN_MODE" in
    none)
      echo "保留现有 common/out"
      ;;
    config)
      rm -f \
        "$OUT/.config" \
        "$OUT/.config.old" \
        "$OUT/include/config/auto.conf" \
        "$OUT/include/config/auto.conf.cmd" \
        "$OUT/include/generated/autoconf.h"
      ;;
    out|all)
      rm -rf "$OUT"
      ;;
  esac
  rm -rf "$SRC/.build-wrapper"
  mkdir -p "$OUT"
}

setup_build_environment() {
  section "搭建构建环境"

  if [[ -x "$ROOT/clang/bin/clang" ]]; then
    CLANG_ROOT="$ROOT/clang"
  elif [[ -x "$ROOT/clang19/bin/clang" ]]; then
    CLANG_ROOT="$ROOT/clang19"
  else
    fail "找不到 clang/bin/clang 或 clang19/bin/clang"
  fi

  export PATH="$CLANG_ROOT/bin:$ROOT/build-tools/bin:$ROOT/build-tools/path/linux-x86:$ROOT/rust/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export ARCH=arm64
  export SUBARCH=arm64
  export LLVM=1
  export LLVM_IAS=1
  export CROSS_COMPILE=aarch64-linux-gnu-

  export HOSTCC=clang
  export HOSTCXX=clang++
  export HOSTLD=ld.lld
  export AR=llvm-ar
  export NM=llvm-nm
  export AS=clang
  export READELF=llvm-readelf
  export OBJCOPY=llvm-objcopy
  export OBJDUMP=llvm-objdump
  export OBJSIZE=llvm-size
  export STRIP=llvm-strip

  export RUSTC=rustc
  export BINDGEN=bindgen

  if [[ -d "$CLANG_ROOT/lib" ]]; then
    export LIBCLANG_PATH="$CLANG_ROOT/lib"
  elif [[ -d "$CLANG_ROOT/lib64" ]]; then
    export LIBCLANG_PATH="$CLANG_ROOT/lib64"
  else
    fail "找不到 libclang 目录"
  fi

  export TZ=UTC
  export LC_ALL=C

  export KBUILD_BUILD_USER="$BUILDER"
  export KBUILD_BUILD_HOST="$BUILD_HOST"
  export KBUILD_BUILD_VERSION=1

  # Android 16 GKI 6.12 的稳定 KMI 必需项。
  export KBUILD_GENDWARFKSYMS_STABLE=1

  if [[ "$SYMTYPES_ENABLED" == true ]]; then
    export KBUILD_SYMTYPES=1
  else
    unset KBUILD_SYMTYPES || true
  fi

  case "$TIMESTAMP_MODE" in
    none)
      unset KBUILD_BUILD_TIMESTAMP || true
      ;;
    fixed|fake)
      export KBUILD_BUILD_TIMESTAMP="$BUILD_TIMESTAMP"
      ;;
  esac

  ROOT_REAL="$(realpath "$ROOT")"
  export KCFLAGS="\
-fdebug-prefix-map=$ROOT_REAL=. \
-fmacro-prefix-map=$ROOT_REAL=. \
-ffile-prefix-map=$ROOT_REAL=. \
-no-canonical-prefixes \
-O2 \
-pipe \
-Wno-error \
-fno-stack-protector \
-D__ANDROID_COMMON_KERNEL__"

  command -v clang >/dev/null || fail "clang 不可用"
  command -v ld.lld >/dev/null || fail "ld.lld 不可用"
  command -v rustc >/dev/null || fail "rustc 不可用"
  command -v bindgen >/dev/null || fail "bindgen 不可用"
  command -v pahole >/dev/null || fail "pahole 不可用"
  command -v make >/dev/null || fail "make 不可用"
  command -v bison >/dev/null || fail "bison 不可用"
  command -v flex >/dev/null || fail "flex 不可用"

  echo "Builder: $KBUILD_BUILD_USER@$KBUILD_BUILD_HOST"
  echo "Timestamp mode: $TIMESTAMP_MODE"
  echo "Stable KMI: KBUILD_GENDWARFKSYMS_STABLE=1"
  clang --version | head -n 2
  ld.lld --version | head -n 1
  rustc --version
  bindgen --version
  pahole --version
}

setup_wrappers() {
  section "搭建编译器包装器"
  WRAPPER_DIR="$SRC/.build-wrapper"
  mkdir -p "$WRAPPER_DIR"

  if [[ "$CCACHE_ENABLED" == true ]]; then
    if [[ -x "$ROOT/ccache-ecs" ]]; then
      CCACHE_BIN="$ROOT/ccache-ecs"
    else
      CCACHE_BIN="$(command -v ccache || true)"
    fi
    [[ -n "$CCACHE_BIN" && -x "$CCACHE_BIN" ]] || fail "ccache=on 但没有找到 ccache"

    export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache-gki-6.12.23}"
    export CCACHE_BASEDIR="$(dirname "$ROOT")"
    export CCACHE_COMPILERCHECK=content
    export CCACHE_NOHASHDIR=true
    export CCACHE_NOHARDLINK=true
    mkdir -p "$CCACHE_DIR"
    "$CCACHE_BIN" -M "${CCACHE_MAXSIZE:-3G}" >/dev/null
    "$CCACHE_BIN" -o compression=true >/dev/null
  else
    CCACHE_BIN=""
  fi

  PRELOAD_LIBS=""
  if [[ "$TIMESTAMP_MODE" == fake ]]; then
    FAKESTAT_LIB="$ROOT/libfakestat.so"
    FAKETIME_LIB="$ROOT/libfaketimeMT.so"
    [[ -f "$FAKESTAT_LIB" ]] || fail "fake 模式缺少 $FAKESTAT_LIB"
    [[ -f "$FAKETIME_LIB" ]] || fail "fake 模式缺少 $FAKETIME_LIB"
    PRELOAD_LIBS="$FAKESTAT_LIB $FAKETIME_LIB"
  fi

  cat > "$WRAPPER_DIR/cc" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
EOF
  if [[ "$TIMESTAMP_MODE" == fake ]]; then
    cat >> "$WRAPPER_DIR/cc" <<EOF
export LD_PRELOAD="$PRELOAD_LIBS"
export FAKETIME="$FAKETIME_VALUE"
export FAKESTAT="$FAKESTAT_VALUE"
EOF
  fi
  if [[ "$CCACHE_ENABLED" == true ]]; then
    cat >> "$WRAPPER_DIR/cc" <<EOF
exec "$CCACHE_BIN" "$CLANG_ROOT/bin/clang" "\$@"
EOF
  else
    cat >> "$WRAPPER_DIR/cc" <<EOF
exec "$CLANG_ROOT/bin/clang" "\$@"
EOF
  fi

  cat > "$WRAPPER_DIR/ld" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
EOF
  if [[ "$TIMESTAMP_MODE" == fake ]]; then
    cat >> "$WRAPPER_DIR/ld" <<EOF
export LD_PRELOAD="$PRELOAD_LIBS"
export FAKETIME="$FAKETIME_VALUE"
export FAKESTAT="$FAKESTAT_VALUE"
EOF
  fi
  cat >> "$WRAPPER_DIR/ld" <<EOF
exec "$CLANG_ROOT/bin/ld.lld" "\$@"
EOF

  chmod +x "$WRAPPER_DIR/cc" "$WRAPPER_DIR/ld"
  BUILD_CC="$WRAPPER_DIR/cc"
  BUILD_LD="$WRAPPER_DIR/ld"
}

setup_configuration() {
  section "搭建内核配置"
  cd "$SRC"

  case "$CONFIG_SOURCE" in
    reference)
      [[ -f "$REF_DIR/config" ]] || fail "缺少 $REF_DIR/config"
      cp -a "$REF_DIR/config" "$OUT/.config"
      make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
        CC=clang LD=ld.lld OBJCOPY=llvm-objcopy olddefconfig

      if ! cmp -s "$REF_DIR/config" "$OUT/.config"; then
        diff -u "$REF_DIR/config" "$OUT/.config" \
          > "$ROOT/config-reference-vs-generated.diff" || true
        fail "参考配置经 olddefconfig 后发生变化"
      fi
      ;;
    gki)
      make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
        CC=clang LD=ld.lld OBJCOPY=llvm-objcopy gki_defconfig
      ;;
    *)
      config_path="$(realpath -m "$CONFIG_SOURCE")"
      [[ -f "$config_path" ]] || fail "配置文件不存在：$config_path"
      cp -a "$config_path" "$OUT/.config"
      make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
        CC=clang LD=ld.lld OBJCOPY=llvm-objcopy olddefconfig
      ;;
  esac

  [[ -s "$OUT/.config" ]] || fail "没有生成 .config"
  grep -qx 'CONFIG_GENDWARFKSYMS=y' "$OUT/.config" ||
    fail "配置未启用 CONFIG_GENDWARFKSYMS"
  grep -qx 'CONFIG_RUST=y' "$OUT/.config" ||
    fail "配置未启用 CONFIG_RUST"
}

build_kernel() {
  section "编译 Image"
  cd "$SRC"

  MAKE_ARGS=(
    -j"$JOBS"
    O=out
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    CROSS_COMPILE=aarch64-linux-gnu-
    CC="$BUILD_CC"
    LD="$BUILD_LD"
    OBJCOPY=llvm-objcopy
    KBUILD_GENDWARFKSYMS_STABLE=1
  )
  if [[ "$SYMTYPES_ENABLED" == true ]]; then
    MAKE_ARGS+=(KBUILD_SYMTYPES=1)
  fi

  if [[ "$LOG_ENABLED" == true ]]; then
    make "${MAKE_ARGS[@]}" Image 2>&1 | tee "$LOG_FILE"
  else
    make "${MAKE_ARGS[@]}" Image
  fi
}

verify_build() {
  section "验证产物"
  IMAGE="$OUT/arch/arm64/boot/Image"
  VMLINUX="$OUT/vmlinux"
  SYMVERS="$OUT/vmlinux.symvers"
  CONFIG="$OUT/.config"

  [[ -s "$IMAGE" ]] || fail "Image 不存在"
  [[ -s "$VMLINUX" ]] || fail "vmlinux 不存在"
  [[ -s "$SYMVERS" ]] || fail "vmlinux.symvers 不存在"

  cd "$SRC"
  KERNEL_RELEASE="$(make -s O=out ARCH=arm64 LLVM=1 kernelrelease)"
  echo "kernelrelease=$KERNEL_RELEASE"

  grep -a -m1 'Linux version ' "$IMAGE" || true

  if grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "$CONFIG"; then
    llvm-readelf -S --wide "$VMLINUX" |
      grep -E '[[:space:]]\.BTF([[:space:]]|$)' >/dev/null ||
      fail "配置启用了 BTF，但 vmlinux 中没有 .BTF"
    echo "BTF：通过"
  fi

  should_verify=false
  case "$VERIFY_SYMVERS" in
    on) should_verify=true ;;
    auto)
      [[ "$CONFIG_SOURCE" == reference && -f "$REF_DIR/vmlinux.symvers" ]] &&
        should_verify=true
      ;;
    off) ;;
  esac

  if [[ "$should_verify" == true ]]; then
    [[ -f "$REF_DIR/vmlinux.symvers" ]] ||
      fail "要求校验 symvers，但参考文件不存在"
    if ! cmp -s "$REF_DIR/vmlinux.symvers" "$SYMVERS"; then
      diff -u "$REF_DIR/vmlinux.symvers" "$SYMVERS" \
        > "$ROOT/vmlinux.symvers.verify.diff" || true
      fail "vmlinux.symvers 与参考不一致"
    fi
    echo "KMI CRC：通过"
  fi

  if [[ "$SYMTYPES_ENABLED" == true ]]; then
    count="$(find "$OUT" -type f -name '*.symtypes' | wc -l)"
    echo "symtypes 数量：$count"
    ((count > 0)) || fail "要求 symtypes，但未生成"
  fi
}

publish_artifacts() {
  section "整理输出产物"
  release_safe="$(sanitize "$KERNEL_RELEASE")"
  final_dir="$DIST_ROOT/gki-${release_safe}-${RUN_ID}"
  stage="$(mktemp -d "$DIST_ROOT/.stage.XXXXXX")"

  cp -a "$IMAGE" "$stage/Image"
  cp -a "$CONFIG" "$stage/config"
  cp -a "$SYMVERS" "$stage/vmlinux.symvers"
  [[ -f "$OUT/System.map" ]] && cp -a "$OUT/System.map" "$stage/System.map"
  [[ "$INCLUDE_VMLINUX" == true ]] && cp -a "$VMLINUX" "$stage/vmlinux"
  [[ "$LOG_ENABLED" == true && -f "$LOG_FILE" ]] && cp -a "$LOG_FILE" "$stage/build.log"

  if [[ "$SYMTYPES_ENABLED" == true ]]; then
    (
      cd "$SRC"
      find out -type f -name '*.symtypes' -print0 |
        LC_ALL=C sort -z |
        tar --null -T - -I 'zstd -T0 -19' -cf "$stage/symtypes.tar.zst"
    )
  fi

  {
    echo "kernel_release=$KERNEL_RELEASE"
    echo "builder=$BUILDER"
    echo "build_host=$BUILD_HOST"
    echo "timestamp_mode=$TIMESTAMP_MODE"
    echo "build_timestamp=$BUILD_TIMESTAMP"
    echo "kbuild_gendwarfksyms_stable=1"
    echo "config_source=$CONFIG_SOURCE"
    echo "clean_mode=$CLEAN_MODE"
    echo "ccache=$CCACHE_ENABLED"
    echo "symtypes=$SYMTYPES_ENABLED"
    echo "jobs=$JOBS"
    echo "source_url=$SOURCE_URL"
    echo
    clang --version | head -n 2
    ld.lld --version | head -n 1
    rustc --version
    bindgen --version
    pahole --version
  } > "$stage/build-info.txt"

  (
    cd "$stage"
    sha256sum ./* > SHA256SUMS
  )

  # 最终目录采用原子 move；Kbuild 的 O=out 保持不变。
  mv "$stage" "$final_dir"
  ln -sfn "$(basename "$final_dir")" "$DIST_ROOT/latest"

  echo "产物目录：$final_dir"
  find "$final_dir" -maxdepth 1 -type f -printf '  %f  %s bytes\n' | sort
}

if [[ "$INSTALL_DEPS" == true ]]; then
  section "安装宿主依赖"
  install_dependencies
fi

clean_inherited_environment

if [[ "$BOOTSTRAP_MODE" == on ]] ||
   [[ "$BOOTSTRAP_MODE" == auto && (
      ! -f "$SRC/Makefile" ||
      ( ! -x "$ROOT/clang/bin/clang" && ! -x "$ROOT/clang19/bin/clang" ) ||
      ! -x "$ROOT/rust/bin/rustc" ||
      ! -x "$ROOT/build-tools/bin/pahole"
   ) ]]; then
  bootstrap_environment
fi

[[ -f "$SRC/Makefile" ]] || fail "源码未就绪"
clean_configuration
setup_build_environment
setup_wrappers
setup_configuration
build_kernel
verify_build
publish_artifacts

section "完成"
echo "原生 stable CRC 构建成功。"
