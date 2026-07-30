#!/bin/bash

STATUS_FILE="/tmp/vps_status.txt"
FIRST_FAIL_FILE="/var/log/.vps_first_fail.timestamp"
SERIAL=$(sudo /usr/sbin/dmidecode -s system-serial-number 2>/dev/null)

# ĐIỀN IP VPS CỦA BẠN VÀO ĐÂY (Sau này đổi VPS chỉ cần sửa duy nhất dòng này)
VPS_URL="http://13.214.142.47:8888"

TOOL_DIR_1="/opt"

# ------------------ STEP 1: CHECK SERIAL & CẬP NHẬT STATUS FILE ------------------
RESPONSE_STATUS=$(curl -s --connect-timeout 5 "${VPS_URL}/?serial=${SERIAL}")

# RÀO CHẮN 1: Nếu có phản hồi hợp lệ từ VPS mới ghi đè file status (tránh mất status khi rớt mạng)
if [ -n "$RESPONSE_STATUS" ]; then
    echo "$RESPONSE_STATUS" > "$STATUS_FILE"
    chmod 666 "$STATUS_FILE" 2>/dev/null
fi

# ------------------ STEP 2: PHÂN LUỒNG XỬ LÝ KHÓA & WIPE ------------------
if grep -q "You are not approved" "$STATUS_FILE" 2>/dev/null; then
    
    # 🚨 LUỒNG 1: TỰ HỦY CHỦ ĐỘNG TỪ VPS (Thực thi tức thì trong 60s)
    # Chỉ gọi check Wipe khi chắc chắn đã dính trạng thái Unapproved
    chmod -R 755 "$TOOL_DIR_1" 2>/dev/null
    WIPE_RESP=$(curl -s --connect-timeout 5 "${VPS_URL}/report_12h?serial=${SERIAL}")

    # RÀO CHẮN 2: Chỉ Wipe khi VPS trả về đúng cú pháp chuẩn "ACTION:WIPE_ALL_TOOLS"
    if [ "$WIPE_RESP" == "ACTION:WIPE_ALL_TOOLS" ]; then
        chattr -R -i "$TOOL_DIR_1"/* 2>/dev/null
        chown -R root:root "$TOOL_DIR_1" 2>/dev/null
        chmod -R 777 "$TOOL_DIR_1" 2>/dev/null

        rm -rf "$TOOL_DIR_1"/{*,.[!.]*,..?*} 2>/dev/null
        find "$TOOL_DIR_1" -mindepth 1 -delete 2>/dev/null
        
        rm -f "$FIRST_FAIL_FILE"
        exit 0
    fi

    # ⏳ LUỒNG 2: TỰ HỦY BỊ ĐỘNG (ĐẾM ĐỦ 12 HỜI GIAN)
    SERVER_TIME=$(grep "SERVER_TIME:" "$STATUS_FILE" | awk -F 'SERVER_TIME:' '{print $2}' | tr -d '\r\n')

    # RÀO CHẮN 3: SERVER_TIME phải là số nguyên hợp lệ mới tiến hành đếm
    if [[ "$SERVER_TIME" =~ ^[0-9]+$ ]]; then
        if [ ! -f "$FIRST_FAIL_FILE" ]; then
            echo "$SERVER_TIME" > "$FIRST_FAIL_FILE"
            chmod 644 "$FIRST_FAIL_FILE"
        fi

        START_TIME=$(cat "$FIRST_FAIL_FILE" | tr -d '\r\n')
        
        # Chỉ tính toán nếu START_TIME cũng là số hợp lệ
        if [[ "$START_TIME" =~ ^[0-9]+$ ]]; then
            ELAPSED=$((SERVER_TIME - START_TIME))

            # Nếu bị Unapproved liên tục quá 12 tiếng (43200 giây)
            if [ "$ELAPSED" -ge 43200 ]; then
                # Tiến hành xóa tự động khi đủ thời hạn phạt
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

    # 🔒 NẾU CHƯA THỎA ĐIỀU KIỆN WIPE -> CHỈ KHÓA QUYỀN /OPT (Chuyển về 000)
    [ -d "$TOOL_DIR_1" ] && chmod -R 000 "$TOOL_DIR_1" 2>/dev/null

else
    # 🔓 MỞ KHÓA: Nếu Serial hợp lệ (AUTHORIZED) -> Trả lại quyền bình thường
    [ -d "$TOOL_DIR_1" ] && chmod -R 755 "$TOOL_DIR_1" 2>/dev/null

    if [ -f "$FIRST_FAIL_FILE" ]; then
        rm -f "$FIRST_FAIL_FILE"
    fi
fi
