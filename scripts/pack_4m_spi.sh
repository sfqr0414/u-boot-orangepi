#!/bin/bash
# pack_4m_spi.sh - create a 4MiB RK SPI loader image using fixed 512KiB offset
#
# This helper implements the "外科手术" layout described in the conversation:
# - SPL (idbloader.img) at offset 0
# - u-boot.itb (FIT with ATF) at offset 512KiB
# - pad to 4MiB total
#
set -euo pipefail

IDB="idbloader.img"
ITB="u-boot.itb"
OUT="rkspi_loader_final.img"
OFFSET_KB=512    # matches CONFIG_SYS_SPI_U_BOOT_OFFS

# 1. verify inputs
if [ ! -f "$IDB" ] || [ ! -f "$ITB" ]; then
    echo "error: missing $IDB or $ITB, run 'make' first" >&2
    exit 1
fi

# 2. prepare 4MiB template
echo "creating 4MiB image template..."
truncate -s 4096K "$OUT"

# 3. write idbloader (tpl+spl) at 0
echo "writing $IDB (TPL+SPL) at offset 0"
dd if="$IDB" of="$OUT" conv=notrunc status=none

# 4. write u-boot.itb at specified offset
echo "writing $ITB at offset ${OFFSET_KB}KiB"
dd if="$ITB" of="$OUT" bs=1K seek=${OFFSET_KB} conv=notrunc status=none

# 5. verification
echo "-------------------------------------------------------"
echo "verification:"
hexdump -C -s $((OFFSET_KB*1024)) -n 16 "$OUT" | grep "d0 0d fe ed" &&
    echo "✅ FIT magic found at ${OFFSET_KB}KiB" ||
    echo "❌ FIT magic NOT at expected location!"
echo "final image size: $(ls -lh "$OUT" | awk '{print $5}')"
echo "SHA256: $(sha256sum "$OUT")"
echo "-------------------------------------------------------"

exit 0
