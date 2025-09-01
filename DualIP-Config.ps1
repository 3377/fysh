# Windows 11 双IP网络配置脚本 (修复版)
# 管理员权限运行 PowerShell 后执行此脚本

# ==================== 配置变量区域 ====================
# 网络接口名称（自动检测或手动指定）
$InterfaceName = ""  # 留空则自动检测第一个活动的以太网接口

# 主网络配置（优先级高）
$PrimaryIP = "10.1.1.99"
$PrimarySubnet = "255.255.255.0"
$PrimaryGateway = "10.1.1.250"

# 辅助网络配置（用于访问其他终端）
$SecondaryIP = "192.168.70.99"
$SecondarySubnet = "255.255.255.0"
$SecondaryGateway = "192.168.70.1"

# DNS配置
$PrimaryDNS = "8.8.8.8"
$SecondaryDNS = "8.8.4.4"

# 路由优先级（数值越小优先级越高）
$PrimaryMetric = 1
$SecondaryMetric = 10
# ==================== 配置变量区域结束 ====================

# 检查管理员权限
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 自动检测或获取网络接口
function Get-NetworkInterface {
    if ([string]::IsNullOrEmpty($script:InterfaceName)) {
        # 自动检测活动的以太网接口
        $adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up" -and ($_.InterfaceDescription -like "*Ethernet*" -or $_.Name -like "*以太网*" -or $_.Name -like "*Ethernet*")}
        if ($adapters.Count -gt 0) {
            $script:InterfaceName = $adapters[0].Name
            Write-Host "自动检测到网络接口: $($script:InterfaceName)" -ForegroundColor Green
        } else {
            # 如果没有以太网接口，使用第一个活动接口
            $adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
            if ($adapters.Count -gt 0) {
                $script:InterfaceName = $adapters[0].Name
                Write-Host "使用第一个活动接口: $($script:InterfaceName)" -ForegroundColor Yellow
            }
        }
    }
    return $script:InterfaceName
}

# 显示菜单
function Show-Menu {
    Clear-Host
    $currentInterface = Get-NetworkInterface
    Write-Host "=== Windows 11 双IP网络配置工具 ===" -ForegroundColor Green
    Write-Host "当前配置:" -ForegroundColor Yellow
    Write-Host "网络接口: $currentInterface"
    Write-Host "主IP: $PrimaryIP/$PrimarySubnet (网关: $PrimaryGateway)"
    Write-Host "辅助IP: $SecondaryIP/$SecondarySubnet (网关: $SecondaryGateway)"
    Write-Host ""
    Write-Host "请选择操作:" -ForegroundColor Cyan
    Write-Host "1. 配置双IP网络（主网络+辅助网络）"
    Write-Host "2. 删除主网络IP ($PrimaryIP)"
    Write-Host "3. 删除辅助网络IP ($SecondaryIP)"
    Write-Host "4. 查看当前网络配置"
    Write-Host "5. 重置网络为DHCP"
    Write-Host "6. 手动选择网络接口"
    Write-Host "0. 退出"
    Write-Host ""
}

# 获取网络接口索引（修复版）
function Get-InterfaceIndex {
    param($Name)
    try {
        if ([string]::IsNullOrEmpty($Name)) {
            $Name = Get-NetworkInterface
        }
        
        $adapter = Get-NetAdapter -Name $Name -ErrorAction Stop
        return $adapter.InterfaceIndex
    }
    catch {
        Write-Host "错误: 找不到网络接口 '$Name'" -ForegroundColor Red
        Write-Host "可用的网络接口:" -ForegroundColor Yellow
        $availableAdapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        foreach ($adapter in $availableAdapters) {
            Write-Host "  - $($adapter.Name) ($($adapter.InterfaceDescription))" -ForegroundColor White
        }
        return $null
    }
}

# 手动选择网络接口
function Select-NetworkInterface {
    Write-Host "可用的网络接口:" -ForegroundColor Yellow
    $adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
    
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        Write-Host "$($i + 1). $($adapters[$i].Name) - $($adapters[$i].InterfaceDescription)" -ForegroundColor White
    }
    
    do {
        $selection = Read-Host "请选择接口编号 (1-$($adapters.Count))"
        $index = [int]$selection - 1
    } while ($index -lt 0 -or $index -ge $adapters.Count)
    
    $script:InterfaceName = $adapters[$index].Name
    Write-Host "已选择接口: $($script:InterfaceName)" -ForegroundColor Green
}

# 配置双IP网络
function Set-DualIP {
    Write-Host "开始配置双IP网络..." -ForegroundColor Green
    
    $interfaceIndex = Get-InterfaceIndex -Name (Get-NetworkInterface)
    if ($null -eq $interfaceIndex) { 
        Write-Host "无法获取网络接口，请先选择正确的网络接口。" -ForegroundColor Red
        return 
    }
    
    try {
        # 1. 清除现有IP配置
        Write-Host "1. 清除现有IP配置..."
        Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.DestinationPrefix -ne "127.0.0.0/8"} | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        
        # 2. 配置主IP
        Write-Host "2. 配置主IP: $PrimaryIP"
        New-NetIPAddress -InterfaceIndex $interfaceIndex -IPAddress $PrimaryIP -PrefixLength 24 -DefaultGateway $PrimaryGateway -ErrorAction Stop
        
        # 3. 配置辅助IP（不设置网关，避免冲突）
        Write-Host "3. 配置辅助IP: $SecondaryIP"
        New-NetIPAddress -InterfaceIndex $interfaceIndex -IPAddress $SecondaryIP -PrefixLength 24 -ErrorAction Stop
        
        # 4. 添加辅助网关路由
        Write-Host "4. 配置辅助网关路由..."
        $SecondaryNetwork = "192.168.70.0"
        New-NetRoute -DestinationPrefix "$SecondaryNetwork/24" -InterfaceIndex $interfaceIndex -NextHop $SecondaryGateway -RouteMetric $SecondaryMetric -ErrorAction SilentlyContinue
        
        # 5. 配置DNS
        Write-Host "5. 配置DNS服务器..."
        Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ServerAddresses $PrimaryDNS, $SecondaryDNS
        
        # 6. 设置接口优先级
        Write-Host "6. 设置接口优先级..."
        Set-NetIPInterface -InterfaceIndex $interfaceIndex -InterfaceMetric $PrimaryMetric
        
        Write-Host "双IP配置完成!" -ForegroundColor Green
        
    }
    catch {
        Write-Host "配置过程中出现错误: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 删除主网络IP
function Remove-PrimaryIP {
    Write-Host "删除主网络IP: $PrimaryIP" -ForegroundColor Yellow
    
    $interfaceIndex = Get-InterfaceIndex -Name (Get-NetworkInterface)
    if ($null -eq $interfaceIndex) { return }
    
    try {
        # 删除主IP地址
        Get-NetIPAddress -InterfaceIndex $interfaceIndex -IPAddress $PrimaryIP -ErrorAction Stop | Remove-NetIPAddress -Confirm:$false
        
        # 删除相关路由
        Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.NextHop -eq $PrimaryGateway} | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        
        Write-Host "主网络IP删除成功!" -ForegroundColor Green
    }
    catch {
        Write-Host "删除主网络IP失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 删除辅助网络IP
function Remove-SecondaryIP {
    Write-Host "删除辅助网络IP: $SecondaryIP" -ForegroundColor Yellow
    
    $interfaceIndex = Get-InterfaceIndex -Name (Get-NetworkInterface)
    if ($null -eq $interfaceIndex) { return }
    
    try {
        # 删除辅助IP地址
        Get-NetIPAddress -InterfaceIndex $interfaceIndex -IPAddress $SecondaryIP -ErrorAction Stop | Remove-NetIPAddress -Confirm:$false
        
        # 删除相关路由
        Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.NextHop -eq $SecondaryGateway} | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        
        Write-Host "辅助网络IP删除成功!" -ForegroundColor Green
    }
    catch {
        Write-Host "删除辅助网络IP失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 查看当前网络配置
function Show-NetworkConfig {
    Write-Host "当前网络配置:" -ForegroundColor Cyan
    
    $interfaceIndex = Get-InterfaceIndex -Name (Get-NetworkInterface)
    if ($null -eq $interfaceIndex) { return }
    
    Write-Host "`n--- IP地址配置 ---" -ForegroundColor Yellow
    Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Format-Table IPAddress, PrefixLength, InterfaceAlias -AutoSize
    
    Write-Host "--- 路由表 ---" -ForegroundColor Yellow
    Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Format-Table DestinationPrefix, NextHop, RouteMetric, InterfaceAlias -AutoSize
    
    Write-Host "--- DNS配置 ---" -ForegroundColor Yellow
    Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Format-Table InterfaceAlias, ServerAddresses -AutoSize
    
    # 测试连通性
    Write-Host "`n--- 连通性测试 ---" -ForegroundColor Yellow
    Write-Host "测试主网关 ($PrimaryGateway):" -NoNewline
    $result1 = Test-NetConnection -ComputerName $PrimaryGateway -InformationLevel Quiet -WarningAction SilentlyContinue
    Write-Host " $(if($result1){'✓ 连通'}else{'✗ 失败'})" -ForegroundColor $(if($result1){'Green'}else{'Red'})
    
    Write-Host "测试辅助网关 ($SecondaryGateway):" -NoNewline
    $result2 = Test-NetConnection -ComputerName $SecondaryGateway -InformationLevel Quiet -WarningAction SilentlyContinue
    Write-Host " $(if($result2){'✓ 连通'}else{'✗ 失败'})" -ForegroundColor $(if($result2){'Green'}else{'Red'})
}

# 重置网络为DHCP
function Reset-ToDHCP {
    Write-Host "重置网络为DHCP模式..." -ForegroundColor Yellow
    
    $interfaceIndex = Get-InterfaceIndex -Name (Get-NetworkInterface)
    if ($null -eq $interfaceIndex) { return }
    
    try {
        # 清除所有静态IP配置
        Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.DestinationPrefix -ne "127.0.0.0/8"} | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        
        # 启用DHCP
        Set-NetIPInterface -InterfaceIndex $interfaceIndex -Dhcp Enabled
        Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ResetServerAddresses
        
        # 重新获取IP
        $interfaceName = Get-NetworkInterface
        Restart-NetAdapter -Name $interfaceName
        
        Write-Host "网络已重置为DHCP模式!" -ForegroundColor Green
    }
    catch {
        Write-Host "重置失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 主程序
function Main {
    # 检查管理员权限
    if (-not (Test-Administrator)) {
        Write-Host "错误: 此脚本需要管理员权限运行!" -ForegroundColor Red
        Write-Host "请右键点击PowerShell，选择'以管理员身份运行'，然后重新执行此脚本。" -ForegroundColor Yellow
        Read-Host "按任意键退出"
        return
    }
    
    do {
        Show-Menu
        $choice = Read-Host "请输入选项 (0-6)"
        
        switch ($choice) {
            "1" { 
                Set-DualIP
                Read-Host "`n按任意键继续"
            }
            "2" { 
                Remove-PrimaryIP
                Read-Host "`n按任意键继续"
            }
            "3" { 
                Remove-SecondaryIP
                Read-Host "`n按任意键继续"
            }
            "4" { 
                Show-NetworkConfig
                Read-Host "`n按任意键继续"
            }
            "5" { 
                Reset-ToDHCP
                Read-Host "`n按任意键继续"
            }
            "6" { 
                Select-NetworkInterface
                Read-Host "`n按任意键继续"
            }
            "0" { 
                Write-Host "退出程序..." -ForegroundColor Green
                break
            }
            default { 
                Write-Host "无效选项，请重新选择!" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    } while ($choice -ne "0")
}

# 启动主程序
Main
