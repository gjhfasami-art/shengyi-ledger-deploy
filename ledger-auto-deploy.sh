#!/bin/bash
# 盛亿台账网站自动部署守望器
# 每 5 分钟由 cron 跑一次：去 GitHub 看 version.json 的版本号，
# 有新版就下载代码包、备份数据库、同步代码、重启服务。
# 部署包来源：https://github.com/gjhfasami-art/shengyi-ledger-deploy（公开仓库，只有代码，没有密码和数据）
set -u
REPO_RAW="https://cdn.jsdelivr.net/gh/gjhfasami-art/shengyi-ledger-deploy@main"
APP_DIR="/opt/ledger-web"
VERSION_FILE="$APP_DIR/.deployed_version"
LOG="/var/log/ledger-auto-deploy.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 取远端版本号（失败就退出，等下一次 cron 再试）
REMOTE_JSON="$(curl -fsSL --max-time 20 "$REPO_RAW/version.json" 2>/dev/null)" || exit 0
REMOTE_VER="$(echo "$REMOTE_JSON" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
REMOTE_ZIP="$(echo "$REMOTE_JSON" | grep -o '"zip"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
[ -n "$REMOTE_VER" ] && [ -n "$REMOTE_ZIP" ] || exit 0

CURRENT_VER=""
[ -f "$VERSION_FILE" ] && CURRENT_VER="$(cat "$VERSION_FILE")"
[ "$REMOTE_VER" = "$CURRENT_VER" ] && exit 0

log "发现新版 $REMOTE_VER（当前 $CURRENT_VER），开始部署 $REMOTE_ZIP"
rm -rf /tmp/ledger-auto-new /tmp/ledger-auto-code.zip
curl -fSL --max-time 120 "$REPO_RAW/$REMOTE_ZIP" -o /tmp/ledger-auto-code.zip || { log "代码包下载失败"; exit 1; }
mkdir -p /tmp/ledger-auto-new
unzip -q -o /tmp/ledger-auto-code.zip -d /tmp/ledger-auto-new || { log "代码包解压失败"; exit 1; }
[ -f /tmp/ledger-auto-new/app.py ] || { log "zip 里找不到 app.py，放弃本次部署"; exit 1; }

# 备份数据库
if [ -f "$APP_DIR/ledger.db" ]; then
  mkdir -p /root/ledger-db-backup
  cp "$APP_DIR/ledger.db" "/root/ledger-db-backup/ledger-$(date +%Y%m%d-%H%M%S).db"
fi
# 同步代码（数据库和虚拟环境不动）
rsync -a --delete --exclude 'ledger.db' --exclude 'venv' --exclude '__pycache__' /tmp/ledger-auto-new/ "$APP_DIR/"
# 装依赖（有变化才装，没变化也很快）
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" -q || { log "依赖安装失败"; exit 1; }
systemctl restart ledger-web
sleep 3
if systemctl is-active --quiet ledger-web; then
  echo "$REMOTE_VER" > "$VERSION_FILE"
  log "部署成功，已是 $REMOTE_VER"
else
  log "服务重启失败，请看 journalctl -u ledger-web"
  exit 1
fi
