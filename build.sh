#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# 🎨 Colors and emojis
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
BOLD_YELLOW='\033[1;33m'
BOLD_BLUE='\033[1;34m'
BOLD_CYAN='\033[1;36m'

# ------------------------------------------------------------------------------
# 📝 Logging helpers
# ------------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}📦 [INFO]${NC} $1"; }
log_success() { echo -e "${BOLD_GREEN}✅ [SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠️ [WARNING]${NC} $1"; }
log_error()   { echo -e "${BOLD_RED}❌ [ERROR]${NC} $1" >&2; }
log_debug()   { [[ "${DEBUG_MODE:-false}" == "true" ]] && echo -e "${CYAN}🐛 [DEBUG]${NC} $1"; }
log_step()    { echo -e "${BOLD_CYAN}🚀 [STEP]${NC} $1"; }
log_progress(){ echo -e "${MAGENTA}📊 [PROGRESS]${NC} $1"; }

# ------------------------------------------------------------------------------
# 🌟 Global variables (will be set during runtime)
# ------------------------------------------------------------------------------
declare -g KERNEL_NAME="mrt-kernel"
declare -g START_TIME
declare -g BUILD_STATUS="failed"
declare -g BUILD_LOG="${CIRRUS_WORKING_DIR:-.}/build.log"

# Redirect all output to log file AND console
exec > >(tee -a "$BUILD_LOG") 2>&1

# ------------------------------------------------------------------------------
# 🛠️  Helper functions
# ------------------------------------------------------------------------------
check_dependencies() {
    local deps=("curl" "git" "make" "zip")
    if [[ "${CCACHE:-false}" == "true" ]]; then
        deps+=("ccache")
    fi
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Missing required command: $cmd"
            exit 1
        fi
    done
}

validate_environment() {
    log_step "Validating environment variables..."
    local required_vars=(
        "DEVICE_CODENAME" "TG_TOKEN" "TG_CHAT_ID" "BUILD_USER" "BUILD_HOST" "ANYKERNEL" "ANYKERNEL_BRANCH" "KERNEL_SOURCE" "KERNEL_BRANCH"
    )
    [[ "${KPM_PATCH:-false}" == "true" ]] && required_vars+=("KPM_VERSION")

    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing[*]}"
        exit 1
    fi

    log_success "Environment validation passed."
}

setup_directories() {
    export KERNEL_ROOTDIR="$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"
    export KERNEL_OUTDIR="$KERNEL_ROOTDIR/out"
    export ANYKERNEL_DIR="$CIRRUS_WORKING_DIR/AnyKernel"

    mkdir -p "$KERNEL_OUTDIR" "$ANYKERNEL_DIR"
}

setup_toolchain() {
    # Ensure Clang exists
    if [[ ! -d "$CLANG_ROOTDIR" || ! -f "$CLANG_ROOTDIR/bin/clang" ]]; then
        log_error "Clang toolchain not found at $CLANG_ROOTDIR"
        exit 1
    fi

    local bin_dir="$CLANG_ROOTDIR/bin"
    export CLANG_VER="$("$bin_dir/clang" --version | head -n1 | sed -E 's/\(http[^)]+\)//g' | awk '{$1=$1};1')"
    export LLD_VER="$("$bin_dir/ld.lld" --version | head -n1)"
    export KBUILD_COMPILER_STRING="$CLANG_VER with $LLD_VER"

    # Setup PATH (with ccache if enabled)
    if [[ "${CCACHE:-false}" == "true" ]]; then
        export USE_CCACHE=1
        export CCACHE_EXEC=$(which ccache)
        export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
        export PATH="/usr/lib/ccache:$CLANG_ROOTDIR/bin:${PATH}"
        ccache -o compression=true
        ccache -o compression_level=1
        ccache -o max_size="$CCACHE_MAXSIZE"
        ccache -z
        log_info "CCache enabled: $CCACHE_DIR (max: $CCACHE_MAXSIZE)"
    else
        export PATH="$CLANG_ROOTDIR/bin:${PATH}"
    fi

    # Add GCC toolchains for AOSP builds if needed
    if [[ "${USE_CLANG:-}" == "aosp" ]]; then
        if [[ ! -d "$GCC32_ROOTDIR" || ! -d "$GCC64_ROOTDIR" ]]; then
            log_error "GCC toolchains missing for AOSP build"
            exit 1
        fi
        export PATH="$GCC32_ROOTDIR/bin:$GCC64_ROOTDIR/bin:$PATH"
        export BUILD_CROSS_COMPILE="aarch64-linux-android-"
        export BUILD_CROSS_COMPILE_ARM32="arm-linux-androideabi-"
    fi
    
    if [[ "${ARCH:-}" == "arm64" ]]; then
        export BUILD_CLANG_TRIPLE="aarch64-linux-gnu-"
    elif [[ "${ARCH:-}" == "arm" ]]; then
        export BUILD_CLANG_TRIPLE="arm-linux-gnueabi-"
    fi

    export LD_LIBRARY_PATH="$CLANG_ROOTDIR/lib"
}

setup_build_vars() {
    export KBUILD_BUILD_USER="$BUILD_USER"
    export KBUILD_BUILD_HOST="$BUILD_HOST"
    export IMAGE="$KERNEL_OUTDIR/arch/arm64/boot/${TYPE_IMAGE:-Image.gz}"
    export DTBO="$KERNEL_OUTDIR/arch/arm64/boot/dtbo.img"
    export DTB="$KERNEL_OUTDIR/${DTB_PATH:-}"
    export DATE=$(date +"%Y%m%d-%H%M%S")
    export NUM_CORES=$(nproc)

    # Build options: default to -j<cores> if not already set
    if [[ -z "${BUILD_OPTIONS:-}" ]]; then
        export BUILD_OPTIONS="-j$NUM_CORES"
    fi
}

setup_telegram() {
    export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
    export BOT_DOC_URL="https://api.telegram.org/bot$TG_TOKEN/sendDocument"
}

tg_post_msg() {
    local message="$1"
    local parse_mode="${2:-html}"
    curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=$parse_mode" \
        -d text="$message" >/dev/null || log_warning "Failed to send message"
}

tg_send_sticker() {
    local sticker_id="$1"
    local url="https://api.telegram.org/bot$TG_TOKEN/sendSticker"
    curl -s -X POST "$url" -d sticker="$sticker_id" -d chat_id="$TG_CHAT_ID" >/dev/null || log_warning "Failed to send sticker"
}

send_failure_log() {
    local exit_code="$1"
    local log_file="$CIRRUS_WORKING_DIR/build_error.log"
    rm -f "$log_file"

    # Capture last 100 lines of build log
    if [[ -f "$BUILD_LOG" ]]; then
        tail -100 "$BUILD_LOG" > "$log_file"
    else
        dmesg | tail -50 > "$log_file" || echo "Unable to capture logs" > "$log_file"
    fi

    {
        echo -e "\n=== Build Environment ==="
        env | grep -E "(CIRRUS|KERNEL|TG_|BUILD_|CLANG_)"
        echo -e "\n=== System Info ==="
        uname -a
    } >> "$log_file"

    if [[ -f "$log_file" ]]; then
        local doc_name="build_error_${DEVICE_CODENAME}_$(date +%s).log"
        local caption="❌ <b>Kernel Build Failed</b>%0A📱 Device: <code>$DEVICE_CODENAME</code>%0A🕐 Time: $(date +'%Y-%m-%d %H:%M:%S')%0A🔢 Exit Code: $exit_code"
        curl -F document=@"$log_file" -F filename="$doc_name" "$BOT_DOC_URL" \
            -F chat_id="$TG_CHAT_ID" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="$caption" >/dev/null || log_warning "Failed to send error log"
    fi
}

cleanup() {
    local exit_code=$?
    local end_time=$(date +%s)
    local build_time=$((end_time - START_TIME))

    if [[ $exit_code -eq 0 && "$BUILD_STATUS" == "success" ]]; then
        log_success "Build completed successfully in ${build_time}s"
        tg_send_sticker "CAACAgQAAx0EabRMmQACAm9jET5WwKp2FMYITmo6O8CJxt3H2wACFQwAAtUjEFPkKwhxHG8_Kx4E"
    else
        log_error "Build failed with exit code $exit_code after ${build_time}s"
        send_failure_log "$exit_code"
        tg_send_sticker "CAACAgQAAx0EabRMmQACAnRjEUAXBTK1Ei_zbJNPFH7WCLzSdAACpBEAAqbxcR716gIrH45xdB4E"
    fi

    # Clean temporary files
    rm -rf "$CIRRUS_WORKING_DIR"/*.tar.* "$CIRRUS_WORKING_DIR"/tmp_downloads 2>/dev/null || true
    [[ "${KEEP_BUILD_LOGS:-false}" != "true" ]] && rm -f "$BUILD_LOG"

    exit "$exit_code"
}

# ------------------------------------------------------------------------------
# 🔧 Feature installation (KernelSU, KPM)
# ------------------------------------------------------------------------------
install_kernelsu() {
    [[ "${KERNELSU:-false}" != "true" ]] && { log_info "KernelSU disabled, skipping."; return 0; }

    local url=""
    case "${KERNELSU_TYPE:-}" in
        sukisu)       url="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/refs/heads/main/kernel/setup.sh" ;;
        rksu)         url="https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh" ;;
        kernelsunext) url="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/refs/heads/dev/kernel/setup.sh" ;;
        backslashxx)  url="https://raw.githubusercontent.com/backslashxx/KernelSU/refs/heads/master/kernel/setup.sh" ;;
        all)          url="https://raw.githubusercontent.com/Sorayukii/KernelSU-Next/stable/kernel/setup.sh" ;;
        *)            log_warning "Invalid KERNELSU_TYPE: '$KERNELSU_TYPE', skipping."; return 1 ;;
    esac

    log_info "Installing $KERNELSU_TYPE..."
    if ! timeout 300 bash -c "curl -LSs '$url' | bash -s '${KERNELSU_BRANCH:-}'"; then
        log_warning "$KERNELSU_TYPE installation failed, continuing without it."
        return 1
    fi
    log_success "KernelSU installed."
}

patch_kpm() {
    if [[ "${KPM_PATCH:-false}" != "true" || "${KERNELSU:-false}" != "true" ]]; then
        log_info "KPM patch is disabled."
        return 0
    fi

    log_step "Applying KPM patch (v$KPM_VERSION)..."
    cd "$KERNEL_OUTDIR/arch/arm64/boot"
    local download_url="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/$KPM_VERSION/patch_linux"
    if ! curl -L --fail -o patch_linux "$download_url"; then
        log_error "Failed to download KPM patcher."
        return 1
    fi
    chmod +x patch_linux
    if ! ./patch_linux "$TYPE_IMAGE"; then
        log_error "KPM patching failed."
        return 1
    fi
    if [[ -f "oImage" ]]; then
        mv oImage "$TYPE_IMAGE"
        log_success "KPM patch applied."
    else
        log_error "Patched image not found."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 🏗️ Kernel compilation
# ------------------------------------------------------------------------------
configure_defconfig() {
    cd "$KERNEL_ROOTDIR"
    log_step "Configuring defconfig..."

    make "$BUILD_OPTIONS" ARCH="$ARCH" "$DEVICE_DEFCONFIG" O="$KERNEL_OUTDIR" LLVM=1 LLVM_IAS=1 || {
        log_error "Configuring defconfig failed."
        return 1
    }
}

compile_kernel() {
    cd "$KERNEL_ROOTDIR"
    log_step "Starting kernel compilation..."

    # Build targets
    local targets=("$TYPE_IMAGE")
    [[ "${BUILD_DTBO:-false}" == "true" ]] && targets+=("dtbo.img")

    if ! make "$BUILD_OPTIONS" ARCH="$ARCH" "$DEVICE_DEFCONFIG" O="$KERNEL_OUTDIR" LLVM=1 LLVM_IAS=1 "${targets[@]}" CROSS_COMPILE="$BUILD_CROSS_COMPILE" CROSS_COMPILE_ARM32="$BUILD_CROSS_COMPILE_ARM32" CLANG_TRIPLE="$BUILD_CLANG_TRIPLE"; then
        log_error "Kernel compilation failed."
        return 1
    fi

    # Verify output
    if [[ ! -f "$IMAGE" ]]; then
        log_error "Kernel image not found at $IMAGE."
        return 1
    fi

    log_success "Kernel compilation successful."
}

# ------------------------------------------------------------------------------
# 📦 AnyKernel preparation
# ------------------------------------------------------------------------------
prepare_anykernel() {
    log_step "Preparing AnyKernel..."
    rm -rf "$ANYKERNEL_DIR"
    git clone --depth=1 -b "$ANYKERNEL_BRANCH" "$ANYKERNEL" "$ANYKERNEL_DIR" || {
        log_error "Failed to clone AnyKernel repo."
        return 1
    }
    cd "$ANYKERNEL_DIR"

    # Copy kernel images
    if [[ "${BUILD_DTBO:-false}" == "true" ]]; then
        cp -f "$IMAGE" "$DTBO" . || { log_error "Failed to copy kernel/DTBO"; return 1; }
    else
        cp -f "$IMAGE" . || { log_error "Failed to copy kernel image"; return 1; }
    fi

    if [[ "${INCLUDE_DTB:-false}" == "true" ]]; then
        cp -f "$DTB" dtb || { log_error "Failed to copy DTB"; return 1; }
    fi

    log_success "AnyKernel prepared."
}

# ------------------------------------------------------------------------------
# 📊 Build info and zip creation
# ------------------------------------------------------------------------------
collect_build_info() {
    cd "$KERNEL_ROOTDIR"
    export KERNEL_VERSION=$(grep 'Linux/arm64' "$KERNEL_OUTDIR/.config" 2>/dev/null | cut -d' ' -f3 || echo "N/A")
    export UTS_VERSION=$(grep 'UTS_VERSION' "$KERNEL_OUTDIR/include/generated/compile.h" 2>/dev/null | cut -d'"' -f2 || echo "N/A")
    export LATEST_COMMIT=$(git log --pretty=format:'%s' -1 2>/dev/null | head -c 100 || echo "N/A")
    export COMMIT_BY=$(git log --pretty=format:'by %an' -1 2>/dev/null | head -c 50 || echo "N/A")
    export BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A")
    export COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "N/A")
    export KERNEL_SOURCE=$(echo "$KERNEL_SOURCE" | sed -E 's|https://github.com/([^/]+/[^/.]+).*|\1|i')
}

generate_caption() {
    local zip_name="$1"
    local zip_size="$2"
    local zip_sha256="$3"
    local zip_md5="$4"
    local zip_sha1="$5"

    local end_time=$(date +%s)
    local build_time=$((end_time - START_TIME))
    local minutes=$((build_time / 60))
    local seconds=$((build_time % 60))
    local build_time_str="${minutes}m ${seconds}s"
    local build_date=$(date +"%Y-%m-%d %H:%M:%S")

    local changelog=""
    if cd "$KERNEL_ROOTDIR" 2>/dev/null; then
        changelog=$(git log --pretty=format:"• %h - %s (%an)" -3 2>/dev/null | head -c 300)
        [[ -n "$changelog" ]] && changelog="📝 <b>Recent commits:</b> $changelog"
    fi

    local kernelsu_status="❌ Disabled"
    if [[ "${KERNELSU:-false}" == "true" && -n "${KERNELSU_TYPE:-}" ]]; then
        kernelsu_status="✅ ${KERNELSU_TYPE} (${KERNELSU_BRANCH:-hookless})"
    fi

    local kpm_status="❌ Disabled"
    if [[ "${KPM_PATCH:-false}" == "true" && "${KERNELSU:-false}" == "true" ]]; then
        kpm_status="✅ v${KPM_VERSION}"
    fi

    local commit_link=""
    if [[ -n "$KERNEL_SOURCE" && -n "$COMMIT_HASH" ]]; then
        commit_link="🔗 <a href=\"https://github.com/$KERNEL_SOURCE/commit/$COMMIT_HASH\">View Commit</a>"
    fi

    cat <<EOF
✨ <b>🚀 KERNEL BUILD SUCCESSFULLY!</b> ✨

📱 <b>Device:</b> <code>$DEVICE_CODENAME</code>
📦 <b>Kernel:</b> <code>$KERNEL_NAME</code>
🌿 <b>Branch:</b> <code>${BRANCH:-N/A}</code>
🔖 <b>Commit:</b> <code>${COMMIT_HASH:-N/A}</code> - ${LATEST_COMMIT:-N/A}
👤 <b>Author:</b> ${COMMIT_BY:-N/A}
⚙️ <b>Defconfig:</b> <code>$DEVICE_DEFCONFIG</code>
🛠️ <b>Compiler:</b> <code>${KBUILD_COMPILER_STRING:-N/A}</code>
📅 <b>Build Date:</b> $build_date
⏱️ <b>Build Time:</b> $build_time_str
🔧 <b>Kernel Version:</b> <code>${KERNEL_VERSION:-N/A}</code>

📊 <b>File Info:</b>
📏 Size: $zip_size
🔐 MD5: <code>${zip_md5:0:16}...</code>
🔑 SHA1: <code>${zip_sha1:0:16}...</code>
🔒 SHA256: <code>${zip_sha256:0:16}...</code>

🔧 <b>KernelSU:</b> $kernelsu_status
📦 <b>KPM Patch:</b> $kpm_status

$changelog

$commit_link | <a href="https://t.me/HyperOS_chime">Channel</a>

🎉 <b>Ready to flash!</b>
EOF
}

create_and_upload_zip() {
    cd "$ANYKERNEL_DIR"
    local zip_name="$KERNEL_NAME-$DEVICE_CODENAME-$DATE.zip"

    log_step "Creating ZIP archive: $zip_name"
    if ! zip -r9 "$zip_name" . -x "*.git*" "README.md" ".github/*"; then
        log_error "ZIP creation failed."
        return 1
    fi

    local zip_sha1=$(sha1sum "$zip_name" | cut -d' ' -f1)
    local zip_md5=$(md5sum "$zip_name" | cut -d' ' -f1)
    local zip_sha256=$(sha256sum "$zip_name" | cut -d' ' -f1)
    local zip_size=$(du -h "$zip_name" | cut -f1)

    local caption=$(generate_caption "$zip_name" "$zip_size" "$zip_sha256" "$zip_md5" "$zip_sha1")

    log_step "Uploading to Telegram..."
    if curl -F document=@"$zip_name" -F filename="$zip_name" "$BOT_DOC_URL" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="$caption" >/dev/null; then
        log_success "Build uploaded successfully."
        BUILD_STATUS="success"
    else
        log_error "Upload failed."
        return 1
    fi
}

send_config() {
    local config_file="$KERNEL_OUTDIR/.config"
    [[ ! -f "$config_file" ]] && { log_warning "No config file to send."; return 0; }

    local config_size=$(du -h "$config_file" | cut -f1)
    local config_name="config-${DEVICE_CODENAME}-${DATE}.txt"
    local caption="⚙️ <b>Kernel Config for $DEVICE_CODENAME</b>
📅 Date: $(date +'%Y-%m-%d %H:%M:%S')
📏 Size: $config_size
🔧 Compiler: $KBUILD_COMPILER_STRING
🌿 Branch: ${BRANCH:-N/A}
📝 Commit: ${LATEST_COMMIT:-N/A}"

    curl -F document=@"$config_file" -F filename="$config_name" "$BOT_DOC_URL" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="$caption" >/dev/null && log_success "Config sent." || log_warning "Failed to send config."
}

# ------------------------------------------------------------------------------
# 🚀 Main orchestration
# ------------------------------------------------------------------------------
main() {
    echo -e "${BOLD_CYAN}"
    echo "╔═══════════════════════════════════════╗"
    echo "║          🚀 KERNEL BUILD PROCESS      ║"
    echo "╚═══════════════════════════════════════╝"
    echo -e "${NC}"

    START_TIME=$(date +%s)
    > "$BUILD_LOG"

    # Setup
    check_dependencies
    validate_environment
    setup_directories
    setup_toolchain
    setup_build_vars
    setup_telegram

    # Display info
    echo -e "${BOLD_BLUE}╔═══════════════════════════════════════╗${NC}"
    echo -e "${BOLD_BLUE}║          BUILD INFORMATION            ║${NC}"
    echo -e "${BOLD_BLUE}╠═══════════════════════════════════════╣${NC}"
    echo -e "${BOLD_BLUE}║${NC} 👤 Builder:      ${GREEN}$KBUILD_BUILD_USER${NC}"
    echo -e "${BOLD_BLUE}║${NC} 🏠 Host:         ${GREEN}$KBUILD_BUILD_HOST${NC}"
    echo -e "${BOLD_BLUE}║${NC} 📱 Device:       ${YELLOW}$DEVICE_CODENAME${NC}"
    echo -e "${BOLD_BLUE}║${NC} ⚙️  Defconfig:    ${YELLOW}$DEVICE_DEFCONFIG${NC}"
    echo -e "${BOLD_BLUE}║${NC} 🛠️  Toolchain:   ${CYAN}$KBUILD_COMPILER_STRING${NC}"
    echo -e "${BOLD_BLUE}║${NC} 💾 Build opts:   ${MAGENTA}$BUILD_OPTIONS${NC}"
    echo -e "${BOLD_BLUE}║${NC} ⚡ Cores:        ${GREEN}$NUM_CORES${NC}"
    echo -e "${BOLD_BLUE}╚═══════════════════════════════════════╝${NC}"

    # Build steps
    tg_post_msg "🚀 <b>Kernel Build Started!</b>%0A%0A📱 Device: <code>$DEVICE_CODENAME</code>%0A⚙️ Defconfig: <code>$DEVICE_DEFCONFIG</code>%0A🔧 Toolchain: <code>$KBUILD_COMPILER_STRING</code>"

    configure_defconfig || exit 1
    install_kernelsu
    compile_kernel || exit 1
    patch_kpm
    prepare_anykernel || exit 1
    collect_build_info
    create_and_upload_zip || exit 1
    send_config

    log_success "All tasks completed successfully."
    return 0
}

# ------------------------------------------------------------------------------
# 🎯 Trap signals and run
# ------------------------------------------------------------------------------
trap cleanup EXIT INT TERM
main "$@"
