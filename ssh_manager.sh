#!/bin/bash

# SSH密钥管理工具
# 功能：自动管理SSH密钥，支持WebDAV同步，主机管理

# 全局变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_DIR="$HOME/.ssh"
HOSTS_FILE="$SCRIPT_DIR/ssh_manager_hosts"
KEY_NAME="drfykey"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CURRENT_USER=$(whoami)
CURRENT_HOST=$(hostname)
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# WebDAV配置
WEBDAV_BASE_URL="https://pan.hstz.com"      # 基础URL，用于连接测试
WEBDAV_PATH="/dav"                          # WebDAV路径
WEBDAV_FULL_URL="${WEBDAV_BASE_URL}${WEBDAV_PATH}"  # 完整URL，用于文件操作

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出信息
info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# 测试WebDAV连接
test_webdav() {
    local user="$1"
    local pass="$2"
    
    info "测试WebDAV连接..."
    
    # 首先测试基本连接
    if ! curl -s -f -X PROPFIND --header "Depth: 0" -u "$user:$pass" "$WEBDAV_BASE_URL" >/dev/null 2>&1; then
        error "WebDAV服务器连接失败"
        return 1
    fi
    
    # 尝试创建必要的目录结构
    if ! curl -s -f -X MKCOL -u "$user:$pass" "$WEBDAV_FULL_URL" >/dev/null 2>&1; then
        # 如果创建失败，可能是目录已存在，继续测试
        info "WebDAV目录已存在或无法创建"
    fi
    
    # 测试目录访问权限
    if ! curl -s -f -X PROPFIND --header "Depth: 0" -u "$user:$pass" "$WEBDAV_FULL_URL" >/dev/null 2>&1; then
        error "WebDAV目录访问失败"
        return 1
    fi
    
    # 测试写入权限（创建临时文件）
    local temp_file="test_${TIMESTAMP}.tmp"
    local test_content="test"
    
    # 创建临时文件
    if ! echo "$test_content" | curl -s -f -X PUT -u "$user:$pass" \
        -H "Content-Type: text/plain" \
        --data-binary @- \
        "$WEBDAV_FULL_URL/$temp_file" >/dev/null 2>&1; then
        error "WebDAV写入测试失败"
        return 1
    fi
    
    # 验证文件是否成功创建
    if ! curl -s -f -X PROPFIND --header "Depth: 1" -u "$user:$pass" "$WEBDAV_FULL_URL/$temp_file" >/dev/null 2>&1; then
        error "WebDAV文件验证失败"
        return 1
    fi
    
    # 删除测试文件
    curl -s -f -X DELETE -u "$user:$pass" "$WEBDAV_FULL_URL/$temp_file" >/dev/null 2>&1
    
    info "WebDAV连接测试成功"
    return 0
}

# 从WebDAV获取重定向URL
get_redirect_url() {
    local url="$1"
    local user="$2"
    local pass="$3"
    
    # 使用curl获取重定向URL，但不跟随重定向
    local redirect_url=$(curl -s -I -u "$user:$pass" "$url" | grep -i "^location:" | cut -d' ' -f2- | tr -d '\r\n')
    echo "$redirect_url"
}

# 从WebDAV下载文件
download_file() {
    local url="$1"
    local output="$2"
    local user="$3"
    local pass="$4"
    local accept_type="$5"
    
    # 先获取重定向URL
    local redirect_url=$(get_redirect_url "$url" "$user" "$pass")
    
    if [ -n "$redirect_url" ]; then
        # 使用重定向URL下载
        curl -s -f --max-time 30 \
            -H "Accept: ${accept_type}" \
            -H "User-Agent: curl/7.68.0" \
            -o "$output" \
            "$redirect_url"
    else
        # 直接从WebDAV下载
        curl -s -f -u "$user:$pass" \
            -H "Accept: ${accept_type}" \
            -o "$output" \
            "$url"
    fi
}

# 从WebDAV下载密钥和配置
download_from_webdav() {
    local user="$1"
    local pass="$2"
    
    info "正在从WebDAV下载文件..."
    
    # 使用PROPFIND检查文件是否存在
    if ! curl -s -f -X PROPFIND --header "Depth: 1" -u "$user:$pass" "$WEBDAV_FULL_URL/$KEY_NAME" >/dev/null 2>&1; then
        info "WebDAV上未找到现有配置"
        return 1
    fi
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    local success=true
    
    # 下载私钥
    if download_file "$WEBDAV_FULL_URL/$KEY_NAME" "$temp_dir/$KEY_NAME" "$user" "$pass" "application/octet-stream" && \
       [ -s "$temp_dir/$KEY_NAME" ] && \
       ! grep -q "^<!DOCTYPE html>\|^<html>\|^<a href=" "$temp_dir/$KEY_NAME" 2>/dev/null; then
        chmod 600 "$temp_dir/$KEY_NAME"
    else
        error "私钥下载失败"
        success=false
    fi
    
    # 下载公钥
    if download_file "$WEBDAV_FULL_URL/$KEY_NAME.pub" "$temp_dir/$KEY_NAME.pub" "$user" "$pass" "application/octet-stream" && \
       [ -s "$temp_dir/$KEY_NAME.pub" ] && \
       ! grep -q "^<!DOCTYPE html>\|^<html>\|^<a href=" "$temp_dir/$KEY_NAME.pub" 2>/dev/null; then
        chmod 644 "$temp_dir/$KEY_NAME.pub"
    else
        error "公钥下载失败"
        success=false
    fi
    
    # 下载主机列表（如果存在）
    if download_file "$WEBDAV_FULL_URL/ssh_manager_hosts" "$temp_dir/ssh_manager_hosts" "$user" "$pass" "text/plain" 2>/dev/null; then
        if grep -q "^<!DOCTYPE html>\|^<html>\|^<a href=" "$temp_dir/ssh_manager_hosts" 2>/dev/null; then
            # 如果是HTML内容，创建新的空文件
            : > "$temp_dir/ssh_manager_hosts"
        fi
        chmod 600 "$temp_dir/ssh_manager_hosts"
    else
        # 如果下载失败，创建新的空文件
        : > "$temp_dir/ssh_manager_hosts"
        chmod 600 "$temp_dir/ssh_manager_hosts"
    fi
    
    # 如果密钥下载成功，移动文件到目标位置
    if [ "$success" = true ]; then
        # 备份现有文件
        if [ -f "$SSH_DIR/$KEY_NAME" ]; then
            cp "$SSH_DIR/$KEY_NAME" "$SSH_DIR/$KEY_NAME.bak.${TIMESTAMP}" 2>/dev/null
        fi
        if [ -f "$SSH_DIR/$KEY_NAME.pub" ]; then
            cp "$SSH_DIR/$KEY_NAME.pub" "$SSH_DIR/$KEY_NAME.pub.bak.${TIMESTAMP}" 2>/dev/null
        fi
        if [ -f "$HOSTS_FILE" ]; then
            cp "$HOSTS_FILE" "$HOSTS_FILE.bak.${TIMESTAMP}" 2>/dev/null
        fi
        
        # 移动新文件到位
        mv "$temp_dir/$KEY_NAME" "$SSH_DIR/$KEY_NAME"
        mv "$temp_dir/$KEY_NAME.pub" "$SSH_DIR/$KEY_NAME.pub"
        mv "$temp_dir/ssh_manager_hosts" "$HOSTS_FILE"
        
        info "文件下载完成"
        rm -rf "$temp_dir"
        return 0
    else
        rm -rf "$temp_dir"
        return 1
    fi
}

# 上传单个文件到WebDAV
upload_file() {
    local file="$1"
    local target="$2"
    local user="$3"
    local pass="$4"
    local description="$5"
    
    info "正在上传${description}..."
    
    # 获取文件大小
    local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file")
    
    # 确保目标目录存在
    local target_dir=$(dirname "$target")
    if [ "$target_dir" != "." ]; then
        curl -s -f -X MKCOL -u "$user:$pass" "$WEBDAV_FULL_URL/$target_dir" >/dev/null 2>&1
    fi
    
    # 使用curl的进度回调
    curl -s -T "$file" \
         -u "$user:$pass" \
         -H "Content-Type: application/octet-stream" \
         "$WEBDAV_FULL_URL/$target" \
         --progress-bar \
         2>&1 | while read -r line; do
        if [[ $line =~ ^([0-9]+)$ ]]; then
            show_progress "${BASH_REMATCH[1]}" "$size"
        fi
    done
    echo # 换行
    
    # 检查上传结果
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        # 验证文件是否成功上传
        if curl -s -f -X PROPFIND --header "Depth: 0" -u "$user:$pass" "$WEBDAV_FULL_URL/$target" >/dev/null 2>&1; then
            info "${description}上传完成"
            return 0
        else
            error "${description}上传后验证失败"
            return 1
        fi
    else
        error "${description}上传失败"
        return 1
    fi
}

# 上传到WebDAV
upload_to_webdav() {
    local user="$1"
    local pass="$2"
    
    info "开始上传文件到WebDAV..."
    
    # 创建临时目录用于备份
    local temp_dir=$(mktemp -d)
    local backup_dir="$temp_dir/backup_${TIMESTAMP}"
    mkdir -p "$backup_dir"
    
    # 备份现有文件
    cp "$SSH_DIR/$KEY_NAME" "$SSH_DIR/$KEY_NAME.pub" "$HOSTS_FILE" "$backup_dir/"
    
    # 确保备份目录存在
    curl -s -f -X MKCOL -u "$user:$pass" "$WEBDAV_FULL_URL/backups" 2>/dev/null
    
    # 上传文件
    if ! upload_file "$SSH_DIR/$KEY_NAME" "$KEY_NAME" "$user" "$pass" "SSH私钥"; then
        rm -rf "$temp_dir"
        return 1
    fi
    
    if ! upload_file "$SSH_DIR/$KEY_NAME.pub" "$KEY_NAME.pub" "$user" "$pass" "SSH公钥"; then
        rm -rf "$temp_dir"
        return 1
    fi
    
    if ! upload_file "$HOSTS_FILE" "ssh_manager_hosts" "$user" "$pass" "主机列表"; then
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 创建并上传备份
    info "正在创建备份..."
    tar czf "$temp_dir/backup_${TIMESTAMP}.tar.gz" -C "$temp_dir" "backup_${TIMESTAMP}"
    if ! upload_file "$temp_dir/backup_${TIMESTAMP}.tar.gz" "backups/backup_${TIMESTAMP}.tar.gz" "$user" "$pass" "备份文件"; then
        warn "备份文件上传失败，但主文件已上传成功"
    fi
    
    # 清理临时文件
    rm -rf "$temp_dir"
    
    info "所有文件上传完成"
    return 0
}

# 检查并创建必要的目录和文件
init_env() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "$HOSTS_FILE"
    chmod 600 "$HOSTS_FILE"
}

# 生成新的SSH密钥对
generate_keys() {
    info "生成新的SSH密钥对..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/$KEY_NAME" -N "" -C "Generated by SSH Manager for $CURRENT_USER@$CURRENT_HOST"
    chmod 600 "$SSH_DIR/$KEY_NAME"
    chmod 644 "$SSH_DIR/$KEY_NAME.pub"
    info "密钥生成完成"
}

# 测试主机连接
test_host() {
    local host_line="$1"
    local user=$(echo "$host_line" | cut -d'@' -f1)
    local host=$(echo "$host_line" | cut -d'@' -f2)
    
    info "测试连接 $host_line ..."
    if [ "$host" = "$CURRENT_HOST" ] || [ "$host" = "localhost" ]; then
        # 如果是当前主机或localhost，直接返回成功
        echo -e "${GREEN}✓ $host_line - 连接成功（本地主机）${NC}"
        return 0
    fi
    
    # 检查SSH密钥是否存在
    if [ ! -f "$SSH_DIR/$KEY_NAME" ]; then
        echo -e "${RED}✗ $host_line - SSH密钥不存在${NC}"
        return 1
    fi
    
    # 尝试SSH连接
    if ssh -i "$SSH_DIR/$KEY_NAME" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$user@$host" exit &>/dev/null; then
        echo -e "${GREEN}✓ $host_line - 连接成功${NC}"
        return 0
    else
        echo -e "${RED}✗ $host_line - 连接失败${NC}"
        return 1
    fi
}

# 测试所有主机连接
test_all_hosts() {
    echo
    info "开始测试所有主机连接..."
    while IFS= read -r host; do
        test_host "$host"
    done < "$HOSTS_FILE"
}

# 添加当前主机到授权列表
add_current_host() {
    local host_entry="$CURRENT_USER@$CURRENT_HOST"
    
    # 确保hosts文件存在
    touch "$HOSTS_FILE"
    
    if ! grep -q "^$host_entry$" "$HOSTS_FILE" 2>/dev/null; then
        echo "$host_entry" >> "$HOSTS_FILE"
        info "已添加当前主机到授权列表: $host_entry"
        
        # 确保当前用户有权限访问自己的.ssh目录
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        
        # 如果公钥存在，确保它被添加到authorized_keys
        if [ -f "$SSH_DIR/$KEY_NAME.pub" ]; then
            touch "$SSH_DIR/authorized_keys"
            chmod 600 "$SSH_DIR/authorized_keys"
            cat "$SSH_DIR/$KEY_NAME.pub" >> "$SSH_DIR/authorized_keys"
            info "已将公钥添加到authorized_keys"
        fi
    else
        info "当前主机已在授权列表中: $host_entry"
    fi
}

# 部署公钥到主机
deploy_keys() {
    echo
    info "开始批量部署公钥..."
    while IFS= read -r host; do
        local user=$(echo "$host" | cut -d'@' -f1)
        local hostname=$(echo "$host" | cut -d'@' -f2)
        
        info "正在部署到 $host ..."
        ssh-copy-id -i "$SSH_DIR/$KEY_NAME.pub" "$user@$hostname"
    done < "$HOSTS_FILE"
    
    # 同步到WebDAV
    upload_to_webdav "$1" "$2"
}

# 显示主菜单
show_menu() {
    echo
    echo "SSH密钥管理工具 - 主菜单"
    echo "------------------------"
    echo "1. 查看授权主机列表"
    echo "2. 添加新主机"
    echo "3. 测试主机连接"
    echo "4. 部署公钥到主机"
    echo "5. 同步到WebDAV"
    echo "6. 帮助信息"
    echo "0. 退出"
    echo
    read -p "请选择操作 [0-6]: " choice
    
    case $choice in
        1) list_hosts ;;
        2) add_host_interactive ;;
        3) test_all_hosts ;;
        4) deploy_keys "$WEBDAV_USER" "$WEBDAV_PASS" ;;
        5) upload_to_webdav "$WEBDAV_USER" "$WEBDAV_PASS" ;;
        6) show_help ;;
        0) exit 0 ;;
        *) warn "无效的选择" ;;
    esac
}

# 显示帮助信息
show_help() {
    echo
    echo "SSH密钥管理工具 - 使用说明"
    echo
    echo "配置文件位置："
    echo "  SSH目录：$SSH_DIR"
    echo "  主机列表：$HOSTS_FILE"
    echo "  密钥文件：$SSH_DIR/$KEY_NAME"
    echo "  WebDAV地址：$WEBDAV_FULL_URL"
    echo
    echo "使用方法："
    echo "1. 首次使用，需要提供WebDAV用户名和密码："
    echo "   $0 <用户名> <密码>"
    echo
    echo "2. 后续使用，直接运行即可进入交互菜单："
    echo "   $0"
    echo
    echo "功能说明："
    echo "- 自动管理SSH密钥"
    echo "- WebDAV同步和备份"
    echo "- 批量部署公钥"
    echo "- 主机连接测试"
    echo "- 授权主机管理"
}

# 显示授权主机列表
list_hosts() {
    echo
    info "授权主机列表："
    if [ -f "$HOSTS_FILE" ]; then
        if [ -s "$HOSTS_FILE" ]; then
            # 显示主机列表，每行前面加上 "- "
            while IFS= read -r line; do
                echo "  - $line"
            done < "$HOSTS_FILE"
        else
            echo "  (空)"
        fi
    else
        echo "  (空)"
        touch "$HOSTS_FILE"
        chmod 600 "$HOSTS_FILE"
    fi
}

# 主程序
main() {
    # 检查参数
    if [ $# -eq 2 ]; then
        WEBDAV_USER="$1"
        WEBDAV_PASS="$2"
        
        # 测试WebDAV连接
        test_webdav "$WEBDAV_USER" "$WEBDAV_PASS"
        
        # 初始化环境
        init_env
        
        # 尝试从WebDAV下载文件
        if ! download_from_webdav "$WEBDAV_USER" "$WEBDAV_PASS"; then
            info "未找到现有配置，开始初始化..."
            generate_keys
            add_current_host
            upload_to_webdav "$WEBDAV_USER" "$WEBDAV_PASS"
        else
            info "成功下载现有配置"
            add_current_host
            upload_to_webdav "$WEBDAV_USER" "$WEBDAV_PASS"
        fi
        
        # 显示菜单
        while true; do
            show_menu
        done
    elif [ $# -eq 0 ]; then
        error "请提供WebDAV用户名和密码"
    else
        error "用法: $0 <用户名> <密码>"
    fi
}

main "$@"
