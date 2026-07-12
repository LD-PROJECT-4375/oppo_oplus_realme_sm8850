#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$(pwd)}"
LABEL="${2:-bundle}"
SRC="$ROOT/common"
OUT="$SRC/out"
DEST="$ROOT/gendwarf-$LABEL"
ARCHIVE="$ROOT/gendwarf-$LABEL.tar.zst"

die() {
  echo "错误：$*" >&2
  exit 1
}

[[ -d "$SRC" ]] || die "源码目录不存在：$SRC"
[[ -d "$OUT" ]] || die "输出目录不存在：$OUT"
[[ -f "$OUT/vmlinux.symvers" ]] || die "缺少 $OUT/vmlinux.symvers"
[[ -f "$OUT/.config" ]] || die "缺少 $OUT/.config"

LLVM_READELF="$ROOT/clang/bin/llvm-readelf"
LLVM_NM="$ROOT/clang/bin/llvm-nm"
if [[ ! -x "$LLVM_READELF" && -x "$ROOT/clang19/bin/llvm-readelf" ]]; then
  LLVM_READELF="$ROOT/clang19/bin/llvm-readelf"
  LLVM_NM="$ROOT/clang19/bin/llvm-nm"
fi
command -v zstd >/dev/null 2>&1 || die "缺少 zstd"
command -v tar >/dev/null 2>&1 || die "缺少 tar"

rm -rf "$DEST"
rm -f "$ARCHIVE"
mkdir -p "$DEST"/{metadata,host,build}

echo "========== 基础构建文件 =========="
cp -a "$OUT/.config" "$DEST/build/config"
cp -a "$OUT/vmlinux.symvers" "$DEST/build/vmlinux.symvers"
[[ -f "$OUT/arch/arm64/boot/Image" ]] &&
  cp -a "$OUT/arch/arm64/boot/Image" "$DEST/build/Image"
[[ -f "$OUT/System.map" ]] &&
  cp -a "$OUT/System.map" "$DEST/build/System.map"

if [[ -f "$OUT/vmlinux" && -x "$LLVM_NM" ]]; then
  "$LLVM_NM" -n "$OUT/vmlinux" |
    grep -E '[[:space:]]__crc_[^[:space:]]+$' \
    > "$DEST/build/vmlinux-crcs.txt" || true
fi

echo "========== 收集 symtypes =========="
SYMTYPES_COUNT="$(
  find "$OUT" -type f -name '*.symtypes' -printf '.' | wc -c
)"
echo "$SYMTYPES_COUNT" > "$DEST/metadata/symtypes-count.txt"
(( SYMTYPES_COUNT > 0 )) || die "没有生成任何 .symtypes；确认构建时设置了 KBUILD_SYMTYPES=1"

(
  cd "$SRC"
  find out -type f -name '*.symtypes' -print0 |
    LC_ALL=C sort -z |
    xargs -0 sha256sum
) > "$DEST/metadata/symtypes.sha256"

(
  cd "$SRC"
  find out -type f -name '*.symtypes' -print0 |
    LC_ALL=C sort -z |
    tar --null -T - -I 'zstd -T0 -19' -cf "$DEST/build/symtypes.tar.zst"
)

echo "========== 收集 Kbuild .cmd =========="
(
  cd "$SRC"
  find out -type f -name '.*.cmd' -print0 |
    LC_ALL=C sort -z |
    tar --null -T - -I 'zstd -T0 -19' -cf "$DEST/build/cmdfiles.tar.zst"
)

echo "========== 源码输入清单 =========="
(
  cd "$SRC"
  find . \
    -path './out' -prune -o \
    -path './.git' -prune -o \
    -type f \
    \( \
      -name '*.c' -o -name '*.h' -o -name '*.S' -o -name '*.s' -o \
      -name '*.rs' -o -name '*.lds' -o -name '*.lds.S' -o \
      -name 'Makefile' -o -name 'Kbuild' -o -name 'Kconfig' -o \
      -name 'Kconfig.*' -o -name 'build.config*' -o \
      -name '*.py' -o -name '*.pl' -o -name '*.sh' \
    \) \
    ! -name 'cc-wrapper*' \
    ! -name 'ld-wrapper*' \
    -print0 |
    LC_ALL=C sort -z |
    xargs -0 sha256sum
) > "$DEST/metadata/source-inputs.sha256"

echo "========== 构建与运行环境 =========="
{
  echo "label=$LABEL"
  echo "date_utc=$(date -u +%FT%TZ)"
  echo "pwd=$(pwd -P)"
  echo "root=$(realpath "$ROOT")"
  echo "source=$(realpath "$SRC")"
  echo "out=$(realpath "$OUT")"
  echo "github_actions=${GITHUB_ACTIONS:-}"
  echo "github_run_id=${GITHUB_RUN_ID:-}"
  echo "github_sha=${GITHUB_SHA:-}"
  echo "github_ref=${GITHUB_REF:-}"
  echo "runner_os=${RUNNER_OS:-}"
  echo "runner_arch=${RUNNER_ARCH:-}"
  echo "image_os=${ImageOS:-}"
  echo "image_version=${ImageVersion:-}"
  echo
  uname -a
  echo
  cat /etc/os-release 2>/dev/null || true
} > "$DEST/host/platform.txt"

{
  env |
    grep -E '^(ARCH|SUBARCH|LLVM|LLVM_IAS|CROSS_COMPILE|CC|LD|HOSTCC|HOSTLD|AR|NM|OBJCOPY|OBJDUMP|READELF|STRIP|RUSTC|BINDGEN|LIBCLANG_PATH|KCFLAGS|KCPPFLAGS|KBUILD_|SOURCE_DATE_EPOCH|CCACHE_|FAKESTAT|FAKETIME|LD_PRELOAD|PATH)=' |
    LC_ALL=C sort
} > "$DEST/host/build-env.txt"

{
  for tool in \
    clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-readelf \
    pahole rustc bindgen make tar zstd; do
    echo "===== $tool ====="
    command -v "$tool" || true
    "$tool" --version 2>&1 | head -n 5 || true
  done
} > "$DEST/host/tool-versions.txt"

{
  echo "===== dpkg relevant packages ====="
  dpkg-query -W -f='${Package}\t${Version}\n' \
    'libdw*' 'libelf*' 'elfutils*' 'zlib1g*' 'libc6*' \
    'binutils*' 'clang*' 'llvm*' 2>/dev/null |
    LC_ALL=C sort -u || true
  echo
  echo "===== ldd version ====="
  ldd --version 2>&1 | head -n 5 || true
  echo
  echo "===== gcc/clang host defaults ====="
  cc --version 2>&1 | head -n 5 || true
  clang --version 2>&1 | head -n 5 || true
} > "$DEST/host/packages.txt"

GENDWARF="$OUT/scripts/gendwarfksyms/gendwarfksyms"
if [[ -x "$GENDWARF" ]]; then
  cp -a "$GENDWARF" "$DEST/host/gendwarfksyms"
  {
    echo "===== file ====="
    file "$GENDWARF" || true
    echo
    echo "===== sha256 ====="
    sha256sum "$GENDWARF"
    echo
    echo "===== ldd ====="
    ldd "$GENDWARF" || true
    echo
    echo "===== dynamic section ====="
    "$LLVM_READELF" -d "$GENDWARF" 2>/dev/null || readelf -d "$GENDWARF" || true
    echo
    echo "===== notes ====="
    "$LLVM_READELF" -n "$GENDWARF" 2>/dev/null || readelf -n "$GENDWARF" || true
    echo
    echo "===== comment ====="
    "$LLVM_READELF" -p .comment "$GENDWARF" 2>/dev/null ||
      readelf -p .comment "$GENDWARF" || true
  } > "$DEST/host/gendwarfksyms-info.txt"

  {
    ldd "$GENDWARF" |
      awk '
        /=> \// {print $3}
        /^\// {print $1}
      ' |
      LC_ALL=C sort -u |
      while IFS= read -r lib; do
        [[ -f "$lib" ]] && sha256sum "$lib"
      done
  } > "$DEST/host/gendwarfksyms-libs.sha256"
fi

for cmd in \
  "$OUT/scripts/gendwarfksyms/.gendwarfksyms.cmd" \
  "$OUT/scripts/gendwarfksyms/.gendwarfksyms.o.cmd" \
  "$OUT/init/.init_task.o.cmd" \
  "$OUT/kernel/module/.version.o.cmd"; do
  if [[ -f "$cmd" ]]; then
    cp -a "$cmd" "$DEST/host/$(basename "$(dirname "$cmd")")-$(basename "$cmd")"
  fi
done

{
  sha256sum "$DEST/build/config"
  sha256sum "$DEST/build/vmlinux.symvers"
  [[ -f "$DEST/build/Image" ]] && sha256sum "$DEST/build/Image"
  [[ -f "$DEST/host/gendwarfksyms" ]] && sha256sum "$DEST/host/gendwarfksyms"
} > "$DEST/SHA256SUMS"

echo "========== 打包 =========="
tar -C "$DEST" -I 'zstd -T0 -19' -cf "$ARCHIVE" .

echo
echo "symtypes 数量：$SYMTYPES_COUNT"
echo "输出：$ARCHIVE"
sha256sum "$ARCHIVE"
