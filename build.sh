#!/usr/bin/env bash
#
# Optimized Kernel Build Script
# Enhanced with better error handling, performance optimizations, and modular structure
#

set -eo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_debug() { [[ "$DEBUG_MODE" == "true" ]] && echo -e "${CYAN}[DEBUG]${NC} $1"; }

# Global variables
declare -g KERNEL_NAME="mrt-Kernel"
declare -g START_TIME
declare -g BUILD_STATUS="failed"
declare -g BUILD_LOG="$CIRRUS_WORKING_DIR/build.log"

## Main Function Declarations
#---------------------------------------------------------------------------------

validate_environment() {
    log_info "Validating environment variables..."
    
    local required_vars=(
        "CIRRUS_WORKING_DIR" "DEVICE_CODENAME" "TG_TOKEN" 
        "TG_CHAT_ID" "BUILD_USER" "BUILD_HOST" "ANYKERNEL" "ANYKERNEL_BRANCH"
        "KERNEL_SOURCE" "KERNEL_BRANCH" "CLANG_ROOTDIR"
    )
    
    if [[ "$KPM_PATCH" == "true" ]]; then
        required_vars+=("KPM_VERSION")
    fi
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        exit 1
    fi
    
    log_success "Environment validation passed"
}

setup_env() {
    log_info "Setting up build environment..."
    
    # Core directories
    export KERNEL_ROOTDIR="$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"
    export KERNEL_OUTDIR="$KERNEL_ROOTDIR/out"
    export ANYKERNEL_DIR="$CIRRUS_WORKING_DIR/AnyKernel"
    export CCACHE_DIR="${CCACHE_DIR:-/tmp/ccache}"

    # Create necessary directories
    mkdir -p "$KERNEL_OUTDIR" "$ANYKERNEL_DIR" "$CCACHE_DIR"

    # PATH setup
    export PATH="$CLANG_ROOTDIR/bin:$PATH:/usr/lib/ccache"
    export LD_LIBRARY_PATH="$CLANG_ROOTDIR/lib:$LD_LIBRARY_PATH"

    # Toolchain validation
    if [[ ! -d "$CLANG_ROOTDIR" || ! -f "$CLANG_ROOTDIR/bin/clang" ]]; then
        log_error "Toolchain (Clang) not found at $CLANG_ROOTDIR"
        exit 1
    fi

    # Toolchain versions
    local bin_dir="$CLANG_ROOTDIR/bin"
    export CLANG_VER="$("$bin_dir/clang" --version | head -n1 | sed -E 's/\(http[^)]+\)//g' | awk '{$1=$1};1')"
    export LLD_VER="$("$bin_dir/ld.lld" --version | head -n1)"
    
    # KBUILD variables
    export KBUILD_BUILD_USER="$BUILD_USER"
    export KBUILD_BUILD_HOST="$BUILD_HOST" 
    export KBUILD_COMPILER_STRING="$CLANG_VER with $LLD_VER"

    # Build variables
    export IMAGE="$KERNEL_OUTDIR/arch/arm64/boot/$TYPE_IMAGE"
    export DTBO="$KERNEL_OUTDIR/arch/arm64/boot/dtbo.img"
    export DATE=$(date +"%Y%m%d-%H%M%S")
    export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
    export BOT_DOC_URL="https://api.telegram.org/bot$TG_TOKEN/sendDocument"
    export START_TIME=$(date +%s)
    
    # Use NUM_CORES from system (nproc)
    export NUM_CORES=$(nproc)
    if [[ "$BUILD_OPTIONS" != "-j"* ]]; then
        export BUILD_OPTIONS="-j$NUM_CORES"
    fi
    
    # CCache configuration
    if [[ "$CCACHE" == "true" ]]; then
        export CCACHE_DIR
        export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
        log_info "CCache enabled: $CCACHE_DIR (max: $CCACHE_MAXSIZE)"
    fi
    
    log_success "Environment setup completed"
}

tg_post_msg() {
    local message="$1"
    local parse_mode="${2:-html}"
    
    if curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=$parse_mode" \
        -d text="$message" > /dev/null; then
        log_debug "Telegram message sent successfully"
    else
        log_warning "Failed to send Telegram message"
    fi
}

tg_send_sticker() {
    local sticker_id="$1"
    local BOT_STICKER_URL="https://api.telegram.org/bot$TG_TOKEN/sendSticker"
    curl -s -X POST "$BOT_STICKER_URL" \
        -d sticker="$sticker_id" \
        -d chat_id="$TG_CHAT_ID" > /dev/null || log_warning "Failed to send sticker"
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
        send_failure_log
        tg_send_sticker "CAACAgQAAx0EabRMmQACAnRjEUAXBTK1Ei_zbJNPFH7WCLzSdAACpBEAAqbxcR716gIrH45xdB4E"
    fi
    
    # Cleanup temporary files
    cleanup_temp_files
    
    exit $exit_code
}

cleanup_temp_files() {
    log_info "Cleaning temporary files..."
    rm -rf "$CIRRUS_WORKING_DIR"/*.tar.* 2>/dev/null || true
    rm -rf "$CIRRUS_WORKING_DIR"/tmp_downloads 2>/dev/null || true
    
    if [[ "$KEEP_BUILD_LOGS" != "true" ]]; then
        rm -f "$BUILD_LOG" 2>/dev/null || true
    fi
}

send_failure_log() {
    local log_file="$CIRRUS_WORKING_DIR/build_error.log"
    
    log_error "Build failed. Collecting error information..."
    rm -f "$log_file"

    # Capture last 100 lines of build log if exists
    if [[ -f "$BUILD_LOG" ]]; then
        tail -100 "$BUILD_LOG" > "$log_file" 2>/dev/null
    else
        dmesg | tail -50 > "$log_file" 2>/dev/null || echo "Unable to capture logs" > "$log_file"
    fi
    
    echo -e "\n=== Build Environment ===" >> "$log_file"
    env | grep -E "(CIRRUS|KERNEL|TG_|BUILD_|CLANG_)" >> "$log_file"
    echo -e "\n=== System Info ===" >> "$log_file"
    uname -a >> "$log_file"
    
    if [[ -f "$log_file" ]]; then
        log_info "Sending failure log to Telegram..."
        local doc_name="build_error_${DEVICE_CODENAME}_$(date +%s).log"

        if curl -F document=@"$log_file" -F filename="$doc_name" "$BOT_DOC_URL" \
            -F chat_id="$TG_CHAT_ID" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="❌ <b>Kernel Build Failed</b>%0ADevice: <code>$DEVICE_CODENAME</code>%0ATime: $(date +'%Y-%m-%d %H:%M:%S')%0AExit Code: $exit_code" > /dev/null; then
            log_success "Failure log sent"
        else
            log_warning "Failed to send error log"
        fi
    fi
}

display_banner() {
    echo -e "${CYAN}"
    cat << "BANNER"
================================================
              _  __  ____  ____               
             / |/ / / __/ / __/               
      __    /    / / _/  _\ \    __           
     /_/   /_/|_/ /_/   /___/   /_/           
    ___  ___  ____     _________________      
   / _ \/ _ \/ __ \__ / / __/ ___/_  __/      
  / ___/ , _/ /_/ / // / _// /__  / /         
 /_/  /_/|_|\____/\___/___/\___/ /_/          
================================================
BANNER
    echo -e "${NC}"
    
    log_info "BUILDER NAME         = ${KBUILD_BUILD_USER}"
    log_info "BUILDER HOSTNAME     = ${KBUILD_BUILD_HOST}"
    log_info "DEVICE_CODENAME      = ${DEVICE_CODENAME}"
    log_info "DEVICE_DEFCONFIG     = ${DEVICE_DEFCONFIG}"
    log_info "TOOLCHAIN_VERSION    = ${KBUILD_COMPILER_STRING}"
    log_info "CLANG_ROOTDIR        = ${CLANG_ROOTDIR}"
    log_info "KERNEL_ROOTDIR       = ${KERNEL_ROOTDIR}"
    log_info "KERNEL_OUTDIR        = ${KERNEL_OUTDIR}"
    log_info "BUILD OPTIONS        = ${BUILD_OPTIONS}"
    log_info "AVAILABLE CORES      = ${NUM_CORES}"
    echo "================================================"
}

install_kernelsu() {
    if [[ "$KERNELSU" != "true" ]]; then
        log_info "KernelSU is disabled, skipping installation"
        return 0
    fi

    local url=""
    case "$KERNELSU_TYPE" in
        "sukisu")
            log_info "Installing SUKISU ULTRA..."
            url="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/refs/heads/main/kernel/setup.sh"
            ;;
        "rksu")
            log_info "Installing RKSU..."
            url="https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh"
            ;;
        "kernelsunext")
            log_info "Installing KERNELSU NEXT..."
            url="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/refs/heads/next/kernel/setup.sh"
            ;;
        "backslashxx")
            log_info "Installing KERNELSU BACKSLASHXX..."
            url="https://raw.githubusercontent.com/backslashxx/KernelSU/refs/heads/master/kernel/setup.sh"
            ;;
        *)
            log_warning "Invalid KERNELSU_TYPE: '$KERNELSU_TYPE'. Continuing build without KernelSU."
            return 1
            ;;
    esac

    if [[ -n "$url" ]]; then
        log_info "Executing $KERNELSU_TYPE setup script from $url"
        # Use timeout to prevent hanging
        if timeout 300 bash -c "curl -LSs '$url' | bash -s '$KERNELSU_BRANCH'"; then
            log_success "KernelSU installation completed"
        else
            log_warning "$KERNELSU_TYPE installation failed, continuing build without KernelSU"
            return 1
        fi
    fi
}

compile_kernel() {
    cd "$KERNEL_ROOTDIR"
    
    # Clean working directory
    log_info "Cleaning working directory..."
    git clean -fdx 
    
    tg_post_msg "🚀 <b>Kernel Build Started</b>%0A📱 <b>Device:</b> <code>$DEVICE_CODENAME</code>%0A⚙️ <b>Defconfig:</b> <code>$DEVICE_DEFCONFIG</code>%0A🔧 <b>Toolchain:</b> <code>$KBUILD_COMPILER_STRING</code>"
    
    log_info "Step 1/4: Installing KernelSU..."
    install_kernelsu
    
    log_info "Step 2/4: Configuring defconfig..."
    rm -f "$KERNEL_OUTDIR/.config" "$KERNEL_OUTDIR/.config.old"
    
    # Menggunakan tee untuk logging defconfig
    if ! make $BUILD_OPTIONS ARCH=arm64 $DEVICE_DEFCONFIG O=$KERNEL_OUTDIR 2>&1 | tee -a "$BUILD_LOG"; then
        log_error "Defconfig configuration failed"
        return 1
    fi
    
    log_info "Step 3/4: Starting kernel compilation..."
    
    # Build configuration
    export LLVM=1
    export LLVM_IAS=1
    
    # CCache configuration
    if [[ "$CCACHE" == "true" ]]; then
        export CC="ccache clang"
        log_info "CCache statistics before build:"
        ccache -s | tee -a "$BUILD_LOG"
    else
        export CC="clang"
    fi
    
    if [[ "$DISABLE_LOCALVERSIO_ST" == "true" ]]; then
        rm -rf localversion-st
    fi
    
    local build_targets=("$TYPE_IMAGE")
    [[ "$BUILD_DTBO" == "true" ]] && build_targets+=("dtbo.img")
    
    # Execute build dengan tee untuk logging real-time
    log_info "Build command: make $BUILD_OPTIONS ARCH=arm64 O=$KERNEL_OUTDIR ${build_targets[*]}"
    
    # Fungsi untuk build dengan tee
    build_with_tee() {
        local tee_pid
        local build_pid
        
        # Jalankan make dan pipe ke tee
        {
            make $BUILD_OPTIONS \
                ARCH=arm64 \
                O="$KERNEL_OUTDIR" \
                CC="$CC" \
                AR="llvm-ar" \
                NM="llvm-nm" \
                STRIP="llvm-strip" \
                OBJCOPY="llvm-objcopy" \
                OBJDUMP="llvm-objdump" \
                OBJSIZE="llvm-size" \
                READELF="llvm-readelf" \
                HOSTCC="clang" \
                HOSTCXX="clang++" \
                HOSTAR="llvm-ar" \
                HOSTLD="ld.lld" \
                CROSS_COMPILE="aarch64-linux-gnu-" \
                CROSS_COMPILE_ARM32="arm-linux-gnueabi-" \
                CLANG_TRIPLE="aarch64-linux-gnu-" \
                "${build_targets[@]}" 2>&1
        } | tee -a "$BUILD_LOG" &
        
        tee_pid=$!
        build_pid=$(jobs -p %+)
        
        # Tunggu proses build selesai
        wait $build_pid
        local build_exit=$?
        
        # Tunggu tee selesai
        wait $tee_pid
        
        return $build_exit
    }
    
    if build_with_tee; then
        log_success "Kernel compilation completed"
    else
        log_error "Kernel compilation failed - check $BUILD_LOG for details"
        return 1
    fi
    
    # Verify output
    if [[ ! -f "$IMAGE" ]]; then
        log_error "Kernel Image not found at expected location: $IMAGE"
        return 1
    fi
    
    log_info "Step 4/4: Build verification completed"
    
    # Show CCache statistics if enabled
    if [[ "$CCACHE" == "true" ]]; then
        log_info "CCache statistics after build:"
        ccache -s | tee -a "$BUILD_LOG"
    fi
}

patch_kpm() {
    if [[ "$KPM_PATCH" == "true" && "$KERNELSU" == "true" ]]; then
        log_info "KPM patch is enabled (Version: $KPM_VERSION)"
        cd "$KERNEL_OUTDIR/arch/arm64/boot"
        
        local download_url="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/$KPM_VERSION/patch_linux"
        log_info "Downloading KPM patcher from $download_url"

        if ! wget -q --timeout=30 "$download_url" 2>&1 | tee -a "$BUILD_LOG"; then
             log_error "Failed to download KPM patcher version $KPM_VERSION"
             return 1
        fi

        chmod +x patch_linux
        log_info "Applying KPM patch to $TYPE_IMAGE..."
        
        if ./patch_linux "$TYPE_IMAGE" 2>&1 | tee -a "$BUILD_LOG"; then
            if [[ -f "oImage" ]]; then
                rm -f "$TYPE_IMAGE"
                mv oImage "$TYPE_IMAGE"
                log_success "KPM patch applied successfully"
            else
                log_error "KPM patcher did not produce 'oImage'"
                return 1
            fi
        else
            log_error "KPM patch execution failed"
            return 1
        fi
    else
        log_info "KPM patch is disabled"
    fi
}

prepare_anykernel() {
    log_info "Preparing AnyKernel..."
    
    [[ -d "$ANYKERNEL_DIR" ]] && rm -rf "$ANYKERNEL_DIR"
    
    if git clone --depth=1 -b "$ANYKERNEL_BRANCH" "$ANYKERNEL" "$ANYKERNEL_DIR" 2>&1 | tee -a "$BUILD_LOG"; then
        cd "$ANYKERNEL_DIR"
        
        # Copy kernel image(s)
        local copy_success=true
        if [[ "$BUILD_DTBO" == "true" ]]; then
            cp -f "$IMAGE" "$DTBO" . 2>&1 | tee -a "$BUILD_LOG" || copy_success=false
        else
            cp -f "$IMAGE" . 2>&1 | tee -a "$BUILD_LOG" || copy_success=false
        fi
        
        if [[ "$copy_success" == "true" ]]; then
            log_success "AnyKernel preparation completed"
        else
            log_error "Failed to copy kernel files to AnyKernel"
            return 1
        fi
    else
        log_error "Failed to clone AnyKernel repository"
        return 1
    fi
}

get_build_info() {
    cd "$KERNEL_ROOTDIR"
    
    # Kernel version info
    local config_file="$KERNEL_OUTDIR/.config"
    if [[ -f "$config_file" ]]; then
        export KERNEL_VERSION=$(grep 'Linux/arm64' "$config_file" | cut -d' ' -f3 2>/dev/null || echo "N/A")
    fi
    
    local compile_h="$KERNEL_OUTDIR/include/generated/compile.h"
    if [[ -f "$compile_h" ]]; then
        export UTS_VERSION=$(grep 'UTS_VERSION' "$compile_h" | cut -d'"' -f2 2>/dev/null || echo "N/A")
    fi
    
    # Git information
    export LATEST_COMMIT=$(git log --pretty=format:'%s' -1 2>/dev/null | head -c 100 | tr -d '\n' || echo "N/A")
    export COMMIT_BY=$(git log --pretty=format:'by %an' -1 2>/dev/null | head -c 50 | tr -d '\n' || echo "N/A")
    export BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A")
    
    # Get the repo owner/name from the URL
    local repo_url="${KERNEL_SOURCE:-https://github.com/unknown/unknown}"
    local owner_repo=$(echo "$repo_url" | sed -E 's|https://github.com/([^/]+/[^/.]+).*|\1|i' 2>/dev/null || echo "unknown/unknown")
    export KERNEL_SOURCE="$owner_repo"
    
    export KERNEL_BRANCH="$BRANCH"
    export COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "N/A")
}

create_and_push_zip() {
    cd "$ANYKERNEL_DIR"
    
    local zip_name="$KERNEL_NAME-$DEVICE_CODENAME-$DATE.zip"
    
    log_info "Creating flashable ZIP: $zip_name"
    
    if zip -r9 "$zip_name" . -x "*.git*" "README.md" ".github/*" 2>&1 | tee -a "$BUILD_LOG"; then
        log_success "ZIP creation completed"
    else
        log_error "ZIP creation failed"
        return 1
    fi
    
    # Calculate checksums
    local zip_sha1=$(sha1sum "$zip_name" | cut -d' ' -f1)
    local zip_md5=$(md5sum "$zip_name" | cut -d' ' -f1)
    local zip_sha256=$(sha256sum "$zip_name" | cut -d' ' -f1)
    local zip_size=$(du -h "$zip_name" | cut -f1)
    
    # Calculate build time
    local end_time=$(date +%s)
    local build_time=$((end_time - START_TIME))
    local minutes=$((build_time / 60))
    local seconds=$((build_time % 60))
    
    log_info "Uploading build to Telegram..."
    
    local caption="
✅ <b>Build Finished Successfully!</b>

📦 <b>Kernel:</b> <code>$KERNEL_NAME</code>
📱 <b>Device:</b> <code>$DEVICE_CODENAME</code>
👤 <b>Builder:</b> <code>$BUILD_USER@$BUILD_HOST</code>

🔧 <b>Build Info:</b>
├ Linux version: <code>${KERNEL_VERSION:-N/A}</code>
├ Branch: <code>${BRANCH:-N/A}</code>
├ Commit: <code>${LATEST_COMMIT:-N/A}</code>
├ Author: <code>${COMMIT_BY:-N/A}</code>
├ Uts: <code>${UTS_VERSION:-N/A}</code>
└ Compiler: <code>${KBUILD_COMPILER_STRING:-N/A}</code>

📊 <b>File Info:</b>
├ Size: $zip_size
├ SHA256: <code>${zip_sha256:0:16}...</code>
├ MD5: <code>$zip_md5</code>
└ SHA1: <code>${zip_sha1:0:16}...</code>

⏱️ <b>Build Time:</b> ${minutes}m ${seconds}s
📝 <b>Changes:</b> <a href=\"https://github.com/$KERNEL_SOURCE/commits/$KERNEL_BRANCH\">View on GitHub</a>"
    
    local doc_name="$(basename "$zip_name")"

    if curl -F document=@"$zip_name" -F filename="$doc_name" "$BOT_DOC_URL" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="$caption" 2>&1 | tee -a "$BUILD_LOG"; then
        log_success "Build uploaded successfully!"
        log_info "File: $zip_name"
        log_info "Size: $zip_size"
        log_info "Build time: ${minutes}m ${seconds}s"
        
        BUILD_STATUS="success"
    else
        log_error "Failed to upload build to Telegram"
        return 1
    fi
}

## Main Execution Flow
#---------------------------------------------------------------------------------

main() {
    log_info "Starting optimized kernel build process..."
    START_TIME=$(date +%s)
    
    # Initialize build log
    > "$BUILD_LOG"
    
    # Setup and validation
    validate_environment
    setup_env
    display_banner
    
    # Build process
    compile_kernel || return 1
    patch_kpm || log_warning "KPM patch failed, continuing..."
    prepare_anykernel || return 1
    get_build_info
    create_and_push_zip || return 1
    
    log_success "All tasks completed successfully!"
    return 0
}

# Trap signals
trap cleanup EXIT INT TERM

# Run main function
main "$@"
