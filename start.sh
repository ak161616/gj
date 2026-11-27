#!/bin/sh
# 升级版启动脚本 (V26 - 免落盘极速瘦身 + 容错增强，支持重启回档)
set -e
echo "--- [Launcher V26] Starting..."

# 1. 从环境变量安全写入 config.yaml
if [ -n "$CONFIG_YAML" ]; then
    printf '%s\n' "$CONFIG_YAML" > /app/config.yaml
    echo "--- [Launcher V26] config.yaml created from environment secret."
else
    echo "CRITICAL: CONFIG_YAML environment variable not found! Halting."
    exit 1
fi

cd /app
DATA_DIR="/app/data"
LOCK_DIR="/tmp/st_backup.lock"
NEED_PUSH_FILE="/tmp/st_need_push"
rm -rf "$LOCK_DIR" "$NEED_PUSH_FILE"

write_gitignore() {
cat << 'EOF' > "$DATA_DIR/.gitignore"
/backups/
/*/backups/
/*/thumbnails/
/_cache/
/_webpack/
/_uploads/
/access.log
/*/content.log
EOF
}

# 封装安全的云备份函数
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

# 2. 诊断并初始化云存档
echo "--- [Cloud Save] Diagnostic Checks ---"
[ -z "$REPO_URL" ] && echo "--> REPO_URL secret: NOT FOUND." || echo "--> REPO_URL secret: Found."
[ -z "$GITHUB_TOKEN" ] && echo "--> GITHUB_TOKEN secret: NOT FOUND." || echo "--> GITHUB_TOKEN secret: Found."

if [ -n "$REPO_URL" ] && [ -n "$GITHUB_TOKEN" ]; then
    echo "--- [Cloud Save] All secrets found. Initializing Smart Sync..."
    CLEAN_REPO_URL="${REPO_URL#https://}"
    CLEAN_REPO_URL="${CLEAN_REPO_URL#http://}"
    AUTH_REPO_URL="https://oauth2:${GITHUB_TOKEN}@${CLEAN_REPO_URL}"

    SYNC_OK=0
    NEED_CHECKOUT=0
    for i in 1 2 3; do
        if [ -d "$DATA_DIR/.git" ]; then
            echo "--- [Cloud Save] Fetching latest backup (Attempt $i/3)..."
            if (cd "$DATA_DIR" && git remote set-url origin "$AUTH_REPO_URL" && git fetch --depth 1 origin main && git reset --hard origin/main); then
                SYNC_OK=1
                break
            fi
        else
            echo "--- [Cloud Save] Cloning backup metadata without checkout (Attempt $i/3)..."
            rm -rf "$DATA_DIR"
            # 关键优化：--no-checkout 只下载压缩包，不把 5 万多个旧文件写到硬盘
            if git clone --depth 1 --no-checkout "$AUTH_REPO_URL" "$DATA_DIR"; then
                SYNC_OK=1
                NEED_CHECKOUT=1
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

        # 先把文件清单读入索引（不写硬盘，约 1 秒完成）
        if [ "$NEED_CHECKOUT" -eq 1 ]; then
            git read-tree HEAD
        fi

        write_gitignore

        # 直接在索引中剔除冗余缓存与本地备份，彻底避开慢速硬盘写入
        if [ -n "$(git ls-files -c -i --exclude-standard | head -n 1)" ]; then
            BEFORE_COUNT=$(git ls-files | wc -l)
            echo "--- [Cloud Save] Detected legacy backups/caches ($BEFORE_COUNT files total). Slimming down in memory..."
            git ls-files -c -i --exclude-standard -z | git update-index --force-remove -z --stdin
            git add .gitignore > /dev/null 2>&1 || true
            AFTER_COUNT=$(git ls-files | wc -l)
            echo "--- [Cloud Save] Index slimmed: $BEFORE_COUNT -> $AFTER_COUNT files."
            if ! git diff --cached --quiet; then
                if git commit -m "Slim down repo: ignore caches and local backups" > /dev/null 2>&1; then
                    if git push origin HEAD:main > /dev/null 2>&1 || git push -f origin HEAD:main > /dev/null 2>&1; then
                        echo "--- [Cloud Save] Repo slimmed down and pushed!"
                    else
                        touch "$NEED_PUSH_FILE"
                        echo "--- [Cloud Save] Slim push delayed, will retry in next backup cycle."
                    fi
                fi
            fi
        fi

        # 只把瘦身后的干净文件释放到硬盘
        if [ "$NEED_CHECKOUT" -eq 1 ]; then
            FINAL_COUNT=$(git ls-files | wc -l)
            echo "--- [Cloud Save] Checking out $FINAL_COUNT clean files..."
            git checkout -f HEAD -- .
            write_gitignore
        fi

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

echo "--- [Launcher V26] All setup complete. Starting SillyTavern server..."
exec node server.js
