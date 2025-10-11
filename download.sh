#!/usr/bin/env bash

echo "Downloading Kernel Sources.."
git clone --depth 1 --recurse-submodules $KERNEL_SOURCE -b $KERNEL_BRANCH $CIRRUS_WORKING_DIR/$DEVICE_CODENAME
echo ""

echo "Downloading Toolchain.."
mkdir -p $CIRRUS_WORKING_DIR/clang

# Pilihan toolchain berdasarkan environment variable
if [ "$USE_CLANG" = "aosp" ]; then
    echo "Using AOSP Clang toolchain..."
    aria2c https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/603a89415bbb04dff8bc577b95534479ec13fdc5/clang-r574158.tar.gz
    tar -xf *.tar.* -C $CIRRUS_WORKING_DIR/clang
    rm *.tar.*
    
elif [ "$USE_CLANG" = "greenforce" ]; then
    echo "Using Greenforce Clang toolchain..."
    aria2c https://github.com/greenforce-project/greenforce_clang/releases/download/05102025/greenforce-clang-22.0.0git-05102025.tar.gz
    tar -xf *.tar.* -C $CIRRUS_WORKING_DIR/clang
    rm *.tar.*
    
else
    echo "Error: USE_CLANG environment variable not set or invalid!"
    echo "Please set USE_CLANG to either 'aosp' or 'greenforce'"
    exit 1
fi

echo "Toolchain setup completed successfully!"
echo "Selected toolchain: $USE_CLANG"
