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
QOS_VERSION="3.1.2"
QOS_UPDATE_URL="https://raw.githubusercontent.com/lyp88997/Server-QoS-Pro/refs/heads/main/qos.sh"

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
        printf "\033[1;33m[!] 检测到首次运行，尚未安装快捷命令 'qos'\033[0m\n"
        printf "\033[0;36m[→] 请执行以下命令完成安装：\033[0m\n"
        echo ""
        printf "    \033[1msudo bash $SCRIPT_SELF setup\033[0m\n"
        echo ""
        printf "\033[2m    安装后直接输入 qos 即可启动\033[0m\n"
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
    printf "${BOLD}${CYAN}--------------------------------------------------${NC}"
    printf "${BOLD}${CYAN}              依赖检测与自动安装                    ${NC}\n"
    printf "${BOLD}${CYAN}--------------------------------------------------${NC}"
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
            printf "  ${GREEN}✓${NC}  ${BOLD}${cmd}${NC}  ${DIM}${desc}${NC}\n"
        else
            printf "  ${RED}✗${NC}  ${BOLD}${cmd}${NC}  ${DIM}${desc}${NC}  ${YELLOW}← 缺失${NC}\n"
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
# PORT_RULES[端口:协议] = "1级速率 2级速率 触发带宽Mbps 触发持续秒 2级限速时长秒 2级开关"
# 字段6: l2_enabled = 1(开启2级) 或 0(仅1级永久限速)
#
# 示例(2级开启): PORT_RULES[443:tcp] = "30mbit 5mbit 80 300 600 1"
#   → 以 30mbit 运行；超过 80Mbps 持续 300s → 降至 5mbit；600s 后恢复 30mbit
# 示例(仅1级):   PORT_RULES[443:tcp] = "30mbit - 0 0 0 0"
#   → 始终以 30mbit 永久限速，不监测触发
# ─────────────────────────────────────────────────────────
load_config() {
    declare -gA PORT_RULES=()
    INTERFACE=""
    # MONITOR_INTERVAL 只在未被外部设置时才从配置读取
    local _mi_from_config=""

    if [ -f "$CONFIG_FILE" ]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            if [[ "$line" =~ ^INTERFACE=\"(.*)\"$ ]]; then
                INTERFACE="${BASH_REMATCH[1]}"
                continue
            fi
            if [[ "$line" =~ ^MONITOR_INTERVAL=([0-9]+)$ ]]; then
                _mi_from_config="${BASH_REMATCH[1]}"
                continue
            fi
            if [[ "$line" =~ ^PORT_RULES\[\"([^\"]+)\"\]=\"(.*)\"$ ]]; then
                PORT_RULES["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
                continue
            fi
        done < "$CONFIG_FILE"
    fi

    [ -n "$_mi_from_config" ] && MONITOR_INTERVAL="$_mi_from_config"

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
        echo "MONITOR_INTERVAL=${MONITOR_INTERVAL}"
        echo ""
        echo "# PORT_RULES[端口:协议]=\"1级速率 2级速率 触发带宽Mbps 触发持续秒 2级限速时长秒 2级开关(1/0)\""
        for key in "${!PORT_RULES[@]}"; do
            echo "PORT_RULES[\"$key\"]=\"${PORT_RULES[$key]}\""
        done
    } > "$CONFIG_FILE"
    ok "配置已保存 -> $CONFIG_FILE"
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
    # 只取 TX（上行）字节数，与限速方向一致
    # /proc/net/dev 列: iface rx_bytes ... tx_bytes(第10列)
    local iface="$1" interval="${2:-$MONITOR_INTERVAL}"
    local tx1 tx2
    tx1=$(awk -v i="$iface:" '$1==i{print $10}' /proc/net/dev 2>/dev/null || echo 0)
    sleep "$interval"
    tx2=$(awk -v i="$iface:" '$1==i{print $10}' /proc/net/dev 2>/dev/null || echo 0)
    local diff=$(( tx2 - tx1 ))
    [ "$diff" -lt 0 ] && diff=0   # 计数器回绕保护
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

    # SIGHUP 触发热重载标志
    _RELOAD_FLAG=0
    trap '_RELOAD_FLAG=1' HUP

    # 初始化 TC 根结构
    init_tc

    # 构建 handle 映射并下发 1 级限速的函数（启动和热重载共用）
    _apply_rules() {
        local old_keys_snapshot="$1"   # 空格分隔的旧 key 列表，用于清理已删除端口

        # 清理已被删除的端口的 TC 类和 iptables mark
        for old_key in $old_keys_snapshot; do
            if [ -z "${PORT_RULES[$old_key]+x}" ]; then
                local op op_proto oh
                op=$(echo "$old_key" | cut -d: -f1)
                op_proto=$(echo "$old_key" | cut -d: -f2)
                oh="${PORT_HANDLE[$old_key]:-0}"
                [ "$oh" -gt 0 ] && _ipt_clear_port "$op" "$op_proto" "$oh" 2>/dev/null || true
                [ "$oh" -gt 0 ] && tc class change dev "$INTERFACE" parent 1: classid "1:${oh}" \
                    htb rate 10gbit ceil 10gbit 2>/dev/null || true
                unset "PORT_HANDLE[$old_key]"
                local sdir="${STATE_DIR}/${old_key//:/_}"
                rm -rf "$sdir"
                log "规则已删除，清理 TC: $old_key"
            fi
        done

        # 为新端口分配 handle，已有端口保持不变
        local h=10
        for key in "${!PORT_RULES[@]}"; do
            # 找一个未被占用的 handle
            while true; do
                local taken=false
                for k in "${!PORT_HANDLE[@]}"; do
                    [ "${PORT_HANDLE[$k]}" = "$h" ] && taken=true && break
                done
                $taken && h=$(( h + 10 )) || break
            done
            if [ -z "${PORT_HANDLE[$key]+x}" ]; then
                PORT_HANDLE[$key]=$h
                h=$(( h + 10 ))
            fi
        done

        # 对每个规则下发/更新 TC 限速
        for key in "${!PORT_RULES[@]}"; do
            local val="${PORT_RULES[$key]}"
            local rate1 port proto
            rate1=$(echo "$val" | awk '{print $1}')
            port=$( echo "$key" | cut -d: -f1)
            proto=$(echo "$key" | cut -d: -f2)
            local hh="${PORT_HANDLE[$key]}"
            local sdir="${STATE_DIR}/${key//:/_}"
            mkdir -p "$sdir"

            local cur_status; cur_status=$(cat "${sdir}/status" 2>/dev/null || echo "")

            if [ -z "$cur_status" ]; then
                # 全新端口：初始化为 level1
                tc_limit_port "$port" "$proto" "$rate1" "$hh"
                echo "level1" > "${sdir}/status"
                rm -f "${sdir}/high_since" "${sdir}/limit_until"
                ok "端口 ${BOLD}${port}${NC}(${proto})  1级限速已启用: ${BOLD}${rate1}${NC}"
                log "端口 $port($proto) 新增，1级限速: $rate1"
            elif [ "$cur_status" = "level1" ]; then
                # 已在 level1，更新速率（参数可能变了）
                tc_limit_port "$port" "$proto" "$rate1" "$hh"
                log "端口 $port($proto) 参数更新，1级速率重下发: $rate1"
            fi
            # level2 状态下不干预速率，等自然到期回 level1
        done
    }

    # 首次初始化
    declare -A PORT_HANDLE
    _apply_rules ""
    info "开始监控 ${#PORT_RULES[@]} 条端口规则..."
    echo ""

    while true; do
        # 收到 SIGHUP → 热重载配置
        if [ "$_RELOAD_FLAG" = "1" ]; then
            _RELOAD_FLAG=0
            local old_keys="${!PORT_RULES[*]}"
            load_config
            log "收到 SIGHUP，重载配置..."
            info "配置已变更，重新应用规则..."
            _apply_rules "$old_keys"
            info "热重载完成，当前监控 ${#PORT_RULES[@]} 条规则"
            echo ""
        fi

        load_config   # 仍保留轮询加载（兼容直接编辑配置文件的场景）

        local now; now=$(date +%s)
        local iface_bw
        iface_bw=$(get_iface_bw_mbps "$INTERFACE" "$MONITOR_INTERVAL")

        for key in "${!PORT_RULES[@]}"; do
            local val="${PORT_RULES[$key]}"
            local rate1 rate2 trig_bw trig_dur limit_dur l2_en port proto
            rate1=$(    echo "$val" | awk '{print $1}')
            rate2=$(    echo "$val" | awk '{print $2}')
            trig_bw=$(  echo "$val" | awk '{print $3}')
            trig_dur=$( echo "$val" | awk '{print $4}')
            limit_dur=$(echo "$val" | awk '{print $5}')
            l2_en=$(    echo "$val" | awk '{print $6}')
            [ -z "$l2_en" ] && l2_en="1"   # 旧配置兼容
            port=$( echo "$key" | cut -d: -f1)
            proto=$(echo "$key" | cut -d: -f2)

            local sdir="${STATE_DIR}/${key//:/_}"
            mkdir -p "$sdir"
            local status; status=$(cat "${sdir}/status" 2>/dev/null || echo "level1")
            local handle="${PORT_HANDLE[$key]:-10}"
            local ts; ts=$(date '+%H:%M:%S')

            # ── 2级关闭：仅维持1级，打印状态即跳过 ─────────
            if [ "$l2_en" = "0" ]; then
                printf "${DIM}[%s]${NC} 端口 %s(%s)  ${GREEN}1级限速${NC} %s  ${DIM}[2级关闭]${NC}\n" \
                    "$ts" "$port" "$proto" "$rate1"
                continue
            fi

            # ── 当前处于 2 级限速状态 ────────────────────────
            if [ "$status" = "level2" ]; then
                local limit_until; limit_until=$(cat "${sdir}/limit_until" 2>/dev/null || echo 0)

                if [ "$limit_dur" -gt 0 ] 2>/dev/null && [ "$now" -ge "$limit_until" ]; then
                    tc_limit_port "$port" "$proto" "$rate1" "$handle"
                    echo "level1" > "${sdir}/status"
                    rm -f "${sdir}/high_since" "${sdir}/limit_until"
                    printf "${GREEN}[%s]${NC} 端口 ${BOLD}%s${NC}(%s)  2级到期 -> ${GREEN}恢复1级 %s${NC}  继续监控\n" \
                        "$ts" "$port" "$proto" "$rate1"
                    log "端口 $port($proto) 2级到期，恢复1级 $rate1"
                else
                    local remain=$(( limit_until - now ))
                    [ "$remain" -lt 0 ] && remain=0
                    if [ "$limit_dur" -gt 0 ] 2>/dev/null; then
                        printf "${DIM}[%s]${NC} 端口 %s(%s)  ${RED}2级限速${NC} %s  剩余 %s\n" \
                            "$ts" "$port" "$proto" "$rate2" "$(format_duration "$remain")"
                    else
                        printf "${DIM}[%s]${NC} 端口 %s(%s)  ${RED}2级限速${NC} %s  ${DIM}[永久]${NC}\n" \
                            "$ts" "$port" "$proto" "$rate2"
                    fi
                fi
                continue
            fi

            # ── 当前处于 1 级，监测带宽 ──────────────────────
            local current_bw="$iface_bw"
            local over; over=$(echo "$current_bw > $trig_bw" | bc -l 2>/dev/null || echo 0)

            if [ "$over" = "1" ]; then
                if [ ! -f "${sdir}/high_since" ]; then
                    echo "$now" > "${sdir}/high_since"
                    printf "${YELLOW}[%s]${NC} 端口 ${BOLD}%s${NC}(%s)  ${YELLOW}1级${NC} %s  带宽 ${BOLD}%sMbps${NC} > 阈值 %sMbps  开始计时...\n" \
                        "$ts" "$port" "$proto" "$rate1" "$current_bw" "$trig_bw"
                    log "端口 $port($proto) 带宽 ${current_bw}Mbps 超阈值 ${trig_bw}Mbps，计时开始"
                else
                    local high_since; high_since=$(cat "${sdir}/high_since")
                    local elapsed=$(( now - high_since ))

                    if [ "$elapsed" -ge "$trig_dur" ]; then
                        tc_limit_port "$port" "$proto" "$rate2" "$handle"
                        echo "level2" > "${sdir}/status"
                        rm -f "${sdir}/high_since"

                        if [ "$limit_dur" -gt 0 ] 2>/dev/null; then
                            echo $(( now + limit_dur )) > "${sdir}/limit_until"
                            printf "${RED}[%s]${NC} 端口 ${BOLD}%s${NC}(%s)  !! 触发2级  %sMbps 持续 %s -> ${BOLD}%s${NC}  %s 后恢复 %s\n" \
                                "$ts" "$port" "$proto" "$current_bw" \
                                "$(format_duration "$elapsed")" "$rate2" \
                                "$(format_duration "$limit_dur")" "$rate1"
                            log "端口 $port($proto) 触发2级: ${current_bw}Mbps 持续 ${elapsed}s -> $rate2，${limit_dur}s 后恢复 $rate1"
                        else
                            echo "0" > "${sdir}/limit_until"
                            printf "${RED}[%s]${NC} 端口 ${BOLD}%s${NC}(%s)  !! 触发2级  %sMbps 持续 %s -> ${BOLD}%s${NC}  ${DIM}[永久，需手动恢复]${NC}\n" \
                                "$ts" "$port" "$proto" "$current_bw" \
                                "$(format_duration "$elapsed")" "$rate2"
                            log "端口 $port($proto) 触发2级永久: ${current_bw}Mbps 持续 ${elapsed}s -> $rate2"
                        fi
                    else
                        local need=$(( trig_dur - elapsed ))
                        printf "${YELLOW}[%s]${NC} 端口 %s(%s)  ${YELLOW}1级${NC} %s  %sMbps  计时 %s/%s  还需 %s\n" \
                            "$ts" "$port" "$proto" "$rate1" "$current_bw" \
                            "$(format_duration "$elapsed")" "$(format_duration "$trig_dur")" \
                            "$(format_duration "$need")"
                    fi
                fi
            else
                if [ -f "${sdir}/high_since" ]; then
                    printf "${GREEN}[%s]${NC} 端口 %s(%s)  ${GREEN}1级${NC} %s  带宽回落 %sMbps <= %sMbps  计时重置\n" \
                        "$ts" "$port" "$proto" "$rate1" "$current_bw" "$trig_bw"
                    log "端口 $port($proto) 带宽回落 ${current_bw}Mbps，计时重置"
                    rm -f "${sdir}/high_since"
                else
                    printf "${DIM}[%s]${NC} 端口 %s(%s)  ${GREEN}1级${NC} %s  %sMbps / 阈值 %sMbps\n" \
                        "$ts" "$port" "$proto" "$rate1" "$current_bw" "$trig_bw"
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

# 通知守护进程重新加载配置（发 SIGHUP）
# 若守护进程未运行则跳过
_notify_daemon_reload() {
    local pid_file="${STATE_DIR}/monitor.pid"
    if [ -f "$pid_file" ]; then
        local pid; pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill -HUP "$pid" 2>/dev/null
            ok "已通知监控进程重载配置（立即生效）"
            log "发送 SIGHUP 至守护进程 PID=$pid"
        fi
    fi
}

monitor_status() {
    local pid_file="${STATE_DIR}/monitor.pid"
    if [ -f "$pid_file" ]; then
        local pid; pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            printf "  监控进程: ${GREEN}运行中${NC}  (PID=$pid)\n"
            return 0
        fi
    fi
    printf "  监控进程: ${DIM}未运行${NC}\n"
    return 1
}

# ─────────────────────────────────────────────────────────
# 手动将端口从 2级 恢复到 1级
# ─────────────────────────────────────────────────────────
unlimit_port_now() {
    local port="$1" proto="$2"
    local key="${port}:${proto}"
    local sdir="${STATE_DIR}/${key//:/_}"

    load_config
    local val="${PORT_RULES[$key]:-}"
    if [ -z "$val" ]; then
        err "未找到端口 $port($proto) 的规则"; return 1
    fi
    local rate1; rate1=$(echo "$val" | awk '{print $1}')

    # 找 handle
    local h=10
    for k in "${!PORT_RULES[@]}"; do
        [ "$k" = "$key" ] && break
        h=$(( h + 10 ))
    done

    tc_limit_port "$port" "$proto" "$rate1" "$h"
    echo "level1" > "${sdir}/status"
    rm -f "${sdir}/high_since" "${sdir}/limit_until"
    ok "端口 $port($proto) 已手动恢复至 1级限速: $rate1"
    log "端口 $port($proto) 手动恢复1级: $rate1"
}

# ─────────────────────────────────────────────────────────
# 显示规则状态
# ─────────────────────────────────────────────────────────
show_rules() {
    local W=70
    local line; printf -v line '%*s' "$W" ''; line="${line// /-}"

    printf "\n"
    printf "${BOLD}${CYAN}+%s+${NC}\n" "$line"
    printf "${BOLD}${CYAN}|  %-*s|${NC}\n" $(( W - 1 )) "QoS 端口限速 v${QOS_VERSION} -- 当前规则"
    printf "${BOLD}${CYAN}+%s+${NC}\n" "$line"
    printf "  接口: ${BOLD}%s${NC}    采样间隔: %ss\n" "$INTERFACE" "$MONITOR_INTERVAL"
    printf "\n"
    monitor_status
    printf "\n"

    if [ ${#PORT_RULES[@]} -eq 0 ]; then
        printf "  ${DIM}暂无规则${NC}\n"
    else
        printf "  ${BOLD}%-7s %-5s %-9s %-9s %-9s %-9s %-9s %-4s  %-16s${NC}\n" \
            "端口" "协议" "1级速率" "2级速率" "触发带宽" "触发持续" "2级时长" "2级" "当前状态"
        printf "  %s\n" "$(printf '%0.s-' {1..80})"

        for key in "${!PORT_RULES[@]}"; do
            local val="${PORT_RULES[$key]}"
            local rate1 rate2 trig_bw trig_dur limit_dur l2_en port proto
            rate1=$(    echo "$val" | awk '{print $1}')
            rate2=$(    echo "$val" | awk '{print $2}')
            trig_bw=$(  echo "$val" | awk '{print $3}')
            trig_dur=$( echo "$val" | awk '{print $4}')
            limit_dur=$(echo "$val" | awk '{print $5}')
            l2_en=$(    echo "$val" | awk '{print $6}')
            [ -z "$l2_en" ] && l2_en="1"   # 旧配置无第6字段默认开启
            port=$( echo "$key" | cut -d: -f1)
            proto=$(echo "$key" | cut -d: -f2)

            local sdir="${STATE_DIR}/${key//:/_}"
            local status; status=$(cat "${sdir}/status" 2>/dev/null || echo "-")

            # 2级开关标识
            local l2_str
            if [ "$l2_en" = "1" ]; then
                l2_str="${GREEN}ON${NC}"
            else
                l2_str="${DIM}OFF${NC}"
            fi

            # 当前状态
            local status_str
            if [ "$l2_en" = "0" ]; then
                case "$status" in
                    level1) status_str="${GREEN}限速中 ${rate1}${NC}" ;;
                    *)      status_str="${DIM}未启动${NC}" ;;
                esac
            else
                case "$status" in
                    level1)
                        status_str="${GREEN}1级 ${rate1}${NC}"
                        ;;
                    level2)
                        local lu; lu=$(cat "${sdir}/limit_until" 2>/dev/null || echo 0)
                        if [ "$lu" -gt 0 ] 2>/dev/null; then
                            local remain=$(( lu - $(date +%s) ))
                            [ "$remain" -lt 0 ] && remain=0
                            status_str="${RED}2级 ${rate2}${NC} ${DIM}剩$(format_duration "$remain")${NC}"
                        else
                            status_str="${RED}2级 ${rate2} [永久]${NC}"
                        fi
                        ;;
                    *) status_str="${DIM}未启动${NC}" ;;
                esac
            fi

            # 2级关闭时，2级相关字段显示 -
            local r2_disp trig_bw_disp trig_dur_disp ldur_disp
            if [ "$l2_en" = "0" ]; then
                r2_disp="-"; trig_bw_disp="-"; trig_dur_disp="-"; ldur_disp="-"
            else
                r2_disp="$rate2"
                trig_bw_disp="${trig_bw}Mbps"
                trig_dur_disp="$(format_duration "$trig_dur")"
                ldur_disp="$(format_duration "${limit_dur:-0}")"
            fi

            printf "  %-7s %-5s %-9s %-9s %-9s %-9s %-9s " \
                "$port" "$proto" "$rate1" "$r2_disp" \
                "$trig_bw_disp" "$trig_dur_disp" "$ldur_disp"
            printf "${l2_str}    ${status_str}\n"
        done
    fi

    printf "\n"
    if command -v systemctl &>/dev/null; then
        if systemctl is-enabled qos &>/dev/null 2>&1; then
            printf "  开机自启: ${GREEN}已启用${NC}\n"
        else
            printf "  开机自启: ${DIM}未启用${NC}\n"
        fi
    fi
    printf "${BOLD}${CYAN}+%s+${NC}\n\n" "$line"
}

# ─────────────────────────────────────────────────────────
# 交互式：添加/修改规则向导
# ─────────────────────────────────────────────────────────
interactive_add() {
    local edit_key="${1:-}"
    local old_val=""
    [ -n "$edit_key" ] && old_val="${PORT_RULES[$edit_key]}"

    local old_rate1 old_rate2 old_tbw old_tdur old_ldur old_l2en
    old_rate1=$(echo "$old_val" | awk '{print $1}')
    old_rate2=$(echo "$old_val" | awk '{print $2}')
    old_tbw=$( echo "$old_val" | awk '{print $3}')
    old_tdur=$(echo "$old_val" | awk '{print $4}')
    old_ldur=$(echo "$old_val" | awk '{print $5}')
    old_l2en=$( echo "$old_val" | awk '{print $6}')
    [ -z "$old_l2en" ] && old_l2en="1"

    local W=60
    local hline; printf -v hline '%*s' "$W" ''; hline="${hline// /-}"

    printf "\n"
    printf "${BOLD}${BLUE}+%s+${NC}\n" "$hline"
    if [ -n "$edit_key" ]; then
        local ep ep_proto
        ep=$(echo "$edit_key" | cut -d: -f1)
        ep_proto=$(echo "$edit_key" | cut -d: -f2)
        printf "${BOLD}${BLUE}|  %-*s|${NC}\n" $(( W - 1 )) "修改端口限速规则"
        printf "${BOLD}${BLUE}+%s+${NC}\n" "$hline"
        printf "  当前: 端口 ${BOLD}%s${NC}(%s)  1级 ${BOLD}%s${NC}  2级 %s\n" \
            "$ep" "$ep_proto" "$old_rate1" \
            "$( [ "$old_l2en" = "1" ] && printf "${GREEN}ON${NC}" || printf "${DIM}OFF${NC}" )"
    else
        printf "${BOLD}${BLUE}|  %-*s|${NC}\n" $(( W - 1 )) "添加端口限速规则"
        printf "${BOLD}${BLUE}+%s+${NC}\n" "$hline"
        printf "  ${DIM}1级: 始终生效的基础限速  2级: 触发后自动降速（可选开启）${NC}\n"
    fi
    printf "${BOLD}${BLUE}+%s+${NC}\n\n" "$hline"

    local port proto

    # ── [1] 端口号 / 协议（修改模式不可更改）────────────
    if [ -n "$edit_key" ]; then
        port=$(echo "$edit_key" | cut -d: -f1)
        proto=$(echo "$edit_key" | cut -d: -f2)
        printf "  ${BOLD}[1] 端口${NC}: ${BOLD}%s${NC}  协议: ${BOLD}%s${NC}  ${DIM}(修改模式不可更改)${NC}\n" "$port" "$proto"
    else
        printf "  ${BOLD}[1] 端口号${NC}  ${DIM}[1-65535]${NC}\n"
        while true; do
            read -rp "      端口号: " port
            [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
            printf "  ${RED}无效，请输入 1-65535 的整数${NC}\n"
        done

        printf "\n  ${BOLD}[2] 协议${NC}\n"
        printf "      1) TCP    2) UDP    3) TCP+UDP\n"
        read -rp "      选择 [默认 1=TCP]: " pc
        case "${pc:-1}" in 2) proto="udp";; 3) proto="both";; *) proto="tcp";; esac
        printf "      已选: ${BOLD}%s${NC}\n" "$proto"
    fi

    # ── [3] 1级速率 ──────────────────────────────────────
    printf "\n  ${BOLD}[3] 1级速率${NC}  ${DIM}[始终生效，单位: kbit/mbit/gbit]${NC}\n"
    [ -n "$old_rate1" ] && printf "      当前值: ${DIM}%s${NC}\n" "$old_rate1"
    local rate1 default_r1="${old_rate1:-30mbit}"
    while true; do
        read -rp "      1级速率 [默认 ${default_r1}]: " rate1
        [ -z "$rate1" ] && rate1="$default_r1" && break
        [[ "${rate1,,}" =~ ^[0-9]+(kbit|mbit|gbit|kbps|mbps|gbps|bps)$ ]] && break
        printf "  ${RED}格式无效，示例: 30mbit  500kbit  1gbit${NC}\n"
    done
    rate1="${rate1,,}"
    printf "      已设: ${BOLD}%s${NC}\n" "$rate1"

    # ── [4] 是否开启2级 ──────────────────────────────────
    printf "\n  ${BOLD}[4] 是否开启2级限速${NC}\n"
    printf "      ${GREEN}Y${NC} = 带宽超过阈值持续一段时间后自动降至2级速率\n"
    printf "      ${DIM}N${NC} = 仅以1级速率永久限速，不做触发监测\n"
    local default_l2yn; [ "$old_l2en" = "1" ] && default_l2yn="Y" || default_l2yn="N"
    read -rp "      开启2级? [Y/N，默认 ${default_l2yn}]: " l2yn
    [ -z "$l2yn" ] && l2yn="$default_l2yn"
    local l2_enabled
    [[ "${l2yn^^}" == "Y" ]] && l2_enabled="1" || l2_enabled="0"
    if [ "$l2_enabled" = "1" ]; then
        printf "      已选: ${BOLD}${GREEN}开启2级${NC}\n"
    else
        printf "      已选: ${BOLD}${DIM}仅1级${NC}\n"
    fi

    local rate2="-" trig_bw="0" trig_dur="0" limit_dur="0" ldur_str="永久"

    if [ "$l2_enabled" = "1" ]; then
        # ── [5] 触发带宽阈值 ────────────────────────────
        printf "\n  ${BOLD}[5] 触发带宽阈值${NC}  ${DIM}[上行超过此值开始计时，单位 Mbps]${NC}\n"
        local dtbw="${old_tbw:-80}"; [ "$dtbw" = "0" ] && dtbw="80"
        [ -n "$old_tbw" ] && [ "$old_tbw" != "0" ] && printf "      当前值: ${DIM}%s Mbps${NC}\n" "$old_tbw"
        while true; do
            read -rp "      触发阈值 [默认 ${dtbw} Mbps]: " trig_bw
            [ -z "$trig_bw" ] && trig_bw="$dtbw" && break
            [[ "$trig_bw" =~ ^[0-9]+(\.[0-9]+)?$ ]] && break
            printf "  ${RED}请输入数字，如 80${NC}\n"
        done
        printf "      已设: ${BOLD}%s Mbps${NC}\n" "$trig_bw"

        # ── [6] 触发持续时间 ────────────────────────────
        printf "\n  ${BOLD}[6] 触发持续时间${NC}  ${DIM}[格式: 30s/5m/1h]${NC}\n"
        local dtdur="${old_tdur:-300}"; [ "$dtdur" = "0" ] && dtdur="300"
        [ -n "$old_tdur" ] && [ "$old_tdur" != "0" ] && \
            printf "      当前值: ${DIM}%s (%ss)${NC}\n" "$(format_duration "$old_tdur")" "$old_tdur"
        while true; do
            read -rp "      持续时间 [默认 $(format_duration "$dtdur")]: " tdi
            if [ -z "$tdi" ]; then trig_dur="$dtdur"; break; fi
            trig_dur=$(parse_duration "$tdi")
            [ "$trig_dur" != "-1" ] && [ "$trig_dur" -gt 0 ] && break
            printf "  ${RED}格式无效，示例: 5m  300s  1h${NC}\n"
        done
        printf "      已设: ${BOLD}%s${NC}\n" "$(format_duration "$trig_dur")"

        # ── [7] 2级速率 ─────────────────────────────────
        printf "\n  ${BOLD}[7] 2级速率${NC}  ${DIM}[触发后降至此速率，应低于1级 %s]${NC}\n" "$rate1"
        local dr2="${old_rate2:-5mbit}"; [ "$dr2" = "-" ] && dr2="5mbit"
        [ -n "$old_rate2" ] && [ "$old_rate2" != "-" ] && printf "      当前值: ${DIM}%s${NC}\n" "$old_rate2"
        while true; do
            read -rp "      2级速率 [默认 ${dr2}]: " rate2
            [ -z "$rate2" ] && rate2="$dr2" && break
            [[ "${rate2,,}" =~ ^[0-9]+(kbit|mbit|gbit|kbps|mbps|gbps|bps)$ ]] && break
            printf "  ${RED}格式无效，示例: 5mbit  512kbit${NC}\n"
        done
        rate2="${rate2,,}"
        printf "      已设: ${BOLD}%s${NC}\n" "$rate2"

        # ── [8] 2级限速时长 ─────────────────────────────
        printf "\n  ${BOLD}[8] 2级限速时长${NC}  ${DIM}[2级持续多久后恢复1级 %s，0=永久循环]${NC}\n" "$rate1"
        local dldur="${old_ldur:-0}"
        [ -n "$old_ldur" ] && [ "$old_ldur" != "0" ] && \
            printf "      当前值: ${DIM}%s (%ss)${NC}\n" "$(format_duration "$old_ldur")" "$old_ldur"
        while true; do
            local dprompt; [ "$dldur" = "0" ] && dprompt="永久" || dprompt="$(format_duration "$dldur")"
            read -rp "      2级时长 [默认 ${dprompt}]: " ldi
            if [ -z "$ldi" ]; then limit_dur="$dldur"; break; fi
            limit_dur=$(parse_duration "$ldi")
            [ "$limit_dur" != "-1" ] && break
            printf "  ${RED}格式无效，示例: 20m  1h  0=永久${NC}\n"
        done
        [ "$limit_dur" = "0" ] && ldur_str="永久" || ldur_str="$(format_duration "$limit_dur")"
        printf "      已设: ${BOLD}%s${NC}\n" "$ldur_str"
    fi

    # ── 确认汇总 ─────────────────────────────────────────
    local rline; printf -v rline '%*s' $(( W - 15 )) ''; rline="${rline// /-}"
    printf "\n"
    printf "${BOLD}${CYAN}+-- 规则确认 --%s+${NC}\n" "$rline"
    printf "${BOLD}${CYAN}|${NC}  端口: ${BOLD}%s${NC}  协议: ${BOLD}%s${NC}\n" "$port" "$proto"
    printf "${BOLD}${CYAN}|${NC}  1级速率: ${BOLD}%s${NC}  (始终生效)\n" "$rate1"
    if [ "$l2_enabled" = "1" ]; then
        printf "${BOLD}${CYAN}|${NC}  2级开关: ${GREEN}ON${NC}\n"
        printf "${BOLD}${CYAN}|${NC}  触发: 上行 > ${BOLD}%s Mbps${NC} 持续 ${BOLD}%s${NC}\n" \
            "$trig_bw" "$(format_duration "$trig_dur")"
        printf "${BOLD}${CYAN}|${NC}  2级速率: ${BOLD}%s${NC}  时长: ${BOLD}%s${NC}\n" "$rate2" "$ldur_str"
    else
        printf "${BOLD}${CYAN}|${NC}  2级开关: ${DIM}OFF${NC}  (仅1级永久限速)\n"
    fi
    printf "${BOLD}${CYAN}+%s+${NC}\n\n" "$hline"

    read -rp "  确认保存? [Y/n]: " confirm
    [[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { warn "已取消"; return; }

    local new_key="${port}:${proto}"
    [ -n "$edit_key" ] && [ "$edit_key" != "$new_key" ] && unset "PORT_RULES[$edit_key]"

    PORT_RULES["$new_key"]="${rate1} ${rate2} ${trig_bw} ${trig_dur} ${limit_dur} ${l2_enabled}"
    log "规则: $port($proto) 1级=$rate1 2级=$rate2 en=${l2_enabled} 触发=${trig_bw}Mbps 持续=${trig_dur}s 时长=${limit_dur}s"
    save_config
    _notify_daemon_reload
    ok "规则已保存并通知守护进程生效"
}


interactive_edit() {
    [ ${#PORT_RULES[@]} -eq 0 ] && warn "没有可修改的规则" && return
    printf "\n  ${BOLD}[ 选择要修改的规则 ]${NC}\n"
    printf "  %s\n" "$(printf '%*s' 52 '' | tr ' ' '-')"
    local i=1; declare -a ekeys
    for key in "${!PORT_RULES[@]}"; do
        local val="${PORT_RULES[$key]}"
        local l2e; l2e=$(echo "$val" | awk '{print $6}'); [ -z "$l2e" ] && l2e="1"
        local l2tag; [ "$l2e" = "1" ] && l2tag="${GREEN}2级:ON${NC}" || l2tag="${DIM}2级:OFF${NC}"
        printf "  ${BOLD}%2d)${NC}  %-6s %-5s  1级:%-8s  %b  触发:%sMbps/%-6s  时长:%s\n" \
            "$i" \
            "$(echo "$key"|cut -d: -f1)" \
            "$(echo "$key"|cut -d: -f2)" \
            "$(echo "$val"|awk '{print $1}')" \
            "$l2tag" \
            "$(echo "$val"|awk '{print $3}')" \
            "$(format_duration "$(echo "$val"|awk '{print $4}')")" \
            "$(format_duration "$(echo "$val"|awk '{print $5}')")"
        ekeys+=("$key"); i=$(( i+1 ))
    done
    printf "\n"
    read -rp "  选择编号 (0=取消): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ekeys[@]}" ] \
        || { warn "已取消"; return; }
    interactive_add "${ekeys[$((choice-1))]}"
}

interactive_delete() {
    [ ${#PORT_RULES[@]} -eq 0 ] && warn "没有可删除的规则" && return
    printf "\n  ${BOLD}[ 删除端口限速规则 ]${NC}\n"
    printf "  %s\n" "$(printf '%*s' 52 '' | tr ' ' '-')"
    local i=1; declare -a dkeys
    for key in "${!PORT_RULES[@]}"; do
        local val="${PORT_RULES[$key]}"
        local l2e; l2e=$(echo "$val" | awk '{print $6}'); [ -z "$l2e" ] && l2e="1"
        local l2tag; [ "$l2e" = "1" ] && l2tag="${GREEN}2级:ON${NC}" || l2tag="${DIM}2级:OFF${NC}"
        printf "  ${BOLD}%2d)${NC}  %-6s %-5s  1级:%-8s  %b  触发:%sMbps\n" \
            "$i" \
            "$(echo "$key"|cut -d: -f1)" \
            "$(echo "$key"|cut -d: -f2)" \
            "$(echo "$val"|awk '{print $1}')" \
            "$l2tag" \
            "$(echo "$val"|awk '{print $3}')"
        dkeys+=("$key"); i=$(( i+1 ))
    done
    printf "\n"
    read -rp "  输入编号删除 (0=取消): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#dkeys[@]}" ]; then
        local dk="${dkeys[$((choice-1))]}"
        unset "PORT_RULES[$dk]"
        rm -rf "${STATE_DIR}/${dk//:/_}"
        ok "已删除规则: $dk"
        log "删除规则: $dk"
        save_config
        _notify_daemon_reload
    else
        warn "已取消"
    fi
}

change_interface() {
    echo ""
    local detected; detected=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
    echo "  当前接口: ${BOLD}${INTERFACE}${NC}"
    [ -n "$detected" ] && echo "  自动检测: ${BOLD}${detected}${NC}"
    echo ""
    echo "  可用接口:"
    ip -o link show 2>/dev/null | awk -F': ' '{print "    - " $2}' | grep -v '- lo$'
    echo ""
    read -rp "  输入接口名 [回车保持不变]: " new_iface
    if [ -n "$new_iface" ]; then
        INTERFACE="$new_iface"
        ok "接口已更改为: $INTERFACE"
        save_config
        _notify_daemon_reload
    else
        info "接口未变更"
    fi
}

change_interval() {
    echo ""
    echo "  +-- 修改监控采样间隔 ------------------------------------+"
    echo "  | 当前采样间隔: ${MONITOR_INTERVAL}s                                  |"
    echo "  | 间隔越短越灵敏，CPU 占用越高。推荐 5-30 秒            |"
    echo "  +--------------------------------------------------------+"
    echo ""
    local new_interval
    read -rp "  新采样间隔 (秒，回车保持不变): " new_interval
    if [[ "$new_interval" =~ ^[0-9]+$ ]] && [ "$new_interval" -ge 1 ]; then
        MONITOR_INTERVAL="$new_interval"
        ok "采样间隔已设为 ${MONITOR_INTERVAL}s"
        save_config
        _notify_daemon_reload
    else
        [ -n "$new_interval" ] && err "无效值，请输入正整数" || info "未变更"
    fi
}

# ─────────────────────────────────────────────────────────
# 安装 systemd 服务
# ─────────────────────────────────────────────────────────
install_service() {
    info "安装 systemd 服务..."
    cp -f "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    cat > "$SERVICE_FILE" << SVCEOF
[Unit]
Description=QoS 端口限速监控服务
After=network.target
Wants=network.target

[Service]
Type=forking
PIDFile=/run/qos/monitor.pid
ExecStart=${QOS_BIN} start
ExecStop=${QOS_BIN} stop
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
    printf "${BOLD}${CYAN}-- TC 底层状态 (%s) ---------------------------------${NC}\n" "$INTERFACE"
    printf "\n${BLUE}[qdisc]${NC}";  tc qdisc  show dev "$INTERFACE" 2>/dev/null || echo "  (空)\n"
    printf "\n${BLUE}[class]${NC}";  tc class  show dev "$INTERFACE" 2>/dev/null || echo "  (空)\n"
    printf "\n${BLUE}[filter]${NC}"; tc filter show dev "$INTERFACE" 2>/dev/null || echo "  (空)\n"
    echo ""
}

show_log() {
    echo ""
    printf "${BOLD}${CYAN}-- 最近 30 条日志 -------------------------------------------${NC}\n"
    tail -30 "$LOG_FILE" 2>/dev/null || echo "  (暂无日志)"
    echo ""
}

# ─────────────────────────────────────────────────────────
# 交互式主菜单
# ─────────────────────────────────────────────────────────
interactive_menu() {
    load_config

    # 启动时静默检查更新（后台检测，有新版本时在菜单顶部提示）
    local _update_available=false
    local _remote_ver=""
    _remote_ver=$(_remote_version "$QOS_UPDATE_URL" 2>/dev/null)
    if [ -n "$_remote_ver" ] && _version_lt "$QOS_VERSION" "$_remote_ver"; then
        _update_available=true
    fi

    while true; do
        clear
        local _mW=62
        local _ml; printf -v _ml '%*s' "$_mW" ''; _ml="${_ml// /-}"
        printf "\n"
        printf "${BOLD}${GREEN}+%s+${NC}\n" "$_ml"
        printf "${BOLD}${GREEN}|  %-*s|${NC}\n" $(( _mW - 1 )) "QoS 端口智能限速管理工具  v${QOS_VERSION}"
        printf "${BOLD}${GREEN}+%s+${NC}\n\n" "$_ml"

        # 有新版本时顶部横幅提示
        if $_update_available; then
            printf "${BOLD}${YELLOW}+%s+${NC}\n" "$_ml"
            printf "${BOLD}${YELLOW}|  %-*s|${NC}\n" $(( _mW - 1 )) "发现新版本 v${_remote_ver}  选 U) 一键升级"
            printf "${BOLD}${YELLOW}+%s+${NC}\n\n" "$_ml"
        fi

        show_rules

        local _sep="  $(printf '%*s' 56 '' | tr ' ' '-')"
        printf "  ${BOLD}[ 规则管理 ]${NC}\n"
        printf "%s\n" "$_sep"
        printf "  1) 添加端口限速规则\n"
        printf "  2) 修改端口限速规则\n"
        printf "  3) 删除端口限速规则\n"
        printf "%s\n" "$_sep"
        printf "  ${BOLD}[ 监控控制 ]${NC}\n"
        printf "  4) 启动监控\n"
        printf "  5) 停止监控\n"
        printf "  6) 手动恢复端口至 1级限速\n"
        printf "%s\n" "$_sep"
        printf "  ${BOLD}[ 配置与系统 ]${NC}\n"
        printf "  7) 保存配置\n"
        printf "  8) 更改网络接口\n"
        printf "  9) 修改监控采样间隔 (当前: %ss)\n" "$MONITOR_INTERVAL"
        printf "  t) 查看 TC 底层状态\n"
        printf "  l) 查看运行日志\n"
        printf "%s\n" "$_sep"
        printf "  i) 安装/更新系统服务 (开机自启)\n"
        printf "  D) 卸载系统服务\n"
        printf "  d) 重新检测/安装依赖\n"
        if $_update_available; then
            printf "  ${BOLD}${YELLOW}U) 在线更新 -> v%s${NC}\n" "$_remote_ver"
        else
            printf "  U) 检查在线更新\n"
        fi
        printf "  R) 清理旧配置并重新安装 (保留规则)\n"
        printf "  0) 退出\n"
        printf "%s\n" "$_sep"
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
            u)   uninstall_service ;;
            d|D) bootstrap_deps force ;;
            U)   do_update ;;
            R|r)
                do_clean_reinstall
                # 清理完重新检测更新状态
                _remote_ver=$(_remote_version "$QOS_UPDATE_URL" 2>/dev/null)
                if [ -n "$_remote_ver" ] && _version_lt "$QOS_VERSION" "$_remote_ver"; then
                    _update_available=true
                else
                    _update_available=false
                fi
                ;;
            0) printf "\n${GREEN}  再见！${NC}\n\n"; exit 0 ;;
            *) err "无效选项: $choice" ;;
        esac

        echo ""
        read -rp "  按 Enter 继续..." _
    done
}

# ─────────────────────────────────────────────────────────
# 在线检测与更新
# ─────────────────────────────────────────────────────────

# 从远程脚本提取版本号（读取 QOS_VERSION="x.x.x" 那行）
_remote_version() {
    local url="$1"
    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 8 "$url" 2>/dev/null \
            | grep -m1 '^QOS_VERSION=' | cut -d'"' -f2
    elif command -v wget &>/dev/null; then
        wget -qO- --timeout=8 "$url" 2>/dev/null \
            | grep -m1 '^QOS_VERSION=' | cut -d'"' -f2
    fi
}

# 版本比较：若 $1 < $2 返回 0（需要更新），否则返回 1
_version_lt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" != "$2" ]
}

check_update() {
    local silent="${1:-}"   # 传 "silent" 则无更新时不输出

    [ "$silent" != "silent" ] && echo ""
    [ "$silent" != "silent" ] && info "正在检查更新..."

    local remote_ver
    remote_ver=$(_remote_version "$QOS_UPDATE_URL")

    if [ -z "$remote_ver" ]; then
        warn "无法获取远程版本，请检查网络或 curl/wget 是否安装"
        return 1
    fi

    if _version_lt "$remote_ver" "$QOS_VERSION" || [ "$remote_ver" = "$QOS_VERSION" ]; then
        # 已是最新
        [ "$silent" != "silent" ] && ok "当前已是最新版本 ${BOLD}v${QOS_VERSION}${NC}"
        return 1   # 返回1=不需要更新
    fi

    # 有新版本
    echo ""
    printf "${BOLD}${YELLOW}--------------------------------------------------${NC}"
    printf "${BOLD}${YELLOW}  发现新版本！${NC}\n"
    printf "  当前版本: ${DIM}v${QOS_VERSION}${NC}\n"
    printf "  最新版本: ${BOLD}${GREEN}v${remote_ver}${NC}\n"
    printf "${BOLD}${YELLOW}--------------------------------------------------${NC}"
    return 0   # 返回0=有新版本
}

do_update() {
    require_root
    echo ""
    printf "${BOLD}${CYAN}--------------------------------------------------${NC}"
    printf "${BOLD}${CYAN}              在线更新 QoS 脚本                     ${NC}\n"
    printf "${BOLD}${CYAN}--------------------------------------------------${NC}"
    echo ""

    local remote_ver
    remote_ver=$(_remote_version "$QOS_UPDATE_URL")
    if [ -z "$remote_ver" ]; then
        err "无法获取远程版本，请检查网络"; return 1
    fi

    if _version_lt "$remote_ver" "$QOS_VERSION" || [ "$remote_ver" = "$QOS_VERSION" ]; then
        ok "当前已是最新版本 v${QOS_VERSION}，无需更新"
        return 0
    fi

    printf "  当前: ${DIM}v${QOS_VERSION}${NC}  ->  最新: ${BOLD}${GREEN}v%s${NC}\n" "$remote_ver"
    echo ""
    read -rp "  确认更新? [Y/n]: " confirm
    [[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { warn "已取消"; return; }

    # 下载新版本到临时文件
    local tmp; tmp=$(mktemp /tmp/qos_update.XXXXXX)
    step "下载新版本..."
    local dl_ok=false
    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 15 "$QOS_UPDATE_URL" -o "$tmp" 2>/dev/null && dl_ok=true
    elif command -v wget &>/dev/null; then
        wget -qO "$tmp" --timeout=15 "$QOS_UPDATE_URL" 2>/dev/null && dl_ok=true
    fi

    if ! $dl_ok || [ ! -s "$tmp" ]; then
        err "下载失败，请检查网络"; rm -f "$tmp"; return 1
    fi

    # 验证下载的是合法 bash 脚本
    if ! bash -n "$tmp" 2>/dev/null; then
        err "下载文件校验失败（语法错误），更新中止"; rm -f "$tmp"; return 1
    fi

    # 备份当前版本
    cp -f "$QOS_BIN" "${QOS_BIN}.bak" 2>/dev/null && \
        ok "已备份当前版本 → ${QOS_BIN}.bak"

    # 替换
    cp -f "$tmp" "$QOS_BIN"
    chmod +x "$QOS_BIN"
    sed -i 's/\r//' "$QOS_BIN" 2>/dev/null || true
    rm -f "$tmp"

    ok "更新完成！${DIM}v${QOS_VERSION}${NC} → ${BOLD}${GREEN}v${remote_ver}${NC}"
    log "脚本更新: v${QOS_VERSION} → v${remote_ver}"

    # 重启监控服务使新版本生效
    echo ""
    step "重启监控服务使新版本生效..."
    stop_monitor 2>/dev/null
    sleep 1
    load_config
    start_monitor
    ok "监控服务已用新版本重启 ✓"
    echo ""
    printf "${BOLD}${GREEN}--------------------------------------------------${NC}"
    printf "  更新完成，请重新执行 ${BOLD}qos${NC} 进入新版本菜单\n"
    printf "${BOLD}${GREEN}--------------------------------------------------${NC}"
    echo ""
    exit 0
}

# ─────────────────────────────────────────────────────────
# 清理旧配置并重新安装（保留规则配置文件）
# ─────────────────────────────────────────────────────────
do_clean_reinstall() {
    require_root
    echo ""
    printf "${BOLD}${RED}--------------------------------------------------${NC}"
    printf "${BOLD}${RED}          清理旧配置并重新安装                      ${NC}\n"
    printf "${BOLD}${RED}--------------------------------------------------${NC}"
    echo ""
    printf "  ${BOLD}此操作将:${NC}\n"
    printf "  ${RED}•${NC} 停止监控守护进程\n"
    printf "  ${RED}•${NC} 清除所有 TC 限速规则和 iptables mark 规则\n"
    printf "  ${RED}•${NC} 删除运行时状态文件 (/run/qos/)\n"
    printf "  ${RED}•${NC} 删除依赖初始化标记（重新检测依赖）\n"
    printf "  ${GREEN}•${NC} ${BOLD}保留${NC} 端口规则配置文件 ($CONFIG_FILE)\n"
    printf "  ${GREEN}•${NC} 重新安装脚本和 systemd 服务\n"
    echo ""
    read -rp "  确认执行? [y/N]: " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { warn "已取消"; return; }

    echo ""

    # 1. 停止监控
    step "停止监控守护进程..."
    stop_monitor 2>/dev/null; sleep 1

    # 2. 清除 TC 和 iptables 规则
    step "清除 TC 和 iptables mark 规则..."
    load_config
    local h=10
    for key in "${!PORT_RULES[@]}"; do
        local port proto
        port=$(echo "$key" | cut -d: -f1)
        proto=$(echo "$key" | cut -d: -f2)
        _ipt_clear_port "$port" "$proto" "$h" 2>/dev/null || true
        h=$(( h + 10 ))
    done
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    ok "TC / iptables 规则已清除"

    # 3. 清除运行时状态
    step "清除运行时状态文件..."
    rm -rf /run/qos
    mkdir -p /run/qos
    ok "状态文件已清除"

    # 4. 清除依赖初始化标记（让 bootstrap 重新检测）
    step "清除依赖初始化标记..."
    rm -f "$FIRST_RUN_FLAG"
    ok "初始化标记已清除"

    # 5. 重新安装脚本
    step "重新安装脚本到 ${QOS_BIN}..."
    cp -f "$SCRIPT_SELF" "$QOS_BIN" 2>/dev/null || cp -f "$0" "$QOS_BIN"
    chmod +x "$QOS_BIN"
    sed -i 's/\r//' "$QOS_BIN" 2>/dev/null || true
    ok "脚本已重新安装 → ${QOS_BIN}"

    # 6. 重新检测依赖
    echo ""
    bootstrap_deps

    # 7. 重新注册 systemd 服务
    echo ""
    step "重新注册 systemd 服务..."
    load_config
    install_service

    # 8. 重新启动监控
    echo ""
    step "重新启动监控..."
    start_monitor

    echo ""
    printf "${BOLD}${GREEN}--------------------------------------------------${NC}"
    ok "清理重装完成！端口规则配置已保留，监控已重新启动"
    printf "${BOLD}${GREEN}--------------------------------------------------${NC}"
    echo ""
    log "清理重装完成"
}

# ─────────────────────────────────────────────────────────
# 一键安装：将脚本装到系统路径，注册 qos 快捷命令
# ─────────────────────────────────────────────────────────
do_setup() {
    echo ""
    printf "${BOLD}${GREEN}--------------------------------------------------${NC}"
    printf "${BOLD}${GREEN}          QoS 快捷命令安装向导                      ${NC}\n"
    printf "${BOLD}${GREEN}--------------------------------------------------${NC}"
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
    printf "${BOLD}${GREEN}--------------------------------------------------${NC}"
    ok "安装完成！现在直接输入 ${BOLD}qos${NC} 即可启动"
    printf "${BOLD}${GREEN}--------------------------------------------------${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────
# 帮助
# ─────────────────────────────────────────────────────────
usage() {
    echo ""
    printf "${BOLD}用法:${NC}  qos [命令]\n"
    echo ""
    printf "  ${BOLD}命令:${NC}\n"
    printf "  %-38s %s\n" "(无参数)"       "进入交互式菜单"
    printf "  %-38s %s\n" "setup"          "首次安装：注册 qos 快捷命令 + 依赖 + 自启"
    printf "  %-38s %s\n" "update"         "检测并在线更新到最新版本"
    printf "  %-38s %s\n" "reinstall"      "清理旧配置并重新安装（保留规则）"
    printf "  %-38s %s\n" "start"          "启动监控守护进程"
    printf "  %-38s %s\n" "stop"           "停止监控守护进程"
    printf "  %-38s %s\n" "status"         "显示规则与监控状态"
    printf "  %-38s %s\n" "clear"          "清除所有 TC 规则"
    printf "  %-38s %s\n" "install"        "安装 systemd 服务（开机自启）"
    printf "  %-38s %s\n" "uninstall"      "卸载系统服务"
    printf "  %-38s %s\n" "check-deps"     "强制检测并安装依赖"
    printf "  %-38s %s\n" "_monitor"       "（内部）监控守护进程主循环"
    printf "  %-38s %s\n" "help"           "显示此帮助"
    echo ""
    printf "  ${BOLD}时长格式:${NC}  30s  5m  2h  1d  1h30m  90（=90分钟）  0=永久\n"
    printf "  ${BOLD}当前版本:${NC}  v${QOS_VERSION}\n"
    echo ""
}

# ─────────────────────────────────────────────────────────
# 主入口
# ─────────────────────────────────────────────────────────
case "${1:-}" in
    setup)
        do_setup ;;
    update)
        do_update ;;
    reinstall)
        do_clean_reinstall ;;
    start)
        require_root; bootstrap_deps; load_config; start_monitor ;;
    stop)
        require_root; stop_monitor ;;
    status)
        load_config; show_rules; show_tc_status ;;
    clear)
        require_root; load_config; clear_rules ;;
    _monitor)
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
