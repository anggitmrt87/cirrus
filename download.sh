#!/usr/bin/env bash

set -e

# 🎨 Color codes
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
export GCC32_ROOTDIR="${GCC32_ROOTDIR:-$CIRRUS_WORKING_DIR/gcc32}"
export GCC64_ROOTDIR="${GCC64_ROOTDIR:-$CIRRUS_WORKING_DIR/gcc64}"
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

# ======================== KERNEL CLONE ========================
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
case "$USE_CLANG" in
    "aosp")
        local_archive_name="aosp-clang.tar.gz"
        log_info "Using AOSP Clang toolchain ⚙️"
        if ! curl --head --silent --fail "$AOSP_CLANG_URL" > /dev/null; then
            handle_error "AOSP Clang URL tidak dapat diakses: $AOSP_CLANG_URL"
        fi
        download_with_retry "$AOSP_CLANG_URL" "$local_archive_name"
        verify_download "$TEMP_DIR/$local_archive_name"
        # Ekstrak dengan strip-components=1 (sama seperti Greenforce)
        echo -e "${CYAN}📁 Extracting AOSP toolchain...${NC}"
        if tar -xzf "$TEMP_DIR/$local_archive_name" -C "$CLANG_ROOTDIR"; then
            log_success "AOSP toolchain extracted successfully! ✅"
        else
            handle_error "Failed to extract AOSP toolchain archive"
        fi
        git clone https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9.git -b android12L-release $GCC64_ROOTDIR
        git clone https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9.git -b android12L-release $GCC32_ROOTDIR
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
        # Ekstrak dengan strip-components=1
        echo -e "${CYAN}📁 Extracting Greenforce toolchain...${NC}"
        if tar -xzf "$TEMP_DIR/$local_archive_name" -C "$CLANG_ROOTDIR"; then
            log_success "Greenforce toolchain extracted successfully! ✅"
        else
            handle_error "Failed to extract Greenforce toolchain archive"
        fi
        ;;
    
    *)
        handle_error "Invalid USE_CLANG value: '$USE_CLANG'. Must be 'aosp' or 'greenforce'"
        ;;
esac

# 🧹 Clean up temporary files (archive still in TEMP_DIR, but we'll delete it after extraction)
rm -rf "$TEMP_DIR"/*
echo -e "${GREEN}🧹 Temporary files cleaned${NC}"

# 🔍 Verifikasi akhir (robust)
echo ""
echo -e "${MAGENTA}🔍 Step 3: Verifying toolchain installation...${NC}"

# Pastikan bin directory ada
mkdir -p "$CLANG_ROOTDIR/bin"

# Jika clang tidak ditemukan di bin, cari dan buat symlink
if [[ ! -f "$CLANG_ROOTDIR/bin/clang" ]]; then
    log_warning "clang not found in expected location, searching recursively..."
    clang_found=$(find "$CLANG_ROOTDIR" -type f -name "clang" -executable | head -1)
    if [[ -n "$clang_found" ]]; then
        log_info "Found clang at: $clang_found"
        ln -sf "$clang_found" "$CLANG_ROOTDIR/bin/clang"
        log_success "Created symlink for clang"
    else
        handle_error "clang binary not found anywhere in $CLANG_ROOTDIR"
    fi
fi

# Jika ld.lld tidak ditemukan di bin, cari dan buat symlink
if [[ ! -f "$CLANG_ROOTDIR/bin/ld.lld" ]]; then
    log_warning "ld.lld not found in expected location, searching recursively..."
    lld_found=$(find "$CLANG_ROOTDIR" -type f -name "ld.lld" -executable | head -1)
    if [[ -n "$lld_found" ]]; then
        log_info "Found ld.lld at: $lld_found"
        ln -sf "$lld_found" "$CLANG_ROOTDIR/bin/ld.lld"
        log_success "Created symlink for ld.lld"
    else
        log_warning "ld.lld not found. This might be okay if your build uses another linker."
    fi
fi

# Pastikan binary dapat dieksekusi
chmod -R +x "$CLANG_ROOTDIR/bin" 2>/dev/null || true

# Tampilkan versi
if [[ -f "$CLANG_ROOTDIR/bin/clang" ]]; then
    CLANG_VERSION=$("$CLANG_ROOTDIR/bin/clang" --version | head -n1)
    echo -e "${GREEN}✅ Clang: $CLANG_VERSION${NC}"
else
    handle_error "clang still not accessible after symlink creation"
fi

if [[ -f "$CLANG_ROOTDIR/bin/ld.lld" ]]; then
    LLD_VERSION=$("$CLANG_ROOTDIR/bin/ld.lld" --version | head -n1)
    echo -e "${GREEN}✅ LLD: $LLD_VERSION${NC}"
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
