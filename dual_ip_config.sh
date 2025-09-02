#!/bin/bash
# 强制主IP优先脚本 - 确保10.1.1.66始终为第一IP

# ==================== 配置变量区域 ====================
PRIMARY_IP="10.1.1.66"
PRIMARY_NETMASK="24"
PRIMARY_GATEWAY="10.1.1.250"

SECONDARY_IP="192.168.70.66"
SECONDARY_NETMASK="24"
SECONDARY_GATEWAY="192.168.70.1"

INTERFACE="ens192"
# ==================== 配置变量区域结束 ====================

echo "=== 强制主IP优先脚本 ==="
echo "目标：确保 ${PRIMARY_IP} 始终为第一IP"
echo

# 删除所有现有的NetworkManager连接
echo "1. 清理所有NetworkManager连接..."
for conn in $(nmcli -t -f NAME connection show); do
    if [[ "$conn" =~ (Wired|ethernet|ens192|primary|secondary|persistent) ]]; then
        echo "删除连接: $conn"
        sudo nmcli connection delete "$conn" 2>/dev/null || true
    fi
done

# 清除接口上的所有IP
echo "2. 清除接口IP配置..."
sudo ip addr flush dev ${INTERFACE}

# 重置接口
echo "3. 重置网络接口..."
sudo ip link set ${INTERFACE} down
sleep 2
sudo ip link set ${INTERFACE} up
sleep 3

# 按正确顺序手动添加IP（主IP先添加）
echo "4. 按顺序添加IP地址..."
echo "添加主IP: ${PRIMARY_IP}"
sudo ip addr add ${PRIMARY_IP}/${PRIMARY_NETMASK} dev ${INTERFACE}
sleep 1

echo "添加辅助IP: ${SECONDARY_IP}"
sudo ip addr add ${SECONDARY_IP}/${SECONDARY_NETMASK} dev ${INTERFACE}
sleep 1

# 配置路由
echo "5. 配置路由..."
sudo ip route add default via ${PRIMARY_GATEWAY} dev ${INTERFACE} metric 100

# 创建只包含主IP的NetworkManager连接（关键）
echo "6. 创建主IP连接..."
sudo nmcli connection add \
    type ethernet \
    con-name "primary-only" \
    ifname ${INTERFACE} \
    ipv4.addresses ${PRIMARY_IP}/${PRIMARY_NETMASK} \
    ipv4.gateway ${PRIMARY_GATEWAY} \
    ipv4.dns "8.8.8.8,8.8.4.4" \
    ipv4.method manual \
    connection.autoconnect yes \
    connection.autoconnect-priority 100

# 创建强制IP顺序的启动脚本
echo "7. 创建启动强制脚本..."
sudo tee /usr/local/bin/force-ip-order.sh > /dev/null <<'EOF'
#!/bin/bash
# 强制IP顺序脚本

PRIMARY_IP="10.1.1.66"
SECONDARY_IP="192.168.70.66"
INTERFACE="ens192"
PRIMARY_NETMASK="24"
SECONDARY_NETMASK="24"
PRIMARY_GATEWAY="10.1.1.250"

# 等待网络就绪
sleep 20

# 强制重新排序IP
echo "$(date): 开始强制IP顺序调整" >> /var/log/force-ip-order.log

# 删除所有IP
ip addr flush dev ${INTERFACE}
sleep 2

# 按正确顺序重新添加
ip addr add ${PRIMARY_IP}/${PRIMARY_NETMASK} dev ${INTERFACE}
sleep 1
ip addr add ${SECONDARY_IP}/${SECONDARY_NETMASK} dev ${INTERFACE}
sleep 1

# 确保路由正确
ip route del default 2>/dev/null || true
ip route add default via ${PRIMARY_GATEWAY} dev ${INTERFACE} metric 100

echo "$(date): IP顺序强制调整完成" >> /var/log/force-ip-order.log
echo "$(date): 当前第一IP: $(ip addr show ${INTERFACE} | grep 'inet ' | head -1 | awk '{print $2}')" >> /var/log/force-ip-order.log
EOF

sudo chmod +x /usr/local/bin/force-ip-order.sh

# 创建systemd服务（在网络完全启动后执行）
echo "8. 创建强制服务..."
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
echo "9. 创建定时检查..."
sudo tee /usr/local/bin/check-ip-order.sh > /dev/null <<'EOF'
#!/bin/bash
# IP顺序检查脚本

PRIMARY_IP="10.1.1.66"
SECONDARY_IP="192.168.70.66"
INTERFACE="ens192"
PRIMARY_NETMASK="24"
SECONDARY_NETMASK="24"
PRIMARY_GATEWAY="10.1.1.250"

FIRST_IP=$(ip addr show ${INTERFACE} | grep 'inet ' | head -1 | awk '{print $2}' | cut -d'/' -f1)

if [ "$FIRST_IP" != "$PRIMARY_IP" ]; then
    echo "$(date): 检测到IP顺序异常，立即修正" >> /var/log/ip-order-check.log
    
    # 立即修正
    ip addr flush dev ${INTERFACE}
    sleep 1
    ip addr add ${PRIMARY_IP}/${PRIMARY_NETMASK} dev ${INTERFACE}
    sleep 1
    ip addr add ${SECONDARY_IP}/${SECONDARY_NETMASK} dev ${INTERFACE}
    
    # 修正路由
    ip route del default 2>/dev/null || true
    ip route add default via ${PRIMARY_GATEWAY} dev ${INTERFACE} metric 100
    
    echo "$(date): IP顺序已修正为主IP优先" >> /var/log/ip-order-check.log
fi
EOF

sudo chmod +x /usr/local/bin/check-ip-order.sh

# 添加到crontab（每分钟检查）
(sudo crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/check-ip-order.sh") | sudo crontab -

# 验证当前配置
echo "10. 验证当前配置..."
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

echo
echo "=== 强制配置完成 ==="
echo "配置特性:"
echo "✓ 强制删除所有NetworkManager连接"
echo "✓ 手动按顺序添加IP地址"
echo "✓ 启动时强制重新排序IP"
echo "✓ 每分钟自动检查并修正IP顺序"
echo
echo "重启后验证:"
echo "主IP ${PRIMARY_IP} 将强制成为第一IP"
echo "查看强制日志: sudo tail -f /var/log/force-ip-order.log"
echo "查看检查日志: sudo tail -f /var/log/ip-order-check.log"
echo
echo "现在重启系统，主IP将被强制设为第一优先级！"
