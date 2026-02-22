#!/bin/bash
# simplified custom builder: compile U-Boot and package RK3588 SPI images
#   * custom full loader contains all NVMe modifications
#   * test loader is a 4‑MiB image that contains only the init prefix
#     (first 109 sectors) of the full loader but is otherwise valid.

set -euo pipefail

DEFCONFIG=${1:-orangepi_5_max_defconfig}
# MODE can be "all" (build everything), "payload" to produce just the
# validated payload‑only image (default), or "minimal" to suppress even
# that and only run the U-Boot build without producing any extra files.
# The variable may be overridden by the caller.
MODE=${2:-payload}

OUT_FULL=custom_loader.img
OUT_TEST=test.img
OUT_PAYLOAD=payload_only.img

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

print_help() {
    cat <<H
Usage: $0 [defconfig]
       Builds U-Boot and produces two images:
         ${OUT_FULL}  - full 4MB RK-SPI loader
         ${OUT_TEST}  - 4MB test image containing init prefix
H
}

# 1. build U-Boot
echo "[build] defconfig=${DEFCONFIG}"
make ${DEFCONFIG}
make -j$(nproc)

# 2. produce FIT image (u-boot.itb)
if ./make.sh itb >/dev/null 2>&1; then
    echo "got u-boot.itb from make.sh"
else
    echo "fallback to manual FIT generation"
    ./arch/arm/mach-rockchip/make_fit_atf.sh > u-boot.its
    tools/mkimage -f u-boot.its -E u-boot.itb
fi

# 3. merge payload
cat tpl/u-boot-tpl.bin spl/u-boot-spl.bin u-boot.itb > merged.bin

# helper to pad and append MD5 trailer to a 4MB file
pad_and_sign() {
    local f="$1"
    local TARGET=$((4096 * 1024))
    local CUR=$(stat -c%s "$f")
    if [ $CUR -lt $TARGET ]; then
        dd if=/dev/zero bs=1 count=$((TARGET - CUR)) 2>/dev/null | tr '\000' '\377' >> "$f"
    fi
    python3 - "$f" <<'PY'
import sys,hashlib,struct
f=sys.argv[1]
with open(f,'rb') as g:
    data=g.read(0x384000)
md5=hashlib.md5(data).digest()
trail=struct.pack('<I',0x20000000 | (md5[0]<<24|md5[1]<<16|md5[2]<<8|md5[3]))
trail+=struct.pack('<I',(md5[4]<<24|md5[5]<<16|md5[6]<<8|md5[7]))
with open(f,'r+b') as g:
    g.seek(4096*1024-8)
    g.write(trail)
PY
}

# 4. make full loader image (skip when only payload requested)
if [ "$MODE" != "payload" ]; then
    # if merged payload is too large for single-file mkimage, use SPL-first fallback
    SPL_MAX=$((0xff000))
    if [ -f merged.bin ]; then
        SZ=$(stat -c%s merged.bin)
    else
        SZ=0
    fi
    if [ ${SZ} -gt ${SPL_MAX} ]; then
        echo "[build] merged.bin is ${SZ} bytes (>${SPL_MAX}), using SPL-first mkimage"
        # u-boot.img should already exist from fit/make.sh
        if [ ! -f u-boot.img ]; then
            echo "ERROR: u-boot.img missing, cannot use SPL-first" >&2
            exit 1
        fi
        tools/mkimage -T rkspi -n rk3588 -d "spl/u-boot-spl.bin:u-boot.img" ${OUT_FULL}.tmp
    else
        tools/mkimage -T rkspi -n rk3588 -d merged.bin ${OUT_FULL}.tmp
    fi
    INIT_SIZE=$(tools/mkimage -l ${OUT_FULL}.tmp 2>/dev/null | awk '/Init Data Size/ {print $4}')
    SECS=$((INIT_SIZE / 2048))
    VAL=$(( (SECS << 16) | 4 ))
    HEX=$(printf '%02x%02x%02x%02x' $((VAL&0xff)) $(((VAL>>8)&0xff)) $(((VAL>>16)&0xff)) $(((VAL>>24)&0xff)))
    printf '%s' "${HEX}" | xxd -r -p | dd of=${OUT_FULL}.tmp bs=1 seek=0x78 conv=notrunc
    dd if=${OUT_FULL}.tmp bs=1 skip=0x78 count=4 of=${OUT_FULL}.tmp bs=1 seek=0x8078 conv=notrunc
    pad_and_sign ${OUT_FULL}.tmp
    mv ${OUT_FULL}.tmp ${OUT_FULL}
    echo "built ${OUT_FULL} size=$(stat -c%s ${OUT_FULL})"
fi

# 4b. always produce payload-only image unless minimal mode
if [ "$MODE" != "minimal" ]; then
    echo "generating ${OUT_PAYLOAD} with signed prefix"
    # Prefer an existing official loader; check both root and compare/
    # in case make was invoked from the top level (the stock file is kept in
    # the compare directory during our experiments).
    if [ -f rkspi_loader.img ]; then
        cp rkspi_loader.img ${OUT_PAYLOAD}
        echo "  (using stock rkspi_loader.img as prefix)"
    elif [ -f compare/rkspi_loader.img ]; then
        cp compare/rkspi_loader.img ${OUT_PAYLOAD}
        echo "  (using compare/rkspi_loader.img as prefix)"
    elif [ -f ${OUT_FULL} ]; then
        cp ${OUT_FULL} ${OUT_PAYLOAD}
        echo "  (using newly-built ${OUT_FULL} as prefix)"
    else
        echo "ERROR: no source for prefix; please build full loader first" >&2
        exit 1
    fi
    if [ -f u-boot-dtb.img ]; then
        dd if=u-boot-dtb.img of=${OUT_PAYLOAD} bs=1 seek=$((4*1024*1024)) conv=notrunc
        echo "built ${OUT_PAYLOAD} size=$(stat -c%s ${OUT_PAYLOAD})"
    else
        echo "warning: u-boot-dtb.img not found; skipping ${OUT_PAYLOAD} generation"
    fi
fi

# 5. create test image from prefix (only in all mode)
if [ "$MODE" = "all" ]; then
    SECTORS=109
    dbg_prefix_bytes=$((SECTORS*2048))
    truncate -s $((SECTORS*2048)) tmp.bin
    dd if=${OUT_FULL} of=tmp.bin bs=1 count=${dbg_prefix_bytes} conv=notrunc

    tools/mkimage -T rkspi -n rk3588 -d tmp.bin ${OUT_TEST}.tmp
    INIT_SIZE=$(tools/mkimage -l ${OUT_TEST}.tmp 2>/dev/null | awk '/Init Data Size/ {print $4}')
    SECS=$((INIT_SIZE / 2048))
    VAL=$(( (SECS << 16) | 4 ))
    HEX=$(printf '%02x%02x%02x%02x' $((VAL&0xff)) $(((VAL>>8)&0xff)) $(((VAL>>16)&0xff)) $(((VAL>>24)&0xff)))
    printf '%s' "${HEX}" | xxd -r -p | dd of=${OUT_TEST}.tmp bs=1 seek=0x78 conv=notrunc
    dd if=${OUT_TEST}.tmp bs=1 skip=0x78 count=4 of=${OUT_TEST}.tmp bs=1 seek=0x8078 conv=notrunc
    pad_and_sign ${OUT_TEST}.tmp
    mv ${OUT_TEST}.tmp ${OUT_TEST}
    echo "built ${OUT_TEST} size=$(stat -c%s ${OUT_TEST})"
fi

