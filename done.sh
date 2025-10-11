#!/usr/bin/env bash

set -e  # Exit on error

# Color setup
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}[INFO]${NC} Starting post-build cleanup..."

export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
export BOT_MSG_URL2="https://api.telegram.org/bot$TG_TOKEN"

# Function to send Telegram message
tg_post_msg() {
    local message="$1"
    if curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        -d text="$message" > /dev/null; then
        echo -e "${GREEN}[SUCCESS]${NC} Telegram message sent"
    else
        echo -e "${BLUE}[WARNING]${NC} Failed to send Telegram message"
    fi
}

cd "$CIRRUS_WORKING_DIR" || exit 1

# Send success sticker
echo -e "${GREEN}[INFO]${NC} Sending success notification..."
if curl -s -X POST "$BOT_MSG_URL2/sendSticker" \
    -d sticker="CAACAgQAAx0EabRMmQACAm9jET5WwKp2FMYITmo6O8CJxt3H2wACFQwAAtUjEFPkKwhxHG8_Kx4E" \
    -d chat_id="$TG_CHAT_ID" > /dev/null; then
    echo -e "${GREEN}[SUCCESS]${NC} Success sticker sent"
fi

# Send completion message
COMPLETION_MSG="🎉 <b>Build Process Completed</b> 🎉

✅ All build tasks finished successfully
📱 Device: <code>$DEVICE_CODENAME</code>
🕒 Completed at: $(date +'%Y-%m-%d %H:%M:%S %Z')

Thank you for using the build system! 👷"

tg_post_msg "$COMPLETION_MSG"

# Cleanup temporary files
echo -e "${GREEN}[INFO]${NC} Cleaning up temporary files..."
rm -rf "$CIRRUS_WORKING_DIR"/*.tar.* 2>/dev/null || true
rm -rf "$CIRRUS_WORKING_DIR"/tmp 2>/dev/null || true

# Show disk usage
echo -e "${GREEN}[INFO]${NC} Final disk usage:"
df -h "$CIRRUS_WORKING_DIR" | tail -1

echo -e "${GREEN}[SUCCESS]${NC} Post-build cleanup completed!"
