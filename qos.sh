#!/bin/bash
#
# QoS 端口限速工具 v3.0
# 功能:
#   - 按端口设置触发规则（超过阈值带宽×持续时间 → 自动限速）
#   - 限速时长到期自动解除，解除后继续监控（可循环触发）
#   - 首次运行自动检测并安装依赖
#   - 配置持久化 + systemd 开机自启
#   - 交互式菜单管理所有参数
#
# 首次安装（只需执行一次）:
#   sudo bash qos.sh setup
# 之后直接输入:
#   qos
#

# ─────────────────────────────────────────────────────────
# 自我安装检测：如果当前不是从 /usr/local/bin/qos 运行，
# 且第一个参数不是内部命令，提示用户先执行 setup
# ─────────────────────────────────────────────────────────
# 确保 PATH 包含常用系统目录（某些 SSH/精简环境 PATH 不完整）
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SCRIPT_SELF="$(realpath "$0" 2>/dev/null || readlink -f "$0")"
QOS_BIN="/usr/bin/qos"

_is_internal_cmd() {
    case "${1:-}" in
        setup|_monitor|"") return 1 ;;  # setup/_monitor/空 不拦截
        *) return 1 ;;
    esac
}

# 如果脚本不在目标位置，且不是 setup 命令，自动提示
if [ "$SCRIPT_SELF" != "$QOS_BIN" ] && [ "${1:-}" != "setup" ] && [ "${1:-}" != "_monitor" ]; then
    # 尝试静默自动安装（有 root 权限时）
    if [ "$(id -u)" = "0" ]; then
        cp -f "$SCRIPT_SELF" "$QOS_BIN" 2>/dev/null && chmod +x "$QOS_BIN" 2>/dev/null
        # 安装成功后用新路径重新执行，传递所有参数
        if [ -x "$QOS_BIN" ]; then
            exec "$QOS_BIN" "$@"
        fi
    else
        echo ""
        echo -e "\033[1;33m[!] 检测到首次运行，尚未安装快捷命令 'qos'\033[0m"
        echo -e "\033[0;36m[→] 请执行以下命令完成安装：\033[0m"
        echo ""
        echo -e "    \033[1msudo bash $SCRIPT_SELF setup\033[0m"
        echo ""
        echo -e "\033[2m    安装后直接输入 qos 即可启动\033[0m"
        echo ""
        exit 0
    fi
fi

# ─────────────────────────────────────────────────────────
# 颜色
# ─────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m';  CYAN='\033[0;36m';   BOLD='\033[1m'
DIM='\033[2m';      NC='\033[0m'

# ─────────────────────────────────────────────────────────
# 路径常量
# ─────────────────────────────────────────────────────────
CONFIG_FILE="/etc/qos/qos.conf"
LOG_FILE="/var/log/qos.log"
SERVICE_FILE="/etc/systemd/system/qos.service"
SCRIPT_PATH="/usr/bin/qos"
STATE_DIR="/run/qos"          # 运行时状态目录
FIRST_RUN_FLAG="/etc/qos/.initialized"
MONITOR_INTERVAL=5            # 监控采样间隔（秒）

# ─────────────────────────────────────────────────────────
# 工具函数
# ─────────────────────────────────────────────────────────
log()  { mkdir -p "$(dirname "$LOG_FILE")"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
info() { echo -e "${BLUE}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
step() { echo -e "${CYAN}[→]${NC} $*"; }

require_root() {
    [ "$(id -u)" = "0" ] && return
    err "此操作需要 root 权限，请使用 sudo 或切换到 root 用户"
    exit 1
}

# ─────────────────────────────────────────────────────────
# 检测包管理器
# ─────────────────────────────────────────────────────────
detect_pkg_manager() {
    if   command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf     &>/dev/null; then echo "dnf"
    elif command -v yum     &>/dev/null; then echo "yum"
    elif command -v pacman  &>/dev/null; then echo "pacman"
    elif command -v apk     &>/dev/null; then echo "apk"
    else echo "unknown"
    fi
}

install_package() {
    local cmd="$1" pkg_apt="${2:-$1}" pkg_rpm="${3:-$1}"
    local mgr; mgr=$(detect_pkg_manager)
    step "安装 ${BOLD}${cmd}${NC} ..."
    case "$mgr" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg_apt" -qq ;;
        dnf)    dnf install -y "$pkg_rpm" -q ;;
        yum)    yum install -y "$pkg_rpm" -q ;;
        pacman) pacman -Sy --noconfirm "$cmd" >/dev/null ;;
        apk)    apk add --no-cache "$cmd" >/dev/null ;;
        *)      err "未识别的包管理器，请手动安装: $cmd"; return 1 ;;
    esac
    local rc=$?
    [ $rc -eq 0 ] && ok "已安装 ${cmd}" || err "安装 ${cmd} 失败（退出码 $rc）"
    return $rc
}

# ─────────────────────────────────────────────────────────
# 首次运行：检测并自动安装依赖
# ─────────────────────────────────────────────────────────
bootstrap_deps() {
    local force="${1:-}"
    if [ -f "$FIRST_RUN_FLAG" ] && [ "$force" != "force" ]; then
        command -v tc &>/dev/null && command -v ifstat &>/dev/null && return 0
    fi

    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}              依赖检测与自动安装                    ${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    local mgr; mgr=$(detect_pkg_manager)
    info "检测到包管理器: ${BOLD}${mgr}${NC}"
    echo ""

    # 命令|apt包|rpm包|用途
    local deps=(
        "tc|iproute2|iproute-tc|流量控制核心"
        "iptables|iptables|iptables|IPv4 出向流量打标记"
        "ip6tables|ip6tables|ip6tables|IPv6 出向流量打标记"
        "ip|iproute2|iproute|IP路由工具"
        "awk|gawk|gawk|文本处理"
        "bc|bc|bc|浮点计算"
    )

    local all_ok=true
    declare -a miss_cmds miss_apt miss_rpm

    info "检查各项依赖..."
    echo ""
    for dep in "${deps[@]}"; do
        local cmd pkg_apt pkg_rpm desc
        cmd=$(    echo "$dep" | cut -d'|' -f1)
        pkg_apt=$(echo "$dep" | cut -d'|' -f2)
        pkg_rpm=$( echo "$dep" | cut -d'|' -f3)
        desc=$(   echo "$dep" | cut -d'|' -f4)
        if command -v "$cmd" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC}  ${BOLD}${cmd}${NC}  ${DIM}${desc}${NC}"
        else
            echo -e "  ${RED}✗${NC}  ${BOLD}${cmd}${NC}  ${DIM}${desc}${NC}  ${YELLOW}← 缺失${NC}"
            miss_cmds+=("$cmd"); miss_apt+=("$pkg_apt"); miss_rpm+=("$pkg_rpm")
            all_ok=false
        fi
    done
    echo ""

    if $all_ok; then
        ok "所有依赖已满足"
        mkdir -p "$(dirname "$FIRST_RUN_FLAG")"; touch "$FIRST_RUN_FLAG"
        log "依赖检查通过"
        echo ""; return 0
    fi

    warn "发现 ${#miss_cmds[@]} 个缺失依赖: ${miss_cmds[*]}"
    echo ""
    read -rp "  是否自动安装缺失依赖? [Y/n]: " confirm
    [[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { err "已跳过，部分功能不可用"; return 1; }

    echo ""
    case "$mgr" in
        apt) step "更新软件包索引..."; apt-get update -qq 2>/dev/null && ok "索引已更新" || warn "更新失败，继续安装" ;;
        dnf|yum) $mgr makecache -q 2>/dev/null || true ;;
    esac
    echo ""

    local failed=()
    for i in "${!miss_cmds[@]}"; do
        install_package "${miss_cmds[$i]}" "${miss_apt[$i]}" "${miss_rpm[$i]}" \
            || failed+=("${miss_cmds[$i]}")
    done
    echo ""

    if [ ${#failed[@]} -gt 0 ]; then
        err "以下依赖安装失败: ${failed[*]}"; err "请手动安装后重试"; return 1
    fi

    ok "所有依赖安装完成 ✓"
    mkdir -p "$(dirname "$FIRST_RUN_FLAG")"; touch "$FIRST_RUN_FLAG"
    log "依赖自动安装完成: ${miss_cmds[*]}"
    echo ""
    [ "$force" = "force" ] && read -rp "  按 Enter 继续..." _
    return 0
}

# ─────────────────────────────────────────────────────────
# 时长解析 / 格式化
# ─────────────────────────────────────────────────────────
parse_duration() {
    local input="${1,,}"
    [[ "$input" =~ ^(0|永久|forever|never|no)$ ]] && echo 0 && return
    [[ "$input" =~ ^[0-9]+$ ]] && echo $(( input * 60 )) && return
    local total=0
    [[ "$input" =~ ([0-9]+)[d天]  ]] && total=$(( total + ${BASH_REMATCH[1]} * 86400 ))
    [[ "$input" =~ ([0-9]+)[hH时] ]] && total=$(( total + ${BASH_REMATCH[1]} * 3600  ))
    [[ "$input" =~ ([0-9]+)[mM分] ]] && total=$(( total + ${BASH_REMATCH[1]} * 60    ))
    [[ "$input" =~ ([0-9]+)[sS秒] ]] && total=$(( total + ${BASH_REMATCH[1]}         ))
    [ "$total" -gt 0 ] && echo "$total" || echo "-1"
}

format_duration() {
    local secs="${1:-0}"
    [ "$secs" -eq 0 ] 2>/dev/null && echo "永久" && return
    local d=$(( secs/86400 )) h=$(( (secs%86400)/3600 )) m=$(( (secs%3600)/60 )) s=$(( secs%60 ))
    local r=""
    [ $d -gt 0 ] && r+="${d}天"; [ $h -gt 0 ] && r+="${h}小时"
    [ $m -gt 0 ] && r+="${m}分"; [ $s -gt 0 ] && r+="${s}秒"
    echo "${r:-0秒}"
}

# ─────────────────────────────────────────────────────────
# 加载配置
#
# PORT_RULES[端口:协议] = "限速值 触发带宽Mbps 触发持续秒 限速时长秒"
# 示例: PORT_RULES[443:tcp] = "10mbit 80 300 180"
#   → 当 443/tcp 超过 80Mbps 持续 300 秒，限速至 10mbit，持续 180 秒后解除
# ─────────────────────────────────────────────────────────
load_config() {
    # 先声明全局空数组，避免 source 在函数作用域内 declare -A 数据丢失
    declare -gA PORT_RULES=()
    INTERFACE=""

    if [ -f "$CONFIG_FILE" ]; then
        # 逐行解析配置，彻底规避 bash 函数内 source+declare 作用域问题
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue   # 跳过注释
            [[ -z "${line// }" ]] && continue              # 跳过空行

            # INTERFACE="eth0"
            if [[ "$line" =~ ^INTERFACE=\"(.*)\"$ ]]; then
                INTERFACE="${BASH_REMATCH[1]}"
                continue
            fi

            # PORT_RULES["443:tcp"]="60mbit 80 120 1200"
            if [[ "$line" =~ ^PORT_RULES\[\"([^\"]+)\"\]=\"(.*)\"$ ]]; then
                PORT_RULES["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
                continue
            fi
        done < "$CONFIG_FILE"
    fi

    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
        [ -z "$INTERFACE" ] && INTERFACE="eth0"
    fi
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    {
        echo "# QoS 配置文件 — 自动生成于 $(date)"
        echo "# 请勿手动修改，使用 qos 命令管理"
        echo ""
        echo "INTERFACE=\"$INTERFACE\""
        echo ""
        echo "# PORT_RULES[端口:协议]=\"限速值 触发带宽Mbps 触发持续秒 限速时长秒\""
        echo "declare -A PORT_RULES"
        for key in "${!PORT_RULES[@]}"; do
            echo "PORT_RULES[\"$key\"]=\"${PORT_RULES[$key]}\""
        done
    } > "$CONFIG_FILE"
    ok "配置已保存 → $CONFIG_FILE"
    log "配置已保存"
}

# ─────────────────────────────────────────────────────────
# TC 方案：仅限出向（egress）上行带宽
#
# 问题背景：
#   - 服务器 IP 为内网 NAT（10.x.x.x），流量经过 DNAT
#   - 连接使用 IPv4-mapped IPv6（::ffff:x.x.x.x）
#   以上两点导致 TC u32 protocol ip 无法匹配
#
# 解决方案：iptables mangle POSTROUTING 按端口打 fwmark
#   → TC fw filter 按 fwmark 匹配出向流量限速
#   → 不关心 IP 版本和 NAT，端口始终可见
# ─────────────────────────────────────────────────────────

# 初始化 TC 出向根结构
init_tc() {
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    tc qdisc add dev "$INTERFACE" root handle 1: htb default 999
    tc class add dev "$INTERFACE" parent 1: classid 1:999 htb rate 10gbit ceil 10gbit
    log "TC 初始化完成（出向: ${INTERFACE}）"
}

# iptables：对出向端口打 fwmark（POSTROUTING，源端口=服务端口）
_ipt_mark_port() {
    local port="$1" proto="$2" mark="$3"
    _mark_one() {
        local p="$1"
        iptables  -t mangle -A POSTROUTING -p "$p" --sport "$port" -j MARK --set-mark "$mark" 2>/dev/null || true
        ip6tables -t mangle -A POSTROUTING -p "$p" --sport "$port" -j MARK --set-mark "$mark" 2>/dev/null || true
    }
    { [ "$proto" = "tcp"  ] || [ "$proto" = "both" ]; } && _mark_one tcp
    { [ "$proto" = "udp"  ] || [ "$proto" = "both" ]; } && _mark_one udp
}

# iptables：清除出向端口的 fwmark 规则
_ipt_clear_port() {
    local port="$1" proto="$2" mark="$3"
    _clear_one() {
        local p="$1"
        iptables  -t mangle -D POSTROUTING -p "$p" --sport "$port" -j MARK --set-mark "$mark" 2>/dev/null || true
        ip6tables -t mangle -D POSTROUTING -p "$p" --sport "$port" -j MARK --set-mark "$mark" 2>/dev/null || true
    }
    { [ "$proto" = "tcp"  ] || [ "$proto" = "both" ]; } && _clear_one tcp
    { [ "$proto" = "udp"  ] || [ "$proto" = "both" ]; } && _clear_one udp
}

# 对指定端口下发出向限速
# $1=端口  $2=协议  $3=速率  $4=handle（同时作为 fwmark 值）
tc_limit_port() {
    local port="$1" proto="$2" rate="$3" handle="$4"
    local mark="$handle"

    # 打 iptables fwmark（出向）
    _ipt_mark_port "$port" "$proto" "$mark"

    # 创建或更新 HTB 限速类
    if tc class show dev "$INTERFACE" | grep -q "1:${handle}"; then
        tc class change dev "$INTERFACE" parent 1: classid "1:${handle}" \
            htb rate "$rate" ceil "$rate" burst 15k 2>/dev/null
    else
        tc class add dev "$INTERFACE" parent 1: classid "1:${handle}" \
            htb rate "$rate" ceil "$rate" burst 15k 2>/dev/null
        tc qdisc add dev "$INTERFACE" parent "1:${handle}" \
            handle "${handle}:" sfq perturb 10 2>/dev/null
        # fw filter 按 fwmark 匹配，兼容 IPv4/IPv6/NAT
        tc filter add dev "$INTERFACE" parent 1: protocol all prio "$handle" \
            handle "$mark" fw flowid "1:${handle}" 2>/dev/null
    fi

    log "限速下发: 端口=$port 协议=$proto 上行限速=$rate mark=$mark"
}

# 解除端口限速（恢复不限速，清除 iptables mark 规则）
# $1=handle  $2=端口  $3=协议
tc_unlimit_port() {
    local handle="$1" port="$2" proto="$3"

    [ -n "$port" ] && _ipt_clear_port "$port" "$proto" "$handle"

    tc class change dev "$INTERFACE" parent 1: classid "1:${handle}" \
        htb rate 10gbit ceil 10gbit 2>/dev/null || true

    log "限速解除: 端口=$port handle=$handle"
}

# 清除所有 TC 规则和 iptables mark 规则
clear_rules() {
    load_config
    local h=10
    for key in "${!PORT_RULES[@]}"; do
        local port proto
        port=$( echo "$key" | cut -d: -f1)
        proto=$(echo "$key" | cut -d: -f2)
        _ipt_clear_port "$port" "$proto" "$h" 2>/dev/null || true
        h=$(( h + 10 ))
    done

    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    warn "已清除 ${INTERFACE} 全部 TC 规则及 iptables mark 规则"
    log "清除所有规则"
}

# ─────────────────────────────────────────────────────────
# 获取端口实时带宽 (Mbps)
# 使用 /proc/net/dev 计算增量，避免依赖 ifstat 单端口统计
# ─────────────────────────────────────────────────────────
get_iface_bw_mbps() {
    # 返回接口总 TX+RX Mbps（两次采样差值）
    local iface="$1" interval="${2:-$MONITOR_INTERVAL}"
    local rx1 tx1 rx2 tx2
    rx1=$(awk -v i="$iface:" '$1==i{print $2}' /proc/net/dev 2>/dev/null || echo 0)
    tx1=$(awk -v i="$iface:" '$1==i{print $10}' /proc/net/dev 2>/dev/null || echo 0)
    sleep "$interval"
    rx2=$(awk -v i="$iface:" '$1==i{print $2}' /proc/net/dev 2>/dev/null || echo 0)
    tx2=$(awk -v i="$iface:" '$1==i{print $10}' /proc/net/dev 2>/dev/null || echo 0)
    local diff=$(( (rx2 - rx1) + (tx2 - tx1) ))
    # bytes → Mbps
    echo "scale=2; $diff * 8 / $interval / 1000000" | bc 2>/dev/null || echo "0"
}

# ─────────────────────────────────────────────────────────
# 监控守护进程（后台运行）
#
# 每个端口规则独立维护状态文件:
#   STATE_DIR/<port>_<proto>/status   : "normal" | "limited"
#   STATE_DIR/<port>_<proto>/high_since: 开始高带宽的时间戳
#   STATE_DIR/<port>_<proto>/limit_until: 限速结束时间戳
# ─────────────────────────────────────────────────────────
monitor_daemon() {
    load_config
    mkdir -p "$STATE_DIR"
    log "监控守护进程启动 (PID=$$, 接口=$INTERFACE)"
    echo $$ > "${STATE_DIR}/monitor.pid"

    # 初始化 TC 根结构
    init_tc

    # 为每个规则分配 handle，建立 handle 映射
    declare -A PORT_HANDLE
    local h=10
    for key in "${!PORT_RULES[@]}"; do
        PORT_HANDLE[$key]=$h
        h=$(( h + 10 ))
    done

    # 初始化状态文件
    for key in "${!PORT_RULES[@]}"; do
        local sdir="${STATE_DIR}/${key//:/_}"
        mkdir -p "$sdir"
        echo "normal" > "${sdir}/status"
        rm -f "${sdir}/high_since" "${sdir}/limit_until"
    done

    info "开始监控 ${#PORT_RULES[@]} 条端口规则..."
    echo ""

    while true; do
        # 重新加载配置（支持运行中热更新）
        load_config

        local now; now=$(date +%s)
        # 采样当前接口带宽
        local iface_bw
        iface_bw=$(get_iface_bw_mbps "$INTERFACE" "$MONITOR_INTERVAL")

        for key in "${!PORT_RULES[@]}"; do
            local val="${PORT_RULES[$key]}"
            local rate trig_bw trig_dur limit_dur port proto
            rate=$(     echo "$val" | awk '{print $1}')   # 限速值，如 10mbit
            trig_bw=$(  echo "$val" | awk '{print $2}')   # 触发带宽 Mbps
            trig_dur=$( echo "$val" | awk '{print $3}')   # 触发持续秒
            limit_dur=$(echo "$val" | awk '{print $4}')   # 限速时长秒（0=永久）
            port=$( echo "$key" | cut -d: -f1)
            proto=$(echo "$key" | cut -d: -f2)

            local sdir="${STATE_DIR}/${key//:/_}"
            mkdir -p "$sdir"
            local status; status=$(cat "${sdir}/status" 2>/dev/null || echo "normal")
            local handle="${PORT_HANDLE[$key]:-10}"

            # ── 当前处于限速状态 ──────────────────────────────
            if [ "$status" = "limited" ]; then
                local limit_until; limit_until=$(cat "${sdir}/limit_until" 2>/dev/null || echo 0)

                if [ "$limit_dur" -gt 0 ] 2>/dev/null && [ "$now" -ge "$limit_until" ]; then
                    # 限速时长到期，解除
                    tc_unlimit_port "$handle" "$port" "$proto"
                    echo "normal" > "${sdir}/status"
                    rm -f "${sdir}/high_since" "${sdir}/limit_until"
                    local ts; ts=$(date '+%H:%M:%S')
                    echo -e "${GREEN}[${ts}]${NC} 端口 ${BOLD}${port}${NC}(${proto})  限速到期 → ${GREEN}恢复正常${NC}"
                    log "端口 $port($proto) 限速到期，已自动解除，继续监控"
                else
                    # 仍在限速中，显示剩余时间
                    local remain=$(( limit_until - now ))
                    local ts; ts=$(date '+%H:%M:%S')
                    if [ "$limit_dur" -gt 0 ] 2>/dev/null; then
                        echo -e "${DIM}[${ts}]${NC} 端口 ${port}(${proto})  ${RED}限速中${NC}  剩余 $(format_duration "$remain")"
                    else
                        echo -e "${DIM}[${ts}]${NC} 端口 ${port}(${proto})  ${RED}永久限速中${NC}"
                    fi
                fi
                continue
            fi

            # ── 当前处于正常状态，监测带宽 ───────────────────
            # 用接口总带宽近似（精确端口带宽需 conntrack，成本高）
            local current_bw="$iface_bw"
            local ts; ts=$(date '+%H:%M:%S')

            local over; over=$(echo "$current_bw > $trig_bw" | bc -l 2>/dev/null || echo 0)
            if [ "$over" = "1" ]; then
                # 带宽超过阈值
                if [ ! -f "${sdir}/high_since" ]; then
                    echo "$now" > "${sdir}/high_since"
                    echo -e "${YELLOW}[${ts}]${NC} 端口 ${BOLD}${port}${NC}(${proto})  带宽 ${BOLD}${current_bw}Mbps${NC} > 阈值 ${trig_bw}Mbps  开始计时..."
                    log "端口 $port($proto) 带宽 ${current_bw}Mbps 超过阈值 ${trig_bw}Mbps，开始计时"
                else
                    local high_since; high_since=$(cat "${sdir}/high_since")
                    local elapsed=$(( now - high_since ))

                    if [ "$elapsed" -ge "$trig_dur" ]; then
                        # 持续时间已达到触发条件，开始限速
                        tc_limit_port "$port" "$proto" "$rate" "$handle"
                        echo "limited" > "${sdir}/status"

                        if [ "$limit_dur" -gt 0 ] 2>/dev/null; then
                            echo $(( now + limit_dur )) > "${sdir}/limit_until"
                            echo -e "${RED}[${ts}]${NC} 端口 ${BOLD}${port}${NC}(${proto})  ⚡ 触发限速！带宽 ${current_bw}Mbps 持续 $(format_duration "$elapsed")  → 限速至 ${BOLD}${rate}${NC}  限速 $(format_duration "$limit_dur") 后自动解除"
                            log "端口 $port($proto) 触发限速: ${current_bw}Mbps 持续 ${elapsed}s → 限速 $rate，时长 ${limit_dur}s"
                        else
                            echo "0" > "${sdir}/limit_until"
                            echo -e "${RED}[${ts}]${NC} 端口 ${BOLD}${port}${NC}(${proto})  ⚡ 触发限速！带宽 ${current_bw}Mbps 持续 $(format_duration "$elapsed")  → 限速至 ${BOLD}${rate}${NC}  ${DIM}[永久，需手动解除]${NC}"
                            log "端口 $port($proto) 触发永久限速: ${current_bw}Mbps 持续 ${elapsed}s → 限速 $rate"
                        fi
                        rm -f "${sdir}/high_since"
                    else
                        local need=$(( trig_dur - elapsed ))
                        echo -e "${YELLOW}[${ts}]${NC} 端口 ${port}(${proto})  带宽 ${BOLD}${current_bw}Mbps${NC}  已持续 $(format_duration "$elapsed")  还需 $(format_duration "$need") 触发限速"
                    fi
                fi
            else
                # 带宽正常
                if [ -f "${sdir}/high_since" ]; then
                    echo -e "${GREEN}[${ts}]${NC} 端口 ${port}(${proto})  带宽回落至 ${current_bw}Mbps ≤ ${trig_bw}Mbps  计时重置"
                    log "端口 $port($proto) 带宽回落 ${current_bw}Mbps，计时重置"
                    rm -f "${sdir}/high_since"
                else
                    echo -e "${DIM}[${ts}]${NC} 端口 ${port}(${proto})  正常  ${current_bw}Mbps / ${trig_bw}Mbps"
                fi
            fi
        done

        echo ""
    done
}

# ─────────────────────────────────────────────────────────
# 启动监控（后台 daemon）
# ─────────────────────────────────────────────────────────
start_monitor() {
    local pid_file="${STATE_DIR}/monitor.pid"
    if [ -f "$pid_file" ]; then
        local old_pid; old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            warn "监控守护进程已在运行 (PID=$old_pid)"
            return
        fi
    fi
    mkdir -p "$STATE_DIR"
    nohup "$SCRIPT_PATH" _monitor </dev/null >> "$LOG_FILE" 2>&1 &
    echo $! > "$pid_file"
    ok "监控守护进程已启动 (PID=$!)"
    log "监控守护进程启动 PID=$!"
}

stop_monitor() {
    local pid_file="${STATE_DIR}/monitor.pid"
    if [ -f "$pid_file" ]; then
        local pid; pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            rm -f "$pid_file"
            ok "监控守护进程已停止 (PID=$pid)"
            log "监控守护进程停止 PID=$pid"
        else
            warn "进程不存在，清理 PID 文件"
            rm -f "$pid_file"
        fi
    else
        warn "监控守护进程未运行"
    fi
}

monitor_status() {
    local pid_file="${STATE_DIR}/monitor.pid"
    if [ -f "$pid_file" ]; then
        local pid; pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "  监控进程: ${GREEN}运行中${NC}  (PID=$pid)"
            return 0
        fi
    fi
    echo -e "  监控进程: ${DIM}未运行${NC}"
    return 1
}

# ─────────────────────────────────────────────────────────
# 手动立即解除某端口限速
# ─────────────────────────────────────────────────────────
unlimit_port_now() {
    local port="$1" proto="$2"
    local key="${port}:${proto}"
    local sdir="${STATE_DIR}/${key//:/_}"

    # 找 handle
    load_config
    local h=10
    for k in "${!PORT_RULES[@]}"; do
        [ "$k" = "$key" ] && break
        h=$(( h + 10 ))
    done

    tc_unlimit_port "$h" "$port" "$proto"
    echo "normal" > "${sdir}/status"
    rm -f "${sdir}/high_since" "${sdir}/limit_until"
    ok "端口 $port($proto) 限速已手动解除"
    log "端口 $port($proto) 手动解除限速"
}

# ─────────────────────────────────────────────────────────
# 显示规则状态
# ─────────────────────────────────────────────────────────
show_rules() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║              QoS端口限速 v3.0 — 当前规则               ║${NC}"
    echo -e "${BOLD}${CYAN}╚═════════════════════════════════════════════════════╝${NC}"
    echo -e "  接口: ${BOLD}${INTERFACE}${NC}    采样间隔: ${MONITOR_INTERVAL}s"
    echo ""
    monitor_status
    echo ""

    if [ ${#PORT_RULES[@]} -eq 0 ]; then
        echo -e "  ${DIM}暂无规则${NC}"
    else
        printf "  ${BOLD}%-8s %-7s %-10s %-12s %-12s %-12s %-10s${NC}\n" \
            "端口" "协议" "限速至" "触发带宽" "触发持续" "限速时长" "当前状态"
        echo "  ─────────────────────────────────────────────────────────────────"

        for key in "${!PORT_RULES[@]}"; do
            local val="${PORT_RULES[$key]}"
            local rate trig_bw trig_dur limit_dur port proto
            rate=$(     echo "$val" | awk '{print $1}')
            trig_bw=$(  echo "$val" | awk '{print $2}')
            trig_dur=$( echo "$val" | awk '{print $3}')
            limit_dur=$(echo "$val" | awk '{print $4}')
            port=$( echo "$key" | cut -d: -f1)
            proto=$(echo "$key" | cut -d: -f2)

            local sdir="${STATE_DIR}/${key//:/_}"
            local status; status=$(cat "${sdir}/status" 2>/dev/null || echo "—")
            local status_str
            case "$status" in
                limited)
                    local lu; lu=$(cat "${sdir}/limit_until" 2>/dev/null || echo 0)
                    if [ "$lu" -gt 0 ] 2>/dev/null; then
                        local remain=$(( lu - $(date +%s) ))
                        [ "$remain" -lt 0 ] && remain=0
                        status_str="${RED}限速中${NC} $(format_duration "$remain")"
                    else
                        status_str="${RED}限速中(永久)${NC}"
                    fi
                    ;;
                normal) status_str="${GREEN}正常监控${NC}" ;;
                *)      status_str="${DIM}未启动${NC}" ;;
            esac

            local trig_str; trig_str="${trig_bw}Mbps"
            local ldur_str; ldur_str=$(format_duration "${limit_dur:-0}")

            printf "  %-8s %-7s %-10s %-12s %-12s %-12s " \
                "$port" "$proto" "$rate" "$trig_str" "$(format_duration "$trig_dur")" "$ldur_str"
            echo -e "$status_str"
        done
    fi

    echo ""
    if command -v systemctl &>/dev/null; then
        if systemctl is-enabled qos &>/dev/null 2>&1; then
            echo -e "  开机自启: ${GREEN}已启用${NC}"
        else
            echo -e "  开机自启: ${DIM}未启用${NC}"
        fi
    fi
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────
# 交互式：添加/修改规则向导
# ─────────────────────────────────────────────────────────
interactive_add() {
    local edit_key="${1:-}"
    local old_val=""
    [ -n "$edit_key" ] && old_val="${PORT_RULES[$edit_key]}"

    # 解析旧值（修改模式用）
    local old_rate old_tbw old_tdur old_ldur
    old_rate=$(echo "$old_val" | awk '{print $1}')
    old_tbw=$( echo "$old_val" | awk '{print $2}')
    old_tdur=$(echo "$old_val" | awk '{print $3}')
    old_ldur=$(echo "$old_val" | awk '{print $4}')

    echo ""
    echo -e "${BOLD}${BLUE}┌────────────────────────────────────────────────────────────────┐${NC}"
    if [ -n "$edit_key" ]; then
        local ep ep_proto
        ep=$(    echo "$edit_key" | cut -d: -f1)
        ep_proto=$(echo "$edit_key" | cut -d: -f2)
        echo -e "${BOLD}${BLUE}│  修改端口限速规则                                              │${NC}"
        echo -e "${BOLD}${BLUE}├────────────────────────────────────────────────────────────────┤${NC}"
        echo -e "  当前值: 端口 ${BOLD}${ep}${NC}(${ep_proto})  限速 ${BOLD}${old_rate}${NC}  触发 ${BOLD}${old_tbw} Mbps${NC} / ${BOLD}$(format_duration "$old_tdur")${NC}  限速时长 ${BOLD}$(format_duration "$old_ldur")${NC}"
    else
        echo -e "${BOLD}${BLUE}│  添加端口限速规则                                              │${NC}"
        echo -e "${BOLD}${BLUE}├────────────────────────────────────────────────────────────────┤${NC}"
        echo -e "  ${DIM}说明: 当端口流量持续超过触发阈值，自动限速；限速到期后继续监控${NC}"
    fi
    echo -e "${BOLD}${BLUE}└────────────────────────────────────────────────────────────────┘${NC}"
    echo ""

    local port proto

    # ── ① 端口号 ────────────────────────────────────────
    if [ -n "$edit_key" ]; then
        port=$( echo "$edit_key" | cut -d: -f1)
        proto=$(echo "$edit_key" | cut -d: -f2)
        echo -e "  ${BOLD}① 端口号${NC}  →  ${BOLD}${port}${NC}  （修改模式不可更改）"
    else
        echo -e "  ${BOLD}① 端口号${NC}  ${DIM}[ 范围: 1 - 65535 ]${NC}"
        while true; do
            read -rp "     端口号: " port
            [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
            err "无效，请输入 1-65535 之间的整数"
        done
    fi

    # ── ② 协议 ──────────────────────────────────────────
    echo ""
    if [ -n "$edit_key" ]; then
        echo -e "  ${BOLD}② 协议${NC}  →  ${BOLD}${proto}${NC}  （修改模式不可更改）"
    else
        echo -e "  ${BOLD}② 协议${NC}"
        echo "     1) TCP      （仅 TCP 流量）"
        echo "     2) UDP      （仅 UDP 流量）"
        echo "     3) TCP+UDP  （全部流量，推荐）"
        read -rp "     选择 [默认: 1=TCP]: " pc
        case "${pc:-1}" in 2) proto="udp";; 3) proto="both";; *) proto="tcp";; esac
        echo -e "     已选: ${BOLD}${proto}${NC}"
    fi

    # ── ③ 触发带宽阈值 ──────────────────────────────────
    echo ""
    echo -e "  ${BOLD}③ 触发带宽阈值${NC}  ${DIM}[ 单位: Mbps，接口总带宽超过此值开始计时 ]${NC}"
    [ -n "$old_tbw" ] && echo -e "     ${DIM}当前值: ${old_tbw} Mbps${NC}"
    local trig_bw default_tbw="${old_tbw:-80}"
    while true; do
        read -rp "     触发阈值 (Mbps) [默认: ${default_tbw} Mbps，直接回车]: " trig_bw
        [ -z "$trig_bw" ] && trig_bw="$default_tbw" && break
        [[ "$trig_bw" =~ ^[0-9]+(\.[0-9]+)?$ ]] && break
        err "请输入纯数字，如 80"
    done
    echo -e "     已设: ${BOLD}${trig_bw} Mbps${NC}"

    # ── ④ 触发持续时间 ──────────────────────────────────
    echo ""
    echo -e "  ${BOLD}④ 触发持续时间${NC}  ${DIM}[ 带宽持续超过阈值多久后才触发限速 ]${NC}"
    echo -e "     ${DIM}格式: 秒=s / 分=m / 时=h，如 300s  5m  1h${NC}"
    [ -n "$old_tdur" ] && echo -e "     ${DIM}当前值: $(format_duration "$old_tdur")（${old_tdur} 秒）${NC}"
    local trig_dur default_tdur="${old_tdur:-300}"
    while true; do
        read -rp "     持续时间 [默认: $(format_duration "$default_tdur")（${default_tdur} 秒），直接回车]: " tdi
        if [ -z "$tdi" ]; then
            trig_dur="$default_tdur"; break
        fi
        trig_dur=$(parse_duration "$tdi")
        [ "$trig_dur" != "-1" ] && [ "$trig_dur" -gt 0 ] && break
        err "格式无效或不能为 0，示例: 300s  5m  1h"
    done
    echo -e "     已设: ${BOLD}$(format_duration "$trig_dur")（${trig_dur} 秒）${NC}"

    # ── ⑤ 限速至（触发后的速率上限）────────────────────
    echo ""
    echo -e "  ${BOLD}⑤ 限速至${NC}  ${DIM}[ 触发后将带宽限制到此速率 ]${NC}"
    echo -e "     ${DIM}格式: kbit / mbit / gbit，如 512kbit  10mbit  1gbit${NC}"
    [ -n "$old_rate" ] && echo -e "     ${DIM}当前值: ${old_rate}${NC}"
    local rate default_rate="${old_rate:-10mbit}"
    while true; do
        read -rp "     限速值 [默认: ${default_rate}，直接回车]: " rate
        [ -z "$rate" ] && rate="$default_rate" && break
        [[ "${rate,,}" =~ ^[0-9]+(kbit|mbit|gbit|kbps|mbps|gbps|bps)$ ]] && break
        err "格式无效，示例: 512kbit  10mbit  1gbit"
    done
    rate="${rate,,}"
    echo -e "     已设: ${BOLD}${rate}${NC}"

    # ── ⑥ 限速时长 ──────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}⑥ 限速时长${NC}  ${DIM}[ 触发后限速持续多久，到期自动解除并继续监控 ]${NC}"
    echo -e "     ${DIM}格式: 秒=s / 分=m / 时=h，0 或直接回车=永久（需手动解除）${NC}"
    [ -n "$old_ldur" ] && echo -e "     ${DIM}当前值: $(format_duration "$old_ldur")（${old_ldur} 秒）${NC}"
    local limit_dur default_ldur="${old_ldur:-0}"
    while true; do
        if [ "$default_ldur" -eq 0 ] 2>/dev/null; then
            read -rp "     限速时长 [默认: 永久，直接回车]: " ldi
        else
            read -rp "     限速时长 [默认: $(format_duration "$default_ldur")（${default_ldur} 秒），直接回车]: " ldi
        fi
        if [ -z "$ldi" ]; then
            limit_dur="$default_ldur"; break
        fi
        limit_dur=$(parse_duration "$ldi")
        [ "$limit_dur" != "-1" ] && break
        err "格式无效，示例: 20m  1h  0=永久"
    done
    if [ "$limit_dur" -eq 0 ] 2>/dev/null; then
        echo -e "     已设: ${BOLD}永久${NC}  ${DIM}（需手动解除）${NC}"
    else
        echo -e "     已设: ${BOLD}$(format_duration "$limit_dur")（${limit_dur} 秒）${NC}"
    fi

    # ── 确认汇总 ─────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}${CYAN}┌── 规则确认 ──────────────────────────────────────────────────┐${NC}"
    echo -e "  ${BOLD}${CYAN}│${NC}  端口: ${BOLD}${port}${NC}  协议: ${BOLD}${proto}${NC}"
    echo -e "  ${BOLD}${CYAN}│${NC}  当 ${INTERFACE} 接口带宽 > ${BOLD}${trig_bw} Mbps${NC} 持续 ${BOLD}$(format_duration "$trig_dur")（${trig_dur}秒）${NC}"
    echo -e "  ${BOLD}${CYAN}│${NC}  → 自动限速至 ${BOLD}${rate}${NC}"
    if [ "$limit_dur" -gt 0 ] 2>/dev/null; then
        echo -e "  ${BOLD}${CYAN}│${NC}  → 限速 ${BOLD}$(format_duration "$limit_dur")（${limit_dur}秒）${NC} 后自动解除，恢复监控（可循环）"
    else
        echo -e "  ${BOLD}${CYAN}│${NC}  → ${BOLD}永久限速${NC}，需从菜单手动解除"
    fi
    echo -e "  ${BOLD}${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    read -rp "  确认保存? [Y/n]: " confirm
    [[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { warn "已取消"; return; }

    local new_key="${port}:${proto}"
    [ -n "$edit_key" ] && [ "$edit_key" != "$new_key" ] && unset "PORT_RULES[$edit_key]"

    PORT_RULES["$new_key"]="${rate} ${trig_bw} ${trig_dur} ${limit_dur}"
    ok "规则已保存 ✓  （记得选「保存配置」写入磁盘）"
    log "规则: 端口=$port 协议=$proto 限速=$rate 触发=${trig_bw}Mbps 持续=${trig_dur}s 限速时长=${limit_dur}s"
    echo -e "${BOLD}${BLUE}└────────────────────────────────────────────────────────────────┘${NC}"
}

interactive_edit() {
    [ ${#PORT_RULES[@]} -eq 0 ] && warn "没有可修改的规则" && return
    echo ""
    echo -e "${BOLD}${BLUE}┌─ 选择要修改的规则 ──────────────────────────────────────────────┐${NC}"
    local i=1; declare -a ekeys
    for key in "${!PORT_RULES[@]}"; do
        local val="${PORT_RULES[$key]}"
        printf "  ${BOLD}%2d)${NC}  端口 %-6s 协议 %-6s → 限速 %-8s 触发 %sMbps/%-8s 限速时长 %s\n" \
            "$i" "$(echo $key|cut -d: -f1)" "$(echo $key|cut -d: -f2)" \
            "$(echo $val|awk '{print $1}')" \
            "$(echo $val|awk '{print $2}')" \
            "$(format_duration "$(echo $val|awk '{print $3}')")" \
            "$(format_duration "$(echo $val|awk '{print $4}')")"
        ekeys+=("$key"); i=$(( i+1 ))
    done
    echo ""
    read -rp "  选择编号 (0=取消): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ekeys[@]}" ] \
        || { warn "已取消"; return; }
    interactive_add "${ekeys[$((choice-1))]}"
}

interactive_delete() {
    [ ${#PORT_RULES[@]} -eq 0 ] && warn "没有可删除的规则" && return
    echo ""
    echo -e "${BOLD}${BLUE}┌─ 删除端口限速规则 ──────────────────────────────────────────────┐${NC}"
    local i=1; declare -a dkeys
    for key in "${!PORT_RULES[@]}"; do
        local val="${PORT_RULES[$key]}"
        printf "  ${BOLD}%2d)${NC}  端口 %-6s 协议 %-6s → 限速 %-8s 触发 %sMbps\n" \
            "$i" "$(echo $key|cut -d: -f1)" "$(echo $key|cut -d: -f2)" \
            "$(echo $val|awk '{print $1}')" "$(echo $val|awk '{print $2}')"
        dkeys+=("$key"); i=$(( i+1 ))
    done
    echo ""
    read -rp "  输入编号删除 (0=取消): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#dkeys[@]}" ]; then
        local dk="${dkeys[$((choice-1))]}"
        unset "PORT_RULES[$dk]"
        rm -rf "${STATE_DIR}/${dk//:/_}"
        ok "已删除规则: $dk"
        log "删除规则: $dk"
    else
        warn "已取消"
    fi
    echo -e "${BOLD}${BLUE}└────────────────────────────────────────────────────────────────┘${NC}"
}

change_interface() {
    echo ""
    echo -e "${BOLD}${BLUE}┌─ 更改网络接口 ──────────────────────────────────────────────────┐${NC}"
    local detected; detected=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
    echo "  当前接口: ${BOLD}$INTERFACE${NC}"
    [ -n "$detected" ] && echo "  检测默认: ${BOLD}$detected${NC}"
    echo ""
    echo "  可用接口:"
    ip -o link show 2>/dev/null | awk -F': ' '{print "    • " $2}' | grep -v '• lo$'
    echo ""
    read -rp "  输入接口名 [回车保持不变]: " new_iface
    [ -n "$new_iface" ] && INTERFACE="$new_iface" && ok "接口已更改为: $INTERFACE" || info "接口未变更"
    echo -e "${BOLD}${BLUE}└────────────────────────────────────────────────────────────────┘${NC}"
}

change_interval() {
    echo ""
    echo -e "${BOLD}${BLUE}┌─ 修改监控采样间隔 ──────────────────────────────────────────────┐${NC}"
    echo "  当前采样间隔: ${BOLD}${MONITOR_INTERVAL}秒${NC}"
    echo -e "  ${DIM}间隔越短越灵敏，但 CPU 占用越高。推荐 5-30 秒${NC}"
    echo ""
    local new_interval
    read -rp "  新采样间隔 (秒，回车保持不变): " new_interval
    if [[ "$new_interval" =~ ^[0-9]+$ ]] && [ "$new_interval" -ge 1 ]; then
        MONITOR_INTERVAL="$new_interval"
        ok "采样间隔已设为 ${MONITOR_INTERVAL}秒"
    else
        [ -n "$new_interval" ] && err "无效值" || info "未变更"
    fi
    echo -e "${BOLD}${BLUE}└────────────────────────────────────────────────────────────────┘${NC}"
}

# ─────────────────────────────────────────────────────────
# 安装 systemd 服务
# ─────────────────────────────────────────────────────────
install_service() {
    info "安装 systemd 服务..."
    cp -f "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    cat > "$SERVICE_FILE" <<'SVCEOF'
[Unit]
Description=QoS 端口限速监控服务
After=network.target
Wants=network.target

[Service]
Type=forking
PIDFile=/run/qos/monitor.pid
ExecStart=/usr/local/bin/qos start
ExecStop=/usr/local/bin/qos stop
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable qos 2>/dev/null
    ok "systemd 服务已安装并启用开机自启 ✓"
    ok "快捷命令已安装 → $SCRIPT_PATH"
    log "systemd 服务已安装"
}

uninstall_service() {
    systemctl stop    qos 2>/dev/null
    systemctl disable qos 2>/dev/null
    rm -f "$SERVICE_FILE" "$SCRIPT_PATH"
    systemctl daemon-reload 2>/dev/null
    warn "QoS 服务已卸载"
    log "服务已卸载"
}

show_tc_status() {
    echo ""
    echo -e "${BOLD}${CYAN}── TC 底层状态 (${INTERFACE}) ──────────────────────────────────${NC}"
    echo -e "\n${BLUE}[qdisc]${NC}";  tc qdisc  show dev "$INTERFACE" 2>/dev/null || echo "  (空)"
    echo -e "\n${BLUE}[class]${NC}";  tc class  show dev "$INTERFACE" 2>/dev/null || echo "  (空)"
    echo -e "\n${BLUE}[filter]${NC}"; tc filter show dev "$INTERFACE" 2>/dev/null || echo "  (空)"
    echo ""
}

show_log() {
    echo ""
    echo -e "${BOLD}${CYAN}── 最近 30 条日志 ──────────────────────────────────────────────${NC}"
    tail -30 "$LOG_FILE" 2>/dev/null || echo "  (暂无日志)"
    echo ""
}

# ─────────────────────────────────────────────────────────
# 交互式主菜单
# ─────────────────────────────────────────────────────────
interactive_menu() {
    load_config
    while true; do
        clear
        echo -e "${BOLD}${GREEN}"
        echo "  ╔═════════════════════════════════════════════════════╗"
        echo "  ║          QoS 端口智能限速管理工具  v3.0                 ║"
        echo "  ╚═════════════════════════════════════════════════════╝${NC}"

        show_rules

        echo -e "  ${BOLD}规则管理${NC}"
        echo "  ──────────────────────────────────────────────────────────"
        echo "  1) 添加端口触发限速规则"
        echo "  2) 修改端口触发限速规则"
        echo "  3) 删除端口触发限速规则"
        echo "  ──────────────────────────────────────────────────────────"
        echo -e "  ${BOLD}监控控制${NC}"
        echo "  4) 启动监控（开始自动检测并触发限速）"
        echo "  5) 停止监控"
        echo "  6) 手动解除某端口当前限速"
        echo "  ──────────────────────────────────────────────────────────"
        echo -e "  ${BOLD}配置与系统${NC}"
        echo "  7) 保存配置"
        echo "  8) 更改网络接口"
        echo "  9) 修改监控采样间隔（当前: ${MONITOR_INTERVAL}s）"
        echo "  t) 查看 TC 底层状态"
        echo "  l) 查看运行日志"
        echo "  ──────────────────────────────────────────────────────────"
        echo "  i) 安装/更新系统服务（开机自启）"
        echo "  u) 卸载系统服务"
        echo "  d) 重新检测/安装依赖"
        echo "  0) 退出"
        echo "  ──────────────────────────────────────────────────────────"
        read -rp "  请选择: " choice

        case "$choice" in
            1) interactive_add "" ;;
            2) interactive_edit ;;
            3) interactive_delete ;;
            4) save_config; start_monitor ;;
            5) stop_monitor ;;
            6)
                read -rp "  端口号: " up; read -rp "  协议 (tcp/udp/both): " upr
                unlimit_port_now "$up" "${upr:-tcp}"
                ;;
            7) save_config ;;
            8) change_interface ;;
            9) change_interval ;;
            t|T) show_tc_status ;;
            l|L) show_log ;;
            i|I) save_config; install_service ;;
            u|U) uninstall_service ;;
            d|D) bootstrap_deps force ;;
            0) echo -e "\n${GREEN}  再见！${NC}\n"; exit 0 ;;
            *) err "无效选项: $choice" ;;
        esac

        echo ""
        read -rp "  按 Enter 继续..." _
    done
}

# ─────────────────────────────────────────────────────────
# 一键安装：将脚本装到系统路径，注册 qos 快捷命令
# ─────────────────────────────────────────────────────────
do_setup() {
    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}          QoS 快捷命令安装向导                      ${NC}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    require_root

    # 1. 复制脚本到系统路径
    step "安装脚本到 ${BOLD}${QOS_BIN}${NC} ..."
    cp -f "$SCRIPT_SELF" "$QOS_BIN" || { err "复制失败，请检查权限"; exit 1; }
    chmod +x "$QOS_BIN"
    # 修复行尾符（防止 Windows 上传的文件）
    sed -i 's/\r//' "$QOS_BIN" 2>/dev/null || true
    ok "脚本已安装 → ${QOS_BIN}"

    # 2. 创建配置目录
    mkdir -p /etc/qos /run/qos
    ok "配置目录已创建 → /etc/qos"

    # 3. 检测并安装依赖
    echo ""
    bootstrap_deps

    # 4. 注册 systemd 服务（开机自启）
    echo ""
    read -rp "  是否注册开机自启服务? [Y/n]: " reg
    if [[ "${reg:-Y}" =~ ^[Yy]$ ]]; then
        load_config
        install_service
    fi

    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    ok "安装完成！现在直接输入 ${BOLD}qos${NC} 即可启动"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────
# 帮助
# ─────────────────────────────────────────────────────────
usage() {
    echo ""
    echo -e "${BOLD}用法:${NC}  qos [命令]"
    echo ""
    echo -e "  ${BOLD}命令:${NC}"
    printf "  %-38s %s\n" "(无参数)"                   "进入交互式菜单"
    printf "  %-38s %s\n" "setup"                      "首次安装：注册 qos 快捷命令 + 依赖 + 自启"
    printf "  %-38s %s\n" "start"                      "启动监控守护进程"
    printf "  %-38s %s\n" "stop"                       "停止监控守护进程"
    printf "  %-38s %s\n" "status"                     "显示规则与监控状态"
    printf "  %-38s %s\n" "clear"                      "清除所有 TC 规则"
    printf "  %-38s %s\n" "install"                    "安装 systemd 服务（开机自启）"
    printf "  %-38s %s\n" "uninstall"                  "卸载系统服务"
    printf "  %-38s %s\n" "check-deps"                 "强制检测并安装依赖"
    printf "  %-38s %s\n" "_monitor"                   "（内部）监控守护进程主循环"
    printf "  %-38s %s\n" "help"                       "显示此帮助"
    echo ""
    echo -e "  ${BOLD}时长格式:${NC}  30s  5m  2h  1d  1h30m  90（=90分钟）  0=永久"
    echo ""
}

# ─────────────────────────────────────────────────────────
# 主入口
# ─────────────────────────────────────────────────────────
case "${1:-}" in
    setup)
        do_setup ;;
    start)
        require_root; bootstrap_deps; load_config; start_monitor ;;
    stop)
        require_root; stop_monitor ;;
    status)
        load_config; show_rules; show_tc_status ;;
    clear)
        require_root; load_config; clear_rules ;;
    _monitor)
        # 内部调用：守护进程主循环
        monitor_daemon ;;
    install)
        require_root; load_config; install_service ;;
    uninstall)
        require_root; uninstall_service ;;
    check-deps)
        require_root; bootstrap_deps force ;;
    help|--help|-h)
        usage ;;
    "")
        require_root; bootstrap_deps; interactive_menu ;;
    *)
        err "未知命令: $1"; usage; exit 1 ;;
esac
