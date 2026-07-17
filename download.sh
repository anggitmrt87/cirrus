#!/usr/bin/env bash
set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════╗"
echo "║      📥 SOURCE & TOOLCHAIN DOWNLOADER  ║"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"

handle_error() {
    echo -e "${RED}❌ [ERROR] $1${NC}"
    exit 1
}

log_info() {
    echo -e "${BLUE}🔧 [INFO] $1${NC}"
}

# Use a temporary directory with mktemp for safety
TEMP_DIR=$(mktemp -d -t kernel_download_XXXXXX)
export TEMP_DIR
trap 'rm -rf "$TEMP_DIR"' EXIT

# Check required tools
for cmd in aria2c git curl; do
    if ! command -v "$cmd" &>/dev/null; then
        handle_error "Required command '$cmd' not found. Please install it."
    fi
done

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
    echo -e "${GREEN}✅ Kernel sources cloned successfully! 🎉${NC}"

    cd "$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"
    if [[ ! -d ".git" ]]; then
        handle_error "Cloned directory is not a valid git repository"
    fi
else
    handle_error "Failed to clone kernel repository"
fi

echo ""

# ======================== TOOLCHAIN ========================
if [[ "${USE_GCC:-false}" == "true" ]]; then
    # -------- GCC build (no Clang) --------
    echo -e "${MAGENTA}🔧 Step 2: Setting up GCC toolchain...${NC}"
    mkdir -p "$GCC64_ROOTDIR" "$GCC32_ROOTDIR"

    log_info "Cloning GCC64 toolchain..."
    git clone --depth=1 --branch "$GCC64_BRANCH" "$GCC64_URL" "$GCC64_ROOTDIR" || handle_error "Failed to clone GCC64"

    log_info "Cloning GCC32 toolchain..."
    git clone --depth=1 --branch "$GCC32_BRANCH" "$GCC32_URL" "$GCC32_ROOTDIR" || handle_error "Failed to clone GCC32"

    echo -e "${GREEN}✅ GCC toolchains downloaded${NC}"

else
    # -------- Clang build --------
    echo -e "${MAGENTA}🔧 Step 2: Setting up Clang toolchain ($USE_CLANG)...${NC}"
    mkdir -p "$CLANG_ROOTDIR"

    case "$USE_CLANG" in
        "aosp")
            log_info "Using AOSP Clang toolchain"
            local_archive_name="aosp-clang.tar.gz"
            if ! curl --head --silent --fail "$AOSP_CLANG_URL" > /dev/null; then
                handle_error "AOSP Clang URL not accessible: $AOSP_CLANG_URL"
            fi
            download_with_retry "$AOSP_CLANG_URL" "$local_archive_name"
            verify_download "$TEMP_DIR/$local_archive_name"
            echo -e "${CYAN}📁 Extracting AOSP toolchain...${NC}"
            tar -xzf "$TEMP_DIR/$local_archive_name" -C "$CLANG_ROOTDIR" || handle_error "Failed to extract AOSP toolchain"

            # For AOSP clang we also need GCC cross compilers (but we may already have them)
            # They are required for proper linking; download them as well.
            log_info "Cloning GCC64 toolchain (required for AOSP clang build)..."
            git clone --depth=1 --branch "$GCC64_BRANCH" "$GCC64_URL" "$GCC64_ROOTDIR" || handle_error "Failed to clone GCC64"
            log_info "Cloning GCC32 toolchain (required for AOSP clang build)..."
            git clone --depth=1 --branch "$GCC32_BRANCH" "$GCC32_URL" "$GCC32_ROOTDIR" || handle_error "Failed to clone GCC32"
            ;;

        "greenforce")
            log_info "Using Greenforce Clang toolchain"
            # Fetch the script that exports LATEST_URL. Use source instead of eval for safety.
            # We'll download the script and then source it to get the variable.
            GREENFORCE_SCRIPT=$(mktemp)
            curl -sL --fail "https://raw.githubusercontent.com/greenforce-project/greenforce_clang/refs/heads/main/get_latest_url.sh" -o "$GREENFORCE_SCRIPT" || handle_error "Failed to fetch Greenforce script"
            # Source the script; it should set LATEST_URL
            source "$GREENFORCE_SCRIPT" || handle_error "Failed to source Greenforce script"
            rm -f "$GREENFORCE_SCRIPT"
            if [[ -z "$LATEST_URL" ]]; then
                handle_error "LATEST_URL not set after sourcing Greenforce script"
            fi
            local_archive_name="greenforce-clang.tar.gz"
            download_with_retry "$LATEST_URL" "$local_archive_name"
            verify_download "$TEMP_DIR/$local_archive_name"
            echo -e "${CYAN}📁 Extracting Greenforce toolchain...${NC}"
            tar -xzf "$TEMP_DIR/$local_archive_name" -C "$CLANG_ROOTDIR" || handle_error "Failed to extract Greenforce toolchain"
            ;;

        "neutron")
            log_info "Using Neutron Clang toolchain"
            if ! command -v jq &> /dev/null; then
                handle_error "jq not found. Please install jq."
            fi
            RELEASE_API="https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest"
            echo -e "${CYAN}🔍 Fetching latest release info from GitHub...${NC}"
            ASSET_URL=$(curl -sL "$RELEASE_API" | jq -r '.assets[] | select(.name | test("^neutron-clang-.*\\.tar\\.zst$")) | .browser_download_url' | head -1)
            if [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]]; then
                handle_error "No neutron-clang asset found in latest release"
            fi
            log_info "Found asset: $ASSET_URL"

            local_archive_name="neutron-clang.tar.zst"
            download_with_retry "$ASSET_URL" "$local_archive_name"
            verify_download "$TEMP_DIR/$local_archive_name"

            echo -e "${CYAN}📁 Extracting Neutron toolchain (zstd)...${NC}"
            # Use --strip-components=1 to avoid extra directory level
            tar -I zstd -xf "$TEMP_DIR/$local_archive_name" -C "$CLANG_ROOTDIR" --strip-components=1 || handle_error "Failed to extract Neutron toolchain"

            # Verify clang binary
            if [[ ! -f "$CLANG_ROOTDIR/bin/clang" ]]; then
                handle_error "Neutron Clang binary not found after extraction"
            fi
            log_info "Neutron Clang extracted successfully."
            ;;
            
        "zyc")
            log_info "Using ZyCromerZ Clang toolchain"
            if [[ -z "${ZYC_VERSION:-}" ]]; then
                handle_error "ZYC_VERSION not set. Please specify version like '16.0.6-20260716'"
            fi
            local_archive_name="zyc-clang.tar.gz"
            local download_url="https://github.com/ZyCromerZ/Clang/releases/download/${ZYC_VERSION}-release/Clang-${ZYC_VERSION}.tar.gz"
            download_with_retry "$download_url" "$local_archive_name"
            verify_download "$TEMP_DIR/$local_archive_name"
            echo -e "${CYAN}📁 Extracting ZyCromerZ toolchain...${NC}"
            tar -xzf "$TEMP_DIR/$local_archive_name" -C "$CLANG_ROOTDIR" || handle_error "Failed to extract ZyC clang"
            ;;

        *)
            handle_error "Invalid USE_CLANG value: '$USE_CLANG'. Must be 'aosp', 'greenforce', or 'neutron'"
            ;;
    esac
fi

echo ""
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════╗"
echo "║   ✅ DOWNLOAD TASKS COMPLETED SUCCESSFULLY!   ║"
echo "╠═══════════════════════════════════════╣"
echo "║   📱 Device: $DEVICE_CODENAME"
if [[ "${USE_GCC:-false}" == "true" ]]; then
    echo "║   ⚙️ Toolchain: GCC"
else
    echo "║   ⚙️ Toolchain: $USE_CLANG (Clang)"
fi
echo "║   🌿 Kernel Branch: $KERNEL_BRANCH"
[[ "${USE_GCC:-false}" == "true" ]] && echo "║   📁 GCC64 Path: $GCC64_ROOTDIR"
[[ "${USE_GCC:-false}" == "true" ]] && echo "║   📁 GCC32 Path: $GCC32_ROOTDIR"
[[ "${USE_GCC:-false}" != "true" ]] && echo "║   📁 Clang Path: $CLANG_ROOTDIR"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"
