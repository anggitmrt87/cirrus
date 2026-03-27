#!/usr/bin/env bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║            📥 SOURCE & TOOLCHAIN DOWNLOADER                     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

handle_error() {
    echo -e "${RED}❌ [ERROR] $1${NC}"
    exit 1
}

log_warning() {
    echo -e "${YELLOW}⚠️ [WARNING] $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ [SUCCESS] $1${NC}"
}

log_info() {
    echo -e "${BLUE}🔧 [INFO] $1${NC}"
}

export CLANG_ROOTDIR="${CLANG_ROOTDIR:-$CIRRUS_WORKING_DIR/clang}"
export TEMP_DIR="$CIRRUS_WORKING_DIR/tmp_downloads"
mkdir -p "$TEMP_DIR"

if ! command -v aria2c &> /dev/null; then
    handle_error "aria2c tidak ditemukan. Pastikan sudah diinstall (apt-get install aria2)"
fi

download_with_retry() {
    local url="$1"
    local dest_file="$2"
    local retries=3
    local attempt=1
    
    echo -e "${CYAN}📥 Downloading:${NC} $url"
    echo -e "${CYAN}📁 Destination:${NC} $dest_file"
    
    while [[ $attempt -le $retries ]]; do
        echo -e "${BLUE}🔄 Attempt $attempt/$retries...${NC}"
        if aria2c --check-certificate=false -x 16 -s 16 "$url" -d "$TEMP_DIR" -o "$dest_file" --console-log-level=warn; then
            echo -e "${GREEN}✅ Download successful${NC}"
            return 0
        fi
        echo -e "${YELLOW}⚠️ Download attempt $attempt failed, retrying in 5 seconds...${NC}"
        ((attempt++))
        sleep 5
    done
    
    handle_error "Failed to download after $retries attempts: $url"
}

verify_download() {
    local file="$1"
    if [[ ! -f "$file" || ! -s "$file" ]]; then
        handle_error "Downloaded file is empty or missing: $file"
    fi
    echo -e "${GREEN}✅ File verified: $(du -h "$file" | cut -f1)${NC}"
}

echo -e "${MAGENTA}📥 Step 1: Cloning Kernel Sources...${NC}"
if git clone --depth=1 --recurse-submodules --shallow-submodules \
    --branch "$KERNEL_BRANCH" \
    "$KERNEL_SOURCE" \
    "$CIRRUS_WORKING_DIR/$DEVICE_CODENAME" 2>&1; then
    log_success "Kernel sources cloned successfully! 🎉"
    
    cd "$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"
    if [[ -d ".git" ]]; then
        echo -e "${GREEN}✅ Git repository verified${NC}"
    else
        handle_error "Cloned directory is not a valid git repository"
    fi
else
    handle_error "Failed to clone kernel repository"
fi

echo ""
echo -e "${MAGENTA}🔧 Step 2: Setting up Toolchain ($USE_CLANG)...${NC}"
mkdir -p "$CLANG_ROOTDIR"

local_archive_name=""
smart_extract() {
    local archive="$1"
    local target="$2"
    local temp_extract="$TEMP_DIR/extract"
    mkdir -p "$temp_extract"
    
    echo -e "${CYAN}📦 Extracting archive to temporary location...${NC}"
    if ! tar -xf "$archive" -C "$temp_extract"; then
        handle_error "Failed to extract archive"
    fi
    
    local clang_path
    clang_path=$(find "$temp_extract" -type f -name "clang" -executable | head -1)
    if [[ -z "$clang_path" ]]; then
        clang_path=$(find "$temp_extract" -type f -name "clang" | head -1)
        if [[ -z "$clang_path" ]]; then
            handle_error "clang binary not found in extracted archive"
        fi
    fi
    
    log_info "Found clang at: $clang_path"
    
    local bin_dir
    bin_dir=$(dirname "$clang_path")
    if [[ "$(basename "$bin_dir")" != "bin" ]]; then
        log_warning "clang is not in a 'bin' directory. Using its parent as bin."
        mkdir -p "$target/bin"
        cp -L "$clang_path" "$target/bin/"
        local lld_path
        lld_path=$(find "$temp_extract" -type f -name "ld.lld" | head -1)
        if [[ -n "$lld_path" ]]; then
            cp -L "$lld_path" "$target/bin/"
        else
            log_warning "ld.lld not found, will use system linker?"
        fi
    else
        local parent_dir
        parent_dir=$(dirname "$bin_dir")
        rm -rf "$target/bin" 2>/dev/null || true
        mv "$bin_dir" "$target/bin"
        for dir in lib lib64 include share; do
            if [[ -d "$parent_dir/$dir" ]]; then
                mv "$parent_dir/$dir" "$target/" 2>/dev/null || true
            fi
        done
    fi
    
    chmod -R +x "$target/bin" 2>/dev/null || true
    
    rm -rf "$temp_extract"
    log_success "Toolchain extracted and organized successfully!"
}

case "$USE_CLANG" in
    "aosp")
        local_archive_name="aosp-clang.tar.gz"
        log_info "Using AOSP Clang toolchain ⚙️"
        if ! curl --head --silent --fail "$AOSP_CLANG_URL" > /dev/null; then
            handle_error "AOSP Clang URL tidak dapat diakses: $AOSP_CLANG_URL"
        fi
        download_with_retry "$AOSP_CLANG_URL" "$local_archive_name"
        verify_download "$TEMP_DIR/$local_archive_name"
        smart_extract "$TEMP_DIR/$local_archive_name" "$CLANG_ROOTDIR"
        ;;
    
    "greenforce")
        local_archive_name="greenforce-clang.tar.gz"
        log_info "Using Greenforce Clang toolchain ⚡"
        GREENFORCE_SCRIPT=$(curl -sL --fail https://raw.githubusercontent.com/greenforce-project/greenforce_clang/refs/heads/main/get_latest_url.sh) || handle_error "Gagal mengambil script Greenforce"
        source /dev/stdin <<< "$GREENFORCE_SCRIPT"
        if [[ -z "$LATEST_URL" ]]; then
            handle_error "LATEST_URL tidak ditemukan dari script Greenforce"
        fi
        download_with_retry "$LATEST_URL" "$local_archive_name"
        verify_download "$TEMP_DIR/$local_archive_name"
        smart_extract "$TEMP_DIR/$local_archive_name" "$CLANG_ROOTDIR"
        ;;
    
    *)
        handle_error "Invalid USE_CLANG value: '$USE_CLANG'. Must be 'aosp' or 'greenforce'"
        ;;
esac

rm -rf "$TEMP_DIR"
echo -e "${GREEN}🧹 Temporary files cleaned${NC}"

echo ""
echo -e "${MAGENTA}🔍 Step 3: Verifying toolchain installation...${NC}"
if [[ -f "$CLANG_ROOTDIR/bin/clang" && -f "$CLANG_ROOTDIR/bin/ld.lld" ]]; then
    CLANG_VERSION=$("$CLANG_ROOTDIR/bin/clang" --version | head -n1)
    LLD_VERSION=$("$CLANG_ROOTDIR/bin/ld.lld" --version | head -n1)
    echo -e "${GREEN}✅ Clang: $CLANG_VERSION${NC}"
    echo -e "${GREEN}✅ LLD: $LLD_VERSION${NC}"
    
    chmod -R +x "$CLANG_ROOTDIR/bin" 2>/dev/null || log_warning "Could not set execute permissions on toolchain binaries"
else
    clang_found=$(find "$CLANG_ROOTDIR" -type f -name "clang" -executable | head -1)
    if [[ -n "$clang_found" ]]; then
        log_warning "clang found at $clang_found but not in expected location"
        mkdir -p "$CLANG_ROOTDIR/bin"
        ln -sf "$clang_found" "$CLANG_ROOTDIR/bin/clang"
        lld_found=$(find "$CLANG_ROOTDIR" -type f -name "ld.lld" -executable | head -1)
        if [[ -n "$lld_found" ]]; then
            ln -sf "$lld_found" "$CLANG_ROOTDIR/bin/ld.lld"
        fi
        echo -e "${GREEN}✅ Fixed symlinks created${NC}"
    else
        handle_error "Toolchain verification failed: essential binaries not found"
    fi
fi

echo ""
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║              ✅ SYNC TASKS COMPLETED SUCCESSFULLY!              ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║   📱 Device: $DEVICE_CODENAME                                  ║"
echo "║   ⚙️  Toolchain: $USE_CLANG                                    ║"
echo "║   🌿 Kernel Branch: $KERNEL_BRANCH                             ║"
echo "║   📁 Toolchain Path: $CLANG_ROOTDIR                            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
