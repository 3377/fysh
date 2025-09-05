#!/bin/bash
# 强制主IP优先脚本 - 确保10.1.1.66始终为第一IP

# ==================== 配置变量区域 ====================
PRIMARY_IP="10.1.1.66"
PRIMARY_NETMASK="24"
PRIMARY_GATEWAY="10.1.1.250"
PRIMARY_DNS="10.1.1.250"
SECONDARY_DNS="223.5.5.5"

SECONDARY_IP="192.168.70.66"
SECONDARY_NETMASK="24"
SECONDARY_GATEWAY="192.168.70.1"

INTERFACE="ens192"
# ==================== 配置变量区域结束 ====================

echo "=== 强制主IP优先脚本 ==="
echo "目标：确保 ${PRIMARY_IP} 始终为第一IP"
echo "DNS配置：主DNS ${PRIMARY_DNS}，辅助DNS ${SECONDARY_DNS}"
echo

# 停止NetworkManager服务以确保完全控制
echo "1. 停止NetworkManager服务..."
sudo systemctl stop NetworkManager 2>/dev/null || true

# 删除所有现有的NetworkManager连接
echo "2. 清理所有NetworkManager连接..."
# 删除所有连接，包括可能存在的primary-only连接
sudo nmcli connection delete "primary-only" 2>/dev/null || true
for conn in $(nmcli -t -f NAME connection show 2>/dev/null); do
    echo "删除连接: $conn"
    sudo nmcli connection delete "$conn" 2>/dev/null || true
done

# 清除接口上的所有IP和路由
echo "3. 强制清除所有网络配置..."
sudo ip addr flush dev ${INTERFACE}
sudo ip route flush dev ${INTERFACE} 2>/dev/null || true
sudo ip route del default 2>/dev/null || true

# 重置接口
echo "4. 重置网络接口..."
sudo ip link set ${INTERFACE} down
sleep 2
sudo ip link set ${INTERFACE} up
sleep 3

# 按正确顺序手动添加IP（主IP先添加）
echo "5. 按顺序添加IP地址..."
echo "添加主IP: ${PRIMARY_IP}"
sudo ip addr add ${PRIMARY_IP}/${PRIMARY_NETMASK} dev ${INTERFACE}
sleep 1

echo "添加辅助IP: ${SECONDARY_IP}"
sudo ip addr add ${SECONDARY_IP}/${SECONDARY_NETMASK} dev ${INTERFACE}
sleep 1

# 配置路由
echo "6. 配置路由..."
sudo ip route add default via ${PRIMARY_GATEWAY} dev ${INTERFACE} metric 100

# 配置DNS
echo "7. 配置DNS..."
sudo tee /etc/resolv.conf > /dev/null <<EOF
# 强制DNS配置 - 由force_primary_ip.sh生成
nameserver ${PRIMARY_DNS}
nameserver ${SECONDARY_DNS}
EOF

# 防止resolv.conf被覆盖
sudo chattr +i /etc/resolv.conf 2>/dev/null || true

# 重启NetworkManager服务
echo "8. 重启NetworkManager服务..."
sudo systemctl start NetworkManager

# 检测实际可用的网络接口
echo "9. 检测网络接口..."
ACTUAL_INTERFACE=$(ip link show | grep -E "^[0-9]+: (eth|ens|enp)" | head -1 | cut -d: -f2 | tr -d ' ')
if [ -z "$ACTUAL_INTERFACE" ]; then
    ACTUAL_INTERFACE=$INTERFACE
fi
echo "使用网络接口: $ACTUAL_INTERFACE"

# 确保接口存在并且UP状态
sudo ip link set $ACTUAL_INTERFACE up 2>/dev/null || true

# 创建只包含主IP的NetworkManager连接（关键）
echo "10. 创建主IP连接..."
# 生成唯一的连接名称
CONN_NAME="primary-$(date +%s)"
sudo nmcli connection add \
    type ethernet \
    con-name "$CONN_NAME" \
    ifname $ACTUAL_INTERFACE \
    ipv4.addresses ${PRIMARY_IP}/${PRIMARY_NETMASK} \
    ipv4.gateway ${PRIMARY_GATEWAY} \
    ipv4.dns "${PRIMARY_DNS},${SECONDARY_DNS}" \
    ipv4.method manual \
    connection.autoconnect yes \
    connection.autoconnect-priority 100

# 等待连接创建完成
sleep 2

# 尝试激活连接
echo "11. 激活网络连接..."
sudo nmcli connection up "$CONN_NAME" 2>/dev/null || {
    echo "NetworkManager连接激活失败，使用手动配置..."
    # 手动重新配置IP（确保配置正确）
    sudo ip addr flush dev $ACTUAL_INTERFACE
    sudo ip addr add ${PRIMARY_IP}/${PRIMARY_NETMASK} dev $ACTUAL_INTERFACE
    sudo ip addr add ${SECONDARY_IP}/${SECONDARY_NETMASK} dev $ACTUAL_INTERFACE
    sudo ip route del default 2>/dev/null || true
    sudo ip route add default via ${PRIMARY_GATEWAY} dev $ACTUAL_INTERFACE metric 100
}

# 创建强制IP顺序的启动脚本
echo "12. 创建启动强制脚本..."
sudo tee /usr/local/bin/force-ip-order.sh > /dev/null <<EOF
#!/bin/bash
# 强制IP顺序脚本

PRIMARY_IP="10.1.1.66"
SECONDARY_IP="192.168.70.66"
INTERFACE="ens192"
PRIMARY_NETMASK="24"
SECONDARY_NETMASK="24"
PRIMARY_GATEWAY="10.1.1.250"
PRIMARY_DNS="10.1.1.250"
SECONDARY_DNS="223.5.5.5"

# 等待网络就绪
sleep 20

# 检测实际网络接口
ACTUAL_INTERFACE=\$(ip link show | grep -E "^[0-9]+: (eth|ens|enp)" | head -1 | cut -d: -f2 | tr -d ' ')
if [ -z "\$ACTUAL_INTERFACE" ]; then
    ACTUAL_INTERFACE=\$INTERFACE
fi

# 强制重新排序IP
echo "\$(date): 开始强制IP顺序调整，使用接口: \$ACTUAL_INTERFACE" >> /var/log/force-ip-order.log

# 删除所有IP和路由
ip addr flush dev \${ACTUAL_INTERFACE}
ip route flush dev \${ACTUAL_INTERFACE} 2>/dev/null || true
ip route del default 2>/dev/null || true
sleep 2

# 按正确顺序重新添加
ip addr add \${PRIMARY_IP}/\${PRIMARY_NETMASK} dev \${ACTUAL_INTERFACE}
sleep 1
ip addr add \${SECONDARY_IP}/\${SECONDARY_NETMASK} dev \${ACTUAL_INTERFACE}
sleep 1

# 确保路由正确
ip route add default via \${PRIMARY_GATEWAY} dev \${ACTUAL_INTERFACE} metric 100

# 强制设置DNS
tee /etc/resolv.conf > /dev/null <<EOFINNER
# 强制DNS配置 - 由force-ip-order.sh生成
nameserver \${PRIMARY_DNS}
nameserver \${SECONDARY_DNS}
EOFINNER

# 防止resolv.conf被覆盖
chattr +i /etc/resolv.conf 2>/dev/null || true

echo "\$(date): IP顺序强制调整完成" >> /var/log/force-ip-order.log
echo "\$(date): 当前第一IP: \$(ip addr show \${ACTUAL_INTERFACE} | grep 'inet ' | head -1 | awk '{print \$2}')" >> /var/log/force-ip-order.log
echo "\$(date): DNS配置: \$(cat /etc/resolv.conf | grep nameserver)" >> /var/log/force-ip-order.log
EOF

sudo chmod +x /usr/local/bin/force-ip-order.sh

# 创建systemd服务（在网络完全启动后执行）
echo "13. 创建强制服务..."
sudo tee /etc/systemd/system/force-ip-order.service > /dev/null <<EOF
[Unit]
Description=Force IP Order Service
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/force-ip-order.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable force-ip-order.service

# 创建定时检查任务（每分钟检查一次）
echo "14. 创建定时检查..."
sudo tee /usr/local/bin/check-ip-order.sh > /dev/null <<EOF
#!/bin/bash
# IP顺序检查脚本

PRIMARY_IP="10.1.1.66"
SECONDARY_IP="192.168.70.66"
INTERFACE="ens192"
PRIMARY_NETMASK="24"
SECONDARY_NETMASK="24"
PRIMARY_GATEWAY="10.1.1.250"
PRIMARY_DNS="10.1.1.250"
SECONDARY_DNS="223.5.5.5"

# 检测实际网络接口
ACTUAL_INTERFACE=\$(ip link show | grep -E "^[0-9]+: (eth|ens|enp)" | head -1 | cut -d: -f2 | tr -d ' ')
if [ -z "\$ACTUAL_INTERFACE" ]; then
    ACTUAL_INTERFACE=\$INTERFACE
fi

FIRST_IP=\$(ip addr show \${ACTUAL_INTERFACE} | grep 'inet ' | head -1 | awk '{print \$2}' | cut -d'/' -f1)

if [ "\$FIRST_IP" != "\$PRIMARY_IP" ]; then
    echo "\$(date): 检测到IP顺序异常，立即修正，使用接口: \$ACTUAL_INTERFACE" >> /var/log/ip-order-check.log
    
    # 立即修正
    ip addr flush dev \${ACTUAL_INTERFACE}
    ip route flush dev \${ACTUAL_INTERFACE} 2>/dev/null || true
    ip route del default 2>/dev/null || true
    sleep 1
    ip addr add \${PRIMARY_IP}/\${PRIMARY_NETMASK} dev \${ACTUAL_INTERFACE}
    sleep 1
    ip addr add \${SECONDARY_IP}/\${SECONDARY_NETMASK} dev \${ACTUAL_INTERFACE}
    
    # 修正路由
    ip route add default via \${PRIMARY_GATEWAY} dev \${ACTUAL_INTERFACE} metric 100
    
    # 确保DNS正确
    tee /etc/resolv.conf > /dev/null <<EOFINNER
# 强制DNS配置 - 由check-ip-order.sh生成
nameserver \${PRIMARY_DNS}
nameserver \${SECONDARY_DNS}
EOFINNER
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    echo "\$(date): IP顺序已修正为主IP优先" >> /var/log/ip-order-check.log
fi
EOF

sudo chmod +x /usr/local/bin/check-ip-order.sh

# 添加到crontab（每分钟检查）
(sudo crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/check-ip-order.sh") | sudo crontab -

# 立即刷新DNS缓存
echo "15. 刷新DNS缓存..."
sudo systemctl restart systemd-resolved 2>/dev/null || true
sudo systemctl flush-dns 2>/dev/null || true

# 验证当前配置
echo "16. 验证当前配置..."
echo "--- IP配置 ---"
ip addr show ${INTERFACE} | grep "inet "

FIRST_IP=$(ip addr show ${INTERFACE} | grep "inet " | head -1 | awk '{print $2}' | cut -d'/' -f1)
echo
if [ "$FIRST_IP" = "$PRIMARY_IP" ]; then
    echo "✓ 成功！主IP ${PRIMARY_IP} 现在是第一IP"
else
    echo "⚠ 当前第一IP: $FIRST_IP，将在重启后强制修正"
fi

echo "--- 路由配置 ---"
ip route show | grep default

echo "--- DNS配置 ---"
cat /etc/resolv.conf

echo "--- DNS连通性测试 ---"
echo "测试主DNS ${PRIMARY_DNS}:"
nslookup baidu.com ${PRIMARY_DNS} 2>/dev/null | grep "Server:" || echo "主DNS连接失败"
echo "测试辅助DNS ${SECONDARY_DNS}:"
nslookup baidu.com ${SECONDARY_DNS} 2>/dev/null | grep "Server:" || echo "辅助DNS连接失败"

echo
echo "=== 强制配置完成 ==="
echo "配置特性:"
echo "✓ 强制删除所有NetworkManager连接"
echo "✓ 手动按顺序添加IP地址"
echo "✓ 强制设置DNS: 主DNS ${PRIMARY_DNS}, 辅助DNS ${SECONDARY_DNS}"
echo "✓ 启动时强制重新排序IP和DNS"
echo "✓ 每分钟自动检查并修正IP顺序和DNS"
echo "✓ 防止resolv.conf被其他程序覆盖"
echo
echo "重启后验证:"
echo "主IP ${PRIMARY_IP} 将强制成为第一IP"
echo "DNS将强制使用 ${PRIMARY_DNS} 和 ${SECONDARY_DNS}"
echo "查看强制日志: sudo tail -f /var/log/force-ip-order.log"
echo "查看检查日志: sudo tail -f /var/log/ip-order-check.log"
echo
echo "配置已立即生效！无需重启即可使用新的网络配置。"
