#!/bin/bash

STATUS_FILE="/tmp/vps_status.txt"
FIRST_FAIL_FILE="/var/log/.vps_first_fail.timestamp"
SERIAL=$(sudo /usr/sbin/dmidecode -s system-serial-number 2>/dev/null)

VPS_URL="http://13.214.142.47:8888"
TOOL_DIR_1="/opt"

# ------------------ STEP 1: GỌI VPS & XỬ LÝ KHI MẤT MẠNG ------------------
# Nếu curl thất bại (rớt mạng, VPS timeout) -> GIỮ NGUYÊN HIỆN TRẠNG & THOÁT NGAY
if ! RESPONSE_STATUS=$(curl -fsS \
    --connect-timeout 5 \
    --max-time 10 \
    -G \
    --data-urlencode "serial=$SERIAL" \
    "${VPS_URL}/"); then
    echo "VPS unreachable; keeping current tool state" >&2
    exit 1
fi

# Kết nối thành công -> Mới ghi đè status mới nhất
echo "$RESPONSE_STATUS" > "$STATUS_FILE"
chmod 666 "$STATUS_FILE" 2>/dev/null

# ------------------ STEP 2: LỆNH TỰ HỦY CHỦ ĐỘNG TỪ VPS ------------------
# Đã kết nối được VPS, hỏi trực tiếp xem có cờ Wipe chủ động không
WIPE_RESP=$(curl -fsS --connect-timeout 5 --max-time 10 -G --data-urlencode "serial=$SERIAL" "${VPS_URL}/report_12h" 2>/dev/null)

if [ "$WIPE_RESP" == "ACTION:WIPE_ALL_TOOLS" ]; then
    chattr -R -i "$TOOL_DIR_1"/* 2>/dev/null
    chown -R root:root "$TOOL_DIR_1" 2>/dev/null
    chmod -R 777 "$TOOL_DIR_1" 2>/dev/null

    rm -rf "$TOOL_DIR_1"/{*,.[!.]*,..?*} 2>/dev/null
    find "$TOOL_DIR_1" -mindepth 1 -delete 2>/dev/null
    
    rm -f "$FIRST_FAIL_FILE"
    exit 0
fi

# ------------------ STEP 3: PHÂN LUỒNG TẠI MÁY (APPROVED / UNAPPROVED) ------------------
if grep -q "You are not approved" "$STATUS_FILE" 2>/dev/null; then

    # ⏳ LUỒNG ĐẾM GIỜ 12H (TỰ ĐỘNG TỰ HỦY)
    SERVER_TIME=$(grep "SERVER_TIME:" "$STATUS_FILE" | awk -F 'SERVER_TIME:' '{print $2}' | tr -d '\r\n')

    if [[ "$SERVER_TIME" =~ ^[0-9]+$ ]]; then
        if [ ! -f "$FIRST_FAIL_FILE" ]; then
            echo "$SERVER_TIME" > "$FIRST_FAIL_FILE"
            chmod 644 "$FIRST_FAIL_FILE"
        fi

        START_TIME=$(cat "$FIRST_FAIL_FILE" | tr -d '\r\n')
        
        if [[ "$START_TIME" =~ ^[0-9]+$ ]]; then
            ELAPSED=$((SERVER_TIME - START_TIME))

            # Bị Unapproved liên tục quá 12 tiếng -> Tự động Wipe
            if [ "$ELAPSED" -ge 43200 ]; then
                chattr -R -i "$TOOL_DIR_1"/* 2>/dev/null
                chown -R root:root "$TOOL_DIR_1" 2>/dev/null
                chmod -R 777 "$TOOL_DIR_1" 2>/dev/null

                rm -rf "$TOOL_DIR_1"/{*,.[!.]*,..?*} 2>/dev/null
                find "$TOOL_DIR_1" -mindepth 1 -delete 2>/dev/null
                
                rm -f "$FIRST_FAIL_FILE"
                exit 0
            fi
        fi
    fi

    # 🔒 KHÓA QUYỀN /OPT KHI BỊ UNAPPROVED
    [ -d "$TOOL_DIR_1" ] && chmod -R 000 "$TOOL_DIR_1" 2>/dev/null

else
    # 🔓 MỞ KHÓA: Trả lại quyền 711 cho /opt (Bảo mật, chặn ls soi thư mục)
    [ -d "$TOOL_DIR_1" ] && chmod 711 "$TOOL_DIR_1" 2>/dev/null && chmod -R 755 "$TOOL_DIR_1"/* 2>/dev/null

    # Reset lại timestamp đếm phạt nếu đã trở lại ngoan (AUTHORIZED)
    if [ -f "$FIRST_FAIL_FILE" ]; then
        rm -f "$FIRST_FAIL_FILE"
    fi
fi
