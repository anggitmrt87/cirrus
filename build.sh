#sync rom
repo init --depth=1 --no-repo-verify -u https://github.com/LineageOS/android.git -b lineage-23.0 -g default,-mips,-darwin,-notdefault
git clone https://github.com/MRT-project/local_manifest --depth 1 -b main .repo/local_manifests
repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune --force-sync -j8

# build rom
source $CIRRUS_WORKING_DIR/config
timeStart

source build/envsetup.sh
export TZ=Asia/Jakarta
export KBUILD_BUILD_USER=admin
export KBUILD_BUILD_HOST=mrtproject
export BUILD_USERNAME=admin
export BUILD_HOSTNAME=mrtproject
# lunch chime-userdebug
mkfifo reading # Jangan di Hapus
tee "${BUILDLOG}" < reading & # Jangan di Hapus
build_message "Building Started" # Jangan di Hapus
progress & # Jangan di Hapus
timeout 95m brunch chime-userdebug -j8 > reading # Jangan di hapus text line (> reading)

retVal=$?
timeEnd
statusBuild
# end