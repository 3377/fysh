#!/bin/bash

# SSH Key Manager
# Version: 1.2.2
# Description: SSH密钥管理工具，支持生成、部署、备份和自动同步

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置文件路径
CONFIG_FILE="$HOME/.ssh/ssh_manager.conf"
BACKUP_DIR="$HOME/.ssh/backup"
KEYS_DIR="$HOME/.ssh"
HOSTS_FILE="$HOME/.ssh/known_hosts"
CONFIG_SSH="$HOME/.ssh/config"
SYNC_INFO_FILE="$HOME/.ssh/sync_info"
LAST_SYNC_FILE="$HOME/.ssh/last_sync"
WEBDAV_SECRET_FILE="$HOME/.ssh/.webdav_secret"
LOG_FILE="$HOME/.ssh/ssh_manager.log"

# 超时设置（秒）
CURL_TIMEOUT=30
SYNC_TIMEOUT=300

# 临时文件安全性
umask 077  # 设置安全的默认权限

# 日志函数
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case "$level" in
        ERROR) echo -e "${RED}错误: $message${NC}" ;;
        WARNING) echo -e "${YELLOW}警告: $message${NC}" ;;
        INFO) echo -e "${GREEN}信息: $message${NC}" ;;
    esac
}

# 安全检查函数
check_file_permissions() {
    local file="$1"
    local expected_perm="$2"
    
    if [ ! -f "$file" ]; then
        return 0
    fi
    
    local actual_perm=$(stat -c %a "$file")
    if [ "$actual_perm" != "$expected_perm" ]; then
        log "WARNING" "文件权限不正确: $file (当前: $actual_perm, 期望: $expected_perm)"
        chmod "$expected_perm" "$file"
    fi
}

# 验证URL格式
validate_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?:// ]]; then
        log "ERROR" "无效的URL格式: $url"
        return 1
    fi
    return 0
}

# 创建安全的临时文件
create_secure_temp() {
    local prefix="$1"
    local temp_file
    temp_file=$(mktemp "/tmp/${prefix}_XXXXXX") || {
        log "ERROR" "无法创建临时文件"
        return 1
    }
    echo "$temp_file"
}

# 清理临时文件
cleanup_temp() {
    local temp_file="$1"
    if [ -f "$temp_file" ]; then
        shred -u "$temp_file" 2>/dev/null || rm -f "$temp_file"
    fi
}

# 函数：检查WebDAV更新
check_webdav_updates() {
    if [ -z "$WEBDAV_URL" ] || [ -z "$WEBDAV_USER" ] || [ -z "$WEBDAV_PASS" ]; then
        log "WARNING" "WebDAV未配置，跳过同步检查"
        return 1
    fi

    log "INFO" "检查远程更新..."
    
    # 获取远程最新备份信息
    local temp_info
    temp_info=$(create_secure_temp "webdav_info") || return 1
    
    if ! curl -s -m "$CURL_TIMEOUT" -u "$WEBDAV_USER:$WEBDAV_PASS" \
        "$WEBDAV_URL/latest_backup.info" -o "$temp_info"; then
        cleanup_temp "$temp_info"
        log "ERROR" "无法连接到WebDAV服务器"
        return 1
    }

    local remote_info
    remote_info=$(cat "$temp_info")
    cleanup_temp "$temp_info"

    local local_info=""
    [ -f "$SYNC_INFO_FILE" ] && local_info=$(cat "$SYNC_INFO_FILE")

    if [ "$remote_info" != "$local_info" ]; then
        log "INFO" "发现新的更新，正在同步..."
        if download_from_webdav; then
            echo "$remote_info" > "$SYNC_INFO_FILE"
            echo "$(date +%s)" > "$LAST_SYNC_FILE"
            log "INFO" "同步完成"
            return 0
        fi
    else
        log "INFO" "已是最新版本"
    fi
    return 0
}

# 函数：从WebDAV下载
download_from_webdav() {
    local temp_file
    temp_file=$(create_secure_temp "ssh_backup") || return 1
    
    # 下载最新备份
    if ! curl -s -m "$CURL_TIMEOUT" -u "$WEBDAV_USER:$WEBDAV_PASS" \
        "$WEBDAV_URL/latest_backup.tar.gz" -o "$temp_file"; then
        cleanup_temp "$temp_file"
        log "ERROR" "下载失败"
        return 1
    fi

    # 验证备份文件
    if ! tar -tzf "$temp_file" >/dev/null 2>&1; then
        cleanup_temp "$temp_file"
        log "ERROR" "备份文件损坏"
        return 1
    fi

    # 解压到临时目录
    local temp_dir
    temp_dir=$(create_secure_temp "ssh_restore_dir") || return 1
    rm -f "$temp_dir"  # mktemp创建的是文件，我们需要目录
    mkdir -p "$temp_dir"
    
    if ! tar -xzf "$temp_file" -C "$temp_dir"; then
        cleanup_temp "$temp_file"
        rm -rf "$temp_dir"
        log "ERROR" "解压失败"
        return 1
    fi
    
    # 备份现有文件
    local backup_time=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$BACKUP_DIR/backup_$backup_time"
    mkdir -p "$backup_dir"
    cp -r "$KEYS_DIR"/* "$backup_dir/" 2>/dev/null
    
    # 恢复文件
    cp -r "$temp_dir"/.ssh/* "$KEYS_DIR/"
    
    # 清理
    cleanup_temp "$temp_file"
    rm -rf "$temp_dir"
    
    # 设置正确的权限
    chmod 700 "$KEYS_DIR"
    find "$KEYS_DIR" -type f -exec chmod 600 {} \;
    
    log "INFO" "密钥恢复完成，旧文件已备份到: $backup_dir"
    return 0
}

# 函数：配置WebDAV
config_webdav() {
    log "INFO" "配置WebDAV备份"
    
    # 首先尝试解密现有配置
    if decrypt_webdav_config; then
        log "INFO" "检测到已保存的WebDAV配置"
        echo "URL: $WEBDAV_URL"
        echo "用户: $WEBDAV_USER"
        read -p "是否使用已保存的配置？(y/n): " use_saved
        if [ "$use_saved" = "y" ]; then
            # 测试现有配置
            if test_webdav_connection "$WEBDAV_URL" "$WEBDAV_USER" "$WEBDAV_PASS"; then
                return 0
            fi
        fi
    fi
    
    # 输入新配置
    while true; do
        read -p "请输入WebDAV服务器URL: " webdav_url
        if validate_url "$webdav_url"; then
            break
        fi
        log "ERROR" "请输入有效的URL（以http://或https://开头）"
    done
    
    read -p "请输入WebDAV用户名: " webdav_user
    read -s -p "请输入WebDAV密码: " webdav_pass
    echo
    
    # 测试新配置
    if ! test_webdav_connection "$webdav_url" "$webdav_user" "$webdav_pass"; then
        return 1
    fi
    
    # 加密保存配置
    encrypt_webdav_config "$webdav_url" "$webdav_user" "$webdav_pass"
    
    # 更新当前会话的配置
    WEBDAV_URL="$webdav_url"
    WEBDAV_USER="$webdav_user"
    WEBDAV_PASS="$webdav_pass"
    
    log "INFO" "WebDAV配置已保存"
    return 0
}

# 函数：生成SSH密钥对
generate_key() {
    log "INFO" "开始生成SSH密钥对..."
    
    read -p "请输入您的邮箱地址: " email
    read -p "请输入密钥文件名(默认: id_rsa): " keyname
    keyname=${keyname:-id_rsa}
    
    if [ -f "$KEYS_DIR/$keyname" ]; then
        read -p "密钥已存在，是否覆盖？(y/n): " confirm
        if [ "$confirm" != "y" ]; then
            log "INFO" "操作取消"
            return
        fi
    fi
    
    ssh-keygen -t rsa -b 4096 -C "$email" -f "$KEYS_DIR/$keyname"
    
    if [ $? -eq 0 ]; then
        log "INFO" "密钥对生成成功！"
        echo "私钥位置: $KEYS_DIR/$keyname"
        echo "公钥位置: $KEYS_DIR/$keyname.pub"
        
        # 自动添加到 SSH 配置
        echo -e "\nIdentityFile $KEYS_DIR/$keyname" >> "$CONFIG_SSH"
    else
        log "ERROR" "密钥对生成失败！"
        exit 1
    fi
}

# 函数：部署公钥到远程主机
deploy_key() {
    log "INFO" "部署公钥到远程主机"
    
    echo "选择部署方式:"
    echo "1. 交互式部署"
    echo "2. 从配置文件部署"
    read -p "请选择 (1/2): " deploy_method
    
    case $deploy_method in
        1)
            deploy_interactive
            ;;
        2)
            deploy_from_config
            ;;
        *)
            log "ERROR" "无效的选择"
            return 1
            ;;
    esac
}

# 函数：交互式部署
deploy_interactive() {
    read -p "请输入远程主机用户名: " remote_user
    read -p "请输入远程主机地址: " remote_host
    read -p "请输入SSH端口(默认: 22): " remote_port
    remote_port=${remote_port:-22}
    read -p "请输入主机别名(用于配置文件): " alias_name
    
    # 选择要部署的公钥
    echo "可用的公钥:"
    ls -1 "$KEYS_DIR"/*.pub 2>/dev/null
    read -p "请输入要部署的公钥文件名: " pubkey_file
    
    if [ ! -f "$KEYS_DIR/$pubkey_file" ]; then
        log "ERROR" "错误：公钥文件不存在！"
        return 1
    fi
    
    # 部署公钥
    ssh-copy-id -i "$KEYS_DIR/$pubkey_file" -p "$remote_port" "$remote_user@$remote_host"
    
    if [ $? -eq 0 ]; then
        log "INFO" "公钥部署成功！"
        # 添加到配置文件
        echo "HOST_${alias_name}=\"$remote_user@$remote_host:$remote_port\"" >> "$CONFIG_FILE"
        # 添加到SSH配置
        cat >> "$CONFIG_SSH" << EOF

Host $alias_name
    HostName $remote_host
    User $remote_user
    Port $remote_port
    IdentityFile $KEYS_DIR/${pubkey_file%.pub}
EOF
    else
        log "ERROR" "公钥部署失败！"
        return 1
    fi
}

# 函数：从配置文件部署
deploy_from_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "ERROR" "配置文件不存在！"
        return 1
    fi
    
    # 读取配置文件中的主机信息
    grep "^HOST_" "$CONFIG_FILE" | while read -r line; do
        host_info=${line#*=}
        host_info=${host_info//\"}
        user_host=${host_info%:*}
        port=${host_info#*:}
        
        log "INFO" "正在部署到 $user_host"
        ssh-copy-id -i "$KEYS_DIR/id_rsa.pub" -p "$port" "$user_host"
    done
}

# 函数：备份SSH密钥
backup_keys() {
    log "INFO" "开始备份SSH密钥..."
    
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_file="$BACKUP_DIR/ssh_backup_$timestamp.tar.gz"
    
    # 创建备份
    tar -czf "$backup_file" -C "$HOME" .ssh/
    
    if [ $? -eq 0 ]; then
        log "INFO" "本地备份成功！"
        echo "备份文件: $backup_file"
        
        # 如果配置了WebDAV，则上传备份
        if [ -f "$CONFIG_FILE" ] && grep -q "WEBDAV_URL" "$CONFIG_FILE"; then
            upload_to_webdav "$backup_file"
        fi
    else
        log "ERROR" "备份失败！"
        return 1
    fi
}

# 函数：上传到WebDAV
upload_to_webdav() {
    local file="$1"
    
    # 读取WebDAV配置
    source "$CONFIG_FILE"
    
    if [ -z "$WEBDAV_URL" ] || [ -z "$WEBDAV_USER" ] || [ -z "$WEBDAV_PASS" ]; then
        log "ERROR" "WebDAV配置不完整！"
        return 1
    fi
    
    log "INFO" "正在上传到WebDAV..."
    curl -u "$WEBDAV_USER:$WEBDAV_PASS" -T "$file" "$WEBDAV_URL/$(basename "$file")"
    
    if [ $? -eq 0 ]; then
        log "INFO" "WebDAV上传成功！"
    else
        log "ERROR" "WebDAV上传失败！"
    fi
}

# 函数：添加当前主机到授权列表
add_current_host() {
    log "INFO" "添加当前主机到授权列表"
    
    # 首先确保有可用的SSH密钥
    setup_ssh_keys || return 1
    
    # 检查WebDAV配置
    if ! decrypt_webdav_config; then
        log "WARNING" "警告：未检测到WebDAV配置"
        echo "建议先配置WebDAV以便同步密钥到其他机器"
        read -p "是否配置WebDAV？(y/n): " setup_webdav
        if [ "$setup_webdav" = "y" ]; then
            config_webdav || return 1
        fi
    fi
    
    # 获取当前主机信息
    local hostname=$(hostname)
    local username=$(whoami)
    local pubkey=$(cat "$KEYS_DIR/id_rsa.pub")
    
    # 添加到授权文件
    echo "$hostname:$username:$pubkey" >> "$HOSTS_FILE"
    chmod 600 "$HOSTS_FILE"
    
    log "INFO" "已添加当前主机到授权列表"
    
    # 如果WebDAV已配置，执行备份
    if [ -n "$WEBDAV_URL" ]; then
        log "INFO" "正在备份到WebDAV..."
        backup_keys
    else
        log "INFO" "提示：配置WebDAV后可自动同步授权列表到其他机器"
    fi
}

# 函数：批量导入主机
import_hosts() {
    log "INFO" "批量导入主机"
    echo "请准备包含主机信息的CSV文件，格式为："
    echo "别名,用户名,主机地址,端口"
    
    read -p "请输入CSV文件路径: " csv_file
    
    if [ ! -f "$csv_file" ]; then
        log "ERROR" "文件不存在！"
        return 1
    fi
    
    while IFS=, read -r alias user host port; do
        # 去除可能的引号和空格
        alias=$(echo "$alias" | tr -d '"' | tr -d ' ')
        user=$(echo "$user" | tr -d '"' | tr -d ' ')
        host=$(echo "$host" | tr -d '"' | tr -d ' ')
        port=$(echo "$port" | tr -d '"' | tr -d ' ')
        
        # 添加到配置文件
        echo "HOST_${alias}=\"$user@$host:$port\"" >> "$CONFIG_FILE"
        
        # 添加到SSH配置
        cat >> "$CONFIG_SSH" << EOF

Host $alias
    HostName $host
    User $user
    Port $port
    IdentityFile $KEYS_DIR/id_rsa
EOF
        
        log "INFO" "已添加主机: $alias ($user@$host:$port)"
    done < "$csv_file"
}

# 函数：列出所有已授权主机
list_hosts() {
    log "INFO" "已授权主机列表："
    echo "================================"
    echo "别名 | 用户名@主机地址:端口"
    echo "--------------------------------"
    
    grep "^HOST_" "$CONFIG_FILE" | while read -r line; do
        alias=${line%%=*}
        alias=${alias#HOST_}
        info=${line#*=\"}
        info=${info%\"}
        echo "$alias | $info"
    done
    
    echo "================================"
}

# 函数：恢复SSH密钥
restore_keys() {
    log "INFO" "开始恢复SSH密钥..."
    
    echo "可用的备份文件:"
    ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null
    
    read -p "请输入要恢复的备份文件名: " backup_file
    
    if [ ! -f "$BACKUP_DIR/$backup_file" ]; then
        log "ERROR" "错误：备份文件不存在！"
        return 1
    fi
    
    # 备份当前的.ssh目录
    if [ -d "$KEYS_DIR" ]; then
        mv "$KEYS_DIR" "$KEYS_DIR.old"
    fi
    
    # 恢复备份
    tar -xzf "$BACKUP_DIR/$backup_file" -C "$HOME"
    
    if [ $? -eq 0 ]; then
        log "INFO" "恢复成功！"
        rm -rf "$KEYS_DIR.old"
    else
        log "ERROR" "恢复失败！"
        if [ -d "$KEYS_DIR.old" ]; then
            mv "$KEYS_DIR.old" "$KEYS_DIR"
        fi
        return 1
    fi
}

# 函数：从WebDAV恢复密钥
restore_from_webdav() {
    log "INFO" "从WebDAV恢复SSH密钥"
    
    # 如果没有WebDAV配置，尝试使用已保存的配置
    if ! decrypt_webdav_config; then
        log "ERROR" "未找到WebDAV配置，请先配置WebDAV"
        config_webdav || return 1
    fi
    
    # 创建临时目录
    local temp_dir
    temp_dir=$(create_secure_temp "ssh_restore_dir") || return 1
    rm -f "$temp_dir"  # mktemp创建的是文件，我们需要目录
    mkdir -p "$temp_dir"
    
    # 下载最新备份
    log "INFO" "正在下载最新备份..."
    if ! curl -s -m "$CURL_TIMEOUT" -u "$WEBDAV_USER:$WEBDAV_PASS" "$WEBDAV_URL/latest_backup.tar.gz" -o "$temp_dir/backup.tar.gz"; then
        rm -rf "$temp_dir"
        log "ERROR" "下载失败"
        return 1
    fi
    
    # 解压备份
    cd "$temp_dir"
    if ! tar -xzf backup.tar.gz; then
        cd - >/dev/null
        rm -rf "$temp_dir"
        log "ERROR" "解压失败"
        return 1
    fi
    
    # 恢复密钥文件（不覆盖加密配置）
    log "INFO" "正在恢复密钥文件..."
    cp -r .ssh/id_rsa* "$KEYS_DIR/" 2>/dev/null
    cp -r .ssh/known_hosts "$KEYS_DIR/" 2>/dev/null
    cp -r .ssh/authorized_keys "$KEYS_DIR/" 2>/dev/null
    
    # 设置正确的权限
    chmod 600 "$KEYS_DIR"/id_rsa* 2>/dev/null
    chmod 600 "$KEYS_DIR"/known_hosts 2>/dev/null
    chmod 600 "$KEYS_DIR"/authorized_keys 2>/dev/null
    
    # 清理
    cd - >/dev/null
    rm -rf "$temp_dir"
    
    log "INFO" "密钥恢复完成！"
    return 0
}

# 函数：检查并设置SSH密钥
setup_ssh_keys() {
    # 检查是否已有密钥
    if [ ! -f "$KEYS_DIR/id_rsa" ]; then
        log "INFO" "未检测到SSH密钥，尝试从WebDAV恢复..."
        if restore_from_webdav; then
            log "INFO" "已从WebDAV恢复密钥"
        else
            log "INFO" "是否生成新的SSH密钥对？"
            read -p "生成新密钥？(y/n): " gen_new
            if [ "$gen_new" = "y" ]; then
                generate_key
            else
                log "ERROR" "未能设置SSH密钥"
                return 1
            fi
        fi
    fi
    return 0
}

# 函数：主菜单
show_main_menu() {
    while true; do
        echo -e "\n${YELLOW}=== SSH Key Manager ====${NC}"
        echo "1. 生成新的SSH密钥对"
        echo "2. 部署公钥到远程主机"
        echo "3. 备份SSH密钥"
        echo "4. 恢复SSH密钥"
        echo "5. 添加当前主机到授权列表"
        echo "6. 批量导入主机"
        echo "7. 列出所有已授权主机"
        echo "8. 配置WebDAV"
        echo "9. 启用/禁用自动同步"
        echo "h. 显示帮助信息"
        echo "0. 退出"
        
        read -p "请选择操作 [0-9,h]: " choice
        
        case $choice in
            1) generate_key ;;
            2) deploy_key ;;
            3) backup_keys ;;
            4) restore_keys ;;
            5) add_current_host ;;
            6) import_hosts ;;
            7) list_hosts ;;
            8) config_webdav ;;
            9) toggle_auto_sync ;;
            h) show_help ;;
            0) exit 0 ;;
            *) log "ERROR" "无效的选择" ;;
        esac
    done
}

# 函数：初始化配置
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "INFO" "首次运行，正在初始化配置..."
        
        # 创建必要的目录和文件
        mkdir -p "$BACKUP_DIR"
        mkdir -p "$KEYS_DIR"
        touch "$HOSTS_FILE"
        touch "$CONFIG_SSH"
        
        # 设置适当的权限
        chmod 700 "$KEYS_DIR"
        chmod 600 "$CONFIG_FILE"
        chmod 600 "$HOSTS_FILE"
        chmod 600 "$CONFIG_SSH"
        
        log "INFO" "初始化完成！"
        
        # 尝试从WebDAV恢复配置和密钥
        log "INFO" "检查是否有可用的WebDAV备份..."
        if config_webdav; then
            restore_from_webdav
        else
            log "INFO" "未找到WebDAV备份，将创建新的配置"
        fi
    fi
    
    # 确保有可用的SSH密钥
    setup_ssh_keys
}

# 初始化
init_config

# 处理命令行参数
if [ "$1" = "--sync" ]; then
    # 自动同步模式
    if [ -f "$KEYS_DIR/auto_sync_enabled" ]; then
        . "$CONFIG_FILE"  # 加载配置
        check_webdav_updates
    fi
    exit 0
fi

# 显示主菜单
show_main_menu
