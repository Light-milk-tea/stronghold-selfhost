#!/usr/bin/env bash
# 在已有网站的 Linux 服务器上安装卫戍协议 v0.4.0。
# 游戏只监听 127.0.0.1:3000。不会修改 www.qimiyo.online 的站点。
# 可重复执行。重复执行会重启游戏进程，正在进行的对局会结束。
set -euo pipefail

TAG="v0.4.0"
APP_DIR="/opt/Stronghold-Protocol"
NODE_DIR="/opt/node-v22"
UPSTREAM="https://github.com/sganggs/Stronghold-Protocol.git"
UPSTREAM_MIRROR="https://gh-proxy.com/https://github.com/sganggs/Stronghold-Protocol.git"
DOMAIN="play.qimiyo.online"
MIN_FREE_MB=3072
SERVICE_USER="stronghold"
NGINX_DEST="/etc/nginx/conf.d/play.qimiyo.online.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请用 root 执行：sudo bash deploy/install.sh"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1"
}

check_disk() {
  local target avail_kb avail_mb
  target="/opt"
  [[ -d "$target" ]] || target="/"
  avail_kb="$(df -Pk "$target" | awk 'NR==2 {print $4}')"
  avail_mb="$((avail_kb / 1024))"
  if [[ "$avail_mb" -lt "$MIN_FREE_MB" ]]; then
    die "${target} 剩余 ${avail_mb} MB，至少需要 ${MIN_FREE_MB} MB（素材约 720 MB）"
  fi
  log "磁盘可用 ${avail_mb} MB"
}

node_major() {
  "$1" -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0
}

install_node() {
  local major arch ver sums line file url tmp
  if [[ -x "$NODE_DIR/bin/node" ]]; then
    major="$(node_major "$NODE_DIR/bin/node")"
    if [[ "$major" -ge 22 ]]; then
      log "已有 Node $( "$NODE_DIR/bin/node" -v )：$NODE_DIR"
      return
    fi
  fi

  case "$(uname -m)" in
    x86_64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac

  sums="$(mktemp)"
  if ! curl -fsSL --retry 3 "https://cdn.npmmirror.com/binaries/node/latest-v22.x/SHASUMS256.txt" -o "$sums"; then
    curl -fsSL --retry 3 "https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt" -o "$sums" \
      || die "无法取得 Node.js 22 的版本清单"
  fi
  line="$(awk -v arch="$arch" '$2 ~ ("node-v22[.][0-9.]+-linux-" arch "[.]tar[.]xz$") { print $2; exit }' "$sums")"
  rm -f "$sums"
  [[ -n "$line" ]] || die "版本清单里没有 linux-${arch} 的 Node.js 22 压缩包"
  ver="${line#node-v}"
  ver="${ver%-linux-${arch}.tar.xz}"
  file="node-v${ver}-linux-${arch}.tar.xz"
  tmp="$(mktemp --suffix=.tar.xz)"

  url="https://cdn.npmmirror.com/binaries/node/v${ver}/${file}"
  log "下载 Node.js v${ver}：$url"
  if ! curl -fL --retry 3 "$url" -o "$tmp"; then
    url="https://nodejs.org/dist/v${ver}/${file}"
    log "镜像失败，改从 $url 下载"
    curl -fL --retry 3 "$url" -o "$tmp" || die "Node.js 下载失败"
  fi

  rm -rf "/opt/node-v${ver}-linux-${arch}"
  tar -xJf "$tmp" -C /opt
  rm -f "$tmp"
  rm -rf "$NODE_DIR"
  mv "/opt/node-v${ver}-linux-${arch}" "$NODE_DIR"
  log "Node.js 装在 $NODE_DIR，未改动系统默认 node"
}

app_git() {
  git -c "safe.directory=$APP_DIR" -C "$APP_DIR" "$@"
}

clone_or_update() {
  local url
  if [[ -d "$APP_DIR/.git" ]]; then
    if app_git describe --tags --exact-match HEAD 2>/dev/null | grep -qx "$TAG"; then
      log "游戏代码已是 $TAG"
      return
    fi
    log "更新游戏代码到 $TAG"
    app_git fetch --depth 1 origin "tag" "$TAG" \
      || app_git fetch --depth 1 origin "+refs/tags/${TAG}:refs/tags/${TAG}"
    app_git checkout --detach "$TAG"
    return
  fi
  if [[ -e "$APP_DIR" ]]; then
    die "$APP_DIR 已存在，但不是游戏仓库。请换目录或先移走它"
  fi
  for url in "$UPSTREAM" "$UPSTREAM_MIRROR"; do
    log "克隆 $url ($TAG)"
    if git clone --depth 1 --branch "$TAG" "$url" "$APP_DIR"; then
      return
    fi
    rm -rf "$APP_DIR"
  done
  die "克隆上游仓库失败"
}

install_app() {
  export PATH="$NODE_DIR/bin:$PATH"
  hash -r
  clone_or_update
  cd "$APP_DIR"
  if [[ ! -d node_modules/ws ]]; then
    log "安装 npm 依赖"
    npm ci --registry=https://registry.npmmirror.com || npm ci
  else
    log "npm 依赖已在"
  fi
  log "检查环境并下载素材（约 720 MB，可中断后再次执行本脚本续传）"
  node tools/setup.mjs --yes --no-local --no-scenes --asset-source=mirror
}

ensure_user() {
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    return
  fi
  local shell_path="/usr/sbin/nologin"
  [[ -x "$shell_path" ]] || shell_path="/sbin/nologin"
  useradd --system --no-create-home --home-dir "$APP_DIR" --shell "$shell_path" "$SERVICE_USER"
}

install_service() {
  ensure_user
  chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR"
  install -m 0644 "$SCRIPT_DIR/stronghold.service" /etc/systemd/system/stronghold.service
  systemctl daemon-reload
  systemctl enable stronghold
  systemctl restart stronghold

  local i
  for i in $(seq 1 30); do
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:3000/"; then
      log "游戏进程已响应 http://127.0.0.1:3000/"
      return
    fi
    sleep 1
  done
  systemctl status stronghold --no-pager || true
  die "游戏进程未在 30 秒内响应。查看日志：journalctl -u stronghold -n 80 --no-pager"
}

print_baota() {
  cat <<EOF

检测到宝塔面板。没有改动面板里的网站配置。
游戏已在 127.0.0.1:3000 运行。请在宝塔中单独添加站点，不要编辑 www.qimiyo.online：

1. 网站 → 添加站点，域名填 ${DOMAIN}。PHP 选纯静态即可。
2. 该站点 → 反向代理 → 目标 URL 填 http://127.0.0.1:3000，并开启 WebSocket。
3. 在该站点的配置里确认有这些行（没有就加在反代的 location 中）：
     proxy_set_header Upgrade \$http_upgrade;
     proxy_set_header Connection "upgrade";
     proxy_read_timeout 1h;
4. 该站点 → SSL → Let's Encrypt，只勾选 ${DOMAIN}。

参考片段：${SCRIPT_DIR}/nginx-play.qimiyo.online.conf
EOF
}

print_caddy() {
  cat <<EOF

检测到 Caddy，未自动改写 Caddyfile，以免动到封面站。
请把 ${SCRIPT_DIR}/Caddyfile.snippet 合并进现有 Caddyfile 后执行：
  sudo systemctl reload caddy
EOF
}

configure_proxy() {
  if [[ -d /www/server/panel ]]; then
    print_baota
    return
  fi
  if command -v caddy >/dev/null 2>&1 && ! command -v nginx >/dev/null 2>&1; then
    print_caddy
    return
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    log "未找到 Nginx。游戏只在本机 3000 端口。请自行把 ${DOMAIN} 反代到 127.0.0.1:3000。"
    log "Nginx 示例：${SCRIPT_DIR}/nginx-play.qimiyo.online.conf"
    return
  fi
  if [[ ! -d /etc/nginx/conf.d ]]; then
    log "没有 /etc/nginx/conf.d。请手动安装 ${SCRIPT_DIR}/nginx-play.qimiyo.online.conf"
    return
  fi
  if [[ -f "$NGINX_DEST" ]] && grep -Eq '^[[:space:]]*ssl_certificate[[:space:]]' "$NGINX_DEST"; then
    log "保留已有 HTTPS 配置：$NGINX_DEST"
  else
    install -m 0644 "$SCRIPT_DIR/nginx-play.qimiyo.online.conf" "$NGINX_DEST"
    log "已写入 $NGINX_DEST"
  fi
  nginx -t
  systemctl reload nginx
  log "Nginx 已重载。www.qimiyo.online 的配置文件没有修改。"

  if ! command -v certbot >/dev/null 2>&1; then
    log "未安装 certbot。安装后只为这个新域名申请证书："
    log "  sudo certbot --nginx -d ${DOMAIN} --redirect"
    return
  fi
  if [[ -f "$NGINX_DEST" ]] && grep -Eq '^[[:space:]]*ssl_certificate[[:space:]]' "$NGINX_DEST"; then
    log "证书配置已在，跳过 certbot"
    return
  fi
  if [[ -t 0 ]]; then
    certbot --nginx -d "$DOMAIN" --redirect
  else
    log "当前不是交互终端。请稍后执行："
    log "  sudo certbot --nginx -d ${DOMAIN} --redirect"
  fi
}

main() {
  require_root
  need_cmd curl
  need_cmd tar
  need_cmd git
  need_cmd awk
  check_disk
  install_node
  install_app
  install_service
  configure_proxy
  cat <<EOF

安装完成。
  游戏本机：http://127.0.0.1:3000/
  对外域名：https://${DOMAIN}/   （证书申请成功后）
  封面站：  https://www.qimiyo.online/  （本次未修改）
  日志：    journalctl -u stronghold -f
安全组不要开放 3000。知道游戏地址的人都能进入。
EOF
}

main "$@"
