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
  ENABLE_SHADOWTLS="${ENABLE_SHADOWTLS:-0}"
  ENABLE_ANYTLS="${ENABLE_ANYTLS:-0}"
  ENABLE_VLESS="${ENABLE_VLESS:-0}"
}

save_profile() {
  mkdir -p "$BASE_DIR"
  umask 077
  {
    printf 'ENABLE_SHADOWTLS=%q\n' "${ENABLE_SHADOWTLS:-0}"
    printf 'ENABLE_ANYTLS=%q\n' "${ENABLE_ANYTLS:-0}"
    printf 'ENABLE_VLESS=%q\n' "${ENABLE_VLESS:-0}"
    printf 'PUBLIC_HOST=%q\n' "${PUBLIC_HOST:-}"
    printf 'ST_PORT=%q\n' "${ST_PORT:-}"
    printf 'SS_METHOD=%q\n' "${SS_METHOD:-}"
    printf 'SS_PASSWORD=%q\n' "${SS_PASSWORD:-}"
    printf 'SHADOWTLS_PASSWORD=%q\n' "${SHADOWTLS_PASSWORD:-}"
    printf 'SHADOWTLS_HANDSHAKE=%q\n' "${SHADOWTLS_HANDSHAKE:-}"
    printf 'ANYTLS_PORT=%q\n' "${ANYTLS_PORT:-}"
    printf 'ANYTLS_PASSWORD=%q\n' "${ANYTLS_PASSWORD:-}"
    printf 'ANYTLS_SNI=%q\n' "${ANYTLS_SNI:-}"
    printf 'VLESS_PORT=%q\n' "${VLESS_PORT:-}"
    printf 'VLESS_UUID=%q\n' "${VLESS_UUID:-}"
    printf 'REALITY_PRIVATE_KEY=%q\n' "${REALITY_PRIVATE_KEY:-}"
    printf 'REALITY_PUBLIC_KEY=%q\n' "${REALITY_PUBLIC_KEY:-}"
    printf 'REALITY_SHORT_ID=%q\n' "${REALITY_SHORT_ID:-}"
    printf 'REALITY_HANDSHAKE=%q\n' "${REALITY_HANDSHAKE:-}"
  } > "$META_FILE"
  chmod 600 "$META_FILE"
}

reset_protocol_selection() {
  ENABLE_SHADOWTLS=0
  ENABLE_ANYTLS=0
  ENABLE_VLESS=0
}

enable_protocol_token() {
  local token
  token="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$token" in
    1|ss|ss2022|shadowtls|ss2022-shadowtls|ss2022+shadowtls)
      ENABLE_SHADOWTLS=1
      ;;
    2|anytls|any)
      ENABLE_ANYTLS=1
      ;;
    3|vless|reality|vless-reality|vless+reality)
      ENABLE_VLESS=1
      ;;
    4|all|a|全部)
      ENABLE_SHADOWTLS=1
      ENABLE_ANYTLS=1
      ENABLE_VLESS=1
      ;;
    *)
      red "未知协议选择：$1"
      return 1
      ;;
  esac
}

selection_is_empty() {
  [[ "${ENABLE_SHADOWTLS:-0}" != "1" && "${ENABLE_ANYTLS:-0}" != "1" && "${ENABLE_VLESS:-0}" != "1" ]]
}

choose_protocols() {
  local tokens=("$@")
  local input token

  reset_protocol_selection

  if (( ${#tokens[@]} > 0 )); then
    for token in "${tokens[@]}"; do
      enable_protocol_token "$token"
    done
  else
    cat <<'EOF'
请选择要安装/启用的协议：
1. SS2022 + ShadowTLS
2. AnyTLS
3. VLESS Reality
4. 全部

可输入单个或多个，例如：1 3
EOF
    read -r -p "请输入选择 [4]: " input
    input="${input:-4}"
    for token in $input; do
      enable_protocol_token "$token"
    done
  fi

  if selection_is_empty; then
    red "至少要选择一个协议。"
    exit 1
  fi
}

enabled_protocol_text() {
  local parts=()
  [[ "${ENABLE_SHADOWTLS:-0}" == "1" ]] && parts+=("SS2022+ShadowTLS")
  [[ "${ENABLE_ANYTLS:-0}" == "1" ]] && parts+=("AnyTLS")
  [[ "${ENABLE_VLESS:-0}" == "1" ]] && parts+=("VLESS Reality")
  if (( ${#parts[@]} == 0 )); then
    printf '未选择'
  else
    local joined="${parts[0]}"
    local i
    for (( i = 1; i < ${#parts[@]}; i++ )); do
      joined="${joined} / ${parts[$i]}"
    done
    printf '%s' "$joined"
  fi
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

  local inbounds=()

  if [[ "${ENABLE_SHADOWTLS:-0}" == "1" ]]; then
    inbounds+=("$(cat <<SHADOWTLS_JSON
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
    }
SHADOWTLS_JSON
)")
    inbounds+=("$(cat <<SS_JSON
    {
      "type": "shadowsocks",
      "tag": "ss2022-in",
      "listen": "127.0.0.1",
      "network": "tcp",
      "method": "${SS_METHOD}",
      "password": "${SS_PASSWORD}"
    }
SS_JSON
)")
  fi

  if [[ "${ENABLE_ANYTLS:-0}" == "1" ]]; then
    inbounds+=("$(cat <<ANYTLS_JSON
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
    }
ANYTLS_JSON
)")
  fi

  if [[ "${ENABLE_VLESS:-0}" == "1" ]]; then
    inbounds+=("$(cat <<VLESS_JSON
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
VLESS_JSON
)")
  fi

  if (( ${#inbounds[@]} == 0 )); then
    red "没有选择任何协议，无法生成配置。"
    exit 1
  fi

  {
    cat <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "${LOG_FILE}",
    "timestamp": true
  },
  "inbounds": [
EOF
    local i
    for (( i = 0; i < ${#inbounds[@]}; i++ )); do
      if (( i > 0 )); then
        printf ',\n'
      fi
      printf '%s\n' "${inbounds[$i]}"
    done
    cat <<EOF
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
  } > "$CONFIG_FILE"
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
  local ports=()
  local port

  [[ "${ENABLE_SHADOWTLS:-0}" == "1" ]] && ports+=("$ST_PORT")
  [[ "${ENABLE_ANYTLS:-0}" == "1" ]] && ports+=("$ANYTLS_PORT")
  [[ "${ENABLE_VLESS:-0}" == "1" ]] && ports+=("$VLESS_PORT")

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

port_usage() {
  local port="$1"
  local lines=""

  if has_cmd ss; then
    lines="$(ss -lntp 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" {print}' | grep -v 'sing-box' || true)"
  elif has_cmd netstat; then
    lines="$(netstat -lntp 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" {print}' | grep -v 'sing-box' || true)"
  fi

  printf '%s' "$lines"
}

ensure_port_available() {
  local label="$1"
  local var_name="$2"
  local current usage next

  while true; do
    current="${!var_name}"
    validate_port "$label" "$current"
    usage="$(port_usage "$current")"

    if [[ -z "$usage" ]]; then
      break
    fi

    red "${label} 端口 ${current} 已被占用："
    printf '%s\n' "$usage"
    yellow "请换一个端口，或先停止占用该端口的程序后直接回车重试。"
    read -r -p "新的 ${label} 端口 [${current}]: " next

    if [[ -n "$next" ]]; then
      printf -v "$var_name" '%s' "$next"
    fi
  done
}

collect_config() {
  local detected_host
  detected_host="$(guess_public_host)"

  PUBLIC_HOST="$(safe_read "服务器公网 IP 或域名" "${PUBLIC_HOST:-$detected_host}")"

  if [[ "${ENABLE_SHADOWTLS:-0}" == "1" ]]; then
    ST_PORT="$(safe_read "SS2022 + ShadowTLS 监听端口" "${ST_PORT:-$DEFAULT_ST_PORT}")"
    SHADOWTLS_HANDSHAKE="$(safe_read "ShadowTLS 握手伪装域名" "${SHADOWTLS_HANDSHAKE:-$DEFAULT_HANDSHAKE}")"
    ensure_port_available "ShadowTLS" ST_PORT
    SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"
    SS_PASSWORD="${SS_PASSWORD:-$(rand_base64 16)}"
    SHADOWTLS_PASSWORD="${SHADOWTLS_PASSWORD:-$(rand_base64 24)}"
  fi

  if [[ "${ENABLE_ANYTLS:-0}" == "1" ]]; then
    ANYTLS_PORT="$(safe_read "AnyTLS 监听端口" "${ANYTLS_PORT:-$DEFAULT_ANYTLS_PORT}")"
    ANYTLS_SNI="$(safe_read "AnyTLS 证书/SNI 名称" "${ANYTLS_SNI:-$DEFAULT_ANYTLS_SNI}")"
    ensure_port_available "AnyTLS" ANYTLS_PORT
    ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-$(rand_base64 24)}"
  fi

  if [[ "${ENABLE_VLESS:-0}" == "1" ]]; then
    VLESS_PORT="$(safe_read "VLESS Reality 监听端口" "${VLESS_PORT:-$DEFAULT_VLESS_PORT}")"
    REALITY_HANDSHAKE="$(safe_read "Reality 握手伪装域名" "${REALITY_HANDSHAKE:-$DEFAULT_REALITY_HANDSHAKE}")"
    ensure_port_available "VLESS Reality" VLESS_PORT
    VLESS_UUID="${VLESS_UUID:-$(make_uuid)}"
    REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(rand_hex 8)}"
  fi

  if [[ "${ENABLE_VLESS:-0}" == "1" && ( -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ) ]]; then
    make_reality_keys
  fi

  check_port_conflicts
}

check_port_conflicts() {
  local used=()
  [[ "${ENABLE_SHADOWTLS:-0}" == "1" ]] && used+=("ShadowTLS:${ST_PORT}")
  [[ "${ENABLE_ANYTLS:-0}" == "1" ]] && used+=("AnyTLS:${ANYTLS_PORT}")
  [[ "${ENABLE_VLESS:-0}" == "1" ]] && used+=("VLESS Reality:${VLESS_PORT}")

  local i j left right
  for (( i = 0; i < ${#used[@]}; i++ )); do
    for (( j = i + 1; j < ${#used[@]}; j++ )); do
      left="${used[$i]}"
      right="${used[$j]}"
      if [[ "${left#*:}" == "${right#*:}" ]]; then
        red "端口冲突：${left%:*} 和 ${right%:*} 都使用 ${left#*:}"
        exit 1
      fi
    done
  done
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
  choose_protocols "$@"
  install_sing_box
  collect_config
  [[ "${ENABLE_ANYTLS:-0}" == "1" ]] && generate_cert
  save_profile
  write_config
  check_config
  write_service
  open_firewall
  install_menu_command
  systemctl enable --now "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
  green "安装完成。当前启用：$(enabled_protocol_text)"
  green "SSH 登录后输入 menu 即可唤出面板。"
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
  local patterns=()
  [[ "${ENABLE_SHADOWTLS:-0}" == "1" && -n "${ST_PORT:-}" ]] && patterns+=(":${ST_PORT}")
  [[ "${ENABLE_ANYTLS:-0}" == "1" && -n "${ANYTLS_PORT:-}" ]] && patterns+=(":${ANYTLS_PORT}")
  [[ "${ENABLE_VLESS:-0}" == "1" && -n "${VLESS_PORT:-}" ]] && patterns+=(":${VLESS_PORT}")

  if (( ${#patterns[@]} == 0 )); then
    yellow "没有已启用协议的端口记录。"
    return
  fi

  local joined="${patterns[0]}"
  local i
  for (( i = 1; i < ${#patterns[@]}; i++ )); do
    joined="${joined}|${patterns[$i]}"
  done
  if has_cmd ss; then
    ss -lntp 2>/dev/null | grep -E "(${joined})" || true
  elif has_cmd netstat; then
    netstat -lntp 2>/dev/null | grep -E "(${joined})" || true
  fi
}

show_status() {
  load_profile
  bold "运行状态"
  printf '当前启用：%s\n' "$(enabled_protocol_text)"

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

  bold "监听端口"
  show_ports

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

  bold "当前启用"
  enabled_protocol_text
  printf '\n'

  bold "Mihomo proxies 配置"
  cat <<'EOF'
proxies:
EOF

  if [[ "${ENABLE_SHADOWTLS:-0}" == "1" ]]; then
    cat <<EOF
  - name: SS2022-ShadowTLS
    type: ss
    server: ${PUBLIC_HOST}
    port: ${ST_PORT}
    cipher: ${SS_METHOD}
    password: ${SS_PASSWORD}
    udp: true
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      host: ${SHADOWTLS_HANDSHAKE}
      password: ${SHADOWTLS_PASSWORD}
      version: 3
EOF
  fi

  if [[ "${ENABLE_ANYTLS:-0}" == "1" ]]; then
    cat <<EOF
  - name: AnyTLS
    type: anytls
    server: ${PUBLIC_HOST}
    port: ${ANYTLS_PORT}
    password: ${ANYTLS_PASSWORD}
    sni: ${ANYTLS_SNI}
    udp: true
    skip-cert-verify: true
    client-fingerprint: chrome
EOF
  fi

  if [[ "${ENABLE_VLESS:-0}" == "1" ]]; then
    cat <<EOF
  - name: VLESS-Reality
    type: vless
    server: ${PUBLIC_HOST}
    port: ${VLESS_PORT}
    uuid: ${VLESS_UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_HANDSHAKE}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT_ID}
EOF
  fi

  if [[ "${ENABLE_VLESS:-0}" == "1" ]]; then
    bold "VLESS Reality URI"
    cat <<EOF
VLESS Reality URI：
vless://${VLESS_UUID}@${PUBLIC_HOST}:${VLESS_PORT}?encryption=none&security=reality&sni=${REALITY_HANDSHAKE}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#VLESS-Reality
EOF
  fi

  if [[ "${ENABLE_ANYTLS:-0}" == "1" ]]; then
    yellow "AnyTLS 使用自签证书时已输出 skip-cert-verify: true；如果你换正式证书，可以改成 false。"
  fi
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
  printf '当前启用：%s\n' "$(enabled_protocol_text)"
  choose_protocols "$@"
  collect_config
  [[ "${ENABLE_ANYTLS:-0}" == "1" ]] && generate_cert
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
1. 安装 / 重新安装（可单独选择协议）
2. 查看运行状态
3. 显示节点参数和客户端配置
4. 启动服务
5. 停止服务
6. 重启服务
7. 查看最近日志
8. 实时跟踪日志
9. 修改协议选择 / 端口 / SNI / 重建配置
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
  sudo bash $0 install      进入选择并安装
  sudo bash $0 install all  安装全部协议
  sudo bash $0 install ss2022-shadowtls
  sudo bash $0 install anytls
  sudo bash $0 install vless-reality
  sudo bash $0 install 1 3  安装 SS2022+ShadowTLS 和 VLESS Reality
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
    install) shift; install_all "$@" ;;
    status) need_root; show_status ;;
    nodes) show_nodes ;;
    start) start_service ;;
    stop) stop_service ;;
    restart) restart_service ;;
    logs) show_logs ;;
    follow-logs) follow_logs ;;
    rebuild) shift; rebuild_config "$@" ;;
    uninstall) uninstall_all ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
