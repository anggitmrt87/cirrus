#!/usr/bin/env bash

set -e

# Color setup
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[INFO]${NC} Starting post-build cleanup..."

cd "$CIRRUS_WORKING_DIR" || exit 1

echo -e "${BLUE}[INFO]${NC} Cleaning up build artifacts..."

# Remove temporary files and directories
cleanup_dirs=(
    "*.tar.*"
    "tmp_downloads"
    "AnyKernel"
    "clang"
    "$DEVICE_CODENAME"
    "build.log"
    "build_error.log"
)

for pattern in "${cleanup_dirs[@]}"; do
    if [[ -e $pattern ]]; then
        echo -e "${YELLOW}[CLEANUP]${NC} Removing: $pattern"
        rm -rf $pattern 2>/dev/null || true
    fi
done

# Additional cleanup for any leftover files
find "$CIRRUS_WORKING_DIR" -maxdepth 1 -name "*.zip" -type f -delete 2>/dev/null || true
find "$CIRRUS_WORKING_DIR" -maxdepth 1 -name "*.log" -type f -delete 2>/dev/null || true

echo -e "${BLUE}[INFO]${NC} Final disk usage:"
df -h "$CIRRUS_WORKING_DIR" | tail -1

echo -e "${BLUE}[INFO]${NC} Memory usage:"
free -h || true

# Show Ccache final status
if [[ "$CCACHE" == "true" ]]; then
    echo -e "${BLUE}[INFO]${NC} Final CCache statistics:"
    ccache -s 2>/dev/null || echo "CCache not available"
fi

echo -e "${GREEN}[SUCCESS]${NC} Cleanup completed successfully!"
