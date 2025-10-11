#!/usr/bin/env bash

set -e  # Exit on any error

echo "=========================================="
echo "    Kernel Source & Toolchain Download"
echo "=========================================="
echo ""

# Function for error handling
handle_error() {
    echo -e "\033[0;31m[ERROR] $1\033[0m"
    exit 1
}

# Function for downloading with retry
download_with_retry() {
    local url="$1"
    local dest="$2"
    local retries=3
    local attempt=1
    
    while [[ $attempt -le $retries ]]; do
        echo "Download attempt $attempt: $url"
        if aria2c --check-certificate=false "$url" -o "$dest"; then
            echo "Download successful!"
            return 0
        fi
        echo "Download attempt $attempt failed"
        ((attempt++))
        sleep 2
    done
    
    handle_error "Failed to download after $retries attempts: $url"
}

echo "📥 Downloading Kernel Sources..."
if git clone --depth=1 --recurse-submodules --shallow-submodules \
    "$KERNEL_SOURCE" -b "$KERNEL_BRANCH" \
    "$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"; then
    echo "✅ Kernel sources downloaded successfully"
else
    handle_error "Failed to clone kernel repository"
fi

echo ""

echo "🔧 Setting up Toolchain..."
mkdir -p "$CIRRUS_WORKING_DIR/clang"

# Toolchain selection with validation
case "$USE_CLANG" in
    "aosp")
        echo "📦 Using AOSP Clang toolchain..."
        download_with_retry \
            "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/603a89415bbb04dff8bc577b95534479ec13fdc5/clang-r574158.tar.gz" \
            "aosp-clang.tar.gz"
        
        echo "📁 Extracting AOSP toolchain..."
        if tar -xf "aosp-clang.tar.gz" -C "$CIRRUS_WORKING_DIR/clang"; then
            rm -f "aosp-clang.tar.gz"
            echo "✅ AOSP toolchain extracted successfully"
        else
            handle_error "Failed to extract AOSP toolchain"
        fi
        ;;
    
    "greenforce")
        echo "🌿 Using Greenforce Clang toolchain..."
        download_with_retry \
            "https://github.com/greenforce-project/greenforce_clang/releases/download/05102025/greenforce-clang-22.0.0git-05102025.tar.gz" \
            "greenforce-clang.tar.gz"
        
        echo "📁 Extracting Greenforce toolchain..."
        if tar -xf "greenforce-clang.tar.gz" -C "$CIRRUS_WORKING_DIR/clang" --strip-components=1; then
            rm -f "greenforce-clang.tar.gz"
            echo "✅ Greenforce toolchain extracted successfully"
        else
            handle_error "Failed to extract Greenforce toolchain"
        fi
        ;;
    
    *)
        handle_error "Invalid USE_CLANG value: '$USE_CLANG'. Must be 'aosp' or 'greenforce'"
        ;;
esac

# Verify toolchain installation
echo ""
echo "🔍 Verifying toolchain installation..."
if [[ -f "$CIRRUS_WORKING_DIR/clang/bin/clang" ]]; then
    CLANG_VERSION=$("$CIRRUS_WORKING_DIR/clang/bin/clang" --version | head -n1)
    echo "✅ Toolchain verified: $CLANG_VERSION"
else
    handle_error "Toolchain verification failed: clang binary not found"
fi

echo ""
echo "=========================================="
echo "✅ All downloads completed successfully!"
echo "   Device: $DEVICE_CODENAME"
echo "   Toolchain: $USE_CLANG"
echo "   Kernel Branch: $KERNEL_BRANCH"
echo "=========================================="
