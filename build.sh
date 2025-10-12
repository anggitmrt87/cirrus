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
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

# Global variables
declare -g KERNEL_NAME="mrt-Kernel"
declare -g START_TIME
declare -g BUILD_STATUS="failed"

## Main Function Declarations
#---------------------------------------------------------------------------------

validate_environment() {
    log_info "Validating environment variables..."
    
    local required_vars=(
        "CIRRUS_WORKING_DIR" "DEVICE_CODENAME" "TG_TOKEN" 
        "TG_CHAT_ID" "BUILD_USER" "BUILD_HOST" "ANYKERNEL"
        "KERNEL_SOURCE" "KERNEL_BRANCH"
    )
    
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

    # Validate encrypted variables
    if [[ "$TG_TOKEN" == ENCRYPTED* ]] || [[ "$TG_CHAT_ID" == ENCRYPTED* ]]; then
        log_warning "Telegram credentials appear to be encrypted. Please ensure they are properly decrypted."
    fi
}

setup_env() {
    log_info "Setting up build environment..."
    
    # Core directories
    export KERNEL_ROOTDIR="$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"
    export CLANG_ROOTDIR="$CIRRUS_WORKING_DIR/clang"
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
    export IMAGE="$KERNEL_OUTDIR/arch/arm64/boot/Image.gz-dtb"
    export DATE=$(date +"%Y%m%d-%H%M%S")
    export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
    export BOT_DOC_URL="https://api.telegram.org/bot$TG_TOKEN/sendDocument"
    export START_TIME=$(date +%s)
    
    # Build optimization
    export NUM_CORES=$(nproc)
    export BUILD_OPTIONS="${BUILD_OPTIONS:--j$NUM_CORES}"
    
    # CCache configuration
    if [[ "$CCACHE" == "true" ]]; then
        export CCACHE_DIR
        export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
        log_info "CCache enabled: $CCACHE_DIR (max: $CCACHE_MAXSIZE)"
    fi
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
    curl -s -X POST "$BOT_MSG_URL/sendSticker" \
        -d sticker="$sticker_id" \
        -d chat_id="$TG_CHAT_ID" > /dev/null
}

cleanup() {
    local exit_code=$?
    local end_time=$(date +%s)
    local build_time=$((end_time - START_TIME))
    
    if [[ $exit_code -eq 0 && "$BUILD_STATUS" == "success" ]]; then
        log_success "Build completed successfully in ${build_time}s"
        tg_send_sticker "CAACAgQAAx0EabRMmQACAm9jET5WwKp2FMYITmo6O8CJxt3H2wACFQwAAtUjEFPkKwhxHG8_Kx4E"
    else
        log_error "Build failed with exit code $exit_code"
        send_failure_log
        tg_send_sticker "CAACAgQAAx0EabRMmQACAnRjEUAXBTK1Ei_zbJNPFH7WCLzSdAACpBEAAqbxcR716gIrH45xdB4E"
    fi
    
    # Cleanup temporary files
    rm -rf "$CIRRUS_WORKING_DIR"/*.tar.* 2>/dev/null || true
    
    exit $exit_code
}

send_failure_log() {
    local log_file="$CIRRUS_WORKING_DIR/build_error.log"
    
    log_error "Build failed. Collecting error information..."
    
    # Capture recent errors
    dmesg | tail -50 > "$log_file" 2>/dev/null || echo "Unable to capture system logs" > "$log_file"
    echo -e "\n=== Build Environment ===" >> "$log_file"
    env | grep -E "(CIRRUS|KERNEL|TG_|BUILD_)" >> "$log_file"
    
    if [[ -f "$log_file" ]]; then
        log_info "Sending failure log to Telegram..."
        curl -F document=@"$log_file" "$BOT_DOC_URL" \
            -F chat_id="$TG_CHAT_ID" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="❌ <b>Kernel Build Failed</b>%0ADevice: <code>$DEVICE_CODENAME</code>%0ATime: $(date +'%Y-%m-%d %H:%M:%S')" || log_warning "Failed to send error log"
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
    log_info "AVAILABLE CORES      = ${NUM_CORES}"
    echo "================================================"
}

install_kernelsu() {
    if [ "$KERNELSU" = "true" ]; then
        if [ "$KERNELSU_TYPE" = "sukisu" ]; then
            log_info "Installing SUKISU ULTRA..."
            curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/refs/heads/main/kernel/setup.sh" | bash -s $KERNELSU_BRANCH || {
                log_warning "KernelSU installation failed, continuing build..."
            }
        elif [ "$KERNELSU_TYPE" = "rksu" ]; then
            log_info "Installing RKSU.."
            curl -LSs "https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh" | bash -s $KERNELSU_BRANCH || {
                log_warning "KernelSU installation failed, continuing build..."
            }
        elif [ "$KERNELSU_TYPE" = "kernelsunext" ]; then
            log_info "Installing KERNELSU NEXT..."
            curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/refs/heads/next/kernel/setup.sh" | bash -s $KERNELSU_BRANCH || {
                log_warning "KernelSU installation failed, continuing build..."
            }
        else
            log_warning "KernelSU installation failed, continuing build without KernelSU..."
            return 1
        fi
    fi
}

compile_kernel() {
    cd "$KERNEL_ROOTDIR"
    
    local bin_dir="$CLANG_ROOTDIR/bin"
    
    tg_post_msg "🚀 <b>Kernel Build Started</b>%0A📱 <b>Device:</b> <code>$DEVICE_CODENAME</code>%0A⚙️ <b>Defconfig:</b> <code>$DEVICE_DEFCONFIG</code>%0A🔧 <b>Toolchain:</b> <code>$KBUILD_COMPILER_STRING</code>"
    
    log_info "Step 1/4: Configuring defconfig..."
    make O="$KERNEL_OUTDIR" ARCH=arm64 "$DEVICE_DEFCONFIG" || {
        log_error "Defconfig configuration failed"
        return 1
    }
    
    log_info "Step 2/4: Installing KernelSU..."
    install_kernelsu
    
    log_info "Step 3/4: Starting kernel compilation..."
    
    # Optimized build flags
    export LLVM=1
    export LLVM_IAS=1
    
    # Use CCache if enabled
    if [[ "$CCACHE" == "true" ]]; then
        export CC="ccache clang"
        log_info "CCache statistics before build:"
        ccache -s
    else
        export CC="clang"
    fi
    
    local build_cmd=(
        make $BUILD_OPTIONS
        ARCH=arm64
        O="$KERNEL_OUTDIR"
        CC="$CC"
        AR="llvm-ar"
        AS="llvm-as"
        LD="ld.lld"
        NM="llvm-nm"
        OBJCOPY="llvm-objcopy"
        OBJDUMP="llvm-objdump"
        OBJSIZE="llvm-size"
        READELF="llvm-readelf"
        STRIP="llvm-strip"
        HOSTCC="clang"
        HOSTCXX="clang++"
        HOSTLD="ld.lld"
        CROSS_COMPILE="aarch64-linux-gnu-"
        CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
        CLANG_TRIPLE="aarch64-linux-gnu-"
        Image.gz-dtb
        dtbo.img
    )
    
    log_debug "Build command: ${build_cmd[*]}"
    
    # Execute build
    if "${build_cmd[@]}"; then
        log_success "Kernel compilation completed"
    else
        log_error "Kernel compilation failed"
        return 1
    fi
    
    # Verify output Image.gz
    if [[ ! -f "$IMAGE" ]]; then
        log_error "Image.gz not found at expected location: $IMAGE"
        return 1
    fi
    
    log_info "Step 4/4: Build verification completed"
    
    # Show CCache statistics if enabled
    if [[ "$CCACHE" == "true" ]]; then
        log_info "CCache statistics after build:"
        ccache -s
    fi
}

prepare_anykernel() {
    log_info "Preparing AnyKernel..."
    
    [[ -d "$ANYKERNEL_DIR" ]] && rm -rf "$ANYKERNEL_DIR"
    
    if git clone --depth=1 --single-branch "$ANYKERNEL" "$ANYKERNEL_DIR"; then
        # Copy kernel image
        if cp -f "$IMAGE" "$ANYKERNEL_DIR"; then
            log_success "AnyKernel preparation completed"
        else
            log_error "Failed to copy kernel image to AnyKernel"
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
    if [[ -f "$KERNEL_OUTDIR/.config" ]]; then
        export KERNEL_VERSION=$(grep 'Linux/arm64' "$KERNEL_OUTDIR/.config" | cut -d' ' -f3 || echo "N/A")
    fi
    
    if [[ -f "$KERNEL_OUTDIR/include/generated/compile.h" ]]; then
        export UTS_VERSION=$(grep 'UTS_VERSION' "$KERNEL_OUTDIR/include/generated/compile.h" | cut -d'"' -f2 || echo "N/A")
    fi
    
    # Git information
    export LATEST_COMMIT=$(git log --pretty=format:'%s' -1 2>/dev/null | head -c 100 || echo "N/A")
    export COMMIT_BY=$(git log --pretty=format:'by %an' -1 2>/dev/null || echo "N/A")
    export BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A")
    export KERNEL_SOURCE="${CIRRUS_REPO_OWNER:-unknown}/${CIRRUS_REPO_NAME:-unknown}"
    export KERNEL_BRANCH="$BRANCH"
    export COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "N/A")
}

create_and_push_zip() {
    cd "$ANYKERNEL_DIR"
    
    local zip_name="$KERNEL_NAME-$DEVICE_CODENAME-$DATE.zip"
    
    log_info "Creating flashable ZIP: $zip_name"
    
    if zip -r9 "$zip_name" . -x "*.git*" "README.md" ".github/*"; then
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

📦 <b>Kernel:</b> $KERNEL_NAME
📱 <b>Device:</b> $DEVICE_CODENAME
👤 <b>Builder:</b> $BUILD_USER@$BUILD_HOST

🔧 <b>Build Info:</b>
├ Linux: ${KERNEL_VERSION:-N/A}
├ Branch: ${BRANCH:-N/A}
├ Commit: ${LATEST_COMMIT:-N/A}
├ Author: ${COMMIT_BY:-N/A}
├ Uts: ${UTS_VERSION:-N/A}
└ Compiler: <code>${KBUILD_COMPILER_STRING:-N/A}</code>

📊 <b>File Info:</b>
├ Size: $zip_size
├ SHA256: <code>${zip_sha256:0:16}...</code>
├ MD5: <code>$zip_md5</code>
└ SHA1: <code>${zip_sha1:0:16}...</code>

⏱️ <b>Build Time:</b> ${minutes}m ${seconds}s
📝 <b>Changes:</b> <a href=\"https://github.com/$KERNEL_SOURCE/commits/$KERNEL_BRANCH\">View on GitHub</a>"

    if curl -F document=@"$zip_name" "$BOT_DOC_URL" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="$caption" > /dev/null; then
        log_success "Build uploaded successfully!"
        log_info "File: $zip_name"
        log_info "Size: $zip_size"
        log_info "Build time: ${minutes}m ${seconds}s"
        
        # Set build status for cleanup
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
    
    # Setup and validation
    validate_environment
    setup_env
    display_banner
    
    # Build process
    compile_kernel || return 1
    prepare_anykernel || return 1
    get_build_info
    create_and_push_zip || return 1
    
    log_success "All tasks completed successfully!"
    return 0
}

# Trap signals
trap cleanup EXIT INT TERM

# Run main function
if main "$@"; then
    exit 0
else
    exit 1
fi
