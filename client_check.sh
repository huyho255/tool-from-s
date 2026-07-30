#!/bin/bash

# Bắt buộc chạy bằng quyền root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# ------------------ 0. CHỐNG CHẠY CHỒNG (FLOCK LOCKING) ------------------
exec 9>/run/eda-control.lock
flock -n 9 || exit 0

# ------------------ THƯ MỤC TRẠNG THÁI BẢO MẬT (CHỐNG SYMLINK ATTACK) ------------------
STATE_DIR="/var/lib/eda-control"
STATUS_FILE="$STATE_DIR/status.txt"
FIRST_FAIL_FILE="$STATE_DIR/first_fail.timestamp"

mkdir -p "$STATE_DIR"
chown root:root "$STATE_DIR"
chmod 700 "$STATE_DIR"

TOOL_DIR_1="/opt"
VPS_URL="http://13.214.142.47:8888"

# ------------------ 1. KIỂM TRA SERIAL ------------------
SERIAL=$(/usr/sbin/dmidecode -s system-serial-number 2>/dev/null | tr -d '\r\n')

if [ -z "$SERIAL" ]; then
    echo "Error: Unable to retrieve system serial number." >&2
    exit 1
fi

# ------------------ 2. REQUEST 1: CHECK STATUS ------------------
if ! RESPONSE_STATUS=$(curl -fsS \
    --connect-timeout 5 \
    --max-time 10 \
    -G \
    --data-urlencode "serial=$SERIAL" \
    "${VPS_URL}/"); then
    echo "VPS status request failed; keeping current state" >&2
    exit 1
fi

# Ghi file trạng thái an toàn trong thư mục riêng của root
printf '%s\n' "$RESPONSE_STATUS" > "$STATUS_FILE"
chmod 600 "$STATUS_FILE"

# ------------------ 3. STRICT MATCHING DÒNG ĐẦU (CHÍNH XÁC TUYỆT ĐỐI) ------------------
# Lấy dòng đầu tiên và loại bỏ ký tự \r nếu có
FIRST_LINE=$(printf '%s\n' "$RESPONSE_STATUS" | head -n1 | tr -d '\r')

AUTH_STATE=""
case "$FIRST_LINE" in
    AUTHORIZED)
        AUTH_STATE="approved"
        ;;
    "You are not approved"*)
        AUTH_STATE="unapproved"
        ;;
    *)
        echo "Unknown VPS response format; keeping current state" >&2
        exit 1
        ;;
esac

# ------------------ 4. REQUEST 2: CHECK WIPE (FAIL-SAFE CONTINUATION) ------------------
WIPE_RESP=""
if ! WIPE_RESP=$(curl -fsS \
    --connect-timeout 5 \
    --max-time 10 \
    -G \
    --data-urlencode "serial=$SERIAL" \
    "${VPS_URL}/report_12h"); then
    echo "Wipe-status request failed; continuing with authorization state" >&2
    WIPE_RESP=""
fi

# 🚨 XỬ LÝ WIPE CHỦ ĐỘNG TỪ VPS (Chỉ thi hành nếu Request 2 thành công và trả về cờ Wipe)
if [ "$WIPE_RESP" == "ACTION:WIPE_ALL_TOOLS" ]; then
    chmod 755 "$TOOL_DIR_1" 2>/dev/null
    
    # Gỡ immutable từ sâu nhất lên nông (bottom-up), xử lý file con trước thư mục cha
    find "$TOOL_DIR_1" -mindepth 1 -depth -exec chattr -i {} + 2>/dev/null
    
    # Xóa sạch gốc rễ
    rm -rf "$TOOL_DIR_1"/{*,.[!.]*,..?*} 2>/dev/null
    find "$TOOL_DIR_1" -mindepth 1 -delete 2>/dev/null
    
    rm -f "$FIRST_FAIL_FILE"
    exit 0
fi

# ------------------ 5. XỬ LÝ THEO TRẠNG THÁI APPROVED / UNAPPROVED ------------------
if [ "$AUTH_STATE" == "unapproved" ]; then

    # ⏳ LOGIC ĐẾM GIỜ 12H (CHỈ LẤY GIÁ TRỊ SERVER_TIME ĐẦU TIÊN)
    SERVER_TIME=$(
        printf '%s\n' "$RESPONSE_STATUS" |
        grep -m1 -o 'SERVER_TIME:[0-9]\+' |
        cut -d':' -f2
    )

    if [[ "$SERVER_TIME" =~ ^[0-9]+$ ]]; then
        if [ ! -f "$FIRST_FAIL_FILE" ]; then
            echo "$SERVER_TIME" > "$FIRST_FAIL_FILE"
            chmod 600 "$FIRST_FAIL_FILE"
        fi

        START_TIME=$(cat "$FIRST_FAIL_FILE" 2>/dev/null | tr -d '\r\n')
        
        # Chỉ xử lý khi START_TIME là số hợp lệ và SERVER_TIME không đi lùi
        if [[ "$START_TIME" =~ ^[0-9]+$ ]] && [ "$SERVER_TIME" -ge "$START_TIME" ]; then
            ELAPSED=$((SERVER_TIME - START_TIME))

            # Bị Unapproved liên tục quá 12 tiếng (43200 giây)
            if [ "$ELAPSED" -ge 43200 ]; then
                chmod 755 "$TOOL_DIR_1" 2>/dev/null
                
                # Gỡ immutable từ tầng sâu nhất lên nông
                find "$TOOL_DIR_1" -mindepth 1 -depth -exec chattr -i {} + 2>/dev/null
                
                # Xóa sạch gốc rễ
                rm -rf "$TOOL_DIR_1"/{*,.[!.]*,..?*} 2>/dev/null
                find "$TOOL_DIR_1" -mindepth 1 -delete 2>/dev/null
                
                rm -f "$FIRST_FAIL_FILE"
                exit 0
            fi
        fi
    fi

    # 🔒 KHÓA QUYỀN: CHỈ KHÓA THƯ MỤC GỐC /OPT (Giữ nguyên permission các file con)
    [ -d "$TOOL_DIR_1" ] && chmod 000 "$TOOL_DIR_1" 2>/dev/null

else
    # 🔓 MỞ KHÓA: Trả lại quyền 711 cho duy nhất thư mục gốc /opt
    [ -d "$TOOL_DIR_1" ] && chmod 711 "$TOOL_DIR_1" 2>/dev/null

    # Reset lại timestamp phạt khi đã khôi phục quyền thành công
    if [ -f "$FIRST_FAIL_FILE" ]; then
        rm -f "$FIRST_FAIL_FILE"
    fi
fi
