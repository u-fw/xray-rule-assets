#!/usr/bin/env bash
# freedom.sh v9.10-final
# VLESS + REALITY 自动配置脚本
# - 手动选择 Xray-core / sing-box
# - 未安装所选内核时，可使用官方安装脚本安装
# - Xray-core: xray x25519 / uuid / vlessenc / mldsa65 / run -test
# - sing-box: sing-box generate reality-keypair / generate uuid / generate rand --hex 8 / check
# - CN/private 阻断默认启用；Xray/sing-box 均采用 geolocation-!cn 优先放行，再阻断 CN/private
# - 二维码默认不生成，最后按需生成，避免长链接导致 qrencode 报错
# - 启动前检测端口占用；如果被另一内核占用，可交互停止对应服务
# - 写入配置前自动备份；检查/启动失败时可交互恢复备份
# - 隐藏服务端私钥等敏感输出；公网 IP 优先使用 api.ip.sb/ip
# - 端口占用报错会明确显示进程名、PID 与监听地址
# - ML-DSA pqv 链接参数做 URL 编码；自动补齐 ss/iproute2 端口检测依赖

set -Eeuo pipefail

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

export PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

SCRIPT_VERSION="v9.10-final"
DEFAULT_SNI="v1-dy.ixigua.com"
DEFAULT_PORT="443"
DEFAULT_NODE_NAME="Premium-Node"

KERNEL=""
BIN=""
SERVICE_NAME=""
CONFIG_PATH=""
CONFIG_DIR=""

PORT=""
SNI=""
SERVER_IP=""
SERVER_HOST_FOR_LINK=""
UUID=""
SHORT_ID=""
REALITY_PRIV=""
REALITY_PUB=""
VLESS_DEC="none"
VLESS_ENC="none"
MLDSA_SEED=""
MLDSA_VERIFY=""
MLDSA_LINK_PARAM=""
BLOCK_CN="true"
NODE_NAME=""
BACKUP_FILE=""

info() { echo -e "${CYAN}[INFO] $*${NC}"; }
ok() { echo -e "${GREEN}[OK] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
fatal() { echo -e "${RED}[ERROR] $*${NC}" >&2; exit 1; }

ensure_systemd_available() {
  command -v systemctl >/dev/null 2>&1 || fatal "未找到 systemctl；此脚本需要 systemd 管理 xray/sing-box 服务。"
  if ! systemctl list-units --type=service >/dev/null 2>&1; then
    fatal "当前环境无法使用 systemd。若在容器内运行，请改用支持 systemd 的 VPS/宿主机环境。"
  fi
}

redact_sensitive_text() {
  # 仅用于错误诊断输出，避免在终端直接暴露服务端私钥/种子。
  sed -E \
    -e 's/^([[:space:]]*(PrivateKey|Private key|Private)[^:]*:[[:space:]]*).*/\1<redacted>/I' \
    -e 's/^([[:space:]]*(Seed)[^:]*:[[:space:]]*).*/\1<redacted>/I' \
    -e 's/("decryption"[[:space:]]*:[[:space:]]*")[^"]+"/\1<redacted>"/I'
}

service_unit_exists() {
  local svc="$1"
  systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service" \
    || systemctl list-units --all --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"
}

print_service_diagnostics() {
  local svc="$1"
  warn "${svc}.service 状态："
  systemctl status "$svc" --no-pager -l >&2 || true
  warn "${svc}.service 最近日志："
  journalctl -u "$svc" -n 80 --no-pager >&2 || true
}

restore_backup() {
  [[ -n "${BACKUP_FILE:-}" && -f "$BACKUP_FILE" ]] || return 1
  cp -a "$BACKUP_FILE" "$CONFIG_PATH"
  chmod 644 "$CONFIG_PATH" 2>/dev/null || true
  ok "已恢复备份配置：$BACKUP_FILE -> $CONFIG_PATH"

  if service_unit_exists "$SERVICE_NAME"; then
    info "尝试重启 ${SERVICE_NAME}.service 以恢复旧配置"
    if systemctl restart "$SERVICE_NAME"; then
      sleep 2
      if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "${SERVICE_NAME}.service 已恢复运行。"
      else
        warn "${SERVICE_NAME}.service 重启后仍未处于 active 状态。"
        print_service_diagnostics "$SERVICE_NAME"
      fi
    else
      warn "恢复备份后重启 ${SERVICE_NAME}.service 失败。"
      print_service_diagnostics "$SERVICE_NAME"
    fi
  fi
}

fatal_with_rollback() {
  local msg="$1"
  local ans=""
  if [[ -n "${BACKUP_FILE:-}" && -f "$BACKUP_FILE" ]]; then
    warn "$msg"
    read -r -p "是否恢复本次备份配置？[y/N]: " ans
    case "${ans:-N}" in
      y|Y|yes|YES) restore_backup || warn "恢复备份失败，请手动检查：$BACKUP_FILE" ;;
      *) warn "已保留当前新配置。备份位置：$BACKUP_FILE" ;;
    esac
  fi
  fatal "$msg"
}

need_root() {
  [[ "$(id -u)" == "0" ]] || fatal "请使用 root 运行：sudo bash $0"
}

install_packages() {
  local pkgs=("$@")
  ((${#pkgs[@]} > 0)) || return 0

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}" >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}" >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${pkgs[@]}" >/dev/null
  else
    fatal "找不到支持的包管理器，请手动安装：${pkgs[*]}"
  fi
}

install_port_detection_dep() {
  # 端口占用检测优先依赖 ss。极简系统可能没有 ss，这里按发行版补齐。
  command -v ss >/dev/null 2>&1 && return 0
  command -v lsof >/dev/null 2>&1 && return 0
  command -v netstat >/dev/null 2>&1 && return 0

  info "安装端口检测依赖：ss"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y iproute >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y iproute >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache iproute2 >/dev/null
  else
    warn "找不到支持的包管理器，无法自动安装 ss；端口检测将尽力使用已有工具。"
  fi

  if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
    warn "未找到 ss/lsof/netstat，端口占用预检查可能无法执行。"
  fi
}

install_base_deps() {
  local missing=()
  for c in curl jq openssl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done

  if ((${#missing[@]} > 0)); then
    info "安装基础依赖：${missing[*]}"
    install_packages "${missing[@]}"
  fi

  install_port_detection_dep
}

sync_time_best_effort() {
  timedatectl set-ntp true >/dev/null 2>&1 || true
  if command -v ntpdate >/dev/null 2>&1; then
    ntpdate -u pool.ntp.org >/dev/null 2>&1 || true
  fi
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535))
}

sanitize_sni() {
  local v="$1"
  v="${v#http://}"
  v="${v#https://}"
  v="${v%%/*}"
  v="${v%%:*}"
  echo "$v"
}

field_after_colon() {
  # 用法：field_after_colon "文本" "PrivateKey|Password|PublicKey"
  # 兼容：
  #   PrivateKey: xxx
  #   Password (PublicKey): xxx
  #   PublicKey: xxx
  #   Private key: xxx
  local text="$1"
  local pattern="$2"
  printf '%s\n' "$text" | awk -v pat="$pattern" '
    BEGIN {
      n = split(pat, names, /\|/)
      for (i = 1; i <= n; i++) {
        want[i] = tolower(names[i])
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", want[i])
      }
    }
    index($0, ":") {
      line = $0
      key = line
      sub(/:.*/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)

      key_no_paren = key
      sub(/[[:space:]]*\(.*/, "", key_no_paren)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key_no_paren)

      key_l = tolower(key)
      key_np_l = tolower(key_no_paren)

      val = line
      sub(/^[^:]*:[[:space:]]*/, "", val)
      gsub(/[[:space:]\r\n\"]/, "", val)

      for (i = 1; i <= n; i++) {
        if (key_l == want[i] || key_np_l == want[i] || index(key_l, want[i]) == 1) {
          if (val != "") {
            print val
            exit
          }
        }
      }
    }
  '
}

extract_vlessenc_value() {
  # 用法：extract_vlessenc_value "文本" "ML-KEM-768" "decryption"
  local text="$1"
  local alg="$2"
  local key="$3"
  printf '%s\n' "$text" | awk -v alg="$alg" -v key="$key" '
    index($0, alg) { f = 1 }
    f && $0 ~ "\\\"" key "\\\"[[:space:]]*:" {
      line = $0
      sub(".*\\\"" key "\\\"[[:space:]]*:[[:space:]]*\\\"", "", line)
      while (line !~ /\"/) {
        if ((getline more) <= 0) break
        line = line more
      }
      sub("\\\".*", "", line)
      gsub(/[[:space:]\r\n,]/, "", line)
      print line
      exit
    }
  '
}

url_encode() {
  # URL encode for VLESS URI fragment/query values.
  jq -rn --arg v "$1"  '$v|@uri'
}

url_host() {
  local h="$1"
  if [[ "$h" == *:* && "$h" != \[*\] ]]; then
    echo "[$h]"
  else
    echo "$h"
  fi
}

get_public_ip() {
  local ip=""
  # 优先使用 ip.sb；失败时多源兜底。
  for endpoint in \
    "https://api.ip.sb/ip" \
    "https://api.ipify.org" \
    "https://ifconfig.me" \
    "https://ipv4.icanhazip.com"; do
    ip="$(curl -fsS4 --max-time 6 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$ip" ]] && break
  done
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "$ip"
}

port_listener_summary() {
  # 输出当前 TCP LISTEN 占用者，格式尽量统一为：进程名 pid=PID 地址。
  # 优先使用 ss；没有 ss 时兜底 lsof/netstat。
  local port="$1"
  local lines=""

  if command -v ss >/dev/null 2>&1; then
    lines="$(ss -H -ltnp "sport = :${port}" 2>/dev/null || true)"
    if [[ -n "$lines" ]]; then
      printf '%s\n' "$lines" | awk '
        {
          line = $0
          found = 0
          while (match(line, /"[^"]+",pid=[0-9]+/)) {
            s = substr(line, RSTART, RLENGTH)
            name = s
            sub(/^"/, "", name)
            sub(/",pid=.*/, "", name)
            pid = s
            sub(/.*pid=/, "", pid)
            print name " pid=" pid " listen=" $4
            line = substr(line, RSTART + RLENGTH)
            found = 1
          }
          if (!found) print "unknown " $0
        }
      ' | sort -u
    fi
    return 0
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1 " pid=" $2 " " $9}' | sort -u
    return 0
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print $7 " " $4}' | sort -u
    return 0
  fi

  return 1
}

service_exists() {
  service_unit_exists "$1"
}

stop_service_and_recheck_port() {
  local svc="$1"
  local port="$2"
  local after=""

  if ! service_exists "$svc"; then
    fatal "检测到端口可能被 ${svc} 占用，但未找到 ${svc}.service；请手动处理后重试。"
  fi

  systemctl stop "$svc"
  sleep 1

  after="$(port_listener_summary "$port" || true)"
  if [[ -n "$after" ]]; then
    warn "停止 ${svc}.service 后，端口 ${port} 仍被占用："
    printf '%s\n' "$after" | sed 's/^/  - /'
    fatal "端口 ${port} 仍未释放，请手动检查。"
  fi

  ok "已停止 ${svc}.service，端口 ${port} 已释放。"
}

check_port_available_or_handle() {
  # 两个内核都走这里：选 xray 检查 xray 端口，选 sing-box 检查 sing-box 端口。
  # 如果端口只被当前选择的服务占用，则允许继续，因为 systemctl restart 会重载本服务。
  # 如果端口被另一内核占用，明确告知占用者，并询问是否停止对应服务。
  local owners=""
  local names=""
  local non_current=""
  local opposite=""
  local ans=""

  if ! owners="$(port_listener_summary "$PORT")"; then
    warn "未找到 ss/lsof/netstat，跳过端口占用预检查。"
    return 0
  fi

  [[ -z "$owners" ]] && return 0

  warn "检测到 TCP 端口 ${PORT} 已被占用："
  printf '%s\n' "$owners" | sed 's/^/  - /'

  names="$(printf '%s\n' "$owners" | awk '{print $1}' | sed 's#^.*/##' | sort -u)"
  non_current="$(printf '%s\n' "$names" | grep -vxF "$SERVICE_NAME" || true)"

  if [[ -z "$non_current" ]]; then
    warn "端口 ${PORT} 当前由本次选择的 ${SERVICE_NAME} 占用；后续重启会重载本服务，继续。"
    return 0
  fi

  if [[ "$KERNEL" == "xray" ]] && printf '%s\n' "$names" | grep -qxF "sing-box"; then
    opposite="sing-box"
  elif [[ "$KERNEL" == "sing-box" ]] && printf '%s\n' "$names" | grep -qxF "xray"; then
    opposite="xray"
  fi

  if [[ -n "$opposite" ]]; then
    warn "你选择的是 ${KERNEL}，但端口 ${PORT} 被 ${opposite} 占用。"
    read -r -p "是否停止 ${opposite}.service 释放端口 ${PORT}？[y/N]: " ans
    case "${ans:-N}" in
      y|Y|yes|YES)
        stop_service_and_recheck_port "$opposite" "$PORT"
        return 0
        ;;
      *)
        fatal "端口 ${PORT} 未释放。请换端口，或手动停止 ${opposite}.service 后重试。"
        ;;
    esac
  fi

  local owner_oneline=""
  owner_oneline="$(printf '%s\n' "$owners" | awk 'BEGIN{first=1} { if (!first) printf "; "; printf "%s", $0; first=0 }')"
  fatal "端口 ${PORT} 被非当前服务占用：${owner_oneline}。请换端口，或手动停止占用进程后重试。"
}

install_xray_official() {
  info "使用 XTLS 官方 Xray-install 安装/更新 Xray-core"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  command -v xray >/dev/null 2>&1 || fatal "Xray 安装后仍未找到 xray 命令"
  systemctl enable xray >/dev/null 2>&1 || true
}

install_singbox_official() {
  info "使用 sing-box 官方 install.sh 安装/更新 sing-box"
  curl -fsSL https://sing-box.app/install.sh | sh
  command -v sing-box >/dev/null 2>&1 || fatal "sing-box 安装后仍未找到 sing-box 命令"
  systemctl enable sing-box >/dev/null 2>&1 || true
}

ensure_selected_kernel_installed() {
  case "$KERNEL" in
    xray)
      if ! command -v xray >/dev/null 2>&1; then
        warn "未找到 xray。"
        read -r -p "是否使用 XTLS 官方脚本安装 Xray-core？[Y/n]: " ans
        case "${ans:-Y}" in
          n|N|no|NO) fatal "已取消安装，退出。" ;;
          *) install_xray_official ;;
        esac
      fi
      BIN="$(command -v xray)"
      SERVICE_NAME="xray"
      CONFIG_DIR="/usr/local/etc/xray"
      CONFIG_PATH="$CONFIG_DIR/config.json"
      ;;
    sing-box)
      if ! command -v sing-box >/dev/null 2>&1; then
        warn "未找到 sing-box。"
        read -r -p "是否使用 sing-box 官方脚本安装 sing-box？[Y/n]: " ans
        case "${ans:-Y}" in
          n|N|no|NO) fatal "已取消安装，退出。" ;;
          *) install_singbox_official ;;
        esac
      fi
      BIN="$(command -v sing-box)"
      SERVICE_NAME="sing-box"
      CONFIG_DIR="/etc/sing-box"
      CONFIG_PATH="$CONFIG_DIR/config.json"
      ;;
    *) fatal "内部错误：未知内核 $KERNEL" ;;
  esac
}

choose_kernel() {
  echo
  echo "请选择要部署的内核："
  echo "1) Xray-core"
  echo "2) sing-box"
  while true; do
    read -r -p "内核选择 [1/2，默认 1]: " ksel
    ksel="${ksel:-1}"
    case "$ksel" in
      1) KERNEL="xray"; break ;;
      2) KERNEL="sing-box"; break ;;
      *) warn "请输入 1 或 2。" ;;
    esac
  done
  ensure_selected_kernel_installed
}

read_common_inputs() {
  clear || true
  ok "VLESS-REALITY 自动化构建 ${SCRIPT_VERSION}"
  info "当前内核：${KERNEL} (${BIN})"

  while true; do
    read -r -p "监听端口 (默认 ${DEFAULT_PORT}): " PORT
    PORT="${PORT:-$DEFAULT_PORT}"
    valid_port "$PORT" && break
    warn "端口无效，请输入 1-65535。"
  done

  read -r -p "伪装域名/SNI (默认 ${DEFAULT_SNI}): " SNI
  SNI="$(sanitize_sni "${SNI:-$DEFAULT_SNI}")"
  [[ -n "$SNI" ]] || fatal "SNI 不能为空"
  read -r -p "节点名称 (默认 ${DEFAULT_NODE_NAME}): " NODE_NAME
  NODE_NAME="${NODE_NAME:-$DEFAULT_NODE_NAME}"

  BLOCK_CN="true"
  info "CN/private 阻断路由：已默认启用。"

  SERVER_IP="$(get_public_ip)"
  if [[ -z "$SERVER_IP" ]]; then
    read -r -p "未能自动获取公网 IP，请手动输入服务器地址/IP: " SERVER_IP
  fi
  [[ -n "$SERVER_IP" ]] || fatal "服务器地址/IP 不能为空"
  SERVER_HOST_FOR_LINK="$(url_host "$SERVER_IP")"
}

gen_uuid() {
  if [[ "$KERNEL" == "xray" ]]; then
    "$BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
  else
    "$BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
  fi
}

gen_short_id() {
  if [[ "$KERNEL" == "sing-box" ]]; then
    "$BIN" generate rand --hex 8 2>/dev/null | tr -d '[:space:]' || openssl rand -hex 8 | tr -d '[:space:]'
  else
    openssl rand -hex 8 | tr -d '[:space:]'
  fi
}

gen_reality_keys_xray() {
  info "生成 Xray REALITY X25519 密钥"
  local out
  out="$($BIN x25519 2>&1)" || { printf '%s\n' "$out" | redact_sensitive_text; fatal "xray x25519 执行失败"; }

  REALITY_PRIV="$(field_after_colon "$out" "PrivateKey|Private key|Private")"
  REALITY_PUB="$(field_after_colon "$out" "Password|PublicKey|Public key|Public")"

  # 兜底：兼容 Password (PublicKey): xxx。
  if [[ -z "$REALITY_PUB" ]]; then
    REALITY_PUB="$(printf '%s\n' "$out" | grep -Ei '^\s*Password(\s*\([^)]*\))?\s*:' | head -n1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]\r\n\"' || true)"
  fi

  [[ -n "$REALITY_PRIV" ]] || { printf '%s\n' "$out" | redact_sensitive_text; fatal "未能提取 Xray PrivateKey"; }
  [[ -n "$REALITY_PUB" ]] || { printf '%s\n' "$out" | redact_sensitive_text; fatal "未能提取 Xray Password/PublicKey，不能生成 pbk"; }
  [[ "$REALITY_PRIV" != *Private* && "$REALITY_PRIV" != *Password* ]] || fatal "Xray 私钥提取异常"
  ok "REALITY private key generated."
  ok "REALITY pbk：$REALITY_PUB"
}

gen_reality_keys_singbox() {
  info "生成 sing-box REALITY 密钥"
  local out
  out="$($BIN generate reality-keypair 2>&1)" || { printf '%s\n' "$out" | redact_sensitive_text; fatal "sing-box generate reality-keypair 执行失败"; }

  REALITY_PRIV="$(field_after_colon "$out" "PrivateKey|Private key|Private")"
  REALITY_PUB="$(field_after_colon "$out" "PublicKey|Public key|Public")"

  [[ -n "$REALITY_PRIV" ]] || { printf '%s\n' "$out" | redact_sensitive_text; fatal "未能提取 sing-box PrivateKey"; }
  [[ -n "$REALITY_PUB" ]] || { printf '%s\n' "$out" | redact_sensitive_text; fatal "未能提取 sing-box PublicKey，不能生成 pbk"; }
  ok "REALITY private key generated."
  ok "REALITY pbk：$REALITY_PUB"
}

gen_xray_vless_encryption() {
  echo
  echo "Xray VLESS Encryption："
  echo "1) none，兼容性最好"
  echo "2) X25519，由 xray vlessenc 生成"
  echo "3) ML-KEM-768，由 xray vlessenc 生成"
  read -r -p "选择加密 [默认 3]: " enc_choice
  enc_choice="${enc_choice:-3}"

  VLESS_DEC="none"
  VLESS_ENC="none"

  if [[ "$enc_choice" == "1" ]]; then
    return 0
  fi

  local out alg
  out="$($BIN vlessenc 2>&1)" || { printf '%s\n' "$out" | redact_sensitive_text; fatal "xray vlessenc 执行失败。当前 Xray 可能过旧，请升级。"; }

  if [[ "$enc_choice" == "2" ]]; then
    alg="X25519"
  elif [[ "$enc_choice" == "3" ]]; then
    alg="ML-KEM-768"
  else
    fatal "加密选项无效，只能选择 1、2 或 3。"
  fi

  VLESS_DEC="$(extract_vlessenc_value "$out" "$alg" "decryption")"
  VLESS_ENC="$(extract_vlessenc_value "$out" "$alg" "encryption")"

  [[ -n "$VLESS_DEC" && -n "$VLESS_ENC" ]] || {
    printf '%s\n' "$out" | redact_sensitive_text
    fatal "未能从 xray vlessenc 输出中提取 ${alg} 的 decryption/encryption"
  }
  ok "Xray VLESS Encryption：${alg}"
}

gen_xray_mldsa_optional() {
  echo
  echo "REALITY ML-DSA-65 额外签名："
  warn "开启后分享链接会明显变长；部分客户端或二维码工具可能处理失败。不确定时建议关闭。"
  read -r -p "是否开启 ML-DSA-65？[y/N]: " ans
  case "${ans:-N}" in
    y|Y|yes|YES) ;;
    *) return 0 ;;
  esac

  local out
  out="$($BIN mldsa65 2>&1)" || { printf '%s\n' "$out" | redact_sensitive_text; fatal "xray mldsa65 执行失败。当前 Xray 可能过旧，请升级。"; }

  MLDSA_SEED="$(field_after_colon "$out" "Seed")"
  MLDSA_VERIFY="$(printf '%s\n' "$out" | sed -n '/^[[:space:]]*Verify[[:space:]]*:/,$p' | sed '1s/^[^:]*:[[:space:]]*//' | tr -d '\n\r[:space:]')"

  [[ -n "$MLDSA_SEED" && -n "$MLDSA_VERIFY" ]] || { printf '%s\n' "$out" | redact_sensitive_text; fatal "未能提取 mldsa65 Seed/Verify"; }
  MLDSA_LINK_PARAM="&pqv=$(url_encode "$MLDSA_VERIFY")"
  ok "ML-DSA-65 已启用；Verify 长度：${#MLDSA_VERIFY}"
}

generate_assets() {
  UUID="$(gen_uuid | tr -d '[:space:]')"
  SHORT_ID="$(gen_short_id)"
  [[ -n "$UUID" && -n "$SHORT_ID" ]] || fatal "UUID 或 shortId 生成失败"

  if [[ "$KERNEL" == "xray" ]]; then
    gen_reality_keys_xray
    gen_xray_vless_encryption
    gen_xray_mldsa_optional
  else
    gen_reality_keys_singbox
    info "sing-box 使用标准 VLESS Reality Vision，已跳过 Xray vlessenc / ML-DSA 参数。"
    VLESS_DEC="none"
    VLESS_ENC="none"
    MLDSA_LINK_PARAM=""
  fi
}

backup_existing_config() {
  install -d -m 755 "$CONFIG_DIR"
  BACKUP_FILE=""
  if [[ -f "$CONFIG_PATH" ]]; then
    BACKUP_FILE="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$CONFIG_PATH" "$BACKUP_FILE"
    warn "已备份旧配置：$BACKUP_FILE"

    # 只保留最新 5 个备份，避免长期堆积。
    ls -1t "${CONFIG_PATH}".bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f || true
  fi
}

write_xray_config() {
  # 路由策略：
  # 1. 默认 outbound 为 direct。
  # 2. 先显式放行 geosite:geolocation-!cn，避免外站服务被 geosite:cn 误伤。
  # 3. 再阻断 CN 域名、CN IP 和私网 IP。
  # 4. 不再使用 !geoip:cn / !geoip:private 反选放行；默认 direct 已经足够。
  # 5. domainStrategy 保持 AsIs，避免服务端额外解析域名后误命中 IP 规则。
  local rules_json='[
    {"type":"field","domain":["geosite:geolocation-!cn"],"outboundTag":"direct"},
    {"type":"field","domain":["geosite:cn"],"outboundTag":"block"},
    {"type":"field","ip":["geoip:private","geoip:cn"],"outboundTag":"block"}
  ]'

  jq -n \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg vdec "$VLESS_DEC" \
    --arg sni "$SNI" \
    --arg private_key "$REALITY_PRIV" \
    --arg short_id "$SHORT_ID" \
    --arg mldsa_seed "$MLDSA_SEED" \
    --argjson rules "$rules_json" \
    '
    {
      log: { loglevel: "warning" },
      inbounds: [
        {
          port: $port,
          protocol: "vless",
          settings: {
            clients: [ { id: $uuid, flow: "xtls-rprx-vision" } ],
            decryption: $vdec
          },
          streamSettings: {
            network: "tcp",
            security: "reality",
            realitySettings: (
              {
                show: false,
                target: ($sni + ":443"),
                xver: 0,
                serverNames: [ $sni ],
                privateKey: $private_key,
                shortIds: [ $short_id ],
                maxTimeDiff: 60000
              }
              + (if $mldsa_seed != "" then { mldsa65Seed: $mldsa_seed } else {} end)
            )
          },
          sniffing: {
            enabled: true,
            destOverride: ["http", "tls", "quic"],
            routeOnly: true
          }
        }
      ],
      outbounds: [
        { protocol: "freedom", tag: "direct" },
        { protocol: "blackhole", tag: "block" }
      ],
      routing: {
        domainStrategy: "AsIs",
        rules: $rules
      }
    }' > "$CONFIG_PATH"
}

write_singbox_config() {
  # sing-box 使用 rule_set。路由顺序与 Xray 对齐：geolocation-!cn 先放行，再阻断 CN/private。
  local route_set_json='[
    {
      "type": "remote",
      "tag": "geosite-geolocation-!cn",
      "format": "binary",
      "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
      "download_detour": "direct",
      "update_interval": "1d"
    },
    {
      "type": "remote",
      "tag": "geosite-cn",
      "format": "binary",
      "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
      "download_detour": "direct",
      "update_interval": "1d"
    },
    {
      "type": "remote",
      "tag": "geoip-cn",
      "format": "binary",
      "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
      "download_detour": "direct",
      "update_interval": "1d"
    }
  ]'

  local rules_json='[
    {"rule_set": "geosite-geolocation-!cn", "outbound": "direct"},
    {"ip_is_private": true, "outbound": "block"},
    {"rule_set": "geosite-cn", "outbound": "block"},
    {"rule_set": "geoip-cn", "outbound": "block"}
  ]'

  jq -n \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg sni "$SNI" \
    --arg private_key "$REALITY_PRIV" \
    --arg short_id "$SHORT_ID" \
    --argjson route_set "$route_set_json" \
    --argjson rules "$rules_json" \
    '
    {
      log: { level: "warn", timestamp: true },
      inbounds: [
        {
          type: "vless",
          tag: "vless-in",
          listen: "::",
          listen_port: $port,
          users: [ { uuid: $uuid, flow: "xtls-rprx-vision" } ],
          tls: {
            enabled: true,
            server_name: $sni,
            reality: {
              enabled: true,
              handshake: { server: $sni, server_port: 443 },
              private_key: $private_key,
              short_id: [ $short_id ],
              max_time_difference: "1m"
            }
          }
        }
      ],
      outbounds: [
        { type: "direct", tag: "direct" },
        { type: "block", tag: "block" }
      ],
      route: {
        auto_detect_interface: true,
        rule_set: $route_set,
        rules: $rules,
        final: "direct"
      },
      experimental: {
        cache_file: { enabled: true }
      }
    }' > "$CONFIG_PATH"
}

validate_config() {
  info "检查配置文件"
  jq empty "$CONFIG_PATH" || fatal_with_rollback "JSON 语法错误：$CONFIG_PATH"

  if [[ "$KERNEL" == "xray" ]]; then
    if ! "$BIN" run -test -c "$CONFIG_PATH" >/tmp/freedom-xray-test.log 2>&1; then
      if ! "$BIN" -test -config "$CONFIG_PATH" >/tmp/freedom-xray-test.log 2>&1; then
        cat /tmp/freedom-xray-test.log >&2
        fatal_with_rollback "Xray 配置测试失败"
      fi
    fi
  else
    "$BIN" check -c "$CONFIG_PATH" >/tmp/freedom-singbox-check.log 2>&1 || {
      cat /tmp/freedom-singbox-check.log >&2
      fatal_with_rollback "sing-box 配置测试失败"
    }
  fi
}

restart_service() {
  info "重启服务：$SERVICE_NAME"

  if ! service_unit_exists "$SERVICE_NAME"; then
    warn "没找到 systemd 服务 ${SERVICE_NAME}.service，仅已写入配置：$CONFIG_PATH"
    return 0
  fi

  if ! systemctl restart "$SERVICE_NAME"; then
    print_service_diagnostics "$SERVICE_NAME"
    fatal_with_rollback "${SERVICE_NAME} 重启命令执行失败"
  fi

  sleep 2
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    print_service_diagnostics "$SERVICE_NAME"
    fatal_with_rollback "${SERVICE_NAME} 启动失败"
  fi
}

build_link() {
  local link encoded_name
  encoded_name="$(url_encode "$NODE_NAME")"
  link="vless://${UUID}@${SERVER_HOST_FOR_LINK}:${PORT}?type=tcp&security=reality&pbk=${REALITY_PUB}${MLDSA_LINK_PARAM}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision&encryption=${VLESS_ENC}#${encoded_name}"
  echo "$link"
}

print_result() {
  local link="$1"
  echo
  ok "构建完成"
  info "内核：${KERNEL}"
  info "配置：${CONFIG_PATH}"
  info "UUID：${UUID}"
  info "SNI：${SNI}"
  info "shortId：${SHORT_ID}"
  info "节点名称：${NODE_NAME}"
  info "pbk：${REALITY_PUB}"
  info "CN/private 阻断路由：启用；geolocation-!cn 优先放行"
  info "链接长度：${#link} 字符"
  echo
  echo "$link"
  echo

  read -r -p "是否生成二维码？长链接可能导致 qrencode 失败。[y/N]: " qr_ans
  case "${qr_ans:-N}" in
    y|Y|yes|YES)
      if ! command -v qrencode >/dev/null 2>&1; then
        warn "未安装 qrencode。"
        read -r -p "是否现在安装 qrencode？[y/N]: " install_qr_ans
        case "${install_qr_ans:-N}" in
          y|Y|yes|YES)
            install_packages qrencode
            ;;
          *) warn "跳过二维码输出。"; return 0 ;;
        esac
      fi

      if ! qrencode -t ANSIUTF8 "$link"; then
        warn "二维码生成失败。通常是链接过长造成的；复制上面的 vless:// 链接即可。"
      fi
      ;;
    *)
      info "已跳过二维码输出。"
      ;;
  esac
}

main() {
  need_root
  ensure_systemd_available
  install_base_deps
  sync_time_best_effort
  choose_kernel
  read_common_inputs
  check_port_available_or_handle
  generate_assets
  backup_existing_config

  if [[ "$KERNEL" == "xray" ]]; then
    write_xray_config
  else
    write_singbox_config
  fi

  chmod 644 "$CONFIG_PATH"
  validate_config
  restart_service
  print_result "$(build_link)"
}

main "$@"
