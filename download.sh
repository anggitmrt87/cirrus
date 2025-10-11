#!/usr/bin/env bash

echo "Downloading Kernel Sources.."
git clone --depth 1 --recurse-submodules $KERNEL_SOURCE -b $KERNEL_BRANCH $CIRRUS_WORKING_DIR/$DEVICE_CODENAME
echo ""
echo "Downloading Toolchain.."
aria2c https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/603a89415bbb04dff8bc577b95534479ec13fdc5/clang-r574158.tar.gz
mkdir -p $CIRRUS_WORKING_DIR/clang
tar -xf *.tar.* -C $CIRRUS_WORKING_DIR/clang
rm *.tar.*
