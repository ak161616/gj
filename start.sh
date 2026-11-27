#!/bin/sh
# 正式稳定版启动脚本 (V27 - 极速浅克隆 + 容错备份，支持重启回档)
set -e
echo "--- [Launcher V27] Starting..."

# 1. 从环境变量安全写入 config.yaml
if [ -n "$CONFIG_YAML" ]; then
    printf '%s\n' "$CONFIG_YAML" > /app/config.yaml
    echo "--- [Launcher V27] config.yaml created from environment secret."
else
    echo "CRITICAL: CONFIG_YAML environment variable not found! Halting."
    exit 1
fi

cd /app
DATA_DIR="/app/data"
LOCK_DIR="/tmp/st_backup.lock"
NEED_PUSH_FILE="/tmp/st_need_push"
rm -rf "$LOCK_DIR" "$NEED_PUSH_FILE"

# 封装安全的云备份函数（独立关闭 set -e，防止单次文件冲突导致后台备份假死）
do_backup() {
    (
        set +e
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            echo "--- [Cloud Save] Backup already running, skipping."
            exit 0
        fi
        trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

        cd "$DATA_DIR" || exit 0
        git add -A > /dev/null 2>&1

        if ! git diff --cached --quiet; then
            COMMIT_MESSAGE="Auto Backup from HF/${SPACE_ID:-unknown}: $(date '+%Y-%m-%d %H:%M:%S')"
            if git commit -m "$COMMIT_MESSAGE" > /dev/null 2>&1; then
                touch "$NEED_PUSH_FILE"
            else
                echo "--- [Cloud Save] Commit failed, will retry next cycle."
            fi
        fi

        if [ -f "$NEED_PUSH_FILE" ]; then
            if git push origin HEAD:main > /dev/null 2>&1 || git push -f origin HEAD:main > /dev/null 2>&1; then
                rm -f "$NEED_PUSH_FILE"
                echo "--- [Cloud Save] Pushed successfully at $(date '+%H:%M:%S')."
            else
                echo "--- [Cloud Save] Push failed (network hiccup), will retry next cycle."
            fi
        fi
    )
}

# 2. 初始化云存档
echo "--- [Cloud Save] Diagnostic Checks ---"
[ -z "$REPO_URL" ] && echo "--> REPO_URL secret: NOT FOUND." || echo "--> REPO_URL secret: Found."
[ -z "$GITHUB_TOKEN" ] && echo "--> GITHUB_TOKEN secret: NOT FOUND." || echo "--> GITHUB_TOKEN secret: Found."

if [ -n "$REPO_URL" ] && [ -n "$GITHUB_TOKEN" ]; then
    echo "--- [Cloud Save] All secrets found. Initializing Smart Sync..."
    CLEAN_REPO_URL="${REPO_URL#https://}"
    CLEAN_REPO_URL="${CLEAN_REPO_URL#http://}"
    AUTH_REPO_URL="https://oauth2:${GITHUB_TOKEN}@${CLEAN_REPO_URL}"

    SYNC_OK=0
    for i in 1 2 3; do
        if [ -d "$DATA_DIR/.git" ]; then
            echo "--- [Cloud Save] Fetching latest backup (Attempt $i/3)..."
            if (cd "$DATA_DIR" && git remote set-url origin "$AUTH_REPO_URL" && git fetch --depth 1 origin main && git reset --hard origin/main); then
                SYNC_OK=1
                break
            fi
        else
            echo "--- [Cloud Save] Cloning latest backup (Attempt $i/3)..."
            rm -rf "$DATA_DIR"
            if git clone --depth 1 "$AUTH_REPO_URL" "$DATA_DIR"; then
                SYNC_OK=1
                break
            fi
        fi
        echo "--- [Cloud Save] Attempt $i failed, retrying in 5s..."
        sleep 5
    done

    if [ "$SYNC_OK" -eq 1 ]; then
        cd "$DATA_DIR"
        git config user.name "SillyTavern Backup"
        git config user.email "backup@huggingface.space"

        # 持续屏蔽本地套娃备份、缩略图、系统缓存和访问日志
        cat << 'EOF' > "$DATA_DIR/.gitignore"
/backups/
/*/backups/
/*/thumbnails/
/_cache/
/_webpack/
/_uploads/
/access.log
EOF

        cd /app

        # 后台定时备份循环
        (
            set +e
            while true; do
                sleep "$((${AUTOSAVE_INTERVAL:-30} * 60))"
                do_backup
            done
        ) &
        echo "--- [Cloud Save] Auto-save running in background (every ${AUTOSAVE_INTERVAL:-30} min)."
    else
        echo "CRITICAL: Cloud Save sync failed after 3 attempts! Halting to protect data."
        exit 1
    fi
else
    echo "--- [Cloud Save] One or more secrets missing. Cloud save is DISABLED."
fi

echo "--- [Launcher V27] All setup complete. Starting SillyTavern server..."
exec node server.js
