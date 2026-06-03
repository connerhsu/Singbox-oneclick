#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="sing-box"
SERVICE_NAME="sing-box"
BASE_DIR="/etc/sing-box"
CONFIG_FILE="${BASE_DIR}/config.json"
META_FILE="${BASE_DIR}/profile.env"
CERT_FILE="${BASE_DIR}/anytls.crt"
KEY_FILE="${BASE_DIR}/anytls.key"
BIN_FILE="/usr/local/bin/sing-box"
MENU_FILE="/usr/local/bin/singbox-menu"
MENU_ALIAS="/usr/local/bin/menu"
MENU_ALIAS_LONG="/usr/local/bin/proxy-menu"
PROFILE_HINT="/etc/profile.d/singbox-menu-hint.sh"
LOG_FILE="/var/log/sing-box.log"

DEFAULT_ST_PORT="443"
DEFAULT_ANYTLS_PORT="8443"
DEFAULT_VLESS_PORT="9443"
DEFAULT_HANDSHAKE="www.microsoft.com"
DEFAULT_REALITY_HANDSHAKE="www.cloudflare.com"
DEFAULT_ANYTLS_SNI="anytls.local"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[34m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    red "请用 root 运行：sudo bash $0"
    exit 1
  fi
}

pause() {
  read -r -p "按回车返回菜单..."
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

safe_read() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  printf '%s' "${value:-$default}"
}

is_number() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" > 0 && "$1" < 65536 ))
}

validate_port() {
  local name="$1"
  local value="$2"
  if ! is_number "$value"; then
    red "${name} 端口不合法：${value}"
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armv7) printf 'armv7' ;;
    armv6l|armv6) printf 'armv6' ;;
    i386|i686) printf '386' ;;
    *) red "不支持的架构：$(uname -m)"; exit 1 ;;
  esac
}

install_packages() {
  local pkgs=(curl tar gzip openssl ca-certificates)

  if has_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif has_cmd dnf; then
    dnf install -y "${pkgs[@]}"
  elif has_cmd yum; then
    yum install -y "${pkgs[@]}"
  elif has_cmd apk; then
    apk add --no-cache "${pkgs[@]}"
  elif has_cmd pacman; then
    pacman -Sy --noconfirm "${pkgs[@]}"
  else
    yellow "未识别包管理器，请确认已安装：curl tar gzip openssl ca-certificates"
  fi
}

install_sing_box() {
  if has_cmd sing-box; then
    green "已检测到 sing-box：$(sing-box version | head -n 1)"
    return
  fi

  install_packages

  local arch tmp_dir api_url download_url archive binary_path
  arch="$(detect_arch)"
  tmp_dir="$(mktemp -d)"
  api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

  blue "正在下载 sing-box linux-${arch}..."
  download_url="$(
    curl -fsSL "$api_url" |
      grep -Eo 'https://[^"]+linux-'"${arch}"'\.tar\.gz' |
      head -n 1
  )"

  if [[ -z "$download_url" ]]; then
    red "没有找到适配 linux-${arch} 的 sing-box 发布包。"
    exit 1
  fi

  archive="${tmp_dir}/sing-box.tar.gz"
  curl -fL "$download_url" -o "$archive"
  tar -xzf "$archive" -C "$tmp_dir"
  binary_path="$(find "$tmp_dir" -type f -name sing-box -perm -111 | head -n 1)"

  if [[ -z "$binary_path" ]]; then
    red "发布包中没有找到 sing-box 可执行文件。"
    exit 1
  fi

  install -m 0755 "$binary_path" "$BIN_FILE"
  green "sing-box 已安装：$("$BIN_FILE" version | head -n 1)"
}

rand_base64() {
  local bytes="${1:-24}"
  openssl rand -base64 "$bytes" | tr -d '\n'
}

rand_hex() {
  local bytes="${1:-8}"
  openssl rand -hex "$bytes" | tr -d '\n'
}

make_uuid() {
  if has_cmd sing-box; then
    sing-box generate uuid | tr -d '\n'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '\n' < /proc/sys/kernel/random/uuid
  else
    uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '\n'
  fi
}

make_reality_keys() {
  local output
  output="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$output" | awk -F': ' 'tolower($1) ~ /private/ {print $2; exit}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$output" | awk -F': ' 'tolower($1) ~ /public/ {print $2; exit}')"

  if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
    red "生成 Reality 密钥失败。"
    printf '%s\n' "$output"
    exit 1
  fi
}

load_profile() {
  if [[ -f "$META_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$META_FILE"
  fi
}

save_profile() {
  umask 077
  {
    printf 'PUBLIC_HOST=%q\n' "$PUBLIC_HOST"
    printf 'ST_PORT=%q\n' "$ST_PORT"
    printf 'SS_METHOD=%q\n' "$SS_METHOD"
    printf 'SS_PASSWORD=%q\n' "$SS_PASSWORD"
    printf 'SHADOWTLS_PASSWORD=%q\n' "$SHADOWTLS_PASSWORD"
    printf 'SHADOWTLS_HANDSHAKE=%q\n' "$SHADOWTLS_HANDSHAKE"
    printf 'ANYTLS_PORT=%q\n' "$ANYTLS_PORT"
    printf 'ANYTLS_PASSWORD=%q\n' "$ANYTLS_PASSWORD"
    printf 'ANYTLS_SNI=%q\n' "$ANYTLS_SNI"
    printf 'VLESS_PORT=%q\n' "$VLESS_PORT"
    printf 'VLESS_UUID=%q\n' "$VLESS_UUID"
    printf 'REALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
    printf 'REALITY_PUBLIC_KEY=%q\n' "$REALITY_PUBLIC_KEY"
    printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
    printf 'REALITY_HANDSHAKE=%q\n' "$REALITY_HANDSHAKE"
  } > "$META_FILE"
  chmod 600 "$META_FILE"
}

guess_public_host() {
  local detected=""
  detected="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$detected" ]]; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "${detected:-YOUR_SERVER_IP}"
}

generate_cert() {
  mkdir -p "$BASE_DIR"
  if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
    return
  fi

  openssl req \
    -x509 \
    -newkey rsa:2048 \
    -nodes \
    -sha256 \
    -days 3650 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=${ANYTLS_SNI}" >/dev/null 2>&1

  chmod 600 "$KEY_FILE"
  chmod 644 "$CERT_FILE"
}

write_config() {
  mkdir -p "$BASE_DIR"
  umask 077
  cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "${LOG_FILE}",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowtls",
      "tag": "shadowtls-in",
      "listen": "::",
      "listen_port": ${ST_PORT},
      "version": 3,
      "users": [
        {
          "name": "ss2022",
          "password": "${SHADOWTLS_PASSWORD}"
        }
      ],
      "handshake": {
        "server": "${SHADOWTLS_HANDSHAKE}",
        "server_port": 443
      },
      "strict_mode": true,
      "detour": "ss2022-in"
    },
    {
      "type": "shadowsocks",
      "tag": "ss2022-in",
      "listen": "127.0.0.1",
      "network": "tcp",
      "method": "${SS_METHOD}",
      "password": "${SS_PASSWORD}"
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${ANYTLS_PORT},
      "users": [
        {
          "name": "anytls",
          "password": "${ANYTLS_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${ANYTLS_SNI}",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
    },
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "name": "vless-reality",
          "uuid": "${VLESS_UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_HANDSHAKE}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_HANDSHAKE}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${REALITY_SHORT_ID}"
          ],
          "max_time_difference": "1m"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
  chmod 600 "$CONFIG_FILE"
}

write_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=sing-box proxy service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_FILE} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

open_firewall() {
  local ports=("$ST_PORT" "$ANYTLS_PORT" "$VLESS_PORT")
  local port

  if has_cmd ufw && ufw status 2>/dev/null | grep -qi active; then
    for port in "${ports[@]}"; do
      ufw allow "${port}/tcp" >/dev/null || true
    done
  fi

  if has_cmd firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    for port in "${ports[@]}"; do
      firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null || true
    done
    firewall-cmd --reload >/dev/null || true
  fi
}

install_menu_command() {
  install -m 0755 "$0" "$MENU_FILE"
  ln -sf "$MENU_FILE" "$MENU_ALIAS"
  ln -sf "$MENU_FILE" "$MENU_ALIAS_LONG"

  cat > "$PROFILE_HINT" <<'EOF'
if [ -n "${SSH_CONNECTION:-}" ] && [ -t 1 ] && command -v menu >/dev/null 2>&1; then
  echo "输入 menu 可打开 sing-box 一键管理面板。"
fi
EOF
  chmod 644 "$PROFILE_HINT"

  green "已安装菜单命令：menu 或 proxy-menu"
}

collect_config() {
  local detected_host
  detected_host="$(guess_public_host)"

  PUBLIC_HOST="$(safe_read "服务器公网 IP 或域名" "${PUBLIC_HOST:-$detected_host}")"
  ST_PORT="$(safe_read "SS2022 + ShadowTLS 监听端口" "${ST_PORT:-$DEFAULT_ST_PORT}")"
  ANYTLS_PORT="$(safe_read "AnyTLS 监听端口" "${ANYTLS_PORT:-$DEFAULT_ANYTLS_PORT}")"
  VLESS_PORT="$(safe_read "VLESS Reality 监听端口" "${VLESS_PORT:-$DEFAULT_VLESS_PORT}")"
  SHADOWTLS_HANDSHAKE="$(safe_read "ShadowTLS 握手伪装域名" "${SHADOWTLS_HANDSHAKE:-$DEFAULT_HANDSHAKE}")"
  REALITY_HANDSHAKE="$(safe_read "Reality 握手伪装域名" "${REALITY_HANDSHAKE:-$DEFAULT_REALITY_HANDSHAKE}")"
  ANYTLS_SNI="$(safe_read "AnyTLS 证书/SNI 名称" "${ANYTLS_SNI:-$DEFAULT_ANYTLS_SNI}")"

  validate_port "ShadowTLS" "$ST_PORT"
  validate_port "AnyTLS" "$ANYTLS_PORT"
  validate_port "VLESS Reality" "$VLESS_PORT"

  SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"
  SS_PASSWORD="${SS_PASSWORD:-$(rand_base64 16)}"
  SHADOWTLS_PASSWORD="${SHADOWTLS_PASSWORD:-$(rand_base64 24)}"
  ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-$(rand_base64 24)}"
  VLESS_UUID="${VLESS_UUID:-$(make_uuid)}"
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(rand_hex 8)}"

  if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
    make_reality_keys
  fi
}

check_config() {
  if ! "$BIN_FILE" check -c "$CONFIG_FILE"; then
    red "配置检查失败，请根据上方错误调整。"
    exit 1
  fi
}

install_all() {
  need_root
  load_profile
  install_sing_box
  collect_config
  generate_cert
  save_profile
  write_config
  check_config
  write_service
  open_firewall
  install_menu_command
  systemctl enable --now "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
  green "安装完成。SSH 登录后输入 menu 即可唤出面板。"
  show_status
  show_nodes
}

restart_service() {
  need_root
  systemctl restart "$SERVICE_NAME"
  green "已重启 sing-box。"
  show_status
}

start_service() {
  need_root
  systemctl start "$SERVICE_NAME"
  green "已启动 sing-box。"
  show_status
}

stop_service() {
  need_root
  systemctl stop "$SERVICE_NAME"
  yellow "已停止 sing-box。"
  show_status
}

show_ports() {
  if has_cmd ss; then
    ss -lntp 2>/dev/null | grep -E "(:${ST_PORT}|:${ANYTLS_PORT}|:${VLESS_PORT})" || true
  elif has_cmd netstat; then
    netstat -lntp 2>/dev/null | grep -E "(:${ST_PORT}|:${ANYTLS_PORT}|:${VLESS_PORT})" || true
  fi
}

show_status() {
  load_profile
  bold "运行状态"

  if has_cmd systemctl && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      green "服务状态：运行中"
    else
      red "服务状态：未运行"
    fi
    systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,12p' || true
  else
    yellow "未检测到 systemd 服务。"
  fi

  if [[ -n "${ST_PORT:-}" ]]; then
    bold "监听端口"
    show_ports
  fi

  if [[ -x "$BIN_FILE" && -f "$CONFIG_FILE" ]]; then
    bold "配置检查"
    "$BIN_FILE" check -c "$CONFIG_FILE" || true
  fi
}

show_nodes() {
  load_profile
  if [[ ! -f "$META_FILE" ]]; then
    yellow "还没有安装配置，请先执行安装。"
    return
  fi

  bold "SS2022 + ShadowTLS v3"
  cat <<EOF
服务器：${PUBLIC_HOST}
端口：${ST_PORT}
SS 方法：${SS_METHOD}
SS 密码：${SS_PASSWORD}
ShadowTLS 版本：3
ShadowTLS 密码：${SHADOWTLS_PASSWORD}
ShadowTLS SNI：${SHADOWTLS_HANDSHAKE}
EOF

  bold "SS2022 + ShadowTLS sing-box 客户端出站示例"
  cat <<EOF
[
  {
    "type": "shadowsocks",
    "tag": "proxy",
    "method": "${SS_METHOD}",
    "password": "${SS_PASSWORD}",
    "detour": "shadowtls-out"
  },
  {
    "type": "shadowtls",
    "tag": "shadowtls-out",
    "server": "${PUBLIC_HOST}",
    "server_port": ${ST_PORT},
    "version": 3,
    "password": "${SHADOWTLS_PASSWORD}",
    "tls": {
      "enabled": true,
      "server_name": "${SHADOWTLS_HANDSHAKE}",
      "utls": {
        "enabled": true,
        "fingerprint": "chrome"
      }
    }
  }
]
EOF

  bold "AnyTLS"
  cat <<EOF
服务器：${PUBLIC_HOST}
端口：${ANYTLS_PORT}
密码：${ANYTLS_PASSWORD}
SNI：${ANYTLS_SNI}
证书：脚本默认生成自签证书，客户端需允许 insecure；如改用正式证书，可替换 ${CERT_FILE} 和 ${KEY_FILE}。

sing-box 客户端出站示例：
{
  "type": "anytls",
  "tag": "proxy",
  "server": "${PUBLIC_HOST}",
  "server_port": ${ANYTLS_PORT},
  "password": "${ANYTLS_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${ANYTLS_SNI}",
    "insecure": true,
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    }
  }
}
EOF

  bold "VLESS Reality"
  cat <<EOF
服务器：${PUBLIC_HOST}
端口：${VLESS_PORT}
UUID：${VLESS_UUID}
Flow：xtls-rprx-vision
Reality public key：${REALITY_PUBLIC_KEY}
Reality short ID：${REALITY_SHORT_ID}
Reality SNI：${REALITY_HANDSHAKE}

VLESS Reality URI：
vless://${VLESS_UUID}@${PUBLIC_HOST}:${VLESS_PORT}?encryption=none&security=reality&sni=${REALITY_HANDSHAKE}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#VLESS-Reality
EOF
}

show_logs() {
  need_root
  if has_cmd journalctl; then
    journalctl -u "$SERVICE_NAME" -n 120 --no-pager
  elif [[ -f "$LOG_FILE" ]]; then
    tail -n 120 "$LOG_FILE"
  else
    yellow "没有找到日志。"
  fi
}

follow_logs() {
  need_root
  if has_cmd journalctl; then
    journalctl -u "$SERVICE_NAME" -f
  else
    tail -f "$LOG_FILE"
  fi
}

rebuild_config() {
  need_root
  load_profile
  collect_config
  generate_cert
  save_profile
  write_config
  check_config
  open_firewall
  restart_service
  show_nodes
}

uninstall_all() {
  need_root
  read -r -p "确认卸载 sing-box 与本脚本配置？输入 YES 继续: " answer
  if [[ "$answer" != "YES" ]]; then
    yellow "已取消卸载。"
    return
  fi

  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$BASE_DIR"
  rm -f "$BIN_FILE" "$MENU_FILE" "$MENU_ALIAS" "$MENU_ALIAS_LONG" "$PROFILE_HINT"
  green "已卸载 sing-box、一键菜单和配置文件。"
}

print_header() {
  clear
  bold "sing-box 一键管理面板"
  printf '配置：%s\n' "$CONFIG_FILE"
  printf '唤出：SSH 登录后输入 menu 或 proxy-menu\n\n'
}

menu_loop() {
  need_root
  while true; do
    print_header
    cat <<'EOF'
1. 安装 / 重新安装三合一配置
2. 查看运行状态
3. 显示节点参数和客户端配置
4. 启动服务
5. 停止服务
6. 重启服务
7. 查看最近日志
8. 实时跟踪日志
9. 修改端口 / SNI / 重建配置
10. 安装或刷新 menu 命令
11. 卸载
0. 退出
EOF
    printf '\n'
    read -r -p "请选择操作: " choice

    case "$choice" in
      1) install_all; pause ;;
      2) show_status; pause ;;
      3) show_nodes; pause ;;
      4) start_service; pause ;;
      5) stop_service; pause ;;
      6) restart_service; pause ;;
      7) show_logs; pause ;;
      8) follow_logs ;;
      9) rebuild_config; pause ;;
      10) install_menu_command; pause ;;
      11) uninstall_all; pause ;;
      0) exit 0 ;;
      *) yellow "无效选择。"; pause ;;
    esac
  done
}

usage() {
  cat <<EOF
用法：
  sudo bash $0              打开交互面板
  sudo bash $0 install      一键安装并生成配置
  sudo bash $0 status       查看运行状态
  sudo bash $0 nodes        显示节点参数
  sudo bash $0 restart      重启服务
  sudo bash $0 logs         查看最近日志

安装后可直接输入：
  menu
  proxy-menu
EOF
}

main() {
  case "${1:-menu}" in
    menu) menu_loop ;;
    install) install_all ;;
    status) need_root; show_status ;;
    nodes) show_nodes ;;
    start) start_service ;;
    stop) stop_service ;;
    restart) restart_service ;;
    logs) show_logs ;;
    follow-logs) follow_logs ;;
    rebuild) rebuild_config ;;
    uninstall) uninstall_all ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
