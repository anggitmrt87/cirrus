#!/usr/bin/env bash

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "=========================================="
echo "    Kernel Source & Toolchain Download"
echo "=========================================="
echo ""

# Function for error handling
handle_error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Ensure CLANG_ROOTDIR is set (as it is needed by build.sh)
export CLANG_ROOTDIR="$CIRRUS_WORKING_DIR/clang" 
export TEMP_DIR="$CIRRUS_WORKING_DIR/tmp_downloads"
mkdir -p "$TEMP_DIR"

# Function for downloading with retry
download_with_retry() {
    local url="$1"
    local dest_file="$2"
    local retries=3
    local attempt=1
    
    echo "Download attempt 1/$retries for: $url"
    while [[ $attempt -le $retries ]]; do
        if aria2c --check-certificate=false -x 16 -s 16 "$url" -d "$TEMP_DIR" -o "$dest_file"; then
            echo -e "${GREEN}Download successful!${NC}"
            return 0
        fi
        echo -e "${RED}Download attempt $attempt failed, retrying...${NC}"
        ((attempt++))
        sleep 5
    done
    
    handle_error "Failed to download after $retries attempts: $url"
}

echo "📥 Cloning Kernel Sources..."
if git clone --depth=1 --recurse-submodules --shallow-submodules \
    "$KERNEL_SOURCE" -b "$KERNEL_BRANCH" \
    "$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"; then
    echo -e "${GREEN}✅ Kernel sources cloned successfully${NC}"
else
    handle_error "Failed to clone kernel repository"
fi

echo ""

echo "🔧 Setting up Toolchain ($USE_CLANG)..."
mkdir -p "$CLANG_ROOTDIR"
local_archive_name=""
strip_components_count=0

# Toolchain selection with validation
case "$USE_CLANG" in
    "aosp")
        local_archive_name="aosp-clang.tar.gz"
        download_with_retry "$AOSP_CLANG_URL" "$local_archive_name"
        strip_components_count=0 # AOSP archives often extract directly into the target folder structure
        ;;
    
    "greenforce")
        local_archive_name="greenforce-clang.tar.gz"
        download_with_retry "$GREENFORCE_CLANG_URL" "$local_archive_name"
        strip_components_count=1 # Greenforce (and most custom toolchains) need stripping
        ;;
    
    *)
        handle_error "Invalid USE_CLANG value: '$USE_CLANG'. Must be 'aosp' or 'greenforce'"
        ;;
esac

echo "📁 Extracting toolchain (strip-components=$strip_components_count)..."
if tar -xf "$TEMP_DIR/$local_archive_name" -C "$CLANG_ROOTDIR" --strip-components=$strip_components_count; then
    rm -rf "$TEMP_DIR" # Clean up temporary download directory
    echo -e "${GREEN}✅ Toolchain extracted successfully${NC}"
else
    rm -rf "$TEMP_DIR"
    handle_error "Failed to extract toolchain"
fi


# Verify toolchain installation
echo ""
echo "🔍 Verifying toolchain installation..."
if [[ -f "$CLANG_ROOTDIR/bin/clang" ]]; then
    CLANG_VERSION=$("$CLANG_ROOTDIR/bin/clang" --version | head -n1)
    echo -e "${GREEN}✅ Toolchain verified: $CLANG_VERSION${NC}"
else
    handle_error "Toolchain verification failed: clang binary not found"
fi

echo ""
echo "=========================================="
echo "✅ All sync tasks completed successfully!"
echo "   Device: $DEVICE_CODENAME"
echo "   Toolchain: $USE_CLANG"
echo "   Kernel Branch: $KERNEL_BRANCH"
echo "=========================================="
