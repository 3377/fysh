#!/bin/bash

# =============================================================================
# 双IP配置脚本 - Debian系统
# =============================================================================

# ======================== 配置变量区域 ========================
# 主IP配置
PRIMARY_IP="10.1.1.66"
PRIMARY_NETMASK="255.255.255.0"
PRIMARY_GATEWAY="10.1.1.250"
PRIMARY_METRIC="100"

# 辅助IP配置
SECONDARY_IP="192.168.70.66"
SECONDARY_NETMASK="255.255.255.0"
SECONDARY_GATEWAY="192.168.70.1"
SECONDARY_METRIC="200"

# DNS服务器
DNS_SERVERS="114.114.114.114 8.8.4.4"

# ======================== 脚本开始 ========================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 显示帮助信息
show_help() {
    echo "双IP配置脚本使用说明："
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  add     添加双IP配置（默认操作）"
    echo "  remove  删除辅助IP配置"
    echo "  status  查看当前IP配置状态"
    echo "  help    显示此帮助信息"
    echo ""
    echo "当前配置变量:"
    echo "  主IP: $PRIMARY_IP/$PRIMARY_NETMASK 网关: $PRIMARY_GATEWAY (优先级: $PRIMARY_METRIC)"
    echo "  辅助IP: $SECONDARY_IP/$SECONDARY_NETMASK 网关: $SECONDARY_GATEWAY (优先级: $SECONDARY_METRIC)"
    echo ""
}

# 检查是否为root用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本需要root权限运行"
        echo "请使用: sudo $0"
        exit 1
    fi
}

# 备份网络配置
backup_config() {
    backup_dir="/etc/network/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    if [ -f /etc/network/interfaces ]; then
        cp /etc/network/interfaces "$backup_dir/"
        log_info "已备份网络配置到: $backup_dir"
    fi
    
    if [ -d /etc/netplan ]; then
        cp -r /etc/netplan "$backup_dir/"
        log_info "已备份netplan配置到: $backup_dir"
    fi
}

# 检测网络接口
detect_interface() {
    interface=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [ -z "$interface" ]; then
        interface=$(ip link show | grep -E "^[0-9]+:" | grep -v lo | head -1 | awk -F': ' '{print $2}')
    fi
    
    if [ -z "$interface" ]; then
        log_error "无法检测到网络接口"
        exit 1
    fi
    
    echo "$interface"
}

# 检查IP是否已配置
check_ip_configured() {
    ip="$1"
    ip addr show | grep -q "$ip" && return 0 || return 1
}

# 检查interfaces文件中是否已有IP配置
check_ip_in_interfaces() {
    ip="$1"
    if [ -f /etc/network/interfaces ]; then
        grep -q "$ip" /etc/network/interfaces && return 0 || return 1
    fi
    return 1
}

# 计算网络地址
get_network_address() {
    ip="$1"
    netmask="$2"
    
    # 简单的网络地址计算（适用于常见子网掩码）
    case "$netmask" in
        "255.255.255.0")
            echo "$ip" | sed 's/\.[0-9]*$/\.0/'
            ;;
        "255.255.0.0")
            echo "$ip" | sed 's/\.[0-9]*\.[0-9]*$/\.0\.0/'
            ;;
        *)
            echo "$ip" | sed 's/\.[0-9]*$/\.0/'
            ;;
    esac
}

# 添加IP配置
add_ip_config() {
    interface="$1"
    config_file="/etc/network/interfaces"
    
    log_info "添加双IP配置..."
    
    # 检查是否已有主IP配置
    has_primary_ip=false
    if check_ip_configured "$PRIMARY_IP" || check_ip_in_interfaces "$PRIMARY_IP"; then
        has_primary_ip=true
        log_info "检测到主IP $PRIMARY_IP 已配置"
    fi
    
    # 检查是否已有辅助IP配置
    if check_ip_configured "$SECONDARY_IP" || check_ip_in_interfaces "$SECONDARY_IP"; then
        log_info "辅助IP $SECONDARY_IP 已配置，跳过配置"
        return 0
    fi
    
    # 创建新配置
    temp_file="/tmp/interfaces_new"
    
    cat > "$temp_file" << 'EOF'
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

EOF

    # 处理主网络接口
    echo "# Primary network interface" >> "$temp_file"
    echo "auto $interface" >> "$temp_file"
    
    if [ "$has_primary_ip" = "false" ]; then
        # 添加主IP配置
        cat >> "$temp_file" << EOF
iface $interface inet static
    address $PRIMARY_IP
    netmask $PRIMARY_NETMASK
    gateway $PRIMARY_GATEWAY
    dns-nameservers $DNS_SERVERS
    metric $PRIMARY_METRIC

EOF
    else
        # 保持现有配置
        if [ -f "$config_file" ]; then
            awk "/^iface $interface inet/ {p=1} p && /^$/ {p=0} p" "$config_file" >> "$temp_file"
            echo "" >> "$temp_file"
        else
            echo "iface $interface inet dhcp" >> "$temp_file"
            echo "" >> "$temp_file"
        fi
    fi

    # 添加辅助IP配置
    secondary_network=$(get_network_address "$SECONDARY_IP" "$SECONDARY_NETMASK")
    cat >> "$temp_file" << EOF
# Secondary IP configuration - $SECONDARY_IP
auto ${interface}:1
iface ${interface}:1 inet static
    address $SECONDARY_IP
    netmask $SECONDARY_NETMASK
    post-up ip route add ${secondary_network}/24 dev ${interface}:1 metric $SECONDARY_METRIC 2>/dev/null || true
    post-up ip route add default via $SECONDARY_GATEWAY dev ${interface}:1 metric $SECONDARY_METRIC 2>/dev/null || true
    pre-down ip route del ${secondary_network}/24 dev ${interface}:1 2>/dev/null || true
    pre-down ip route del default via $SECONDARY_GATEWAY dev ${interface}:1 2>/dev/null || true
EOF

    # 替换原配置文件
    mv "$temp_file" "$config_file"
    log_info "已更新 $config_file"
}

# 删除辅助IP配置
remove_secondary_ip() {
    interface="$1"
    config_file="/etc/network/interfaces"
    
    log_info "删除辅助IP配置..."
    
    # 检查是否配置了辅助IP
    if ! check_ip_configured "$SECONDARY_IP" && ! check_ip_in_interfaces "$SECONDARY_IP"; then
        log_warn "辅助IP $SECONDARY_IP 未配置，无需删除"
        return 0
    fi
    
    # 立即删除IP地址
    if check_ip_configured "$SECONDARY_IP"; then
        log_info "删除接口上的辅助IP: $SECONDARY_IP"
        ip addr del "$SECONDARY_IP/24" dev "$interface" 2>/dev/null || true
        ip addr del "$SECONDARY_IP/24" dev "${interface}:1" 2>/dev/null || true
        
        # 删除相关路由
        secondary_network=$(get_network_address "$SECONDARY_IP" "$SECONDARY_NETMASK")
        ip route del "${secondary_network}/24" dev "${interface}:1" 2>/dev/null || true
        ip route del default via "$SECONDARY_GATEWAY" dev "${interface}:1" 2>/dev/null || true
    fi
    
    # 从配置文件中删除辅助IP配置
    if [ -f "$config_file" ]; then
        temp_file="/tmp/interfaces_clean"
        
        # 删除辅助IP相关的配置行
        awk '
        /^# Secondary IP configuration/ { skip=1; next }
        /^auto.*:1$/ && skip { next }
        /^iface.*:1 inet static/ && skip { 
            while (getline && $0 !~ /^$/ && $0 !~ /^[a-zA-Z]/) { }
            skip=0
            if ($0 ~ /^[a-zA-Z]/) print $0
            next
        }
        { if (!skip) print }
        ' "$config_file" > "$temp_file"
        
        mv "$temp_file" "$config_file"
        log_info "已从配置文件中删除辅助IP配置"
    fi
}

# 手动添加IP（确保立即生效）
add_ip_manually() {
    interface="$1"
    
    # 检查并添加辅助IP
    if ! check_ip_configured "$SECONDARY_IP"; then
        log_info "手动添加辅助IP $SECONDARY_IP 到接口 $interface"
        ip addr add "$SECONDARY_IP/24" dev "$interface" 2>/dev/null || true
        
        # 添加路由
        secondary_network=$(get_network_address "$SECONDARY_IP" "$SECONDARY_NETMASK")
        ip route add "${secondary_network}/24" dev "$interface" metric "$SECONDARY_METRIC" 2>/dev/null || true
        ip route add default via "$SECONDARY_GATEWAY" dev "$interface" metric "$SECONDARY_METRIC" 2>/dev/null || true
    fi
}

# 应用网络配置
apply_network_config() {
    log_info "应用网络配置..."
    
    if command -v netplan >/dev/null 2>&1 && [ -d /etc/netplan ]; then
        netplan apply
        log_info "netplan配置已应用"
    else
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart networking
        else
            service networking restart
        fi
        log_info "网络服务已重启"
    fi
    
    sleep 3
}

# 显示当前状态
show_status() {
    log_info "当前网络配置状态："
    
    echo ""
    echo "IP地址配置:"
    ip addr show | grep -E "inet.*global" | sed 's/^/  /'
    
    echo ""
    echo "路由表:"
    ip route | sed 's/^/  /'
    
    echo ""
    echo "配置检查:"
    
    if check_ip_configured "$PRIMARY_IP"; then
        echo "  ✓ 主IP: $PRIMARY_IP 已配置"
    else
        echo "  ✗ 主IP: $PRIMARY_IP 未配置"
    fi
    
    if check_ip_configured "$SECONDARY_IP"; then
        echo "  ✓ 辅助IP: $SECONDARY_IP 已配置"
    else
        echo "  ✗ 辅助IP: $SECONDARY_IP 未配置"
    fi
    
    echo ""
    echo "配置文件状态:"
    if [ -f /etc/network/interfaces ]; then
        if check_ip_in_interfaces "$SECONDARY_IP"; then
            echo "  ✓ 辅助IP已写入配置文件（重启后生效）"
        else
            echo "  ✗ 辅助IP未在配置文件中"
        fi
    fi
}

# 主函数
main() {
    action="${1:-add}"
    
    case "$action" in
        "add")
            log_info "开始添加双IP配置..."
            check_root
            backup_config
            
            interface=$(detect_interface)
            log_info "检测到网络接口: $interface"
            
            add_ip_config "$interface"
            add_ip_manually "$interface"
            apply_network_config
            
            echo ""
            echo "${GREEN}双IP配置完成！${NC}"
            echo "  主IP: $PRIMARY_IP (优先级: $PRIMARY_METRIC)"
            echo "  辅助IP: $SECONDARY_IP (优先级: $SECONDARY_METRIC)"
            echo "  主网关: $PRIMARY_GATEWAY"
            echo "  辅助网关: $SECONDARY_GATEWAY"
            echo ""
            echo "${GREEN}重启后配置依然生效！${NC}"
            ;;
            
        "remove")
            log_info "开始删除辅助IP配置..."
            check_root
            backup_config
            
            interface=$(detect_interface)
            log_info "检测到网络接口: $interface"
            
            remove_secondary_ip "$interface"
            apply_network_config
            
            echo ""
            echo "${GREEN}辅助IP删除完成！${NC}"
            echo "  已删除: $SECONDARY_IP"
            ;;
            
        "status")
            show_status
            ;;
            
        "help"|"-h"|"--help")
            show_help
            ;;
            
        *)
            log_error "未知操作: $action"
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
