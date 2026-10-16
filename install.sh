#!/bin/sh
#
# OpenWrt 自动登录服务安装脚本
# 自动检测环境、安装依赖、配置服务
#
# 版本: v1.4.0 (2026-10-16)
# 更新: 在线判据重写 + 认证报文 MAC 动态化 + 策略开关接通 + 行尾规范化
#

set -e

# 版本信息
VERSION="v1.4.0"
VERSION_DATE="2026-10-16"
VERSION_DESC="在线判据重写与认证报文MAC动态化"

INSTALL_DIR="/usr/local/autologin"
CONFIG_FILE="/etc/config/autologin"
SERVICE_FILE="/etc/init.d/autologin"
SCRIPT_FILE="$INSTALL_DIR/login.sh"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

print_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

print_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

# 检测是否为 OpenWrt 系统
check_system() {
    print_info "检测系统环境..."
    if [ ! -f "/etc/openwrt_release" ]; then
        print_warn "警告: 未检测到 OpenWrt 系统标识文件"
        printf "是否继续安装? (y/n): "
        read confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            exit 1
        fi
    else
        . /etc/openwrt_release
        print_info "系统: $DISTRIB_ID $DISTRIB_RELEASE"
    fi
}

# 检测并安装依赖
check_dependencies() {
    print_info "检测依赖包..."
    local missing_deps=""
    local deps="wget curl"
    local critical_cmds="ip ping sleep awk grep cut"

    # 检查可通过opkg安装的依赖
    for dep in $deps; do
        if ! command -v $dep >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done

    # 检查关键系统命令（通常预装，但需验证）
    local missing_critical=""
    for cmd in $critical_cmds; do
        if ! command -v $cmd >/dev/null 2>&1; then
            missing_critical="$missing_critical $cmd"
        fi
    done

    if [ -n "$missing_critical" ]; then
        print_error "缺少关键系统命令:$missing_critical"
        print_error "这些命令应该预装在OpenWrt中，请检查系统完整性"
        return 1
    fi

    if [ -n "$missing_deps" ]; then
        print_warn "缺失依赖包:$missing_deps"
        print_info "正在更新软件源..."
        if ! opkg update; then
            print_error "软件源更新失败，请检查网络连接"
            return 1
        fi

        for dep in $missing_deps; do
            print_info "正在安装 $dep..."
            if ! opkg install $dep; then
                print_error "安装 $dep 失败"
                return 1
            fi
        done
    else
        print_info "所有依赖已满足"
    fi

    return 0
}

# 获取 WAN 接口名称
get_wan_interface() {
    # 尝试多种方法获取 WAN 接口
    local wan_if=""

    # 方法1: 通过 uci 获取
    wan_if=$(uci get network.wan.ifname 2>/dev/null || uci get network.wan.device 2>/dev/null || echo "")

    # 方法2: 通过 ip route 获取默认网关接口
    if [ -z "$wan_if" ]; then
        wan_if=$(ip route | grep default | head -n1 | awk '{print $5}')
    fi

    # 方法3: 常见接口名猜测
    if [ -z "$wan_if" ]; then
        for if_name in eth1 eth0.2 wan; do
            if ifconfig $if_name >/dev/null 2>&1; then
                wan_if=$if_name
                break
            fi
        done
    fi

    echo "$wan_if"
}

# 交互式配置
interactive_config() {
    print_info "开始配置登录服务..."
    echo ""

    # 自动检测 WAN 接口
    WAN_IF=$(get_wan_interface)
    if [ -n "$WAN_IF" ]; then
        print_info "自动检测到 WAN 接口: $WAN_IF"
        printf "是否使用此接口? (Y/n): "
        read use_auto
        if [ "$use_auto" = "n" ] || [ "$use_auto" = "N" ]; then
            printf "请输入 WAN 接口名称: "
            read WAN_IF
        fi
    else
        printf "请输入 WAN 接口名称 (如 eth1): "
        read WAN_IF
    fi

    # 账号密码
    printf "请输入登录账号: "
    read USER_ACCOUNT
    printf "请输入登录密码: "
    read -s USER_PASSWORD
    echo ""

    # 运营商选择
    echo "请选择运营商:"
    echo "  1) 联通"
    echo "  2) 移动"
    printf "请输入选项 (1/2) [默认: 1]: "
    read ISP_CHOICE
    ISP_CHOICE=${ISP_CHOICE:-1}

    # 检测策略配置
    echo ""
    print_info "检测策略配置"
    echo "系统使用双层检测策略："
    echo "  • 主检测: 公网DNS Ping (快速响应，不受认证服务器限制)"
    echo "  • 辅助检测: 本地认证服务器HTTP状态 (fallback验证)"
    echo ""
    echo "注意: 认证服务器有防护机制，高频HTTP请求会被强制登出"
    echo ""

    # 在线状态检测频率
    print_info "在线状态检测频率"
    printf "公网DNS检测频率 (秒) [默认: 10]: "
    read DNS_CHECK_INTERVAL
    DNS_CHECK_INTERVAL=${DNS_CHECK_INTERVAL:-10}

    # 离线状态检测配置
    echo ""
    print_info "离线状态检测配置"
    echo "当检测到离线时，系统会尝试重新认证并检测登录状态"
    printf "离线时登录请求发送间隔 (秒) [默认: 2]: "
    read OFFLINE_AUTH_INTERVAL
    OFFLINE_AUTH_INTERVAL=${OFFLINE_AUTH_INTERVAL:-2}

    printf "离线时本地登录状态查询间隔 (秒) [默认: 2]: "
    read OFFLINE_HTTP_CHECK_INTERVAL
    OFFLINE_HTTP_CHECK_INTERVAL=${OFFLINE_HTTP_CHECK_INTERVAL:-2}

    # 离线认证保护配置
    echo ""
    print_info "离线认证保护配置"
    echo "防止离线时无限制发送认证请求，避免给服务器造成压力"
    printf "离线时最大认证尝试次数 [默认: 20]: "
    read OFFLINE_AUTH_MAX_ATTEMPTS
    OFFLINE_AUTH_MAX_ATTEMPTS=${OFFLINE_AUTH_MAX_ATTEMPTS:-20}

    printf "达到最大尝试次数后冷却时间 (秒) [默认: 300]: "
    read OFFLINE_COOLDOWN_SECONDS
    OFFLINE_COOLDOWN_SECONDS=${OFFLINE_COOLDOWN_SECONDS:-300}

    # 离线状态重连配置（保留用于兼容性）
    echo ""
    print_info "离线状态重连配置"
    printf "离线重连等待时间 (秒) [默认: 3]: "
    read RECONNECT_INTERVAL
    RECONNECT_INTERVAL=${RECONNECT_INTERVAL:-3}

    # DNS失败阈值配置
    echo ""
    print_info "DNS离线判定策略"
    echo "当多个DNS服务器检测失败时，判定为离线："
    echo "  1) 任何1个DNS失败就离线 (最敏感，快速反应，可能误判)"
    echo "  2) 至少2个DNS失败才离线 (推荐，平衡误判和延迟)"
    echo "  3) 所有DNS都失败才离线 (最保守，可能延迟发现断线)"
    printf "请选择策略 (1/2/3) [默认: 2]: "
    read DNS_FAILURE_THRESHOLD_OPTION
    DNS_FAILURE_THRESHOLD_OPTION=${DNS_FAILURE_THRESHOLD_OPTION:-2}

    case "$DNS_FAILURE_THRESHOLD_OPTION" in
        1) DNS_FAILURE_THRESHOLD=1 ;;
        3) DNS_FAILURE_THRESHOLD=999 ;;  # 使用999表示"所有"
        *) DNS_FAILURE_THRESHOLD=2 ;;
    esac

    # 在线判定策略
    echo ""
    print_info "在线判定策略"
    echo "从离线恢复到在线状态的条件："
    echo "  1) 仅依赖DNS检测 (达到DNS阈值即判定在线)"
    echo "  2) DNS + HTTP双重验证 (至少1个DNS可达 + 本地HTTP在线)"
    printf "请选择策略 (1/2) [默认: 2]: "
    read ONLINE_VERIFY_STRATEGY
    ONLINE_VERIFY_STRATEGY=${ONLINE_VERIFY_STRATEGY:-2}

    # 公网DNS服务器配置
    echo ""
    print_info "公网DNS服务器配置"
    echo "用于辅助验证网络连通性（负载均衡轮询）"
    printf "公网DNS服务器 [默认: 119.29.29.29 223.5.5.5 1.1.1.1]: "
    read DNS_TEST_SERVERS
    DNS_TEST_SERVERS=${DNS_TEST_SERVERS:-"119.29.29.29 223.5.5.5 1.1.1.1"}

    # 固定启用的检测方法（移除公网HTTP重定向）
    ENABLE_AUTH_HTTP="Y"
    ENABLE_PUBLIC_HTTP="N"
    ENABLE_PUBLIC_PING="Y"
    HTTP_TEST_URLS=""

    # 日志配置
    echo ""
    print_info "日志配置"
    echo "请选择日志输出方式:"
    echo "  1) 输出到文件 (智能日志系统，故障分析优化)"
    echo "  2) 输出到 syslog (系统日志)"
    echo "  3) 输出到 /dev/null (不记录)"
    printf "请输入选项 (1/2/3) [默认: 1]: "
    read LOG_TYPE
    LOG_TYPE=${LOG_TYPE:-1}

    if [ "$LOG_TYPE" = "1" ]; then
        echo ""
        print_info "智能日志系统配置"
        echo "系统采用双层日志架构："
        echo "  • 实时日志: /tmp/autologin/ (内存，快速写入)"
        echo "  • 持久化日志: /usr/local/autologin/logs/persistent.log (仅保留故障事件)"
        echo ""
        printf "持久化故障日志大小限制 (MB) [默认: 10]: "
        read LOG_SIZE_MB
        LOG_SIZE_MB=${LOG_SIZE_MB:-10}
        printf "实时日志切割阈值 (MB) [默认: 2]: "
        read REALTIME_LOG_SIZE_MB
        REALTIME_LOG_SIZE_MB=${REALTIME_LOG_SIZE_MB:-2}

        # 告警阈值配置
        echo ""
        print_info "故障告警阈值配置"
        printf "离线次数告警阈值 (次/小时) [默认: 3]: "
        read OFFLINE_ALERT_THRESHOLD
        OFFLINE_ALERT_THRESHOLD=${OFFLINE_ALERT_THRESHOLD:-3}
        printf "连续认证失败告警阈值 (次) [默认: 3]: "
        read AUTH_FAIL_THRESHOLD
        AUTH_FAIL_THRESHOLD=${AUTH_FAIL_THRESHOLD:-3}

        # 状态摘要间隔
        echo ""
        printf "状态摘要输出间隔 (秒) [默认: 3600 (1小时)]: "
        read STAT_INTERVAL
        STAT_INTERVAL=${STAT_INTERVAL:-3600}

        # 疑似离线日志记录配置
        echo ""
        print_info "疑似离线日志记录配置"
        echo "网络波动时会频繁触发疑似离线状态，记录这些信息会导致日志量增大"
        echo "建议：网络稳定环境选择 N，网络波动大需要调试时选择 Y"
        printf "是否记录疑似离线信息到持久化日志? (Y/N) [默认: N]: "
        read LOG_SUSPECT_STATE
        LOG_SUSPECT_STATE=${LOG_SUSPECT_STATE:-N}

        LOG_DIR="$INSTALL_DIR/logs"
        PERSISTENT_LOG_FILE="$LOG_DIR/persistent.log"
        REALTIME_LOG_DIR="/tmp/autologin"
        REALTIME_LOG_FILE="$REALTIME_LOG_DIR/autologin.log"
    elif [ "$LOG_TYPE" = "2" ]; then
        LOG_FILE="logger -t autologin"
        LOG_SIZE_MB=0
        REALTIME_LOG_SIZE_MB=0
        OFFLINE_ALERT_THRESHOLD=3
        AUTH_FAIL_THRESHOLD=3
        STAT_INTERVAL=3600
    else
        LOG_FILE="/dev/null"
        LOG_SIZE_MB=0
        REALTIME_LOG_SIZE_MB=0
        OFFLINE_ALERT_THRESHOLD=3
        AUTH_FAIL_THRESHOLD=3
        STAT_INTERVAL=3600
    fi

    echo ""
    print_info "配置摘要:"
    echo "  WAN 接口: $WAN_IF"
    echo "  登录账号: $USER_ACCOUNT"
    echo "  运营商: $([ "$ISP_CHOICE" = "1" ] && echo "联通" || echo "移动")"
    echo ""
    echo "  检测策略:"
    echo "    主检测: 公网DNS Ping"
    echo "    辅助检测: 本地认证服务器HTTP"
    echo ""
    echo "  在线状态检测频率:"
    echo "    公网DNS检测: 每 ${DNS_CHECK_INTERVAL} 秒"
    echo ""
    echo "  离线状态配置:"
    echo "    登录请求间隔: ${OFFLINE_AUTH_INTERVAL} 秒"
    echo "    状态查询间隔: ${OFFLINE_HTTP_CHECK_INTERVAL} 秒"
    echo "    重连等待时间: ${RECONNECT_INTERVAL} 秒"
    echo "    最大认证次数: ${OFFLINE_AUTH_MAX_ATTEMPTS} 次"
    echo "    冷却时间: ${OFFLINE_COOLDOWN_SECONDS} 秒"
    echo ""
    echo "  判定策略:"
    case "$DNS_FAILURE_THRESHOLD" in
        1) echo "    DNS离线判定: 任何1个DNS失败即离线" ;;
        999) echo "    DNS离线判定: 所有DNS都失败才离线" ;;
        *) echo "    DNS离线判定: 至少${DNS_FAILURE_THRESHOLD}个DNS失败才离线" ;;
    esac
    case "$ONLINE_VERIFY_STRATEGY" in
        1) echo "    在线判定: 仅依赖DNS检测" ;;
        2) echo "    在线判定: DNS + HTTP双重验证" ;;
    esac
    echo ""
    echo "  公网DNS服务器: $DNS_TEST_SERVERS"
    echo ""
    if [ "$LOG_TYPE" = "1" ]; then
        echo "  日志系统: 智能双层架构"
        echo "    实时日志: $REALTIME_LOG_FILE (切割阈值: ${REALTIME_LOG_SIZE_MB}MB)"
        echo "    持久化日志: $PERSISTENT_LOG_FILE (最大: ${LOG_SIZE_MB}MB)"
        echo "    状态摘要间隔: $((STAT_INTERVAL/60)) 分钟"
        echo "    离线告警阈值: ${OFFLINE_ALERT_THRESHOLD} 次/小时"
        echo "    认证失败告警阈值: ${AUTH_FAIL_THRESHOLD} 次"
    elif [ "$LOG_TYPE" = "2" ]; then
        echo "  日志输出: syslog (结构化格式)"
    else
        echo "  日志输出: 禁用"
    fi
    echo ""

    printf "确认以上配置并继续安装? (y/n): "
    read confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        print_error "安装已取消"
        exit 1
    fi
}

# 创建安装目录
create_directories() {
    print_info "创建安装目录..."
    mkdir -p "$INSTALL_DIR"
    if [ "$LOG_TYPE" = "1" ]; then
        mkdir -p "$LOG_DIR"
        mkdir -p "$REALTIME_LOG_DIR"
        print_info "已创建持久化日志目录: $LOG_DIR"
        print_info "已创建实时日志目录: $REALTIME_LOG_DIR"
    fi
}

# 生成登录脚本
generate_login_script() {
    print_info "生成登录脚本..."

    cat > "$SCRIPT_FILE" << 'EOFSCRIPT'
#!/bin/sh
#
# 自动登录脚本 - 智能日志系统增强版
# 由安装程序自动生成
#
EOFSCRIPT

    # 插入版本信息（使用变量替换）
    cat >> "$SCRIPT_FILE" << EOF
# 版本: $VERSION ($VERSION_DATE)
# 说明: $VERSION_DESC
#

EOF

    # 继续写入脚本内容
    cat >> "$SCRIPT_FILE" << 'EOFSCRIPT'
# 配置文件
CONFIG_FILE="/etc/config/autologin"

# 脚本版本信息（由安装程序自动写入）
EOFSCRIPT

    # 写入版本变量
    cat >> "$SCRIPT_FILE" << EOF
SCRIPT_VERSION="$VERSION"
SCRIPT_VERSION_DATE="$VERSION_DATE"
SCRIPT_VERSION_DESC="$VERSION_DESC"

EOF

    # 继续写入脚本内容
    cat >> "$SCRIPT_FILE" << 'EOFSCRIPT'
# 全局状态变量
CURRENT_STATE="UNKNOWN"  # ONLINE, SUSPECT, OFFLINE, RECOVERING, UNKNOWN
CURRENT_SESSION_START=0  # 当前会话开始时间
LAST_DNS_CHECK=0
LAST_HTTP_CHECK=0
DNS_SERVER_INDEX=0
DNS_CONSECUTIVE_FAILURES=0  # DNS连续失败计数器
RECOVERING_SUCCESS_COUNT=0  # 恢复状态成功计数
OFFLINE_DNS_CHECK_INTERVAL=5  # 离线状态下DNS检测间隔（秒）
OFFLINE_HTTP_CHECK_INTERVAL=60  # 离线状态下HTTP检测间隔（秒）

# 离线事件追踪（当前离线事件的临时变量）
OFFLINE_START_TIME=0
OFFLINE_DNS_FAIL_LIST=""
OFFLINE_PARALLEL_FAIL_LIST=""
OFFLINE_AUTH_RESPONSE=""
AUTH_ATTEMPT_COUNT=0

# ============ 命令兼容性检测 ============
# 检查命令是否可用
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 验证关键命令
check_required_commands() {
    local missing=""
    for cmd in ip ifconfig ping wget sleep date; do
        if ! command_exists "$cmd"; then
            missing="$missing $cmd"
        fi
    done

    if [ -n "$missing" ]; then
        log_message "错误: 缺少必需命令:$missing"
        return 1
    fi
    return 0
}

# 安全的sleep函数（确保参数为正整数）
safe_sleep() {
    local seconds="$1"
    # 验证是否为数字
    case "$seconds" in
        ''|*[!0-9]*)
            log_message "警告: sleep参数无效 ($seconds), 使用默认值1秒"
            seconds=1
            ;;
    esac
    # 确保至少sleep 1秒
    if [ "$seconds" -lt 1 ]; then
        seconds=1
    fi
    sleep "$seconds"
}

# 获取当前时间戳（秒）
get_timestamp() {
    date +%s
}

# 格式化时长显示（秒 -> 人类可读）
format_duration() {
    local seconds=$1
    local days=$((seconds / 86400))
    local hours=$(( (seconds % 86400) / 3600 ))
    local mins=$(( (seconds % 3600) / 60 ))
    local secs=$((seconds % 60))

    if [ $days -gt 0 ]; then
        echo "${days}天${hours}小时${mins}分钟"
    elif [ $hours -gt 0 ]; then
        echo "${hours}小时${mins}分钟"
    elif [ $mins -gt 0 ]; then
        echo "${mins}分钟${secs}秒"
    else
        echo "${secs}秒"
    fi
}

# 格式化日期时间（时间戳 -> YY-MM-DD HH:MM）
format_datetime() {
    local timestamp=$1
    if [ "$timestamp" -eq 0 ] || [ -z "$timestamp" ]; then
        echo "未知"
    else
        # Busybox date 支持 -D 参数或 @timestamp 格式
        # 方法1: 使用 @ 前缀（busybox 标准格式，无引号）
        date -d @$timestamp '+%Y-%m-%d %H:%M' 2>/dev/null || \
        # 方法2: 使用 -r 参数（某些busybox版本）
        date -r $timestamp '+%Y-%m-%d %H:%M' 2>/dev/null || \
        # 方法3: GNU date 格式（标准Linux，带引号）
        date -d "@$timestamp" '+%Y-%m-%d %H:%M' 2>/dev/null || \
        # 方法4: 如果都失败，显示原始时间戳（便于调试）
        echo "$(date '+%Y-%m-%d %H:%M') [TS:$timestamp]"
    fi
}

# 读取配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    else
        echo "错误: 配置文件不存在"
        exit 1
    fi
}

# ============ 状态文件管理 ============

# 初始化状态文件
init_state_file() {
    local now=$(get_timestamp)
    local now_readable=$(date -d "@$now" "+%a %b %e %H:%M:%S CST %Y" 2>/dev/null || date "+%a %b %e %H:%M:%S CST %Y")

    # 检查文件是否存在且完整
    local need_init=0
    if [ ! -f "$STATE_FILE" ]; then
        need_init=1
    else
        # 检查关键字段是否存在
        if ! grep -q "^OFFLINE_COUNT=" "$STATE_FILE" 2>/dev/null || \
           ! grep -q "^AUTH_TOTAL_COUNT=" "$STATE_FILE" 2>/dev/null || \
           ! grep -q "^ONLINE_SINCE=" "$STATE_FILE" 2>/dev/null; then
            need_init=1
        fi
    fi

    if [ $need_init -eq 1 ]; then
        # 如果是重新初始化，保留FIRST_START_TIME
        local first_start=$now
        if [ -f "$STATE_FILE" ] && grep -q "^FIRST_START_TIME=" "$STATE_FILE" 2>/dev/null; then
            first_start=$(grep "^FIRST_START_TIME=" "$STATE_FILE" | cut -d'=' -f2 | awk '{print $1}')
        fi

        cat > "$STATE_FILE" << EOF
# 自动登录服务运行状态
# 此文件由系统自动维护，请勿手动编辑

# 服务运行统计
FIRST_START_TIME=$first_start  # $(date -d "@$first_start" "+%a %b %e %H:%M:%S CST %Y" 2>/dev/null || date "+%a %b %e %H:%M:%S CST %Y")
LAST_START_TIME=$now  # $now_readable
TOTAL_OFFLINE_SECONDS=0

# 离线统计
OFFLINE_COUNT=0
CURRENT_EVENT_ID=0

# 在线状态
ONLINE_SINCE=0  # 未上线
MAX_ONLINE_DURATION=0

# 上次离线信息
LAST_OFFLINE_TIME=0  # 从未离线
LAST_OFFLINE_DNS_FAIL=""
LAST_OFFLINE_PARALLEL_FAIL=""
LAST_OFFLINE_AUTH_RESPONSE=""
LAST_RECOVERY_DURATION=0

# 认证统计
AUTH_TOTAL_COUNT=0
AUTH_LAST_ATTEMPTS=0
TOTAL_RECOVERY_TIME=0

# DNS失败统计
DNS_FAIL_119=0
DNS_FAIL_223=0
DNS_FAIL_8=0
DNS_FAIL_1=0
DNS_FAIL_114=0

# 状态摘要
LAST_STAT_TIME=$now  # $now_readable

# 告警统计
LAST_HOUR_OFFLINE_COUNT=0
LAST_HOUR_START_TIME=$now  # $now_readable
CONSECUTIVE_AUTH_FAILURES=0
EOF
    else
        # 文件存在且完整，只更新最后启动时间
        update_state "LAST_START_TIME" "$now"
    fi
}

# 加载状态文件
load_state() {
    if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE"
    else
        init_state_file
        . "$STATE_FILE"
    fi
}

# 更新状态字段
update_state() {
    local key="$1"
    local value="$2"

    if [ ! -f "$STATE_FILE" ]; then
        init_state_file
    fi

    # 使用临时文件避免并发问题
    local tmp_file="${STATE_FILE}.tmp"

    # 判断是否为时间戳字段，需要添加可读格式注释
    local comment=""
    case "$key" in
        FIRST_START_TIME|LAST_START_TIME|LAST_STAT_TIME|LAST_HOUR_START_TIME)
            # 时间戳字段，添加可读格式
            if [ "$value" -gt 0 ]; then
                comment="  # $(date -d "@$value" "+%a %b %e %H:%M:%S CST %Y" 2>/dev/null || date "+%a %b %e %H:%M:%S CST %Y")"
            fi
            ;;
        ONLINE_SINCE)
            # 在线时间字段
            if [ "$value" -gt 0 ]; then
                comment="  # $(date -d "@$value" "+%a %b %e %H:%M:%S CST %Y" 2>/dev/null || date "+%a %b %e %H:%M:%S CST %Y")"
            else
                comment="  # 未上线"
            fi
            ;;
        LAST_OFFLINE_TIME)
            # 离线时间字段
            if [ "$value" -gt 0 ]; then
                comment="  # $(date -d "@$value" "+%a %b %e %H:%M:%S CST %Y" 2>/dev/null || date "+%a %b %e %H:%M:%S CST %Y")"
            else
                comment="  # 从未离线"
            fi
            ;;
    esac

    # 如果字段存在则更新，否则重新初始化文件
    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        grep -v "^${key}=" "$STATE_FILE" > "$tmp_file"
        echo "${key}=${value}${comment}" >> "$tmp_file"
        mv "$tmp_file" "$STATE_FILE"
    else
        # 字段不存在，说明文件不完整，重新初始化
        log_with_level "WARN" "状态文件缺少字段 ${key}，重新初始化"
        init_state_file
        # 重新尝试更新
        if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
            grep -v "^${key}=" "$STATE_FILE" > "$tmp_file"
            echo "${key}=${value}${comment}" >> "$tmp_file"
            mv "$tmp_file" "$STATE_FILE"
        fi
    fi
}

# 增加状态计数器
increment_state() {
    local key="$1"
    local increment="${2:-1}"

    # 加载当前值
    load_state
    local current_value=$(eval echo \$${key})

    # 如果为空或非数字，初始化为0
    case "$current_value" in
        ''|*[!0-9]*) current_value=0 ;;
    esac

    # 增加并更新
    local new_value=$((current_value + increment))
    update_state "$key" "$new_value"
}

# 获取DNS服务器统计键名
get_dns_stat_key() {
    local dns_ip="$1"
    case "$dns_ip" in
        119.29.29.29) echo "DNS_FAIL_119" ;;
        223.5.5.5) echo "DNS_FAIL_223" ;;
        8.8.8.8) echo "DNS_FAIL_8" ;;
        1.1.1.1) echo "DNS_FAIL_1" ;;
        114.114.114.114) echo "DNS_FAIL_114" ;;
        *) echo "DNS_FAIL_OTHER" ;;
    esac
}

# 获取 WAN 口 IP 地址
get_wan_ip() {
    local ip=""

    # 方法1: 使用 ip addr
    ip=$(ip addr show dev "$WAN_INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -n1)

    # 方法2: 使用 ifconfig (兼容旧版本)
    if [ -z "$ip" ]; then
        ip=$(ifconfig "$WAN_INTERFACE" 2>/dev/null | grep "inet addr:" | awk '{print $2}' | cut -d: -f2)
    fi

    # 方法3: 使用 uci + ifconfig
    if [ -z "$ip" ]; then
        ip=$(ifconfig "$WAN_INTERFACE" 2>/dev/null | grep -oE "inet addr:[0-9.]+" | cut -d: -f2)
    fi

    echo "$ip"
}

# 获取 MAC 地址
get_wan_mac() {
    local mac=""

    # 方法1: 使用 ip link
    mac=$(ip link show dev "$WAN_INTERFACE" 2>/dev/null | grep "link/ether" | awk '{print $2}' | tr ':' '-')

    # 方法2: 使用 ifconfig
    if [ -z "$mac" ]; then
        mac=$(ifconfig "$WAN_INTERFACE" 2>/dev/null | grep "HWaddr" | awk '{print $5}' | tr '[:upper:]' '[:lower:]' | tr ':' '-')
    fi

    echo "$mac"
}


# 获取 WAN 网卡真实 MAC（12 位十六进制小写，供认证报文使用）
# 取不到或格式非法时返回空字符串
#
# 注意：此处不能用 case 的方括号表达式（如 [0-9a-f][0-9a-f]...），
#       BusyBox ash 下不生效；也不能用 tr -d '0-9a-f' 反向过滤，
#       实测 BusyBox 的 tr 对字符范围处理有偏差。故拆成两步：
#       先 case ??????? 查长度，再用 grep -Eqi 查字符。
get_wan_mac_hex() {
    local _raw=$(get_wan_mac)
    [ -n "$_raw" ] || _raw=$(cat /sys/class/net/"$WAN_INTERFACE"/address 2>/dev/null)
    local _hex=$(echo "$_raw" | tr -d ':-' | tr '[:upper:]' '[:lower:]')

    # 长度必须为 12
    case "$_hex" in
        ????????????) ;;
        *) echo ""; return ;;
    esac
    # 只能由十六进制字符组成
    echo "$_hex" | grep -Eqi '^[0-9a-f]{12}$' || { echo ""; return; }
    # 排除全零（无效 MAC）
    case "$_hex" in
        000000000000) echo ""; return ;;
    esac

    echo "$_hex"
}

# ============ 智能日志系统 ============

# 带级别的日志输出函数
# 级别: INFO, CHECK, OFFLINE, AUTH, ONLINE, ERROR, STAT, WARN, SUSPECT
log_with_level() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$level] $message"

    if [ "$LOG_TYPE" = "1" ]; then
        # 文件日志模式：写入实时日志
        # 确保实时日志目录存在（/tmp为RAM盘，重启后消失）
        local realtime_log_dir=$(dirname "$REALTIME_LOG_FILE")
        [ ! -d "$realtime_log_dir" ] && mkdir -p "$realtime_log_dir"

        echo "$log_line" >> "$REALTIME_LOG_FILE"

        # 故障级别日志同时写入持久化日志（立即写入，不等待切割）
        case "$level" in
            OFFLINE|AUTH|ONLINE|ERROR|WARN|STAT)
                # 确保持久化日志目录存在
                local log_dir=$(dirname "$PERSISTENT_LOG_FILE")
                [ ! -d "$log_dir" ] && mkdir -p "$log_dir"

                # 追加到持久化日志
                echo "$log_line" >> "$PERSISTENT_LOG_FILE"
                ;;
            SUSPECT)
                # SUSPECT级别日志根据配置决定是否写入持久化日志（v1.3.1+）
                if [ "$LOG_SUSPECT_STATE" = "Y" ] || [ "$LOG_SUSPECT_STATE" = "y" ]; then
                    local log_dir=$(dirname "$PERSISTENT_LOG_FILE")
                    [ ! -d "$log_dir" ] && mkdir -p "$log_dir"
                    echo "$log_line" >> "$PERSISTENT_LOG_FILE"
                fi
                ;;
        esac

        # 检查实时日志大小，触发切割
        check_and_rotate_log
    elif [ "$LOG_TYPE" = "2" ]; then
        # syslog模式
        logger -t autologin "[$level] $message"
    fi
}

# 检查并切割实时日志
check_and_rotate_log() {
    if [ ! -f "$REALTIME_LOG_FILE" ]; then
        return
    fi

    # 检查文件大小（MB）
    local size=$(du -m "$REALTIME_LOG_FILE" 2>/dev/null | cut -f1)
    if [ -z "$size" ]; then
        size=0
    fi

    # 如果超过阈值，执行智能切割
    if [ "$size" -ge "$REALTIME_LOG_SIZE_MB" ]; then
        rotate_realtime_log
    fi
}

# 智能切割实时日志
rotate_realtime_log() {
    log_with_level "INFO" "实时日志达到${REALTIME_LOG_SIZE_MB}MB，开始智能切割..."

    # 注意：故障事件已通过log_with_level()实时写入persistent.log
    # 此处仅需清空实时日志并记录切割标记

    # 清空实时日志并记录切割标记
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [INFO] 日志已切割（故障事件已实时归档到持久化日志）" > "$REALTIME_LOG_FILE"

    # 检查持久化日志大小
    trim_persistent_log
}

# 提取故障事件（从实时日志中提取OFFLINE、AUTH、ERROR、WARN、STAT级别）
extract_fault_events() {
    local source_log="$1"
    local dest_log="$2"

    if [ ! -f "$source_log" ]; then
        return
    fi

    # 提取故障相关日志（OFFLINE、AUTH、ONLINE、ERROR、WARN）和最后的STAT
    grep -E '\[(OFFLINE|AUTH|ONLINE|ERROR|WARN)\]' "$source_log" > "$dest_log" 2>/dev/null || true

    # 添加最后一条STAT日志
    grep '\[STAT\]' "$source_log" | tail -1 >> "$dest_log" 2>/dev/null || true
}

# 修剪持久化日志（按大小限制）
trim_persistent_log() {
    if [ ! -f "$PERSISTENT_LOG_FILE" ]; then
        return
    fi

    local size=$(du -m "$PERSISTENT_LOG_FILE" 2>/dev/null | cut -f1)
    if [ -z "$size" ]; then
        size=0
    fi

    # 如果超过配置大小，删除最旧的故障事件
    if [ "$size" -ge "$LOG_SIZE_MB" ]; then
        local temp_log="/tmp/persistent_trim_$$.tmp"

        # 保留后半部分日志和最后的STAT
        local total_lines=$(wc -l < "$PERSISTENT_LOG_FILE")
        local keep_lines=$((total_lines / 2))

        tail -n "$keep_lines" "$PERSISTENT_LOG_FILE" > "$temp_log"
        mv "$temp_log" "$PERSISTENT_LOG_FILE"

        log_with_level "INFO" "持久化日志已修剪，删除了最旧的 $((total_lines - keep_lines)) 行"
    fi
}

# 生成并输出状态摘要
generate_stat_summary() {
    load_state  # 重新加载最新状态

    local now=$(get_timestamp)
    local total_runtime=$((now - FIRST_START_TIME - TOTAL_OFFLINE_SECONDS))
    local online_duration=0

    if [ "$ONLINE_SINCE" -gt 0 ]; then
        online_duration=$((now - ONLINE_SINCE))
    fi

    # 计算平均恢复时间
    local avg_recovery="N/A"
    if [ "$OFFLINE_COUNT" -gt 0 ] && [ "$TOTAL_RECOVERY_TIME" -gt 0 ]; then
        avg_recovery=$(( TOTAL_RECOVERY_TIME / OFFLINE_COUNT ))
        avg_recovery="${avg_recovery}秒"
    fi

    # 计算平均认证次数
    local avg_auth="N/A"
    if [ "$OFFLINE_COUNT" -gt 0 ] && [ "$AUTH_TOTAL_COUNT" -gt 0 ]; then
        # 使用整数除法计算
        local auth_times_10=$(( AUTH_TOTAL_COUNT * 10 / OFFLINE_COUNT ))
        local auth_int=$((auth_times_10 / 10))
        local auth_dec=$((auth_times_10 % 10))
        avg_auth="${auth_int}.${auth_dec}次"
    fi

    # 输出状态摘要
    log_with_level "STAT" "========== 状态摘要 =========="
    log_with_level "STAT" "服务启动时间: $(format_datetime $FIRST_START_TIME)"
    log_with_level "STAT" "最后重启时间: $(format_datetime $LAST_START_TIME)"
    log_with_level "STAT" "总运行时长: $(format_duration $total_runtime)"
    log_with_level "STAT" "本次在线时长: $(format_duration $online_duration)"
    log_with_level "STAT" "本次上线时间: $(format_datetime $ONLINE_SINCE)"
    log_with_level "STAT" "历史离线次数: ${OFFLINE_COUNT}次"
    log_with_level "STAT" "上次离线时间: $(format_datetime $LAST_OFFLINE_TIME)"
    log_with_level "STAT" "上次离线原因: DNS失败[$LAST_OFFLINE_DNS_FAIL] | 并行验证失败[$LAST_OFFLINE_PARALLEL_FAIL] | 认证响应[$LAST_OFFLINE_AUTH_RESPONSE]"
    log_with_level "STAT" "上次恢复耗时: ${LAST_RECOVERY_DURATION}秒"
    log_with_level "STAT" "总认证次数: ${AUTH_TOTAL_COUNT}次 (平均${avg_auth})"

    # 动态生成DNS失败统计（仅显示配置的DNS服务器）
    local dns_stats=""
    for dns in $DNS_TEST_SERVERS; do
        local dns_key=$(get_dns_stat_key "$dns")
        local fail_count=$(eval echo \$${dns_key})
        # 如果fail_count为空，设置为0
        [ -z "$fail_count" ] && fail_count=0
        dns_stats="${dns_stats}${dns}(${fail_count}次) "
    done
    log_with_level "STAT" "DNS失败统计: ${dns_stats}"

    log_with_level "STAT" "最长在线时长: $(format_duration $MAX_ONLINE_DURATION)"
    log_with_level "STAT" "平均恢复耗时: ${avg_recovery}"

    # 检查告警
    check_and_alert

    log_with_level "STAT" "================================"

    # 更新最后摘要时间
    update_state "LAST_STAT_TIME" "$now"
}

# 检查并输出告警
check_and_alert() {
    load_state

    local now=$(get_timestamp)

    # 检查每小时离线次数
    local hour_elapsed=$((now - LAST_HOUR_START_TIME))
    if [ "$hour_elapsed" -ge 3600 ]; then
        # 重置每小时计数器
        update_state "LAST_HOUR_OFFLINE_COUNT" "0"
        update_state "LAST_HOUR_START_TIME" "$now"
    elif [ "$LAST_HOUR_OFFLINE_COUNT" -ge "$OFFLINE_ALERT_THRESHOLD" ]; then
        log_with_level "WARN" "⚠️ 告警: 最近1小时离线次数(${LAST_HOUR_OFFLINE_COUNT})超过阈值(${OFFLINE_ALERT_THRESHOLD})"
    fi

    # 检查连续认证失败
    if [ "$CONSECUTIVE_AUTH_FAILURES" -ge "$AUTH_FAIL_THRESHOLD" ]; then
        log_with_level "WARN" "⚠️ 告警: 连续认证失败次数(${CONSECUTIVE_AUTH_FAILURES})超过阈值(${AUTH_FAIL_THRESHOLD})"
    fi
}

# 定期输出状态摘要
periodic_stat_summary() {
    load_state
    local now=$(get_timestamp)
    local time_since_last=$((now - LAST_STAT_TIME))

    if [ "$time_since_last" -ge "$STAT_INTERVAL" ]; then
        generate_stat_summary
    fi
}

# 兼容旧代码的日志函数
log_message() {
    log_with_level "INFO" "$1"
}

log_message_force() {
    log_with_level "INFO" "$1"
}

# 执行登录请求
do_login() {
    local current_ip=$(get_wan_ip)
    local mac_address=$(get_wan_mac)

    # 增加认证尝试计数
    AUTH_ATTEMPT_COUNT=$((AUTH_ATTEMPT_COUNT + 1))

    # 取 WAN 网卡真实 MAC；取不到就放弃本次认证，避免带非法 MAC 打服务器
    local mac_hex=$(get_wan_mac_hex)
    if [ -z "$mac_hex" ]; then
        log_with_level "ERROR" "无法获取 WAN 口 MAC 地址 (接口: $WAN_INTERFACE)"
        OFFLINE_AUTH_RESPONSE="MAC获取失败"
        increment_state "CONSECUTIVE_AUTH_FAILURES"
        return 1
    fi

    if [ -z "$current_ip" ]; then
        log_with_level "ERROR" "无法获取 WAN 口 IP 地址 (接口: $WAN_INTERFACE)"
        OFFLINE_AUTH_RESPONSE="IP获取失败"
        increment_state "CONSECUTIVE_AUTH_FAILURES"
        return 1
    fi

    log_with_level "AUTH" "尝试认证 (第${AUTH_ATTEMPT_COUNT}次) - IP: $current_ip"

    # 构建登录 URL
    local url="http://${AUTH_SERVER}:${AUTH_PORT_801}/eportal/portal/login?callback=dr1003&login_method=1&user_account=%2C0%2C${USER_ACCOUNT}&user_password=${USER_PASSWORD}&wlan_user_ip=${current_ip}&wlan_user_ipv6=&wlan_user_mac=${mac_hex}&wlan_ac_ip=&wlan_ac_name=&page_index=pMnaGv1756888844&authex_enable=${ISP_CHOICE}&jsVersion=4.2.1&terminal_type=1&lang=zh-cn&lang=zh"

    # 执行登录请求
    local response=$(wget -T 5 -q -O - "$url" 2>&1)

    # 解析响应（简化版，提取关键信息）
    if echo "$response" | grep -q '"result":1' || echo "$response" | grep -q '认证成功' || echo "$response" | grep -q "success"; then
        OFFLINE_AUTH_RESPONSE="success"
        LAST_AUTH_OK=$(get_timestamp)
        log_with_level "AUTH" "认证响应: 成功"
        # 重置连续失败计数
        update_state "CONSECUTIVE_AUTH_FAILURES" "0"
    elif echo "$response" | grep -q "error"; then
        OFFLINE_AUTH_RESPONSE="error"
        log_with_level "AUTH" "认证响应: 失败"
        increment_state "CONSECUTIVE_AUTH_FAILURES"
    else
        OFFLINE_AUTH_RESPONSE="unknown"
        log_with_level "AUTH" "认证响应: $response"
    fi

    # 增加总认证计数
    increment_state "AUTH_TOTAL_COUNT"

    return 0
}

# ============================================
# 检测方法
# ============================================

# ==========================================================
# 在线状态判据（本环境实测结论）
# ----------------------------------------------------------
#   /drcom/chkstatus      : TCP 连上后不发响应头，挂起直到超时（接口已废弃）
#   /eportal/portal/login : 已在线时反而返回 result:0（服务器拒绝重复认证）
#   HTTP 明文出站          : 被本机 ua3f 透明代理(TPROXY 1080, UA 改写为 FFF)吞掉，
#                            表现为"TCP 3ms 建连成功、之后 0 字节响应"
#   HTTPS 出站             : 正常（TLS 不受 UA 改写影响）—— 主判据
#   DNS 直连公网 53        : 正常（可绕开 ua3f）—— 备判据
# ==========================================================

# 主判据：HTTPS 探测公网。成功=在线
check_real_http() {
    wget --spider -T 6 -t 1 -q "https://www.baidu.com/" 2>/dev/null && return 0
    wget --spider -T 6 -t 1 -q "https://www.qq.com/" 2>/dev/null && return 0

    # 备判据：直连公网 DNS 做一次查询，看是否返回真实应答
    # 注意：本地 dnsmasq 缓存可能应答，故必须指定公网 DNS 服务器
    local _r _srv
    for _srv in 223.5.5.5 119.29.29.29 1.1.1.1; do
        _r=$(nslookup www.baidu.com "$_srv" 2>/dev/null)
        case "$_r" in
            *"Non-authoritative answer"*)
                case "$_r" in
                    *"Address:"*[0-9].[0-9]*) return 0 ;;
                esac
                ;;
        esac
    done
    return 1
}

# 带日志的真实连通性检测
real_http_check() {
    check_real_http
    local _rc=$?
    if [ $_rc -eq 0 ]; then
        log_message "真实连通性检测: 在线 (HTTPS/DNS 出口正常)"
    else
        log_message "真实连通性检测: 离线 (HTTPS 与 DNS 出口均不可用)"
    fi
    return $_rc
}

# 方法1: 认证服务器HTTP状态检测（静默，不记录日志）
# 说明：本门户无法通过任何 HTTP 接口区分"在线/离线"，故此处统一走真实连通性判据。
check_auth_http() {
    if [ "$ENABLE_AUTH_HTTP" != "Y" ] && [ "$ENABLE_AUTH_HTTP" != "y" ]; then
        return 2
    fi
    check_real_http
    return $?
}

# 方法1: 认证服务器HTTP状态检测（带日志输出）
check_auth_http_with_log() {
    real_http_check
    return $?
}

# 方法2a: 公网DNS Ping检测（并行模式，用于快速验证）
check_public_ping_parallel() {
    if [ "$ENABLE_PUBLIC_PING" != "Y" ] && [ "$ENABLE_PUBLIC_PING" != "y" ]; then
        return 2
    fi

    # 将空格分隔的DNS转换为列表
    local dns_list=""
    for dns in $DNS_TEST_SERVERS; do
        dns_list="$dns_list $dns"
    done

    # 计算DNS数量
    local dns_count=0
    for dns in $dns_list; do
        dns_count=$((dns_count + 1))
    done

    if [ $dns_count -eq 0 ]; then
        return 2
    fi

    # 并行检测所有DNS服务器（快速判定）
    local success_count=0
    local fail_count=0

    for dns in $dns_list; do
        if ping -c 1 -W 1 "$dns" >/dev/null 2>&1; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    # 判断逻辑：至少1个DNS成功即在线
    if [ $success_count -ge 1 ]; then
        return 0  # 至少1个在线，判定在线
    fi

    # 所有DNS失败，用HTTP验证认证服务器
    check_auth_http
    local http_result=$?
    if [ $http_result -eq 0 ]; then
        return 0  # HTTP在线，可能是DNS问题
    fi

    # DNS和HTTP都失败，确认离线
    return 1
}

# 方法2a: 公网DNS Ping检测（并行模式，带日志）
check_public_ping_parallel_with_log() {
    if [ "$ENABLE_PUBLIC_PING" != "Y" ] && [ "$ENABLE_PUBLIC_PING" != "y" ]; then
        return 2
    fi

    # 将空格分隔的DNS转换为列表
    local dns_list=""
    for dns in $DNS_TEST_SERVERS; do
        dns_list="$dns_list $dns"
    done

    # 计算DNS数量
    local dns_count=0
    for dns in $dns_list; do
        dns_count=$((dns_count + 1))
    done

    if [ $dns_count -eq 0 ]; then
        return 2
    fi

    # 并行检测所有DNS服务器
    local success_count=0
    local fail_count=0
    local success_list=""
    local fail_list=""

    for dns in $dns_list; do
        if ping -c 1 -W 1 "$dns" >/dev/null 2>&1; then
            success_count=$((success_count + 1))
            success_list="$success_list $dns"
        else
            fail_count=$((fail_count + 1))
            fail_list="$fail_list $dns"
            # 记录失败的DNS到全局变量（用于离线事件）
            OFFLINE_PARALLEL_FAIL_LIST="${OFFLINE_PARALLEL_FAIL_LIST}${dns} "
            # 增加DNS失败统计
            local dns_key=$(get_dns_stat_key "$dns")
            increment_state "$dns_key"
        fi
    done

    # 记录详细日志
    log_with_level "CHECK" "并行DNS检测: 成功 $success_count/$dns_count, 失败 $fail_count/$dns_count"
    [ -n "$success_list" ] && log_with_level "CHECK" "  可达:$success_list"
    [ -n "$fail_list" ] && log_with_level "CHECK" "  不可达:$fail_list"

    # 判断逻辑
    if [ $success_count -ge 1 ]; then
        log_with_level "ONLINE" "判定: 在线 (至少1个DNS可达)"
        return 0
    fi

    # 所有DNS失败，用HTTP验证认证服务器
    log_with_level "CHECK" "所有DNS失败，验证认证服务器HTTP状态..."
    check_auth_http
    local http_result=$?

    if [ $http_result -eq 0 ]; then
        log_with_level "ONLINE" "判定: 在线 (DNS不可达但HTTP在线，可能是DNS问题)"
        return 0
    elif [ $http_result -eq 1 ]; then
        log_with_level "OFFLINE" "判定: 离线 (DNS和HTTP均不可达)"
        return 1
    else
        log_with_level "OFFLINE" "判定: 离线 (DNS全部失败，HTTP状态不确定)"
        return 1
    fi
}

# 方法2b: 公网DNS Ping检测（轮询模式，静默）
check_public_ping() {
    if [ "$ENABLE_PUBLIC_PING" != "Y" ] && [ "$ENABLE_PUBLIC_PING" != "y" ]; then
        return 2
    fi

    # 将空格分隔的DNS转换为列表
    local dns_list=""
    for dns in $DNS_TEST_SERVERS; do
        dns_list="$dns_list $dns"
    done

    # 计算DNS数量
    local dns_count=0
    for dns in $dns_list; do
        dns_count=$((dns_count + 1))
    done

    if [ $dns_count -eq 0 ]; then
        return 2
    fi

    # 先ping认证服务器（确保本地网络正常）
    if ! ping -c 1 -W 1 "$AUTH_SERVER" >/dev/null 2>&1; then
        DNS_CONSECUTIVE_FAILURES=$((DNS_CONSECUTIVE_FAILURES + 1))
        if [ $DNS_CONSECUTIVE_FAILURES -ge 2 ]; then
            return 1  # 本地网络故障，连续失败
        fi
        return 0  # 首次失败，不立即判定离线
    fi

    # 轮询检测：选择当前索引的DNS服务器
    local current_index=0
    local target_dns=""
    for dns in $dns_list; do
        if [ $current_index -eq $DNS_SERVER_INDEX ]; then
            target_dns="$dns"
            break
        fi
        current_index=$((current_index + 1))
    done

    # 更新索引，下次检测下一个DNS（循环）
    DNS_SERVER_INDEX=$(((DNS_SERVER_INDEX + 1) % dns_count))

    # 检测当前DNS服务器
    if ping -c 1 -W 2 "$target_dns" >/dev/null 2>&1; then
        # 成功：重置连续失败计数器
        DNS_CONSECUTIVE_FAILURES=0
        return 0  # 在线
    else
        # 失败：增加连续失败计数器
        DNS_CONSECUTIVE_FAILURES=$((DNS_CONSECUTIVE_FAILURES + 1))
        if [ $DNS_CONSECUTIVE_FAILURES -ge 2 ]; then
            return 1  # 连续2次失败，判定离线
        fi
        return 0  # 首次失败，不立即判定离线
    fi
}

# 方法2: 公网DNS Ping检测（轮询模式，带日志输出）
check_public_ping_with_log() {
    if [ "$ENABLE_PUBLIC_PING" != "Y" ] && [ "$ENABLE_PUBLIC_PING" != "y" ]; then
        return 2
    fi

    # 将空格分隔的DNS转换为列表
    local dns_list=""
    for dns in $DNS_TEST_SERVERS; do
        dns_list="$dns_list $dns"
    done

    # 计算DNS数量
    local dns_count=0
    for dns in $dns_list; do
        dns_count=$((dns_count + 1))
    done

    if [ $dns_count -eq 0 ]; then
        return 2
    fi

    # 先ping认证服务器（确保本地网络正常）
    if ! ping -c 1 -W 1 "$AUTH_SERVER" >/dev/null 2>&1; then
        DNS_CONSECUTIVE_FAILURES=$((DNS_CONSECUTIVE_FAILURES + 1))
        log_message "公网DNS Ping检测: 认证服务器 $AUTH_SERVER 不可达 (连续失败: $DNS_CONSECUTIVE_FAILURES)"
        if [ $DNS_CONSECUTIVE_FAILURES -ge 2 ]; then
            log_message "  判定: 离线 (本地网络连续失败 >= 2次)"
            return 1  # 本地网络故障，连续失败
        fi
        log_message "  判定: 暂不判定离线 (首次失败)"
        return 0  # 首次失败，不立即判定离线
    fi

    # 轮询检测：选择当前索引的DNS服务器
    local current_index=0
    local target_dns=""
    for dns in $dns_list; do
        if [ $current_index -eq $DNS_SERVER_INDEX ]; then
            target_dns="$dns"
            break
        fi
        current_index=$((current_index + 1))
    done

    log_message "公网DNS Ping检测: 轮询检测 DNS[$((DNS_SERVER_INDEX))]=$target_dns (连续失败计数: $DNS_CONSECUTIVE_FAILURES)"

    # 更新索引，下次检测下一个DNS（循环）
    DNS_SERVER_INDEX=$(((DNS_SERVER_INDEX + 1) % dns_count))

    # 检测当前DNS服务器
    if ping -c 1 -W 2 "$target_dns" >/dev/null 2>&1; then
        # 成功：重置连续失败计数器
        log_message "  结果: 可达"
        DNS_CONSECUTIVE_FAILURES=0
        log_message "  判定: 在线 (连续失败计数器已重置)"
        return 0  # 在线
    else
        # 失败：增加连续失败计数器
        DNS_CONSECUTIVE_FAILURES=$((DNS_CONSECUTIVE_FAILURES + 1))
        log_message "  结果: 不可达 (连续失败计数: $DNS_CONSECUTIVE_FAILURES)"
        if [ $DNS_CONSECUTIVE_FAILURES -ge 2 ]; then
            log_message "  判定: 离线 (连续失败 >= 2次)"
            return 1  # 连续2次失败，判定离线
        fi
        log_message "  判定: 暂不判定离线 (首次失败)"
        return 0  # 首次失败，不立即判定离线
    fi
}

# ============================================
# 状态机主逻辑 - 4状态自适应检测
# ============================================

# 在线状态处理（ONLINE）- 低频轮询检测
handle_online_state() {
    # 定期输出状态摘要
    periodic_stat_summary

    local current_time=$(get_timestamp)

    # 轮询检测：每DNS_CHECK_INTERVAL秒检测1个DNS
    local time_since_last_dns=$((current_time - LAST_DNS_CHECK))

    if [ $time_since_last_dns -ge $DNS_CHECK_INTERVAL ]; then
        LAST_DNS_CHECK=$current_time
        check_public_ping  # 轮询模式
        local dns_result=$?

        if [ $dns_result -eq 1 ]; then
            # 单次失败，进入疑似离线状态快速验证
            log_with_level "SUSPECT" "*** 状态变化: 在线 -> 疑似离线 (轮询检测失败，启动快速验证) ***"
            CURRENT_STATE="SUSPECT"
            return
        fi
        # dns_result=0，继续在线状态
    fi

    # 在线状态不检测认证服务器HTTP，避免被强制下线
    safe_sleep 1
}

# 疑似离线状态处理（SUSPECT）- 并行快速验证
handle_suspect_state() {
    log_with_level "SUSPECT" "疑似离线状态，立即启动并行快速验证..."

    # 立即并行检测所有DNS（1秒超时）
    check_public_ping_parallel_with_log
    local parallel_result=$?

    if [ $parallel_result -eq 0 ]; then
        # 并行检测通过，是误报，回到在线状态
        log_with_level "SUSPECT" "*** 状态变化: 疑似离线 -> 在线 (快速验证通过，误报) ***"
        DNS_CONSECUTIVE_FAILURES=0  # 重置计数器
        CURRENT_STATE="ONLINE"
        LAST_DNS_CHECK=$(get_timestamp)
        return
    elif [ $parallel_result -eq 1 ]; then
        # 并行检测确认离线
        log_with_level "OFFLINE" "*** 状态变化: 疑似离线 -> 离线 (快速验证确认离线) ***"
        CURRENT_STATE="OFFLINE"
        return
    else
        # 检测失败（不应该发生）
        log_with_level "ERROR" "疑似离线验证失败，默认判定为离线"
        CURRENT_STATE="OFFLINE"
        return
    fi
}

# 离线状态处理（OFFLINE）- 快速登录恢复
handle_offline_state() {
    # 初始化离线事件
    OFFLINE_START_TIME=$(get_timestamp)
    OFFLINE_DNS_FAIL_LIST=""
    OFFLINE_PARALLEL_FAIL_LIST=""
    OFFLINE_AUTH_RESPONSE=""
    AUTH_ATTEMPT_COUNT=0
    COOLDOWN_END_TIME=0  # 冷却结束时间戳

    # 记录离线事件
    increment_state "OFFLINE_COUNT"
    increment_state "CURRENT_EVENT_ID"
    increment_state "LAST_HOUR_OFFLINE_COUNT"
    update_state "LAST_OFFLINE_TIME" "$OFFLINE_START_TIME"

    # 记录在线时长
    if [ "$ONLINE_SINCE" -gt 0 ]; then
        local online_duration=$((OFFLINE_START_TIME - ONLINE_SINCE))
        if [ "$online_duration" -gt "$MAX_ONLINE_DURATION" ]; then
            update_state "MAX_ONLINE_DURATION" "$online_duration"
        fi
    fi

    load_state  # 重新加载最新事件ID
    log_with_level "OFFLINE" "========== 故障事件 #${CURRENT_EVENT_ID} =========="
    log_with_level "OFFLINE" "检测到离线，立即尝试登录并进入快速恢复模式..."

    # 立即执行登录
    do_login

    # 快速恢复循环
    local offline_loop_count=0
    local last_offline_check=$(get_timestamp)
    local last_login_attempt=$(get_timestamp)
    local fast_check_interval=10  # 离线时状态查询间隔（固定10秒，避免空转刷屏）
    local login_interval=$OFFLINE_AUTH_INTERVAL  # 离线时登录请求发送间隔（v1.3.0+）

    while true; do
        offline_loop_count=$((offline_loop_count + 1))
        safe_sleep $fast_check_interval

        local current_time=$(get_timestamp)
        local time_since_check=$((current_time - last_offline_check))

        # 定期并行检测DNS
        if [ $time_since_check -ge $fast_check_interval ]; then
            last_offline_check=$current_time

            # 并行检测DNS
            check_public_ping_parallel
            local dns_result=$?

            if [ $dns_result -eq 0 ]; then
                # DNS恢复，立即检测HTTP
                log_with_level "CHECK" "DNS检测恢复，立即验证HTTP状态..."
                check_auth_http_with_log
                local http_result=$?

                if [ $http_result -eq 0 ] || [ $LAST_AUTH_OK -gt 0 ]; then
                    # DNS + HTTP双重验证通过，记录恢复时长
                    local recovery_duration=$((current_time - OFFLINE_START_TIME))
                    update_state "LAST_RECOVERY_DURATION" "$recovery_duration"
                    increment_state "TOTAL_RECOVERY_TIME" "$recovery_duration"
                    update_state "LAST_OFFLINE_DNS_FAIL" "$OFFLINE_DNS_FAIL_LIST"
                    update_state "LAST_OFFLINE_PARALLEL_FAIL" "$OFFLINE_PARALLEL_FAIL_LIST"
                    update_state "LAST_OFFLINE_AUTH_RESPONSE" "$OFFLINE_AUTH_RESPONSE"
                    update_state "AUTH_LAST_ATTEMPTS" "$AUTH_ATTEMPT_COUNT"

                    # 累计离线时间
                    local offline_duration=$((current_time - OFFLINE_START_TIME))
                    increment_state "TOTAL_OFFLINE_SECONDS" "$offline_duration"

                    log_with_level "ONLINE" "*** 状态变化: 离线 -> 恢复中 (策略${ONLINE_VERIFY_STRATEGY:-2}: DNS通过$( [ "${ONLINE_VERIFY_STRATEGY:-2}" = "1" ] || printf " + HTTP通过" )) ***"
                    log_with_level "ONLINE" "恢复耗时: ${recovery_duration}秒 | 认证尝试: ${AUTH_ATTEMPT_COUNT}次"
                    log_with_level "ONLINE" "=========================================="

                    CURRENT_STATE="RECOVERING"
                    RECOVERING_SUCCESS_COUNT=0
                    return
                elif [ $http_result -eq 1 ]; then
                    # DNS在线但HTTP离线，需要继续登录
                    log_with_level "CHECK" "DNS恢复但HTTP显示离线，需要继续认证"
                    # 继续循环，下面会处理登录
                fi
            fi
        fi

        # 智能登录：DNS失败或HTTP离线时才登录
        local time_since_login=$((current_time - last_login_attempt))

        # 检查是否在冷却期
        if [ $current_time -lt $COOLDOWN_END_TIME ]; then
            # 仍在冷却期，跳过登录但继续检测
            continue
        fi

        # 检查是否需要发送登录请求
        if [ $time_since_login -ge $login_interval ]; then
            # 检查是否达到最大认证次数
            if [ $AUTH_ATTEMPT_COUNT -ge $OFFLINE_AUTH_MAX_ATTEMPTS ]; then
                log_with_level "WARN" "已达到最大认证次数 ($OFFLINE_AUTH_MAX_ATTEMPTS)，进入冷却期 ($OFFLINE_COOLDOWN_SECONDS 秒)"
                # 设置冷却结束时间（继续DNS/HTTP检测，仅暂停登录）
                COOLDOWN_END_TIME=$((current_time + OFFLINE_COOLDOWN_SECONDS))
                # 重置认证计数器
                AUTH_ATTEMPT_COUNT=0
                continue
            fi

            if [ $((offline_loop_count % 3)) -eq 0 ]; then
                log_with_level "AUTH" "网络仍离线 (循环 #$offline_loop_count)，继续尝试登录..."
            fi
            do_login
            last_login_attempt=$current_time
        fi
    done
}

# 在线判据：按配置的 ONLINE_VERIFY_STRATEGY 决定
#   1 = 仅依赖DNS检测
#       注意：本环境的"DNS检测"是 ICMP ping，登出后仍可能通，
#             故策略1下额外用一次真实连通性探测兜底，否则会漏判登出。
#   2 = DNS + HTTP双重验证（默认，推荐）
check_online_criteria() {
    local _dns=$1
    local _http=$2
    local _strategy=${ONLINE_VERIFY_STRATEGY:-2}

    [ "$_dns" -eq 0 ] || return 1

    case "$_strategy" in
        1)
            check_real_http
            return $?
            ;;
        *)
            [ "$_http" -eq 0 ] && return 0
            [ "$_http" -eq 2 ] && return 0
            return 1
            ;;
    esac
}

# 恢复中状态处理（RECOVERING）- 持续验证稳定性
handle_recovering_state() {
    log_with_level "CHECK" "进入恢复验证阶段，持续监控稳定性..."

    local recovering_check_count=0
    local required_success=5  # 需要连续5次成功才确认稳定
    local check_interval=10  # 每10秒检测一次（避免空转刷屏）

    while [ $recovering_check_count -lt $required_success ]; do
        recovering_check_count=$((recovering_check_count + 1))
        safe_sleep $check_interval

        # 并行检测DNS
        check_public_ping_parallel
        local dns_result=$?

        # 检测HTTP（每次都检测，确保真正在线）
        check_auth_http
        local http_result=$?

        if check_online_criteria "$dns_result" "$http_result"; then
            # 本次检测成功
            RECOVERING_SUCCESS_COUNT=$((RECOVERING_SUCCESS_COUNT + 1))
            log_with_level "CHECK" "恢复验证: $RECOVERING_SUCCESS_COUNT/$required_success 成功"
        else
            # 验证失败，重新进入离线状态
            log_with_level "OFFLINE" "*** 状态变化: 恢复中 -> 离线 (验证失败，网络不稳定) ***"
            RECOVERING_SUCCESS_COUNT=0
            CURRENT_STATE="OFFLINE"
            return
        fi
    done

    # 连续验证成功，确认稳定在线
    local now=$(get_timestamp)
    update_state "ONLINE_SINCE" "$now"
    CURRENT_SESSION_START=$now

    log_with_level "ONLINE" "*** 状态变化: 恢复中 -> 在线 (连续${required_success}次验证成功，确认稳定) ***"
    LAST_AUTH_OK=0
    CURRENT_STATE="ONLINE"
    DNS_CONSECUTIVE_FAILURES=0
    LAST_DNS_CHECK=$now
    LAST_HTTP_CHECK=$now
}

# 主循环
main() {
    load_config

    # 初始化状态文件
    init_state_file
    load_state

    # 验证关键命令是否可用
    if ! check_required_commands; then
        exit 1
    fi

    # 验证配置参数
    if [ -z "$WAN_INTERFACE" ] || [ -z "$USER_ACCOUNT" ] || [ -z "$USER_PASSWORD" ]; then
        log_with_level "ERROR" "配置文件缺少必要参数"
        exit 1
    fi

    # 验证检测频率是否为有效数字
    case "$DNS_CHECK_INTERVAL" in
        ''|*[!0-9]*)
            log_with_level "WARN" "DNS_CHECK_INTERVAL无效，使用默认值10秒"
            DNS_CHECK_INTERVAL=10
            ;;
    esac

    # AUTH_HTTP_CHECK_INTERVAL已废弃，仅保留用于兼容旧版本配置（v1.3.3+）
    case "$AUTH_HTTP_CHECK_INTERVAL" in
        ''|*[!0-9]*)
            AUTH_HTTP_CHECK_INTERVAL=60  # 默认值，实际未使用
            ;;
    esac

    case "$RECONNECT_INTERVAL" in
        ''|*[!0-9]*)
            log_with_level "WARN" "RECONNECT_INTERVAL无效，使用默认值3秒"
            RECONNECT_INTERVAL=3
            ;;
    esac

    # 新增参数验证（v1.3.0+）
    case "$OFFLINE_AUTH_INTERVAL" in
        ''|*[!0-9]*)
            log_with_level "WARN" "OFFLINE_AUTH_INTERVAL无效或未配置，使用默认值2秒"
            OFFLINE_AUTH_INTERVAL=2
            ;;
    esac

    case "$OFFLINE_HTTP_CHECK_INTERVAL" in
        ''|*[!0-9]*)
            log_with_level "WARN" "OFFLINE_HTTP_CHECK_INTERVAL无效或未配置，使用默认值2秒"
            OFFLINE_HTTP_CHECK_INTERVAL=2
            ;;
    esac

    # 新增参数验证（v1.3.2+）
    case "$OFFLINE_AUTH_MAX_ATTEMPTS" in
        ''|*[!0-9]*)
            log_with_level "WARN" "OFFLINE_AUTH_MAX_ATTEMPTS无效或未配置，使用默认值20次"
            OFFLINE_AUTH_MAX_ATTEMPTS=20
            ;;
    esac

    case "$OFFLINE_COOLDOWN_SECONDS" in
        ''|*[!0-9]*)
            log_with_level "WARN" "OFFLINE_COOLDOWN_SECONDS无效或未配置，使用默认值300秒"
            OFFLINE_COOLDOWN_SECONDS=300
            ;;
    esac

    case "$DNS_FAILURE_THRESHOLD" in
        ''|*[!0-9]*)
            log_with_level "WARN" "DNS_FAILURE_THRESHOLD无效，使用默认值2"
            DNS_FAILURE_THRESHOLD=2
            ;;
    esac

    # 新增参数验证（v1.3.1+）
    case "$LOG_SUSPECT_STATE" in
        ''|[Nn]*)
            LOG_SUSPECT_STATE="N"
            ;;
        [Yy]*)
            LOG_SUSPECT_STATE="Y"
            ;;
        *)
            log_with_level "WARN" "LOG_SUSPECT_STATE无效或未配置，使用默认值N（不记录疑似离线日志）"
            LOG_SUSPECT_STATE="N"
            ;;
    esac

    # 确保检测频率至少为1秒
    if [ $DNS_CHECK_INTERVAL -lt 1 ]; then
        DNS_CHECK_INTERVAL=1
    fi
    if [ $AUTH_HTTP_CHECK_INTERVAL -lt 1 ]; then
        AUTH_HTTP_CHECK_INTERVAL=1
    fi
    if [ $RECONNECT_INTERVAL -lt 1 ]; then
        RECONNECT_INTERVAL=1
    fi
    if [ $OFFLINE_AUTH_INTERVAL -lt 1 ]; then
        OFFLINE_AUTH_INTERVAL=1
    fi
    if [ $OFFLINE_HTTP_CHECK_INTERVAL -lt 1 ]; then
        OFFLINE_HTTP_CHECK_INTERVAL=1
    fi
    if [ $OFFLINE_AUTH_MAX_ATTEMPTS -lt 1 ]; then
        OFFLINE_AUTH_MAX_ATTEMPTS=1
    fi
    if [ $OFFLINE_COOLDOWN_SECONDS -lt 1 ]; then
        OFFLINE_COOLDOWN_SECONDS=1
    fi

    log_with_level "INFO" "=== 自动登录服务启动 ==="
    log_with_level "INFO" "版本: $SCRIPT_VERSION ($SCRIPT_VERSION_DESC)"
    log_with_level "INFO" "WAN 接口: $WAN_INTERFACE"
    log_with_level "INFO" ""
    log_with_level "INFO" "检测策略:"
    log_with_level "INFO" "  • ONLINE状态: 低频轮询检测（每${DNS_CHECK_INTERVAL}秒1个DNS）"
    log_with_level "INFO" "  • SUSPECT状态: 并行快速验证（1秒超时，所有DNS）"
    log_with_level "INFO" "  • OFFLINE状态: 快速恢复模式（每2秒并行检测）"
    log_with_level "INFO" "  • RECOVERING状态: 稳定性验证（连续5次成功确认）"
    log_with_level "INFO" ""
    log_with_level "INFO" "性能指标:"
    log_with_level "INFO" "  • 在线误判防护: 轮询单点失败→并行快速验证"
    log_with_level "INFO" "  • 离线发现时间: < 2秒（并行检测）"
    log_with_level "INFO" "  • 恢复时间: < 2秒（快速检测+立即登录）"
    log_with_level "INFO" "  • 状态稳定性: 连续5次验证防止频繁切换"
    log_with_level "INFO" ""
    log_with_level "INFO" "日志系统:"
    log_with_level "INFO" "  • 实时日志: $REALTIME_LOG_FILE"
    log_with_level "INFO" "  • 持久化日志: $PERSISTENT_LOG_FILE"
    log_with_level "INFO" "  • 状态文件: $STATE_FILE"
    log_with_level "INFO" "  • 状态摘要间隔: $((STAT_INTERVAL/60))分钟"
    log_with_level "INFO" ""
    log_with_level "INFO" "公网DNS服务器: $DNS_TEST_SERVERS"

    # 初始化时间戳
    CURRENT_SESSION_START=$(get_timestamp)
    LAST_DNS_CHECK=0
    LAST_HTTP_CHECK=0

    # 初始化状态为UNKNOWN，进行首次检测
    CURRENT_STATE="UNKNOWN"
    log_with_level "INFO" "执行初始状态检测（并行快速检测）..."

    # 使用并行检测快速判定初始状态
    check_public_ping_parallel_with_log
    local initial_dns=$?

    if [ $initial_dns -eq 0 ]; then
        # DNS检测通过，检查HTTP验证
        check_auth_http_with_log
        local initial_http=$?

        if [ $initial_http -eq 0 ]; then
            log_with_level "ONLINE" "初始状态: 在线 (DNS + HTTP双重验证通过)"
            CURRENT_STATE="ONLINE"
            update_state "ONLINE_SINCE" "$(get_timestamp)"
        else
            log_with_level "OFFLINE" "初始状态: 离线 (DNS通过但HTTP验证失败)"
            CURRENT_STATE="OFFLINE"
        fi
    else
        log_with_level "OFFLINE" "初始状态: 离线 (DNS检测失败)"
        CURRENT_STATE="OFFLINE"
    fi

    # 状态机主循环
    while true; do
        case "$CURRENT_STATE" in
            ONLINE)
                handle_online_state
                ;;
            SUSPECT)
                handle_suspect_state
                ;;
            OFFLINE)
                handle_offline_state
                ;;
            RECOVERING)
                handle_recovering_state
                ;;
            *)
                log_with_level "ERROR" "未知状态 $CURRENT_STATE，重置为OFFLINE"
                CURRENT_STATE="OFFLINE"
                ;;
        esac
    done
}

# 如果直接运行（不是被 source）
if [ "${0##*/}" = "login.sh" ]; then
    main
fi
EOFSCRIPT

    chmod +x "$SCRIPT_FILE"
}

# 生成配置文件
generate_config() {
    print_info "生成配置文件..."

    cat > "$CONFIG_FILE" << EOF
# 自动登录服务配置文件

# WAN 接口名称
WAN_INTERFACE="$WAN_IF"

# 登录凭证
USER_ACCOUNT="$USER_ACCOUNT"
USER_PASSWORD="$USER_PASSWORD"

# 运营商选择 (1=联通, 2=移动)
ISP_CHOICE="$ISP_CHOICE"

# 认证服务器配置
AUTH_SERVER="10.10.11.11"
AUTH_PORT_801="801"
AUTH_PORT_80="80"

# 检测频率配置 (秒)
DNS_CHECK_INTERVAL="$DNS_CHECK_INTERVAL"
AUTH_HTTP_CHECK_INTERVAL="$AUTH_HTTP_CHECK_INTERVAL"
RECONNECT_INTERVAL="$RECONNECT_INTERVAL"

# 离线状态检测配置 (v1.3.0+)
OFFLINE_AUTH_INTERVAL="$OFFLINE_AUTH_INTERVAL"
OFFLINE_HTTP_CHECK_INTERVAL="$OFFLINE_HTTP_CHECK_INTERVAL"

# 离线认证保护配置 (v1.3.2+)
OFFLINE_AUTH_MAX_ATTEMPTS="$OFFLINE_AUTH_MAX_ATTEMPTS"
OFFLINE_COOLDOWN_SECONDS="$OFFLINE_COOLDOWN_SECONDS"

# 检测策略配置
DNS_FAILURE_THRESHOLD="$DNS_FAILURE_THRESHOLD"
ONLINE_VERIFY_STRATEGY="$ONLINE_VERIFY_STRATEGY"

# 检测方法开关
ENABLE_AUTH_HTTP="$ENABLE_AUTH_HTTP"
ENABLE_PUBLIC_HTTP="$ENABLE_PUBLIC_HTTP"
ENABLE_PUBLIC_PING="$ENABLE_PUBLIC_PING"

# 公网测试服务器配置
DNS_TEST_SERVERS="$DNS_TEST_SERVERS"

# 日志配置
LOG_TYPE="$LOG_TYPE"
LOG_SIZE_MB="$LOG_SIZE_MB"

# 日志系统配置 (LOG_TYPE=1 文件模式专用)
REALTIME_LOG_FILE="$REALTIME_LOG_FILE"
PERSISTENT_LOG_FILE="$PERSISTENT_LOG_FILE"
REALTIME_LOG_SIZE_MB="$REALTIME_LOG_SIZE_MB"
STAT_INTERVAL="$STAT_INTERVAL"
OFFLINE_ALERT_THRESHOLD="$OFFLINE_ALERT_THRESHOLD"
AUTH_FAIL_THRESHOLD="$AUTH_FAIL_THRESHOLD"

# 疑似离线日志记录配置 (v1.3.1+)
LOG_SUSPECT_STATE="$LOG_SUSPECT_STATE"

# 状态文件路径
STATE_FILE="/usr/local/autologin/runtime.state"
EOF

    chmod 600 "$CONFIG_FILE"
}

# 生成服务启动脚本
generate_service() {
    print_info "生成服务启动脚本..."

    cat > "$SERVICE_FILE" << 'EOFSERVICE'
#!/bin/sh /etc/rc.common
#
# 自动登录服务
#

START=99
STOP=15

USE_PROCD=1

PROG="/usr/local/autologin/login.sh"
NAME="autologin"

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh "$PROG"
    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-5}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    killall -9 login.sh 2>/dev/null
}

reload_service() {
    stop
    start
}
EOFSERVICE

    chmod +x "$SERVICE_FILE"
}

# 启用并启动服务
enable_service() {
    print_info "启用服务..."
    "$SERVICE_FILE" enable

    print_info "启动服务..."
    "$SERVICE_FILE" start

    sleep 2

    if "$SERVICE_FILE" status >/dev/null 2>&1; then
        print_info "服务启动成功!"
    else
        print_warn "服务状态未知，请检查日志"
    fi
}

# 显示后续操作提示
show_usage() {
    echo ""
    print_info "============================================"
    print_info "  安装完成!"
    print_info "============================================"
    echo ""
    echo "服务管理命令:"
    echo "  启动服务: /etc/init.d/autologin start"
    echo "  停止服务: /etc/init.d/autologin stop"
    echo "  重启服务: /etc/init.d/autologin restart"
    echo "  查看状态: /etc/init.d/autologin status"
    echo "  开机启动: /etc/init.d/autologin enable"
    echo "  禁用启动: /etc/init.d/autologin disable"
    echo ""
    echo "配置文件:"
    echo "  配置文件: $CONFIG_FILE"
    echo "  登录脚本: $SCRIPT_FILE"
    echo ""
    if [ "$LOG_TYPE" = "1" ]; then
        echo "日志系统 (智能双层架构):"
        echo "  实时日志: $REALTIME_LOG_FILE"
        echo "  持久化故障日志: $PERSISTENT_LOG_FILE"
        echo "  状态文件: /usr/local/autologin/runtime.state"
        echo ""
        echo "  查看实时日志: tail -f $REALTIME_LOG_FILE"
        echo "  查看故障日志: tail -f $PERSISTENT_LOG_FILE"
        echo "  查看运行统计: cat /usr/local/autologin/runtime.state"
    elif [ "$LOG_TYPE" = "2" ]; then
        echo "日志查看:"
        echo "  实时日志: logread -f | grep autologin"
        echo "  历史日志: logread | grep autologin"
    fi
    echo ""
    echo "重新配置:"
    echo "  编辑配置: vi $CONFIG_FILE"
    echo "  重启服务使配置生效"
    echo ""
}

# 主安装流程
main() {
    echo ""
    print_info "========================================"
    print_info "  OpenWrt 自动登录服务安装程序"
    print_info "           版本: $VERSION"
    print_info "========================================"
    echo ""

    # 显示版本更新信息
    printf "${GREEN}📦 $VERSION 新版本特性 ($VERSION_DESC)${NC}\n"
    echo ""
    echo "🔧 关键问题修复："
    echo "   • wget命令BusyBox兼容性（短选项替代长选项）"
    echo "   • /tmp目录自动创建（解决重启后日志丢失）"
    echo "   • 离线认证保护机制（最大尝试次数+冷却期）"
    echo "   • read -p 和 echo -e 命令兼容性修复"
    echo ""
    echo "✨ 新增功能："
    echo "   • 离线认证保护（可配置最大尝试次数和冷却时间）"
    echo "   • 冷却期默认300秒，防止服务器压力过大"
    echo ""
    echo "✨ 继承特性："
    echo "   • 双层日志架构（实时+持久化）"
    echo "   • 完整运行统计与故障追踪"
    echo "   • 结构化日志级别与智能切割"
    echo "   • 智能告警机制"
    echo ""
    printf "${YELLOW}💡 提示: 从 v1.3.1 升级无破坏性变更，配置兼容${NC}\n"
    echo ""
    printf "按回车键继续安装..."
    read dummy
    echo ""

    check_system

    if ! check_dependencies; then
        print_error "依赖检测失败，安装终止"
        exit 1
    fi

    interactive_config
    create_directories
    generate_login_script
    generate_config
    generate_service
    enable_service
    show_usage

    print_info "安装程序执行完毕"
}

# 执行主函数
main
