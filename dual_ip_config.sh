#!/bin/bash
# 飞牛NAS双IP网络配置脚本 v3
# 支持主IP和辅助IP配置，变量化配置便于修改

# ==================== 配置变量区域 ====================
# 主网络配置（优先级高）
PRIMARY_IP="10.1.1.66"
PRIMARY_NETMASK="24"
PRIMARY_GATEWAY="10.1.1.250"
PRIMARY_NETWORK="10.1.1.0/24"

# 辅助网络配置（用于访问其他终端）
SECONDARY_IP="192.168.70.66"
SECONDARY_NETMASK="24"
SECONDARY_GATEWAY="192.168.70.1"
SECONDARY_NETWORK="192.168.70.0/24"

# DNS配置
DNS_PRIMARY="8.8.8.8"
DNS_SECONDARY="8.8.4.4"

# 网络接口名称
INTERFACE="ens192"

# NetworkManager连接名称
PRIMARY_CONNECTION="ens192-primary"
SECONDARY_CONNECTION="ens192-secondary"
# ==================== 配置变量区域结束 ====================

echo "=== 飞牛NAS双IP网络配置脚本 v3 ==="
echo "主IP配置: ${PRIMARY_IP}/${PRIMARY_NETMASK}, 网关: ${PRIMARY_GATEWAY}"
echo "辅助IP配置: ${SECONDARY_IP}/${SECONDARY_NETMASK}, 网关: ${SECONDARY_GATEWAY}"
echo "网络接口: ${INTERFACE}"
echo

# 停止可能干扰的服务
echo "1. 停止可能干扰的网络服务..."
sudo systemctl stop docker 2>/dev/null || true
sleep 2

# 清除接口上的所有IP配置
echo "2. 清除${INTERFACE}接口上的现有IP配置..."
sudo ip addr flush dev ${INTERFACE}
sudo ip route flush dev ${INTERFACE} 2>/dev/null || true

# 删除所有相关的NetworkManager连接
echo "3. 删除现有的网络连接配置..."
for conn in $(nmcli -t -f NAME connection show | grep -E "(Wired|${INTERFACE}|ethernet|primary|secondary)"); do
    echo "删除连接: $conn"
    sudo nmcli connection delete "$conn" 2>/dev/null || true
done

# 重置网络接口
echo "4. 重置${INTERFACE}接口..."
sudo ip link set ${INTERFACE} down
sleep 2
sudo ip link set ${INTERFACE} up
sleep 2

# 配置主IP（优先级高）
echo "5. 配置主IP: ${PRIMARY_IP}/${PRIMARY_NETMASK}..."
sudo ip addr add ${PRIMARY_IP}/${PRIMARY_NETMASK} dev ${INTERFACE}

# 配置辅助IP
echo "6. 配置辅助IP: ${SECONDARY_IP}/${SECONDARY_NETMASK}..."
sudo ip addr add ${SECONDARY_IP}/${SECONDARY_NETMASK} dev ${INTERFACE}

# 配置路由表（主网关优先级更高）
echo "7. 配置路由表..."
# 删除可能存在的默认路由
sudo ip route del default 2>/dev/null || true

# 添加主网关作为默认路由（metric值越小优先级越高）
sudo ip route add default via ${PRIMARY_GATEWAY} dev ${INTERFACE} metric 100

# 添加辅助网关路由（更高的metric值，作为备用）
sudo ip route add default via ${SECONDARY_GATEWAY} dev ${INTERFACE} metric 200

# 添加特定网段路由
sudo ip route add ${PRIMARY_NETWORK} dev ${INTERFACE} src ${PRIMARY_IP} metric 100
sudo ip route add ${SECONDARY_NETWORK} dev ${INTERFACE} src ${SECONDARY_IP} metric 200

# 配置DNS
echo "8. 配置DNS..."
sudo tee /etc/resolv.conf > /dev/null <<EOF
nameserver ${DNS_PRIMARY}
nameserver ${DNS_SECONDARY}
nameserver ${PRIMARY_GATEWAY}
nameserver ${SECONDARY_GATEWAY}
EOF

# 创建主IP的NetworkManager连接配置
echo "9. 创建主IP持久化配置..."
sudo nmcli connection add \
    type ethernet \
    con-name "${PRIMARY_CONNECTION}" \
    ifname ${INTERFACE} \
    ipv4.addresses ${PRIMARY_IP}/${PRIMARY_NETMASK} \
    ipv4.gateway ${PRIMARY_GATEWAY} \
    ipv4.dns "${DNS_PRIMARY},${DNS_SECONDARY}" \
    ipv4.method manual \
    connection.autoconnect yes \
    connection.autoconnect-priority 100

# 为辅助IP创建别名接口配置
echo "10. 创建辅助IP配置..."
sudo nmcli connection add \
    type ethernet \
    con-name "${SECONDARY_CONNECTION}" \
    ifname ${INTERFACE} \
    ipv4.addresses ${SECONDARY_IP}/${SECONDARY_NETMASK} \
    ipv4.method manual \
    connection.autoconnect yes \
    connection.autoconnect-priority 50

# 等待配置生效
echo "11. 等待网络配置生效..."
sleep 5

# 验证配置
echo "12. 验证网络配置..."
echo "--- 当前IP配置 ---"
ip addr show ${INTERFACE} | grep "inet "

echo "--- 路由表 ---"
echo "默认路由:"
ip route show | grep default
echo "网段路由:"
ip route show | grep -E "(${PRIMARY_NETWORK%/*}|${SECONDARY_NETWORK%/*})"

echo "--- DNS配置 ---"
cat /etc/resolv.conf | grep nameserver

# 测试网络连通性
echo "13. 测试网络连通性..."

echo "测试主IP本地连通性:"
if ping -c 2 -W 3 ${PRIMARY_IP} >/dev/null 2>&1; then
    echo "✓ 主IP ${PRIMARY_IP} 本地连通正常"
else
    echo "✗ 主IP ${PRIMARY_IP} 本地连通异常"
fi

echo "测试辅助IP本地连通性:"
if ping -c 2 -W 3 ${SECONDARY_IP} >/dev/null 2>&1; then
    echo "✓ 辅助IP ${SECONDARY_IP} 本地连通正常"
else
    echo "✗ 辅助IP ${SECONDARY_IP} 本地连通异常"
fi

echo "测试主网关连通性:"
if ping -c 3 -W 5 ${PRIMARY_GATEWAY} >/dev/null 2>&1; then
    echo "✓ 主网关 ${PRIMARY_GATEWAY} 连通正常"
else
    echo "✗ 主网关 ${PRIMARY_GATEWAY} 连通失败"
fi

echo "测试辅助网关连通性:"
if ping -c 3 -W 5 ${SECONDARY_GATEWAY} >/dev/null 2>&1; then
    echo "✓ 辅助网关 ${SECONDARY_GATEWAY} 连通正常"
else
    echo "✗ 辅助网关 ${SECONDARY_GATEWAY} 连通失败"
fi

echo "测试外网连通性（通过主网关）:"
if ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1; then
    echo "✓ 外网连通正常"
else
    echo "✗ 外网连通失败"
fi

# 重启Docker服务
echo "14. 重启Docker服务..."
sudo systemctl start docker 2>/dev/null || true

echo
echo "=== 配置完成 ==="
echo "网络配置摘要:"
echo "主IP: ${PRIMARY_IP}/${PRIMARY_NETMASK} (网关: ${PRIMARY_GATEWAY}, 优先级: 高)"
echo "辅助IP: ${SECONDARY_IP}/${SECONDARY_NETMASK} (网关: ${SECONDARY_GATEWAY}, 优先级: 低)"
echo "接口状态:"
nmcli device status | grep ${INTERFACE}
echo
echo "路由优先级说明:"
echo "- 默认情况下使用主网关 ${PRIMARY_GATEWAY} 进行外网访问"
echo "- 访问 ${SECONDARY_NETWORK%/*}.x 网段时会使用辅助IP ${SECONDARY_IP}"
echo "- 如需修改配置，请编辑脚本顶部的变量区域"
echo
echo "建议重启系统以确保所有配置持久化生效。"
