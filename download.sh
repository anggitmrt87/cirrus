#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Colors
# ==============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════╗"
echo "║      📥 SOURCE & TOOLCHAIN DOWNLOADER  ║"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"

# ==============================================================================
# Helpers
# ==============================================================================
handle_error() { echo -e "${RED}❌ [ERROR] $1${NC}" >&2; exit 1; }
log_info()     { echo -e "${BLUE}🔧 [INFO] $1${NC}"; }
log_ok()       { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()     { echo -e "${YELLOW}⚠️ $1${NC}"; }

CIRRUS_WORKING_DIR="${CIRRUS_WORKING_DIR:-/home/circleci/project}"
export CIRRUS_WORKING_DIR
mkdir -p "$CIRRUS_WORKING_DIR"

TEMP_DIR=$(mktemp -d -t kernel_download_XXXXXX)
export TEMP_DIR
trap 'rm -rf "$TEMP_DIR"' EXIT

for cmd in aria2c git curl; do
    command -v "$cmd" &>/dev/null || handle_error "Required command '$cmd' not found."
done

# ==============================================================================
# Download & extract helpers
# ==============================================================================
download_with_retry() {
    local url="$1" dest_file="$2" retries=3 attempt=1
    echo -e "${CYAN}📥 Downloading:${NC} $url"
    while [[ $attempt -le $retries ]]; do
        echo -e "${BLUE}🔄 Attempt $attempt/$retries...${NC}"
        if aria2c --check-certificate=false -x 16 -s 16 "$url" -d "$TEMP_DIR" -o "$dest_file" \
                  --console-log-level=warn --check-integrity=true; then
            log_ok "Download successful"
            return 0
        fi
        log_warn "Attempt $attempt failed, retrying in 5s..."
        ((attempt++))
        sleep 5
    done
    handle_error "Failed to download after $retries attempts: $url"
}

verify_download() {
    local file="$1"
    [[ -f "$file" && -s "$file" ]] || handle_error "Downloaded file missing/empty: $file"
    log_ok "File verified: $(du -h "$file" | cut -f1)"
}

flatten_extracted() {
    local dest="$1"
    if [[ -f "$dest/bin/clang" ]]; then
        return 0
    fi
    local found
    found=$(find "$dest" -maxdepth 3 -type f -name clang 2>/dev/null | head -1)
    if [[ -z "$found" ]]; then
        return 1
    fi
    local wrapper
    wrapper=$(dirname "$(dirname "$found")")
    log_info "Flattening $wrapper → $dest"
    shopt -s dotglob
    mv "$wrapper"/* "$dest"/ 2>/dev/null || true
    rmdir "$wrapper" 2>/dev/null || true
    shopt -u dotglob
}

extract_with_retry() {
    local archive="$1" dest="$2" url="$3" max_attempts=2 attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        echo -e "${CYAN}📦 Extracting (attempt $attempt/$max_attempts)...${NC}"

        local ok=0
        case "$archive" in
            *.tar.gz|*.tgz)  gzip -t "$archive" 2>/dev/null && ok=1 ;;
            *.tar.zst)       command -v zstd &>/dev/null && zstd -t "$archive" 2>/dev/null && ok=1 ;;
            *)               ok=1 ;;
        esac

        if [[ $ok -eq 1 ]]; then
            local cmd
            case "$archive" in
                *.tar.gz|*.tgz)  cmd="tar -xzf \"$archive\" -C \"$dest\"" ;;
                *.tar.zst)       cmd="tar -I zstd -xf \"$archive\" -C \"$dest\"" ;;
                *)               handle_error "Unsupported archive: $archive" ;;
            esac
            if eval "$cmd" 2>&1; then
                log_ok "Extraction successful"
                flatten_extracted "$dest" && return 0
                log_warn "Flatten failed — checking manually"
                [[ -f "$dest/bin/clang" ]] && return 0
            else
                log_warn "Extraction failed."
            fi
        else
            log_warn "Archive appears corrupt."
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_info "Re-downloading (attempt $((attempt+1))/$max_attempts)..."
            rm -f "$archive"
            download_with_retry "$url" "$(basename "$archive")"
            verify_download "$archive"
        fi
        ((attempt++))
    done
    handle_error "Extraction failed after $max_attempts attempts"
}

# ==============================================================================
# Parse devices
# ==============================================================================
declare -a DEVICES=()
if [[ -n "${DEVICE_LIST:-}" ]]; then
    IFS=',' read -ra entries <<< "$DEVICE_LIST"
    for entry in "${entries[@]}"; do
        entry=$(echo "$entry" | xargs)
        [[ -z "$entry" ]] && continue
        codename="${entry%%:*}"
        [[ -z "$codename" ]] && continue
        DEVICES+=("$codename")
    done
elif [[ -n "${DEVICE_CODENAME:-}" ]]; then
    DEVICES+=("$DEVICE_CODENAME")
else
    handle_error "Neither DEVICE_LIST nor DEVICE_CODENAME is set"
fi

[[ ${#DEVICES[@]} -eq 0 ]] && handle_error "No devices resolved"

echo -e "${MAGENTA}📱 Devices to prepare: ${DEVICES[*]}${NC}"

# ==============================================================================
# 1. TOOLCHAIN
# ==============================================================================
if [[ "${USE_GCC:-false}" == "true" ]]; then
    echo -e "${MAGENTA}🔧 Step 1: Setting up GCC toolchain...${NC}"
    mkdir -p "${GCC64_ROOTDIR:?}" "${GCC32_ROOTDIR:?}"
    git clone --depth=1 --branch "${GCC64_BRANCH:?}" "${GCC64_URL:?}" "$GCC64_ROOTDIR" \
        || handle_error "Failed to clone GCC64"
    git clone --depth=1 --branch "${GCC32_BRANCH:?}" "${GCC32_URL:?}" "$GCC32_ROOTDIR" \
        || handle_error "Failed to clone GCC32"
    log_ok "GCC toolchains ready"
else
    echo -e "${MAGENTA}🔧 Step 1: Setting up Clang toolchain ($USE_CLANG)...${NC}"
    mkdir -p "${CLANG_ROOTDIR:?}"

    case "${USE_CLANG:-}" in
        aosp)
            log_info "Using AOSP Clang"
            [[ -z "${AOSP_CLANG_URL:-}" ]] && handle_error "AOSP_CLANG_URL not set"
            local_archive_name="aosp-clang.tar.gz"
            download_with_retry "$AOSP_CLANG_URL" "$local_archive_name"
            verify_download "$TEMP_DIR/$local_archive_name"
            extract_with_retry "$TEMP_DIR/$local_archive_name" "$CLANG_ROOTDIR" "$AOSP_CLANG_URL"
            ;;
        greenforce)
            log_info "Using Greenforce Clang"
            GREENFORCE_SCRIPT=$(mktemp)
            curl -sL --fail "https://raw.githubusercontent.com/greenforce-project/greenforce_clang/refs/heads/main/get_latest_url.sh" -o "$GREENFORCE_SCRIPT" \
                || handle_error "Failed to fetch Greenforce script"
            source "$GREENFORCE_SCRIPT"
            rm -f "$GREENFORCE_SCRIPT"
            [[ -z "${LATEST_URL:-}" ]] && handle_error "LATEST_URL not set"
            local_archive_name="greenforce-clang.tar.gz"
            download_with_retry "$LATEST_URL" "$local_archive_name"
            verify_download "$TEMP_DIR/$local_archive_name"
            extract_with_retry "$TEMP_DIR/$local_archive_name" "$CLANG_ROOTDIR" "$LATEST_URL"
            ;;
        neutron)
            log_info "Using Neutron Clang"
            command -v jq &>/dev/null || handle_error "jq not installed"
            RELEASE_API="https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest"
            ASSET_URL=$(curl -sL "$RELEASE_API" | jq -r '.assets[] | select(.name | test("^neutron-clang-.*\\.tar\\.zst$")) | .browser_download_url' | head -1)
            [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]] && handle_error "No neutron-clang asset in latest release"
            log_info "Found asset: $ASSET_URL"
            local_archive_name="neutron-clang.tar.zst"
            download_with_retry "$ASSET_URL" "$local_archive_name"
            verify_download "$TEMP_DIR/$local_archive_name"
            extract_with_retry "$TEMP_DIR/$local_archive_name" "$CLANG_ROOTDIR" "$ASSET_URL"
            ;;
        zyc)
            log_info "Using ZyCromerZ Clang"
            [[ -z "${ZYC_VERSION:-}" ]] && handle_error "ZYC_VERSION not set"
            local_archive_name="zyc-clang.tar.gz"
            download_url="https://github.com/ZyCromerZ/Clang/releases/download/${ZYC_VERSION}-release/Clang-${ZYC_VERSION}.tar.gz"
            download_with_retry "$download_url" "$local_archive_name"
            verify_download "$TEMP_DIR/$local_archive_name"
            extract_with_retry "$TEMP_DIR/$local_archive_name" "$CLANG_ROOTDIR" "$download_url"
            ;;
        *)
            handle_error "Invalid USE_CLANG='${USE_CLANG:-}'. Use aosp|greenforce|neutron|zyc"
            ;;
    esac

    # Sanity check
    for bin in clang ld.lld llvm-ar llvm-objcopy llvm-strip; do
        [[ -x "$CLANG_ROOTDIR/bin/$bin" ]] || handle_error "Missing $bin in $CLANG_ROOTDIR/bin"
    done
    log_ok "Clang toolchain verified"
fi

# ==============================================================================
# 2. CLONE KERNEL SOURCE(S)
# ==============================================================================
echo -e "${MAGENTA}📥 Step 2: Cloning kernel sources...${NC}"
[[ -z "${KERNEL_SOURCE:-}" ]] && handle_error "KERNEL_SOURCE not set"
[[ -z "${KERNEL_BRANCH:-}" ]] && handle_error "KERNEL_BRANCH not set"

CLONE_URL="$KERNEL_SOURCE"
if [[ -n "${GIT_TOKEN:-}" ]]; then
    CLONE_URL=$(echo "$KERNEL_SOURCE" | sed -E "s|^(https://)|\1${GIT_TOKEN}@|")
fi

for codename in "${DEVICES[@]}"; do
    dest="$CIRRUS_WORKING_DIR/$codename"
    if [[ -d "$dest/.git" ]]; then
        log_info "[$codename] Source already exists, skipping."
        continue
    fi
    log_info "[$codename] Cloning into $dest ..."
    git clone --depth=1 --recurse-submodules --shallow-submodules \
        --branch "$KERNEL_BRANCH" "$CLONE_URL" "$dest" \
        || handle_error "Failed to clone kernel source for $codename"
    [[ -d "$dest/.git" ]] || handle_error "Clone for $codename is not a valid git repo"
    log_ok "[$codename] Source ready"
done

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════╗"
echo "║   ✅ DOWNLOAD TASKS COMPLETED         ║"
echo "╠═══════════════════════════════════════╣"
echo "║   📱 Devices: ${DEVICES[*]}"
if [[ "${USE_GCC:-false}" == "true" ]]; then
    echo "║   ⚙️  Toolchain: GCC"
else
    echo "║   ⚙️  Toolchain: $USE_CLANG (Clang)"
fi
echo "║   🌿 Branch: $KERNEL_BRANCH"
[[ "${USE_GCC:-false}" == "true" ]] && echo "║   📁 GCC64: $GCC64_ROOTDIR"
[[ "${USE_GCC:-false}" == "true" ]] && echo "║   📁 GCC32: $GCC32_ROOTDIR"
[[ "${USE_GCC:-false}" != "true" ]] && echo "║   📁 Clang: $CLANG_ROOTDIR"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"
