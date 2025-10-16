#!/usr/bin/env bash

set -e  # Exit on error

# Color setup
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}[INFO]${NC} Starting post-build cleanup..."

# Base Telegram URL (for sticker and final status if needed, though mostly handled by build.sh)
export BOT_BASE_URL="https://api.telegram.org/bot$TG_TOKEN"

cd "$CIRRUS_WORKING_DIR" || exit 1

# Note: Success sticker is typically sent by build.sh's 'cleanup' trap.
# We keep this section minimal for *final* confirmation and file cleanup.

# Cleanup temporary files
echo -e "${GREEN}[INFO]${NC} Cleaning up temporary files..."

# Remove any tarballs left from download.sh or build.sh (AnyKernel zip is in $ANYKERNEL_DIR)
# Use '|| true' to prevent script exit if no files are found (non-fatal removal)
rm -rf "$CIRRUS_WORKING_DIR"/*.tar.* 2>/dev/null || true
rm -rf "$CIRRUS_WORKING_DIR"/tmp_downloads 2>/dev/null || true # New temporary download folder
rm -rf "$CIRRUS_WORKING_DIR"/AnyKernel 2>/dev/null || true # Cleanup the extracted AnyKernel repo
rm -rf "$CIRRUS_WORKING_DIR"/clang 2>/dev/null || true # Cleanup the extracted toolchain
rm -rf "$CIRRUS_WORKING_DIR"/$DEVICE_CODENAME 2>/dev/null || true # Cleanup the kernel source tree

# Show disk usage after cleanup
echo -e "${GREEN}[INFO]${NC} Final disk usage:"
df -h "$CIRRUS_WORKING_DIR" | tail -1

# Show Ccache final status (optional, but useful)
if [[ "$CCACHE" == "true" ]]; then
    echo -e "${GREEN}[INFO]${NC} Final Ccache statistics:"
    ccache -s
fi

echo -e "${GREEN}[SUCCESS]${NC} Post-build cleanup completed!"
