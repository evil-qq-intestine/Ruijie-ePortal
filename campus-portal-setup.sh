#!/usr/bin/env bash
#
# ============================================================
#  校园网 (锐捷 Ruijie ePortal) 自动认证 —— 一键安装脚本
# ============================================================
#
#  功能:
#    1. 首次运行交互式询问: 门户地址 / 账号 / 密码 / 上网服务(教育网/电信/联通/移动)
#    2. 自动安装认证脚本 + systemd 服务与定时器
#    3. 之后每次开机自动认证; 掉线后每 60 秒自动重连
#
#  用法:
#    sudo bash campus-portal-setup.sh                     # 交互式配置(推荐)
#    sudo bash campus-portal-setup.sh -y \
#         --user 学号 --pass 密码 --service 教育网        # 全自动, 不询问
#    sudo bash campus-portal-setup.sh --uninstall         # 卸载(保留配置)
#    sudo bash campus-portal-setup.sh --uninstall --purge # 彻底卸载
#
#  参数:
#    --user <账号>      校园网账号
#    --pass <密码>      校园网密码
#    --service <服务>   教育网|电信|联通|移动 或 after-auth|dx|lt|yd
#    --portal <IP>      门户地址, 默认 10.80.1.122
#    --check-url <URL>  认证检测地址, 默认 http://223.5.5.5/
#    --interval <秒>    掉线检测间隔, 默认 60
#    -y, --yes          全部使用默认值/已给参数, 不交互
#    --no-daed          不修改 daed 透明代理的路由规则
#    --uninstall        卸载;  --purge 连同配置一起删除
#    -h, --help         显示帮助
#
set -euo pipefail

# ------------------------------------------------------------------
# 可调默认值
# ------------------------------------------------------------------
DEF_PORTAL_IP="10.80.1.122"
DEF_CHECK_URL="http://223.5.5.5/"
DEF_SERVICE="after-auth"
DEF_INTERVAL="60"

CONF_DIR="/etc/campus-portal"
CONF_FILE="${CONF_DIR}/credentials.conf"
LOGIN_BIN="/usr/local/sbin/campus-portal-login.sh"
SELF_COPY="/usr/local/share/campus-portal/campus-portal-setup.sh"
UNIT_SERVICE="/etc/systemd/system/campus-portal-login.service"
UNIT_TIMER="/etc/systemd/system/campus-portal-login.timer"
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

# ------------------------------------------------------------------
# 输出helpers
# ------------------------------------------------------------------
if [ -t 1 ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi
log()  { printf '%s[+ ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[! ]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '%s[x ]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ------------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------------
USERNAME=""; PASSWORD=""; SERVICE=""; PORTAL_IP=""; CHECK_URL=""
INTERVAL="$DEF_INTERVAL"; ASSUME_YES=0; USE_DAED=1; UNINSTALL=0; PURGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user)      USERNAME="${2:-}"; shift 2 ;;
    --pass)      PASSWORD="${2:-}"; shift 2 ;;
    --service)   SERVICE="${2:-}";  shift 2 ;;
    --portal)    PORTAL_IP="${2:-}"; shift 2 ;;
    --check-url) CHECK_URL="${2:-}"; shift 2 ;;
    --interval)  INTERVAL="${2:-}"; shift 2 ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    --no-daed)   USE_DAED=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge)     PURGE=1; shift ;;
    -h|--help)   usage ;;
    *) die "未知参数: $1  (用 --help 查看用法)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 运行:  sudo bash $0"

# ------------------------------------------------------------------
# 卸载
# ------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  hr; log "卸载校园网自动认证"
  systemctl disable --now campus-portal-login.timer   >/dev/null 2>&1 || true
  systemctl disable --now campus-portal-login.service >/dev/null 2>&1 || true
  rm -f "$UNIT_TIMER" "$UNIT_SERVICE" "$LOGIN_BIN"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
  if [ "$PURGE" -eq 1 ]; then
    rm -rf "$CONF_DIR" "$(dirname "$SELF_COPY")"
    log "已删除配置与脚本"
  else
    log "已删除服务与脚本(保留了 ${CONF_FILE})"
  fi
  log "卸载完成"
  exit 0
fi

# ------------------------------------------------------------------
# 读取已有配置作为默认值(重复运行时可回车保留)
# ------------------------------------------------------------------
OLD_USERNAME=""; OLD_PASSWORD=""; OLD_SERVICE=""; OLD_PORTAL=""; OLD_CHECK=""
if [ -r "$CONF_FILE" ]; then
  # shellcheck source=/dev/null
  . "$CONF_FILE"
  OLD_USERNAME="${USERNAME:-}"; OLD_PASSWORD="${PASSWORD:-}"
  OLD_SERVICE="${SERVICE:-}";  OLD_PORTAL="${PORTAL_IP:-}"; OLD_CHECK="${CHECK_URL:-}"
  USERNAME=""; PASSWORD=""; SERVICE=""; PORTAL_IP=""; CHECK_URL=""
fi

# ------------------------------------------------------------------
# 依赖检查
# ------------------------------------------------------------------
command -v systemctl >/dev/null 2>&1 || die "本系统没有 systemd, 无法安装为开机自启服务"

if ! command -v curl >/dev/null 2>&1; then
  log "缺少 curl, 正在安装…"
  if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq curl
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q curl
  elif command -v yum     >/dev/null 2>&1; then yum install -y -q curl
  elif command -v pacman  >/dev/null 2>&1; then pacman -Sy --noconfirm curl
  else die "无法自动安装 curl, 请手动安装后重试"
  fi
fi

# ------------------------------------------------------------------
# 服务名归一化
# ------------------------------------------------------------------
normalize_service() {
  case "${1:-}" in
    1|教育网|jy|edu|after-auth) echo "after-auth" ;;
    2|电信|电信服务|dx)          echo "dx" ;;
    3|联通|联通服务|lt)          echo "lt" ;;
    4|移动|移动服务|yd)          echo "yd" ;;
    "")                          echo "$DEF_SERVICE" ;;
    *)                           echo "$1" ;;
  esac
}
service_label() {
  case "$1" in
    after-auth) echo "教育网" ;;
    dx)         echo "电信服务" ;;
    lt)         echo "联通服务" ;;
    yd)         echo "移动服务" ;;
    *)          echo "$1" ;;
  esac
}

# ------------------------------------------------------------------
# 交互式收集配置
# ------------------------------------------------------------------
hr
printf '%s校园网自动认证 · 首次配置%s\n' "$C_B" "$C_0"
hr

prompt() {  # prompt <提示语> <变量名> <默认值> <是否必填>
  local msg="$1" var="$2" def="${3:-}" required="${4:-0}" ans=""
  while :; do
    if [ -n "$def" ]; then printf '%s [%s]: ' "$msg" "$def"; else printf '%s: ' "$msg"; fi
    IFS= read -r ans || ans=""
    [ -z "$ans" ] && ans="$def"
    if [ -z "$ans" ] && [ "$required" = "1" ]; then
      warn "该项不能为空, 请重新输入"; continue
    fi
    printf -v "$var" '%s' "$ans"
    return 0
  done
}

# ---- 门户地址 ----
if [ -z "$PORTAL_IP" ]; then
  if [ "$ASSUME_YES" -eq 1 ]; then
    PORTAL_IP="${OLD_PORTAL:-$DEF_PORTAL_IP}"
  else
    prompt "认证门户 IP" PORTAL_IP "${OLD_PORTAL:-$DEF_PORTAL_IP}" 1
  fi
fi
PORTAL_IP="${PORTAL_IP#http://}"; PORTAL_IP="${PORTAL_IP#https://}"; PORTAL_IP="${PORTAL_IP%%/*}"

# ---- 检测地址 ----
if [ -z "$CHECK_URL" ]; then
  if [ "$ASSUME_YES" -eq 1 ]; then
    CHECK_URL="${OLD_CHECK:-$DEF_CHECK_URL}"
  else
    prompt "认证检测地址(未认证时会被劫持的网址)" CHECK_URL "${OLD_CHECK:-$DEF_CHECK_URL}" 1
  fi
fi

# ---- 账号 ----
if [ -z "$USERNAME" ]; then
  if [ "$ASSUME_YES" -eq 1 ]; then
    USERNAME="${OLD_USERNAME:-}"
    [ -n "$USERNAME" ] || die "--yes 模式下必须用 --user 指定账号"
  else
    prompt "校园网账号" USERNAME "$OLD_USERNAME" 1
  fi
fi

# ---- 密码 ----
if [ -z "$PASSWORD" ]; then
  if [ "$ASSUME_YES" -eq 1 ]; then
    PASSWORD="${OLD_PASSWORD:-}"
    [ -n "$PASSWORD" ] || die "--yes 模式下必须用 --pass 指定密码"
  else
    if [ -n "$OLD_PASSWORD" ]; then
      printf '校园网密码 [直接回车保留原密码]: '
      IFS= read -rs PASSWORD || PASSWORD=""
      printf '\n'
      if [ -z "$PASSWORD" ]; then PASSWORD="$OLD_PASSWORD"; fi
    else
      while :; do
        printf '校园网密码(输入时不显示): '
        IFS= read -rs PASSWORD || PASSWORD=""
        printf '\n'
        [ -n "$PASSWORD" ] || { warn "密码不能为空"; continue; }
        printf '再输入一次确认: '
        IFS= read -rs P2 || P2=""
        printf '\n'
        [ "$PASSWORD" = "$P2" ] && break
        warn "两次输入不一致, 请重新输入"
      done
    fi
  fi
fi

# ---- 上网服务 ----
if [ -z "$SERVICE" ]; then
  if [ "$ASSUME_YES" -eq 1 ]; then
    SERVICE="${OLD_SERVICE:-$DEF_SERVICE}"
  else
    echo
    echo "请选择上网服务类型:"
    echo "  1) 教育网   (after-auth)   <- 默认, 校园网内网/教育网出口"
    echo "  2) 电信服务 (dx)"
    echo "  3) 联通服务 (lt)"
    echo "  4) 移动服务 (yd)"
    echo "  5) 其他(手动输入)"
    printf '选择 [1]: '
    IFS= read -r ans || ans=""
    [ -z "$ans" ] && ans="1"
    if [ "$ans" = "5" ]; then
      printf '请输入服务标识: '
      IFS= read -r SERVICE || SERVICE=""
      [ -n "$SERVICE" ] || SERVICE="$DEF_SERVICE"
    else
      SERVICE="$(normalize_service "$ans")"
    fi
  fi
fi
SERVICE="$(normalize_service "$SERVICE")"

# ------------------------------------------------------------------
# 确认
# ------------------------------------------------------------------
hr
echo "即将安装以下配置:"
printf '  %-10s %s\n' "门户地址"  "http://${PORTAL_IP}"
printf '  %-10s %s\n' "检测地址"  "${CHECK_URL}"
printf '  %-10s %s\n' "账号"      "${USERNAME}"
printf '  %-10s %s\n' "密码"      "$(printf '%s' "$PASSWORD" | sed 's/./*/g')"
printf '  %-10s %s\n' "上网服务"  "$(service_label "$SERVICE")  [${SERVICE}]"
printf '  %-10s %s\n' "检测间隔"  "${INTERVAL} 秒"
printf '  %-10s %s\n' "开机自启"  "是 (systemd timer)"
hr
if [ "$ASSUME_YES" -eq 0 ]; then
  printf '确认安装? [Y/n]: '
  IFS= read -r ans || ans=""
  case "${ans:-Y}" in
    n|N|no|NO) log "已取消"; exit 0 ;;
  esac
fi

# ------------------------------------------------------------------
# 写入认证脚本
# ------------------------------------------------------------------
log "安装认证脚本 ${LOGIN_BIN}"
install -d -m 755 "$(dirname "$LOGIN_BIN")"
cat > "$LOGIN_BIN" <<'LOGIN_EOF'
#!/bin/bash
# 校园网 (锐捷 ePortal) 自动认证
# 由 campus-portal-login.timer 定时调用; 也可手动执行, 加 --force 强制认证
set -u

CONF=/etc/campus-portal/credentials.conf
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

[ -r "$CONF" ] || { echo "缺少配置文件 $CONF"; exit 1; }
# shellcheck source=/dev/null
. "$CONF"

PORTAL_IP=${PORTAL_IP:-10.80.1.122}
CHECK_URL=${CHECK_URL:-http://223.5.5.5/}
SERVICE=${SERVICE:-after-auth}
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

log() { echo "[$(date '+%F %T')] $*"; }

# ---------- 1. 判断是否需要认证 ----------
BODY=$(curl -s -m 8 -A "$UA" "$CHECK_URL" 2>/dev/null || true)
INTERCEPTED=0
if printf '%s' "$BODY" | grep -qE 'eportal/index\.jsp|eportal/InterFace\.do'; then
    INTERCEPTED=1
fi

if [ "$INTERCEPTED" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
    log "网络已认证，无需登录"
    exit 0
fi
if [ "$FORCE" -eq 1 ]; then log "强制认证模式"; fi

# ---------- 2. 取出门户地址与 queryString ----------
PURL=$(printf '%s' "$BODY" | grep -oE "location\.href='[^']+'" | head -n1 | sed "s/location\.href='//; s/'$//")

if [ -z "$PURL" ]; then
    LOC=$(curl -s -m 8 -A "$UA" -o /dev/null -D - "$CHECK_URL" 2>/dev/null \
          | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}' | head -n1)
    case "$LOC" in *index.jsp*) PURL="$LOC" ;; esac
fi

if [ -z "$PURL" ]; then
    if [ "$INTERCEPTED" -eq 0 ]; then
        log "当前未被门户拦截，网络已认证，无需操作"
        exit 0
    fi
    log "无法取得门户地址，放弃本次认证"
    exit 2
fi
QS=${PURL#*\?}
log "检测到门户拦截，开始认证…"
log "门户地址: $PURL"

# ---------- 3. 提交认证 ----------
RESP=$(curl -s -m 15 -A "$UA" \
    -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
    -H "Referer: $PURL" \
    --data-urlencode "userId=$USERNAME" \
    --data-urlencode "password=$PASSWORD" \
    --data-urlencode "service=$SERVICE" \
    --data-urlencode "queryString=$QS" \
    --data "operatorPwd=" \
    --data "operatorUserId=" \
    --data "validcode=" \
    --data "passwordEncrypt=false" \
    "http://$PORTAL_IP/eportal/InterFace.do?method=login" 2>/dev/null || true)

case "$RESP" in
    *'"result":"success"'*)
        MSG=$(printf '%s' "$RESP" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
        if [ -n "$MSG" ]; then log "认证成功（服务器提示: $MSG）"; else log "认证成功"; fi
        exit 0 ;;
    *'已经在线'*|*'已在线'*|*'重复登录'*)
        log "账号已在线"
        exit 0 ;;
    *)
        log "认证失败，服务器返回: $RESP"
        exit 3 ;;
esac
LOGIN_EOF
chmod 755 "$LOGIN_BIN"
bash -n "$LOGIN_BIN" || die "认证脚本语法错误"

# ------------------------------------------------------------------
# 写入凭据文件
# ------------------------------------------------------------------
log "写入配置 ${CONF_FILE}"
install -d -m 700 "$CONF_DIR"
# 单引号转义, 保证任何特殊字符都能安全写入
sq() { local s=$1; s=${s//\'/\'\\\'\'}; printf "'%s'" "$s"; }
umask 077
{
  echo "# 校园网 (锐捷 ePortal) 认证凭据"
  echo "# 本文件含明文密码, 权限必须保持 600 / root"
  echo "USERNAME=$(sq "$USERNAME")"
  echo "PASSWORD=$(sq "$PASSWORD")"
  echo "SERVICE=$(sq "$SERVICE")"
  echo "PORTAL_IP=$(sq "$PORTAL_IP")"
  echo "CHECK_URL=$(sq "$CHECK_URL")"
} > "$CONF_FILE"
chmod 600 "$CONF_FILE"; chown root:root "$CONF_FILE"
umask 022

# ------------------------------------------------------------------
# 写入 systemd 单元
# ------------------------------------------------------------------
log "写入 systemd 服务与定时器"
cat > "$UNIT_SERVICE" <<'UNIT_EOF'
[Unit]
Description=校园网 ePortal 自动认证
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/campus-portal-login.sh
UNIT_EOF

cat > "$UNIT_TIMER" <<UNIT_EOF
[Unit]
Description=定时检查校园网认证状态（掉线自动重连）

[Timer]
OnBootSec=20s
OnUnitActiveSec=${INTERVAL}s
AccuracySec=5s
Unit=campus-portal-login.service

[Install]
WantedBy=timers.target
UNIT_EOF

systemctl daemon-reload

# ------------------------------------------------------------------
# 如果装了 daed 透明代理: 让门户/检测地址强制直连
# 否则 daed 的 pname(curl)->proxy 规则会把认证请求丢给代理, 形成死锁
# ------------------------------------------------------------------
if [ "$USE_DAED" -eq 1 ] && [ -f /etc/daed/wing.db ] && command -v python3 >/dev/null 2>&1; then
  log "检测到 daed 透明代理, 添加门户直连规则"
  set +e
  PYOUT=$(python3 - "$PORTAL_IP" "$CHECK_URL" <<'PY_EOF' 2>&1
import sqlite3, sys, re, shutil, time
portal_ip = sys.argv[1]
check_url = sys.argv[2]
host = re.sub(r'^https?://', '', check_url).split('/')[0].split(':')[0]
db = '/etc/daed/wing.db'
shutil.copy2(db, db + '.bak-' + time.strftime('%Y%m%d-%H%M%S'))
con = sqlite3.connect(db); cur = con.cursor()
r, ver = cur.execute("select routing,version from routings where selected=1").fetchone()
need = [ip for ip in (portal_ip, host)
        if re.fullmatch(r'\d+\.\d+\.\d+\.\d+', ip) and ('dip(%s) -> must_direct' % ip) not in r]
if not need:
    print('ALREADY')
else:
    block = "# ===== 校园网门户/认证检测必须直连(须放最前, 否则被 pname(curl)->proxy 抢走) =====\n"
    for ip in need:
        block += "dip(%s) -> must_direct\n" % ip
    block += "\n"
    i = r.find('routing {')
    j = r.find('\n', i)
    new_r = r[:j+1] + block + r[j+1:]
    cur.execute("update routings set routing=?, version=? where selected=1", (new_r, ver + 1))
    con.commit()
    print('ADDED ' + ','.join(need))
con.close()
PY_EOF
)
  set -e
  case "$PYOUT" in
    ADDED*) echo "  已添加直连规则: ${PYOUT#ADDED }"
            if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx daed; then
              log "重启 daed 使规则生效"
              docker restart daed >/dev/null 2>&1 || true
              sleep 6
            fi ;;
    ALREADY) echo "  直连规则已存在, 跳过" ;;
    *) warn "daed 规则写入失败(不影响认证脚本本身): $PYOUT" ;;
  esac
fi

# ------------------------------------------------------------------
# 保留一份安装脚本便于以后重跑
# ------------------------------------------------------------------
install -d -m 755 "$(dirname "$SELF_COPY")"
if [ "$(readlink -f "$0")" != "$(readlink -f "$SELF_COPY" 2>/dev/null || echo /nonexistent)" ]; then
  cp -f "$0" "$SELF_COPY" 2>/dev/null && chmod 755 "$SELF_COPY" || true
fi

# ------------------------------------------------------------------
# 启用并立即试跑
# ------------------------------------------------------------------
log "启用开机自启"
systemctl enable campus-portal-login.timer >/dev/null 2>&1
systemctl restart campus-portal-login.timer
systemctl reset-failed campus-portal-login.service >/dev/null 2>&1 || true

log "立即执行一次认证测试…"
sleep 1
set +e
"$LOGIN_BIN"
RC=$?
set -e
case "$RC" in
  0) log "认证测试: 通过" ;;
  2) warn "认证测试: 未取到门户地址(可能当前无网或已认证)" ;;
  3) warn "认证测试: 服务器拒绝了认证, 请检查账号/密码/服务类型是否正确" ;;
  *) warn "认证测试: 异常退出码 $RC" ;;
esac

# ------------------------------------------------------------------
# 完成
# ------------------------------------------------------------------
hr
log "安装完成"
hr
printf '  凭据文件   : %s   (权限 600, 仅 root 可读)\n' "$CONF_FILE"
printf '  认证脚本   : %s\n' "$LOGIN_BIN"
printf '  安装脚本   : %s\n' "$SELF_COPY"
printf '  定时器     : campus-portal-login.timer (%s 秒检查一次, 开机自动运行)\n' "$INTERVAL"
echo
echo "常用命令:"
echo "  手动认证一次 : sudo systemctl start campus-portal-login.service"
echo "  强制重新认证 : sudo $LOGIN_BIN --force"
echo "  查看日志     : journalctl -u campus-portal-login.service -f"
echo "  修改账号密码 : sudo $SELF_COPY"
echo "  卸载         : sudo $SELF_COPY --uninstall"
hr
