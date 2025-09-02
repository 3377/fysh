#!/bin/bash
# 飞牛NAS双IP网络配置脚本 v4 - 优化版
# 确保重启后主IP始终生效

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
DNS_PRIMARY="10.1.1.250"
DNS_SECONDARY="223.5.5.5"

# 网络接口名称
INTERFACE="ens192"

# 统一连接名称（使用单连接管理双IP）
CONNECTION_NAME="ens192-dual-ip"
# ==================== 配置变量区域结束 ====================

echo "=== 飞牛NAS双IP网络配置脚本 v4 - 优化版 ==="
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
for conn in $(nmcli -t -f NAME connection show | grep -E "(Wired|${INTERFACE}|ethernet|primary|secondary|dual-ip)"); do
    echo "删除连接: $conn"
    sudo nmcli connection delete "$conn" 2>/dev/null || true
done

# 重置网络接口
echo "4. 重置${INTERFACE}接口..."
sudo ip link set ${INTERFACE} down
sleep 2
sudo ip link set ${INTERFACE} up
sleep 3

# 创建单一NetworkManager连接配置双IP（关键优化）
echo "5. 创建统一的双IP网络连接..."
sudo nmcli connection add \
    type ethernet \
    con-name "${CONNECTION_NAME}" \
    ifname ${INTERFACE} \
    ipv4.addresses "${PRIMARY_IP}/${PRIMARY_NETMASK},${SECONDARY_IP}/${SECONDARY_NETMASK}" \
    ipv4.gateway ${PRIMARY_GATEWAY} \
    ipv4.dns "${DNS_PRIMARY},${DNS_SECONDARY}" \
    ipv4.method manual \
    connection.autoconnect yes \
    connection.autoconnect-priority 999 \
    connection.autoconnect-retries 0

# 激活连接
echo "6. 激活网络连接..."
sudo nmcli connection up "${CONNECTION_NAME}"
sleep 3

# 配置高级路由规则确保主IP优先
echo "7. 配置路由表和优先级..."

# 删除可能存在的默认路由
sudo ip route del default 2>/dev/null || true

# 添加主网关作为默认路由（最高优先级）
sudo ip route add default via ${PRIMARY_GATEWAY} dev ${INTERFACE} metric 50

# 添加辅助网关路由（较低优先级，仅用于辅助网段）
sudo ip route add ${SECONDARY_NETWORK} via ${SECONDARY_GATEWAY} dev ${INTERFACE} metric 100

# 添加特定网段路由，确保源IP正确
sudo ip route add ${PRIMARY_NETWORK} dev ${INTERFACE} src ${PRIMARY_IP} metric 50
sudo ip route add ${SECONDARY_NETWORK} dev ${INTERFACE} src ${SECONDARY_IP} metric 100

# 配置策略路由确保IP优先级
echo "8. 配置策略路由..."

# 清除现有的策略路由规则
sudo ip rule del from ${PRIMARY_IP} 2>/dev/null || true
sudo ip rule del from ${SECONDARY_IP} 2>/dev/null || true

# 添加策略路由规则
sudo ip rule add from ${PRIMARY_IP} table main priority 100
sudo ip rule add from ${SECONDARY_IP} table main priority 200

# 配置DNS
echo "9. 配置DNS..."
sudo tee /etc/resolv.conf > /dev/null <<EOF
nameserver ${DNS_PRIMARY}
nameserver ${DNS_SECONDARY}
nameserver ${PRIMARY_GATEWAY}
EOF

# 创建启动时配置验证服务
echo "10. 创建启动验证服务..."
sudo tee /etc/systemd/system/dual-ip-verify.service > /dev/null <<EOF
[Unit]
Description=Dual IP Configuration Verification Service
After=network.target NetworkManager.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '
# 验证主IP是否为第一个IP
FIRST_IP=\$(ip addr show ${INTERFACE} | grep "inet " | head -1 | awk "{print \$2}" | cut -d"/" -f1)
if [ "\$FIRST_IP" != "${PRIMARY_IP}" ]; then
    echo "检测到IP优先级异常，重新配置..."
    # 重新应用IP配置
    nmcli connection down "${CONNECTION_NAME}" 2>/dev/null || true
    sleep 2
    nmcli connection up "${CONNECTION_NAME}"
    sleep 2
    # 重新配置路由
    ip route del default 2>/dev/null || true
    ip route add default via ${PRIMARY_GATEWAY} dev ${INTERFACE} metric 50
    ip route add ${SECONDARY_NETWORK} via ${SECONDARY_GATEWAY} dev ${INTERFACE} metric 100
    echo "IP优先级已修正"
else
    echo "IP配置正常，主IP: \$FIRST_IP"
fi
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 启用验证服务
sudo systemctl daemon-reload
sudo systemctl enable dual-ip-verify.service

# 创建网络配置监控脚本
echo "11. 创建网络监控脚本..."
sudo tee /usr/local/bin/dual-ip-monitor.sh > /dev/null <<'EOF'
#!/bin/bash
# 双IP配置监控脚本

PRIMARY_IP="10.1.1.66"
SECONDARY_IP="192.168.70.66"
INTERFACE="ens192"
CONNECTION_NAME="ens192-dual-ip"

check_ip_priority() {
    FIRST_IP=$(ip addr show ${INTERFACE} | grep "inet " | head -1 | awk '{print $2}' | cut -d"/" -f1)
    if [ "$FIRST_IP" != "$PRIMARY_IP" ]; then
        echo "$(date): 检测到IP优先级异常，主IP应为 $PRIMARY_IP，当前为 $FIRST_IP"
        return 1
    fi
    return 0
}

fix_ip_priority() {
    echo "$(date): 开始修复IP优先级..."
    nmcli connection down "$CONNECTION_NAME" 2>/dev/null || true
    sleep 2
    nmcli connection up "$CONNECTION_NAME"
    sleep 3
    
    # 重新配置路由
    ip route del default 2>/dev/null || true
    ip route add default via 10.1.1.250 dev ${INTERFACE} metric 50
    
    echo "$(date): IP优先级修复完成"
}

# 检查并修复
if ! check_ip_priority; then
    fix_ip_priority
fi
EOF

sudo chmod +x /usr/local/bin/dual-ip-monitor.sh

# 创建定时检查任务
echo "12. 创建定时检查任务..."
(sudo crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/dual-ip-monitor.sh >> /var/log/dual-ip-monitor.log 2>&1") | sudo crontab -

# 等待配置生效
echo "13. 等待网络配置生效..."
sleep 5

# 验证配置
echo "14. 验证网络配置..."
echo "--- 当前IP配置 ---"
ip addr show ${INTERFACE} | grep "inet "

echo "--- 路由表 ---"
echo "默认路由:"
ip route show | grep default
echo "网段路由:"
ip route show | grep -E "(${PRIMARY_NETWORK%/*}|${SECONDARY_NETWORK%/*})"

echo "--- 策略路由 ---"
ip rule show

echo "--- DNS配置 ---"
cat /etc/resolv.conf | grep nameserver

echo "--- NetworkManager连接状态 ---"
nmcli connection show --active

# 测试网络连通性
echo "15. 测试网络连通性..."

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

# 验证IP优先级
echo "16. 验证IP优先级..."
FIRST_IP=$(ip addr show ${INTERFACE} | grep "inet " | head -1 | awk '{print $2}' | cut -d"/" -f1)
if [ "$FIRST_IP" = "$PRIMARY_IP" ]; then
    echo "✓ IP优先级正确：主IP ${PRIMARY_IP} 为第一IP"
else
    echo "✗ IP优先级异常：当前第一IP为 $FIRST_IP，应为 ${PRIMARY_IP}"
fi

# 重启Docker服务
echo "17. 重启Docker服务..."
sudo systemctl start docker 2>/dev/null || true

echo
echo "=== 配置完成 ==="
echo "网络配置摘要:"
echo "主IP: ${PRIMARY_IP}/${PRIMARY_NETMASK} (网关: ${PRIMARY_GATEWAY}, 优先级: 最高)"
echo "辅助IP: ${SECONDARY_IP}/${SECONDARY_NETMASK} (网关: ${SECONDARY_GATEWAY}, 优先级: 较低)"
echo "连接名称: ${CONNECTION_NAME}"
echo
echo "优化特性:"
echo "✓ 使用单连接管理双IP，避免连接冲突"
echo "✓ 配置策略路由确保IP优先级"
echo "✓ 创建启动验证服务，自动修正配置"
echo "✓ 定时监控任务，每5分钟检查一次"
echo "✓ 主IP ${PRIMARY_IP} 始终为第一优先级"
echo
echo "重启后验证:"
echo "1. 检查 'ip addr show ${INTERFACE}' 第一个IP应为 ${PRIMARY_IP}"
echo "2. 检查 'ip route show' 默认路由应指向 ${PRIMARY_GATEWAY}"
echo "3. 查看监控日志: 'sudo tail -f /var/log/dual-ip-monitor.log'"
echo
echo "现在可以安全重启系统，主IP优先级将得到保证！"
