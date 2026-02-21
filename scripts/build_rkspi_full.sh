#!/bin/bash
# build_rkspi_full.sh - build RK SPI loader image (tpl + spl + u-boot.itb)
# Produces rkspi_loader.img (4MB, padded) for RK3588 OrangePi_5_Max
# Usage: ./build_rkspi_full.sh [defconfig]

set -euo pipefail
# support special modes before normal build
#   --make-test <sectors> [<real-bytes>]
#       create a minimal rkspi file containing the given number of 2KiB init
#       sectors, optionally copying <real-bytes> from the official loader as
#       non‑zero prefix.  Useful for exercising ROM checks without a full
#       U-Boot build.
#   --make-hybrid <offset> [<custom-file>]
#       start with the vendor rkspi_loader.img header+init (up to <offset>)
#       then append the contents of <custom-file> (defaults to OUT_IMG).
if [ "${1:-}" = "--make-test" ]; then
    SECTORS=${2:-109}
    REALBYTES=${3:-0}
    TMP=test.img
    echo "[test] generating ${SECTORS} init sectors (real ${REALBYTES} bytes)"
    truncate -s $((SECTORS * 2048)) tmp.bin
    if [ ${REALBYTES} -gt 0 ]; then
        dd if=compare/rkspi_loader.img of=tmp.bin bs=1 skip=$((0x8080)) count=${REALBYTES} seek=$((0x8080)) conv=notrunc
    fi
    tools/mkimage -T rkspi -n rk3588 -d tmp.bin ${TMP}
    # patch size field and duplicate
    INIT_SIZE=$(tools/mkimage -l ${TMP} 2>/dev/null | awk '/Init Data Size/ {print $4}')
    SECS=$((INIT_SIZE / 2048))
    VAL=$(( (SECS << 16) | 4 ))
    HEX=$(printf '%02x%02x%02x%02x' $((VAL&0xff)) $(((VAL>>8)&0xff)) $(((VAL>>16)&0xff)) $(((VAL>>24)&0xff)))
    printf '%s' "${HEX}" | xxd -r -p | dd of=${TMP} bs=1 seek=0x78 conv=notrunc
    dd if=${TMP} bs=1 skip=0x78 count=4 of=${TMP} bs=1 seek=0x8078 conv=notrunc
    echo "generated ${TMP}"
    exit 0
fi
if [ "${1:-}" = "--make-hybrid" ]; then
    OFF=${2:-258048}   # default 0x3f000 (vendor header + boot prefix boundary)
    CUSTOM=${3:-${OUT_IMG}}
    echo "[hybrid] using vendor file up to ${OFF}, appending ${CUSTOM}"
    cp compare/rkspi_loader.img hybrid.img
    truncate -s ${OFF} hybrid.img
    # copy contents of custom file starting at offset ${OFF}
    # copy from CUSTOM starting at input offset and place into hybrid.img at the same offset
    dd if=${CUSTOM} of=hybrid.img bs=1 skip=${OFF} seek=${OFF} conv=notrunc

    # After merging we need to fix the RKNS header so that the
    # size fields and SHA256 hashes reflect the new payload.  This
    # mostly mirrors the logic used later in the normal build flow.
    if command -v tools/mkimage >/dev/null 2>&1; then
        MKINFO=$(tools/mkimage -l hybrid.img 2>/dev/null |
            awk '/Init Data Size/ {i=$4} /Boot Data Size/ {b=$4} END {printf "%d %d", i, b}' || true)
        if [ -n "${MKINFO}" ]; then
            INIT_SIZE=$(echo "${MKINFO}" | cut -d' ' -f1)
            BOOT_SIZE=$(echo "${MKINFO}" | cut -d' ' -f2)
            if [ -n "${INIT_SIZE}" ] && [ -n "${BOOT_SIZE}" ]; then
                echo "[hybrid] patching size fields and recalculating hashes"
                # patch the RKNS init-size field at offset 0x78
                SECTORS=$((INIT_SIZE / 2048))
                OFFF=4
                VAL=$(( (SECTORS << 16) | OFFF ))
                HEX=$(printf '%02x%02x%02x%02x' \
                      $((VAL & 0xff)) $(((VAL >> 8) & 0xff)) \
                      $(((VAL >> 16) & 0xff)) $(((VAL >> 24) & 0xff)))
                printf '%s' "${HEX}" | xxd -r -p | \
                    dd of=hybrid.img bs=1 seek=$((0x78)) conv=notrunc 2>/dev/null

                # use Python snippet to recalc both image hashes and header hash
                python3 - "hybrid.img" "${INIT_SIZE}" "${BOOT_SIZE}" <<'PY'
import sys,hashlib
fn=sys.argv[1]; init=int(sys.argv[2]); boot=int(sys.argv[3])
blk=512
# header0_info_v2 layout constants (same as later in script)
hdr_off_images=4+4+4+4+104
entry_size=88
hash_offset_in_entry=4+4+4+4+8
header_hash_offset=1536
with open(fn,'r+b') as f:
    # compute image0 hash
    f.seek(4*blk)
    data=f.read(init)
    h0=hashlib.sha256(data).digest()
    f.seek(hdr_off_images + hash_offset_in_entry)
    f.write(h0)
    # image1 hash
    f.seek(4*blk + init)
    data=f.read(boot)
    h1=hashlib.sha256(data).digest()
    f.seek(hdr_off_images + entry_size + hash_offset_in_entry)
    f.write(h1)
    # header0 hash
    f.seek(0)
    prefix=f.read(header_hash_offset)
    hh=hashlib.sha256(prefix).digest()
    f.seek(header_hash_offset)
    f.write(hh)
PY
            fi
        fi
    fi

    echo "created hybrid.img"
    exit 0
fi

BOARD_DEFCONFIG=${1:-orangepi_5_max_defconfig}
OUT_IMG=${2:-rkspi_loader.img}
TMP_INI=tmp-mini/mini_loader.ini

# Optional: allow overriding SPL_FIT_IMAGE_KB for the FIT flow
# Usage: --fit-4mb  or  --fit-image-kb=<KB>  or set FIT_IMAGE_KB env var
SPL_FIT_IMAGE_KB_OVERRIDE=""
# scan CLI args (supports --fit-4mb, --fit-image-kb=NNN and --fit-image-kb NNN)
ARG_INDEX=1
while [ ${ARG_INDEX} -le $# ]; do
  eval _a=\$${ARG_INDEX}
  case "${_a}" in
    --fit-4mb)
      SPL_FIT_IMAGE_KB_OVERRIDE=4096
      ;;
    --fit-image-kb=*)
      SPL_FIT_IMAGE_KB_OVERRIDE="${_a#--fit-image-kb=}"
      ;;
    --fit-image-kb)
      NEXT_IDX=$((ARG_INDEX+1))
      if [ ${NEXT_IDX} -le $# ]; then
        eval SPL_FIT_IMAGE_KB_OVERRIDE=\$${NEXT_IDX}
      fi
      ;;
  esac
  ARG_INDEX=$((ARG_INDEX+1))
done
# allow environment override as well
if [ -z "${SPL_FIT_IMAGE_KB_OVERRIDE}" ] && [ -n "${FIT_IMAGE_KB:-}" ]; then
  SPL_FIT_IMAGE_KB_OVERRIDE="${FIT_IMAGE_KB}"
fi
# sanity: must be numeric when set
if [ -n "${SPL_FIT_IMAGE_KB_OVERRIDE}" ]; then
  case "${SPL_FIT_IMAGE_KB_OVERRIDE}" in
    ''|*[!0-9]*) echo "ERROR: invalid SPL_FIT_IMAGE_KB_OVERRIDE='${SPL_FIT_IMAGE_KB_OVERRIDE}'" >&2; exit 1 ;;
  esac
fi
MERGED_BIN=rkloader_full.bin
SPL_INPUT="spl/u-boot-spl.bin"
TPL_INPUT="tpl/u-boot-tpl.bin"
UBOOT_ITB="u-boot.itb"
JOBS=${JOBS:-$(nproc)}

echo "[build_rkspi_full] Start: board=${BOARD_DEFCONFIG}, out=${OUT_IMG}"

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# 1) Build U-Boot (defconfig + full build)
# Always run defconfig + build here (do not rely on SKIP_BUILD).
echo "[1/8] make ${BOARD_DEFCONFIG} && make -j${JOBS}"
make ${BOARD_DEFCONFIG}

# If requested, temporarily set CONFIG_SPL_FIT_IMAGE_KB in .config so
# the FIT flow (scripts/fit-core.sh) will create the ITB/IMG at that size.
# We keep a backup and restore it at the end of the script.
if [ -n "${SPL_FIT_IMAGE_KB_OVERRIDE}" ]; then
  CONFIG_BAK=".config.build_rkspi_full.$$"
  cp -f .config "${CONFIG_BAK}"
  if grep -q '^CONFIG_SPL_FIT_IMAGE_KB=' .config 2>/dev/null; then
    sed -i "s/^CONFIG_SPL_FIT_IMAGE_KB=.*/CONFIG_SPL_FIT_IMAGE_KB=${SPL_FIT_IMAGE_KB_OVERRIDE}/" .config
  else
    echo "CONFIG_SPL_FIT_IMAGE_KB=${SPL_FIT_IMAGE_KB_OVERRIDE}" >> .config
  fi
  echo "INFO: temporarily set CONFIG_SPL_FIT_IMAGE_KB=${SPL_FIT_IMAGE_KB_OVERRIDE} (backup: ${CONFIG_BAK})"
fi

make -j${JOBS}

# 2) Ensure SPL/TPL exist
echo "[2/8] Ensure SPL/TPL exist"
if [ ! -f "${SPL_INPUT}" ]; then
  echo "ERROR: SPL not found: ${SPL_INPUT}" >&2
  exit 1
fi
if [ ! -f "${TPL_INPUT}" ]; then
  echo "ERROR: TPL not found: ${TPL_INPUT}" >&2
  exit 1
fi

# 3) Generate u-boot.itb (prefer project scripts)
# If ../rkbin exists, prefer its BL31 and let ./make.sh itb pick it up.
if [ -d ../rkbin ]; then
  BL31_CANDIDATE=$(ls -1 ../rkbin/bin/rk35/rk3588_bl31_*.elf 2>/dev/null | tail -n1 || true)
  if [ -n "${BL31_CANDIDATE}" ]; then
    export BL31="${BL31_CANDIDATE}"
    echo "INFO: using BL31 from ${BL31}"
    # Also copy BL31 locally and attempt to decode ATF segments so the FIT
    # generator can find bl31_0x*.bin even when python2 is not available.
    cp -f "${BL31_CANDIDATE}" ./bl31.elf
    if command -v python3 >/dev/null 2>&1; then
      echo "INFO: decoding BL31 segments with python3"
      python3 arch/arm/mach-rockchip/decode_bl31.py || true
    else
      echo "WARN: python3 not found — BL31 segments won't be decoded"
    fi
  fi
fi

if [ -x ./make.sh ]; then
  echo "[3/8] Attempt: pack u-boot.itb via ./make.sh itb"
  if ./make.sh CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-} itb 2>/dev/null; then
    if [ -f "${UBOOT_ITB}" ]; then
      echo "-> got ${UBOOT_ITB} from make.sh"
    fi
  else
    echo "-> make.sh itb failed or rkbin missing; fallback to fit generator"
  fi
fi

if [ ! -f "${UBOOT_ITB}" ]; then
  echo "[3b/8] Fallback: build u-boot.itb via SPL_FIT_GENERATOR"
  # generate u-boot.its then mkimage
  srctree=. ./arch/arm/mach-rockchip/make_fit_atf.sh > u-boot.its || true
  if [ -f u-boot.its ]; then
    tools/mkimage -f u-boot.its -E u-boot.itb
  fi
  if [ ! -f "${UBOOT_ITB}" ]; then
    echo "ERROR: failed to produce ${UBOOT_ITB}" >&2
    exit 1
  fi
fi

# 4) Prepare INI for boot_merger (loader pack)
mkdir -p tmp-mini
# If ../rkbin provides an RKBOOT INI for RK3588, use it as base so FlashData
# (DDR) and FlashBoot (miniloader/SPL) come from rkbin. Inject our u-boot.itb
# as an additional loader entry. Otherwise create a simple INI that uses the
# locally-built tpl/spl.
if [ -d ../rkbin ] && [ -f ../rkbin/RKBOOT/RK3588MINIALL.ini ]; then
  echo "INFO: using ../rkbin/RKBOOT/RK3588MINIALL.ini as base INI"
  cp ../rkbin/RKBOOT/RK3588MINIALL.ini ${TMP_INI}

  # Ensure loader count includes our uboot entry and point it to local u-boot.itb
  if grep -q '^LOADER3=' ${TMP_INI}; then
    sed -i "s|^LOADER3=.*$|LOADER3=uboot|" ${TMP_INI}
  else
    sed -i "/^LOADER2=/a LOADER3=uboot" ${TMP_INI}
  fi
  sed -i "s/^NUM=[0-9]\+/NUM=3/" ${TMP_INI}

  # Inject uboot entry (replace if exists).  Place it immediately
  # after the FlashBoot path so that boot_merger sees the loader entry
  # before any other sections such as [OUTPUT].
  UBOOT_PATH="$(pwd)/u-boot.itb"
  if grep -q '^uboot=' ${TMP_INI}; then
    sed -i "s|^uboot=.*$|uboot=${UBOOT_PATH}|" ${TMP_INI}
  else
    # insert after FlashBoot line if present, otherwise append in section
    if grep -q '^FlashBoot=' ${TMP_INI}; then
      sed -i "/^FlashBoot=/a uboot=${UBOOT_PATH}" ${TMP_INI}
    else
      # fallback to end of file
      printf "uboot=${UBOOT_PATH}\n" >> ${TMP_INI}
    fi
  fi

  # Ensure output path points to rkloader_full.bin (boot_merger expects this)
  sed -i "/^\[OUTPUT\]/,/^$/ s|^PATH=.*$|PATH=rkloader_full.bin|" ${TMP_INI}
else
  cat > ${TMP_INI} <<'INI'
[CHIP_NAME]
NAME=RK3588

[VERSION]
MAJOR=1
MINOR=0

[CODE471_OPTION]
NUM=0

[CODE472_OPTION]
NUM=0

[LOADER_OPTION]
NUM=3
LOADER1=FlashData
LOADER2=FlashBoot
LOADER3=uboot

FlashData=tpl/u-boot-tpl.bin
FlashBoot=spl/u-boot-spl.bin
uboot=u-boot.itb

[OUTPUT]
PATH=rkloader_full.bin
INI
fi

# 5) Run boot_merger to produce merged loader (rkloader_full.bin)
echo "[5/8] Generating loader via scripts/fit.sh (use modified ${TMP_INI} so local u-boot.itb is injected)"
# Always prefer the TMP_INI we prepared above (it mirrors ../rkbin INI but
# has our injected `uboot=./u-boot.itb`). Use an absolute pathname so
# downstream scripts can still open it even if they change directory.
INI_LOADER="$(pwd)/${TMP_INI}"
echo "INFO: using INI loader ${INI_LOADER}"

# Make sure make.sh can find the toolchain (make.sh reads .cc)
printf "%s" "${CROSS_COMPILE}" > .cc
# Use FIT flow to generate u-boot.itb + loader; --spl-new forces packing with local spl
scripts/fit.sh --ini-loader "${INI_LOADER}" --spl-new --chip RK3588
rm -f .cc || true

# discover produced loader
MERGED_BIN=$(ls *loader*.bin 2>/dev/null | head -n1 || true)
if [ -z "${MERGED_BIN}" ]; then
  MERGED_BIN=$(ls *idblock*.img 2>/dev/null | head -n1 || true)
fi
if [ -z "${MERGED_BIN}" ]; then
  echo "ERROR: fit/loader did not produce loader (expected *loader*.bin or *idblock*.img)" >&2
  exit 1
fi

echo "INFO: loader produced: ${MERGED_BIN}"
# boot_merger also writes out uboot.img containing the FIT payload.  it
# frequently pads this file to exactly 4 MiB, which forces the subsequent
# mkimage invocation to reserve a full 4 MiB of boot data and pushes the
# final RK-SPI image above the 4 MiB limit.  trim any trailing 0x00/0xFF
# padding now so mkimage sees only the real FIT data.
if [ -f "uboot.img" ]; then
  echo "INFO: trimming padding from uboot.img"
  python3 - <<'PY'
import sys
fname='uboot.img'
b=open(fname,'rb').read()
i=len(b)
# drop trailing 0x00 or 0xFF bytes
while i>0 and b[i-1] in (0x00,0xFF):
    i-=1
if i != len(b):
    with open(fname,'rb+') as f: f.truncate(i)
    print('INFO: uboot.img shrunk to', i, 'bytes')
PY
fi

# the FIT payload (u-boot.itb) might not be part of ${MERGED_BIN} generated
# by fit.sh.  if we have a local u-boot.itb, assemble a custom merged
# binary that concatenates TPL + SPL + u-boot.itb so the FIT image is
# included inside the SPI payload.
if [ -f "u-boot.itb" ]; then
  CUSTOM_BIN="rkloader_with_uboot.bin"
  cat "${TPL_INPUT}" "${SPL_INPUT}" "u-boot.itb" > "${CUSTOM_BIN}"
  MERGED_BIN="${CUSTOM_BIN}"
  echo "INFO: created custom merged loader including u-boot.itb -> ${MERGED_BIN}"
fi

if [ -n "${MERGED_BIN}" ]; then
  echo "INFO: loader already generated by fit.sh; skipping boot_merger fallback"
else
# boot_merger is preferred but sometimes crashes on some hosts; tolerate failure
FALLBACK=0
if ./tools/boot_merger ${TMP_INI}; then
  if [ ! -f "${MERGED_BIN}" ]; then
    echo "WARN: boot_merger returned OK but ${MERGED_BIN} missing — will fallback to concat"
    FALLBACK=1
  fi
else
  echo "WARN: tools/boot_merger failed — will fallback to concatenation (mkimage input)"
  FALLBACK=1
fi

if [ ${FALLBACK} -eq 1 ]; then
  echo "[5b/8] Fallback: try boot_merger CLI mode (avoid INI parser)"
  # Try CLI mode (-d / -b) up to 3 times in case of transient crash
  TRIES=0
  SUCCESS=0
  while [ $TRIES -lt 3 ]; do
    ./tools/boot_merger -c RK3588 -d "${TPL_INPUT}" -b "${SPL_INPUT}" -o "${MERGED_BIN}" && SUCCESS=1 && break || true
    TRIES=$((TRIES+1))
    sleep 1
  done

  if [ ${SUCCESS} -eq 0 ] || [ ! -s "${MERGED_BIN}" ]; then
    echo "[5c/8] Final fallback: create ${MERGED_BIN} by simple concatenation"
    # Prefer rkbin FlashData/FlashBoot when available, otherwise use local TPL/SPL
    if [ -d ../rkbin ] && [ -f ../rkbin/RKBOOT/RK3588MINIALL.ini ]; then
      # extract FlashData/FlashBoot paths from RK3588MINIALL.ini
      RK_FLASHDATA=$(sed -n "/^FlashData=/s/FlashData=//p" ../rkbin/RKBOOT/RK3588MINIALL.ini | tr -d '\r')
      RK_FLASHBOOT=$(sed -n "/^FlashBoot=/s/FlashBoot=//p" ../rkbin/RKBOOT/RK3588MINIALL.ini | tr -d '\r')
      RK_FLASHDATA_PATH="../rkbin/${RK_FLASHDATA}"
      RK_FLASHBOOT_PATH="../rkbin/${RK_FLASHBOOT}"
      if [ -f "${RK_FLASHDATA_PATH}" ] && [ -f "${RK_FLASHBOOT_PATH}" ]; then
        echo "INFO: using rkbin FlashData=${RK_FLASHDATA_PATH} and FlashBoot=${RK_FLASHBOOT_PATH} for concatenation"
        cat "${RK_FLASHDATA_PATH}" "${RK_FLASHBOOT_PATH}" "${UBOOT_ITB}" > "${MERGED_BIN}" || {
          echo "ERROR: concatenation fallback (rkbin) failed" >&2
          exit 1
        }
      else
        echo "WARN: rkbin FlashData/SPL not found, falling back to local tpl/spl concatenation"
        cat "${TPL_INPUT}" "${SPL_INPUT}" "${UBOOT_ITB}" > "${MERGED_BIN}" || {
          echo "ERROR: concatenation fallback failed" >&2
          exit 1
        }
      fi
    else
      cat "${TPL_INPUT}" "${SPL_INPUT}" "${UBOOT_ITB}" > "${MERGED_BIN}" || {
        echo "ERROR: concatenation fallback failed" >&2
        exit 1
      }
    fi

    if [ ! -s "${MERGED_BIN}" ]; then
      echo "ERROR: ${MERGED_BIN} is empty after concatenation" >&2
      exit 1
    fi
    echo "INFO: ${MERGED_BIN} created via concatenation (fallback)"
  fi
fi

fi

# 6) Wrap merged loader into RK SPI image
# Remove any previous temporary output to avoid mkimage appending errors
rm -f "${OUT_IMG}.tmp"
echo "[6/8] Converting ${MERGED_BIN} -> rkspi image"

# mkimage will write the RKNS header at the beginning of its output.
# we'll duplicate that header to offset 0x8000 below, so there's no need
# to pad the input beforehand.
# Pre‑check: if the merged binary is evidently too big to serve as the init/SPL
# portion we should skip the single‑file invocation and go straight to the
# SPL-first method.  This prevents mkimage from complaining about a "SPL image
# too large" when we have concatenated TPL+SPL+u-boot.itb (which usually exceeds
# the 0xff000 limit).
SPL_MAX_SIZE=$((0xff000))
USE_SPL_FIRST=0
if [ -n "${CUSTOM_BIN:-}" ]; then
  USE_SPL_FIRST=1
else
  if [ -f "${MERGED_BIN}" ]; then
    SZ=$(stat -c%s "${MERGED_BIN}")
    if [ ${SZ} -gt ${SPL_MAX_SIZE} ]; then
      echo "INFO: ${MERGED_BIN} is ${SZ} bytes (>$((SPL_MAX_SIZE))) – skipping naive mkimage"
      USE_SPL_FIRST=1
    fi
  fi
fi

MKIMG_LOG=$(mktemp -u tmp-mini/mkimage.XXXX.log)

if [ ${USE_SPL_FIRST} -eq 0 ]; then
  # Try the straightforward invocation first; if it fails (tool bugs or size checks),
  # fall back to the safe two-file method below.
  if tools/mkimage -T rkspi -n rk3588 -d ${MERGED_BIN} ${OUT_IMG}.tmp 2>"${MKIMG_LOG}"; then
    echo "INFO: tools/mkimage succeeded using ${MERGED_BIN}"
  else
    echo "WARN: tools/mkimage failed with ${MERGED_BIN}, trying SPL-first fallback (see ${MKIMG_LOG})"
    cat "${MKIMG_LOG}" >&2 || true
    USE_SPL_FIRST=1
  fi
fi

if [ ${USE_SPL_FIRST} -eq 1 ]; then
  # Fallback: mkimage can accept two files (init: SPL, boot: uboot.img) which
  # avoids treating the entire merged binary as the SPL.  uboot.img is produced by
  # boot_merger and contains the FIT payload (with ATF/OP-TEE/U-Boot).  Using
  # this method we don't depend on u-boot.itb still being available.
  TMP_BOOT="uboot.img"
  if [ ! -f "${TMP_BOOT}" ]; then
    echo "ERROR: fallback requires ${TMP_BOOT} (boot_merger failed to create it?)" >&2
    cat "${MKIMG_LOG}" >&2 || true
    exit 1
  fi
  if tools/mkimage -T rkspi -n rk3588 -d "${SPL_INPUT}:${TMP_BOOT}" ${OUT_IMG}.tmp 2>>"${MKIMG_LOG}"; then
    echo "INFO: tools/mkimage succeeded with SPL-first fallback"
  else
    echo "ERROR: tools/mkimage failed (both normal and SPL-first fallbacks). See ${MKIMG_LOG}" >&2
    cat "${MKIMG_LOG}" >&2 || true
    exit 1
  fi
fi
rm -f "${MKIMG_LOG}" || true

# mkimage sometimes produces an oversized file by appending the boot section
# twice when using the two-file fallback.  trim back to the stated init+boot
# length if necessary so subsequent padding works correctly.  guard the whole
# sequence so a failure here doesn't abort the build.
if [ -f "${OUT_IMG}.tmp" ]; then
  MKINFO=$(tools/mkimage -l "${OUT_IMG}.tmp" 2>/dev/null |
    awk '/Init Data Size/ {i=$4} /Boot Data Size/ {b=$4} END {printf "%d %d", i, b}' || true)
  if [ -n "${MKINFO}" ]; then
    INIT_SIZE=$(echo "${MKINFO}" | cut -d' ' -f1)
    BOOT_SIZE=$(echo "${MKINFO}" | cut -d' ' -f2)
    if [ -n "${INIT_SIZE}" ] && [ -n "${BOOT_SIZE}" ]; then
      DESIRED=$((INIT_SIZE + BOOT_SIZE))
      CUR=$(stat -c%s "${OUT_IMG}.tmp")
      if [ ${CUR} -gt ${DESIRED} ]; then
        echo "INFO: trimming ${OUT_IMG}.tmp from ${CUR} to ${DESIRED} bytes"
        truncate -s ${DESIRED} "${OUT_IMG}.tmp"
      fi
    fi

    # fix rkspi header size field if mkimage inflated it for SPI alignment
    # mkimage writes (sectors<<16)|offset, but sectors may include the
    # 4x padding introduced by rkspi_vrec_header; the ROM expects the
    # *actual* init size in 2KiB sectors.  mkimage -l hides this
    # discrepancy by dividing the value, so we replicate the correct
    # count here and patch the raw header bytes before we duplicate it.
    if [ -n "${INIT_SIZE}" ]; then
      # number of 2KiB sectors in the init data
      SECTORS=$((INIT_SIZE / 2048))
      # offset field is always 4
      OFF=4
      VAL=$(( (SECTORS << 16) | OFF ))
      # write in little-endian order to offset 0x78
      # build a 4-byte hex string and convert it to raw bytes with xxd
      HEX=$(printf '%02x%02x%02x%02x' \
            $((VAL & 0xff)) $(((VAL >> 8) & 0xff)) \
            $(((VAL >> 16) & 0xff)) $(((VAL >> 24) & 0xff)))
      printf '%s' "${HEX}" | xxd -r -p | \
        dd of="${OUT_IMG}.tmp" bs=1 seek=$((0x78)) conv=notrunc 2>/dev/null
      echo "INFO: patched RKNS size field to ${SECTORS} sectors (0x$(printf '%x' ${VAL}))"
    fi
  fi
fi

# after mkimage we may still have the header at byte 0; the boot ROM
# only looks at 0x8000, so duplicate the header there rather than moving it.
if [ -f "${OUT_IMG}.tmp" ]; then
    # some BootROM variants ignore init_offset and simply fetch SPL at
    # 0x8000+0x600=0x8600.  compute where the first non-zero byte of the
    # payload currently resides and, if it’s before 0x600, pad accordingly.
    SPL_OFF=$(grep -aob '[^\x00]' "${OUT_IMG}.tmp" | awk -F: '$1 >= 512 {print $1; exit}' || true)
    if [ -n "${SPL_OFF}" ] && [ ${SPL_OFF} -lt $((0x600)) ]; then
        DELTA=$((0x600 - SPL_OFF))
        echo "INFO: inserting ${DELTA} bytes padding before SPL (was at ${SPL_OFF})"
        head -c ${SPL_OFF} "${OUT_IMG}.tmp" > tmp.pre
        dd if=/dev/zero bs=1 count=${DELTA} 2>/dev/null >> tmp.pre
        tail -c +$((SPL_OFF+1)) "${OUT_IMG}.tmp" >> tmp.pre
        mv tmp.pre "${OUT_IMG}.tmp"
        SPL_OFF=$((SPL_OFF + DELTA))
    fi
    if [ -n "${SPL_OFF}" ]; then
        echo "INFO: SPL entry now at offset 0x$(printf '%x' ${SPL_OFF})"
    fi

    # ensure the FIT payload starts at 0x80000; if it doesn’t, slide it forward
    PAYLOAD_OFF=$(grep -aob $'\xd0\x0d\xfe\xed' "${OUT_IMG}.tmp" | head -n1 | cut -d: -f1 || true)
    if [ -n "${PAYLOAD_OFF}" ] && [ ${PAYLOAD_OFF} -lt $((0x80000)) ]; then
        DELTA=$((0x80000 - PAYLOAD_OFF))
        echo "INFO: shifting payload by ${DELTA} bytes to reach 0x80000"
        # insert zeros before the payload offset
        head -c ${PAYLOAD_OFF} "${OUT_IMG}.tmp" > tmp.pre
        dd if=/dev/zero bs=1 count=${DELTA} 2>/dev/null >> tmp.pre
        tail -c +$((PAYLOAD_OFF+1)) "${OUT_IMG}.tmp" >> tmp.pre
        mv tmp.pre "${OUT_IMG}.tmp"
    fi

    # recalc RKNS hashes in case we padded/shifted payloads
    INIT_SIZE=$(tools/mkimage -l "${OUT_IMG}.tmp" 2>/dev/null |
      awk '/Init Data Size/ {print $4}') || INIT_SIZE=0
    BOOT_SIZE=$(tools/mkimage -l "${OUT_IMG}.tmp" 2>/dev/null |
      awk '/Boot Data Size/ {print $4}') || BOOT_SIZE=0
    if [ -n "${INIT_SIZE}" ] && [ -n "${BOOT_SIZE}" ]; then
        echo "INFO: recalculating SHA256 hashes (init ${INIT_SIZE}, boot ${BOOT_SIZE})"
        python3 - "${OUT_IMG}.tmp" "${INIT_SIZE}" "${BOOT_SIZE}" <<'PY'
import sys,hashlib
fn=sys.argv[1]; init=int(sys.argv[2]); boot=int(sys.argv[3])
blk=512
# header0_info_v2 layout constants
hdr_off_images=4+4+4+4+104
entry_size=88
hash_offset_in_entry=4+4+4+4+8
header_hash_offset=1536
with open(fn,'r+b') as f:
    # compute image0 hash
    f.seek(4*blk)
    data=f.read(init)
    h0=hashlib.sha256(data).digest()
    f.seek(hdr_off_images + hash_offset_in_entry)
    f.write(h0)
    # image1 hash
    f.seek(4*blk + init)
    data=f.read(boot)
    h1=hashlib.sha256(data).digest()
    f.seek(hdr_off_images + entry_size + hash_offset_in_entry)
    f.write(h1)
    # header0 hash
    f.seek(0)
    prefix=f.read(header_hash_offset)
    hh=hashlib.sha256(prefix).digest()
    f.seek(header_hash_offset)
    f.write(hh)
PY
    fi

    # finally, copy corrected header to 0x8000 after all adjustments
    if ! dd if="${OUT_IMG}.tmp" bs=1 skip=$((64*512)) count=4 2>/dev/null | grep -q RKNS; then
        echo "INFO: copying RKNS header to offset 0x8000"
        dd if="${OUT_IMG}.tmp" bs=512 count=1 of=tmp.hdr
        dd if=tmp.hdr of="${OUT_IMG}.tmp" bs=512 seek=64 conv=notrunc
        rm -f tmp.hdr
    fi
fi

# 7) Pad to 4MB (0xFF fill) to match Rockchip SPI loader size
TARGET_SIZE=$((4096 * 1024))
CUR_SIZE=$(stat -c%s "${OUT_IMG}.tmp")
if [ ${CUR_SIZE} -gt ${TARGET_SIZE} ]; then
  echo "WARNING: generated image is larger than 4MB (${CUR_SIZE} bytes)" >&2
fi
PAD_BYTES=$((TARGET_SIZE - CUR_SIZE))
if [ ${PAD_BYTES} -gt 0 ]; then
  echo "[7/8] Padding ${OUT_IMG}.tmp with ${PAD_BYTES} bytes (0xFF) to reach 4MB"
  dd if=/dev/zero bs=1 count=${PAD_BYTES} 2>/dev/null | tr '\000' '\377' >> ${OUT_IMG}.tmp
fi
mv ${OUT_IMG}.tmp ${OUT_IMG}

# 8) Report
echo "[8/8] Output: ${OUT_IMG}"
ls -lh ${OUT_IMG}
sha256sum ${OUT_IMG}

# restore .config if we modified it earlier
if [ -n "${CONFIG_BAK:-}" ] && [ -f "${CONFIG_BAK}" ]; then
  mv -f "${CONFIG_BAK}" .config
  echo "INFO: restored original .config from ${CONFIG_BAK}"
fi

echo "[build_rkspi_full] Done. Clean-up tmp files kept in tmp-mini/ if you need to inspect."
exit 0
