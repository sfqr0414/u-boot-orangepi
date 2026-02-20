#!/bin/bash
# build_rkspi_full.sh - build RK SPI loader image (tpl + spl + u-boot.itb)
# Produces rkspi_loader.img (4MB, padded) for RK3588 OrangePi_5_Max
# Usage: ./build_rkspi_full.sh [defconfig]

set -euo pipefail
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

  # Inject uboot entry (replace if exists)
  if grep -q '^uboot=' ${TMP_INI}; then
    sed -i "s|^uboot=.*$|uboot=./u-boot.itb|" ${TMP_INI}
  else
    printf "uboot=./u-boot.itb\n" >> ${TMP_INI}
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
# has our injected `uboot=./u-boot.itb`). This ensures the local u-boot.itb
# (with ATF when present) ends up inside the final loader payload.
INI_LOADER="${TMP_INI}"
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
echo "[6/8] Converting ${MERGED_BIN} -> rkspi image"
# Try the straightforward invocation first; if it fails (tool bugs or size checks),
# attempt a safe two-file invocation using SPL as the "init" file and the rest as
# the "boot" file (created in a temp file).
MKIMG_LOG=$(mktemp -u tmp-mini/mkimage.XXXX.log)
if tools/mkimage -T rkspi -n rk3588 -d ${MERGED_BIN} ${OUT_IMG}.tmp 2>"${MKIMG_LOG}"; then
  echo "INFO: tools/mkimage succeeded using ${MERGED_BIN}"
else
  echo "WARN: tools/mkimage failed with ${MERGED_BIN}, trying SPL-first fallback (see ${MKIMG_LOG})"
  cat "${MKIMG_LOG}" >&2 || true
  # Create a temporary boot payload that contains TPL + u-boot.itb (used as boot_file)
  TMP_BOOT="${MERGED_BIN}.boot"
  cat "${TPL_INPUT}" "${UBOOT_ITB}" > "${TMP_BOOT}"
  if tools/mkimage -T rkspi -n rk3588 -d "${SPL_INPUT}:${TMP_BOOT}" ${OUT_IMG}.tmp 2>>"${MKIMG_LOG}"; then
    echo "INFO: tools/mkimage succeeded with SPL-first fallback"
    rm -f "${TMP_BOOT}"
  else
    echo "ERROR: tools/mkimage failed (both normal and SPL-first fallbacks). See ${MKIMG_LOG}" >&2
    cat "${MKIMG_LOG}" >&2 || true
    exit 1
  fi
fi
rm -f "${MKIMG_LOG}" || true

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
