#!/usr/bin/env bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "    Kernel Source & Toolchain Download"
echo "=========================================="
echo ""

# Function for error handling
handle_error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Function for warning
log_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Ensure CLANG_ROOTDIR is set
export CLANG_ROOTDIR="${CLANG_ROOTDIR:-$CIRRUS_WORKING_DIR/clang}" 
export TEMP_DIR="$CIRRUS_WORKING_DIR/tmp_downloads"
mkdir -p "$TEMP_DIR"

# Function for downloading with retry and progress
download_with_retry() {
    local url="$1"
    local dest_file="$2"
    local retries=3
    local attempt=1
    
    echo "Downloading: $url"
    echo "Destination: $dest_file"
    
    while [[ $attempt -le $retries ]]; do
        echo "Attempt $attempt/$retries..."
        if aria2c --check-certificate=false -x 16 -s 16 "$url" -d "$TEMP_DIR" -o "$dest_file" --console-log-level=warn; then
            echo -e "${GREEN}✓ Download successful${NC}"
            return 0
        fi
        echo -e "${YELLOW}✗ Download attempt $attempt failed, retrying in 5 seconds...${NC}"
        ((attempt++))
        sleep 5
    done
    
    handle_error "Failed to download after $retries attempts: $url"
}

# Function to verify download
verify_download() {
    local file="$1"
    if [[ ! -f "$file" || ! -s "$file" ]]; then
        handle_error "Downloaded file is empty or missing: $file"
    fi
    echo -e "${GREEN}✓ File verified: $(du -h "$file" | cut -f1)${NC}"
}

echo "📥 Cloning Kernel Sources..."
if git clone --depth=1 --recurse-submodules --shallow-submodules \
    --branch "$KERNEL_BRANCH" \
    "$KERNEL_SOURCE" \
    "$CIRRUS_WORKING_DIR/$DEVICE_CODENAME" 2>&1; then
    echo -e "${GREEN}✅ Kernel sources cloned successfully${NC}"
    
    # Verify clone
    cd "$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"
    if [[ -d ".git" ]]; then
        echo -e "${GREEN}✓ Git repository verified${NC}"
    else
        handle_error "Cloned directory is not a valid git repository"
    fi
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
        verify_download "$TEMP_DIR/$local_archive_name"
        strip_components_count=0
        ;;
    
    "greenforce")
        local_archive_name="greenforce-clang.tar.gz"
        download_with_retry "$GREENFORCE_CLANG_URL" "$local_archive_name"
        verify_download "$TEMP_DIR/$local_archive_name"
        strip_components_count=1
        ;;
    
    *)
        handle_error "Invalid USE_CLANG value: '$USE_CLANG'. Must be 'aosp' or 'greenforce'"
        ;;
esac

echo "📁 Extracting toolchain (strip-components=$strip_components_count)..."
if tar -xf "$TEMP_DIR/$local_archive_name" -C "$CLANG_ROOTDIR" --strip-components=$strip_components_count; then
    echo -e "${GREEN}✅ Toolchain extracted successfully${NC}"
else
    handle_error "Failed to extract toolchain archive"
fi

# Clean up temporary files
rm -rf "$TEMP_DIR"
echo -e "${GREEN}✓ Temporary files cleaned${NC}"

# Verify toolchain installation
echo ""
echo "🔍 Verifying toolchain installation..."
if [[ -f "$CLANG_ROOTDIR/bin/clang" && -f "$CLANG_ROOTDIR/bin/ld.lld" ]]; then
    CLANG_VERSION=$("$CLANG_ROOTDIR/bin/clang" --version | head -n1)
    LLD_VERSION=$("$CLANG_ROOTDIR/bin/ld.lld" --version | head -n1)
    echo -e "${GREEN}✅ Clang: $CLANG_VERSION${NC}"
    echo -e "${GREEN}✅ LLD: $LLD_VERSION${NC}"
    
    # Make binaries executable
    chmod -R +x "$CLANG_ROOTDIR/bin" 2>/dev/null || log_warning "Could not set execute permissions on toolchain binaries"
else
    handle_error "Toolchain verification failed: essential binaries not found"
fi

echo ""
echo "=========================================="
echo "✅ All sync tasks completed successfully!"
echo "   Device: $DEVICE_CODENAME"
echo "   Toolchain: $USE_CLANG"
echo "   Kernel Branch: $KERNEL_BRANCH"
echo "   Toolchain Path: $CLANG_ROOTDIR"
echo "=========================================="
