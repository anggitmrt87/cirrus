#!/usr/bin/env bash

export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
export BOT_MSG_URL2="https://api.telegram.org/bot$TG_TOKEN"

tg_post_msg() {
	curl -s -X POST "$BOT_MSG_URL" -d chat_id="$TG_CHAT_ID" \
	-d "disable_web_page_preview=true" \
	-d "parse_mode=html" \
	-d text="$1"

}

cd $CIRRUS_WORKING_DIR

curl -s -X POST "$BOT_MSG_URL2/sendSticker" \
-d sticker="CAACAgQAAx0EabRMmQACAm9jET5WwKp2FMYITmo6O8CJxt3H2wACFQwAAtUjEFPkKwhxHG8_Kx4E" \
-d chat_id="$TG_CHAT_ID"
