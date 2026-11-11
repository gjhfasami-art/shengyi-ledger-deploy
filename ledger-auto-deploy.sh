#!/bin/bash
# 盛亿台账网站自动部署守望器
# 每 5 分钟由 cron 跑一次：去 GitHub 看 version.json 的版本号，
# 有新版就下载代码包、备份数据库、同步代码、重启服务。
# 版本号走 GitHub API(实时准确, 不走 CDN 缓存); 代码包走 jsDelivr(新文件名无旧缓存), 失败则走 GitHub API。
# 部署包来源：https://github.com/gjhfasami-art/shengyi-ledger-deploy（公开仓库，只有代码，没有密码和数据）
set -u
REPO="gjhfasami-art/shengyi-ledger-deploy"
API="https://api.github.com/repos/$REPO/contents"
CDN="https://cdn.jsdelivr.net/gh/$REPO@main"
APP_DIR="/opt/ledger-web"
VERSION_FILE="$APP_DIR/.deployed_version"
LOG="/var/log/ledger-auto-deploy.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 取远端版本号 (GitHub API, 不走 CDN 缓存)
REMOTE_JSON="$(curl -fsSL --max-time 20 "$API/version.json" 2>/dev/null | python3 -c "import json,sys,base64; d=json.load(sys.stdin); sys.stdout.write(base64.b64decode(d.get('content','')).decode())" 2>/dev/null)" || exit 0
REMOTE_VER="$(echo "$REMOTE_JSON" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
REMOTE_ZIP="$(echo "$REMOTE_JSON" | grep -o '"zip"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
[ -n "$REMOTE_VER" ] && [ -n "$REMOTE_ZIP" ] || exit 0

CURRENT_VER=""
[ -f "$VERSION_FILE" ] && CURRENT_VER="$(cat "$VERSION_FILE")"
[ "$REMOTE_VER" = "$CURRENT_VER" ] && exit 0

log "发现新版 $REMOTE_VER（当前 $CURRENT_VER），开始部署 $REMOTE_ZIP"
rm -rf /tmp/ledger-auto-new /tmp/ledger-auto-code.zip
# 代码包先走 jsDelivr(新文件名, 无旧缓存); 失败则走 GitHub API base64
if ! curl -fSL --max-time 120 "$CDN/$REMOTE_ZIP" -o /tmp/ledger-auto-code.zip 2>/dev/null; then
  curl -fsSL --max-time 120 "$API/$REMOTE_ZIP" 2>/dev/null | python3 -c "import json,sys,base64; d=json.load(sys.stdin); open('/tmp/ledger-auto-code.zip','wb').write(base64.b64decode(d.get('content','')))" 2>/dev/null || { log "代码包下载失败"; exit 1; }
fi
[ -s /tmp/ledger-auto-code.zip ] || { log "代码包下载失败(空文件)"; exit 1; }
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
sleep 2
if systemctl is-active --quiet ledger-web; then
  echo "$REMOTE_VER" > "$VERSION_FILE"
  log "部署成功，已是 $REMOTE_VER"
else
  log "部署后服务未起来，请人工检查"
  exit 1
fi
