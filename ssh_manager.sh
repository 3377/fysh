    #!/bin/bash

    # 全局变量
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SSH_MANAGER_DIR="$HOME/.ssh_manager"
    SSH_DIR="$SSH_MANAGER_DIR"
    KEY_NAME="drfykey"
    HOSTS_FILE="$SSH_MANAGER_DIR/hosts.md"
    CURRENT_USER="$(whoami)"
    CURRENT_HOST="$(hostname)"
    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    CONFIG_FILE="$SSH_MANAGER_DIR/config.sh"

    # WebDAV配置
    WEBDAV_BASE_URL="https://pan.hstz.com"
    WEBDAV_PATH="/dav/ssh_manager"
    WEBDAV_FULL_URL="${WEBDAV_BASE_URL}${WEBDAV_PATH}"

    # ANSI颜色代码
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    NC='\033[0m'

    # 日志函数
    info() {
        echo -e "${BLUE}[INFO]${NC} $1"
    }

    success() {
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    }

    warn() {
        echo -e "${YELLOW}[WARN]${NC} $1"
    }

    error() {
        echo -e "${RED}[ERROR]${NC} $1"
    }

    # 测试WebDAV连接
    test_webdav() {
        local user="$1"
        local pass="$2"
        
        info "测试WebDAV连接..."
        
        # 创建一个临时文件
        local temp_file="test_${TIMESTAMP}.tmp"
        echo "test" > "$temp_file"
        
        # 尝试上传临时文件
        if ! curl -s -f -T "$temp_file" -u "$user:$pass" "$WEBDAV_FULL_URL/$temp_file"; then
            error "无法连接到WebDAV服务器"
            rm -f "$temp_file"
            return 1
        fi
        
        # 检查文件是否存在
        if ! curl -s -f -X PROPFIND --header "Depth: 1" -u "$user:$pass" "$WEBDAV_FULL_URL/$temp_file" >/dev/null 2>&1; then
            error "无法验证WebDAV上传"
            rm -f "$temp_file"
            return 1
        fi
        
        # 删除临时文件
        curl -s -f -X DELETE -u "$user:$pass" "$WEBDAV_FULL_URL/$temp_file"
        rm -f "$temp_file"
        
        info "WebDAV连接测试成功"
        return 0
    }

    # 清理现有配置
    clean_local_config() {
        info "清理本地配置..."
        rm -rf "$SSH_MANAGER_DIR"
        mkdir -p "$SSH_MANAGER_DIR"
        chmod 700 "$SSH_MANAGER_DIR"
    }

    # 初始化配置
    init_config() {
        info "初始化配置目录..."
        
        # 创建必要的目录
        mkdir -p "$SSH_MANAGER_DIR"
        chmod 700 "$SSH_MANAGER_DIR"
        
        # 确保hosts文件存在
        touch "$HOSTS_FILE"
        chmod 600 "$HOSTS_FILE"
    }

    # 初始化环境
    init_env() {
        # 清理旧的ssh_manager目录
        if [ -d "$SSH_MANAGER_DIR" ]; then
            info "清理旧的配置目录..."
            rm -rf "$SSH_MANAGER_DIR"
        fi
        
        # 创建必要的目录
        mkdir -p "$SSH_MANAGER_DIR"
        chmod 700 "$SSH_MANAGER_DIR"
        
        # 初始化hosts文件
        : > "$HOSTS_FILE"
        chmod 600 "$HOSTS_FILE"
        
        success "环境初始化完成"
    }

    # 生成新的SSH密钥对
    generate_keys() {
        info "生成新的SSH密钥对..."
        
        # 确保.ssh目录存在
        if [ ! -d "$SSH_DIR" ]; then
            mkdir -p "$SSH_DIR"
            chmod 700 "$SSH_DIR"
        fi

        # 删除可能存在的旧密钥
        rm -f "$SSH_DIR/$KEY_NAME" "$SSH_DIR/${KEY_NAME}.pub"
        
        # 生成新的SSH密钥对
        if ! ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/$KEY_NAME" -N ""; then
            error "生成SSH密钥对失败"
            return 1
        fi
        
        # 设置正确的权限
        chmod 600 "$SSH_DIR/$KEY_NAME"
        chmod 644 "$SSH_DIR/${KEY_NAME}.pub"
        
        # 确保authorized_keys文件存在
        local auth_keys="$SSH_DIR/authorized_keys"
        touch "$auth_keys"
        chmod 600 "$auth_keys"
        
        # 将新生成的公钥添加到authorized_keys
        cat "$SSH_DIR/${KEY_NAME}.pub" >> "$auth_keys"
        
        success "SSH密钥对生成成功，并已添加到本机的authorized_keys"
        return 0
    }

    # 下载文件
    download_file() {
        local url="$1"
        local output_file="$2"
        local user="$3"
        local pass="$4"

        info "正在从 $url 下载文件..."
        
        # 使用curl下载文件，添加-L参数处理重定向，禁用缓存
        local response
        response=$(curl -s -k -L \
            -H "Cache-Control: no-cache" \
            -H "Pragma: no-cache" \
            -w "%{http_code}" \
            -u "$user:$pass" \
            -o "$output_file" \
            "$url" \
            --create-dirs)
        
        # 检查HTTP状态码
        if [ "$response" = "200" ] || [ "$response" = "201" ]; then
            # 验证文件是否下载成功
            if [ -s "$output_file" ]; then
                # 检查文件内容是否是HTML（可能是错误页面）
                if ! grep -q "^<!DOCTYPE\|^<html\|^<a href=" "$output_file"; then
                    info "文件下载成功，大小: $(wc -c < "$output_file") 字节"
                    info "文件内容预览: $(head -n 1 "$output_file")"
                    return 0
                else
                    warn "下载的文件包含HTML内容，可能是错误页面"
                    rm -f "$output_file"
                    return 1
                fi
            else
                warn "下载的文件为空"
                rm -f "$output_file"
                return 1
            fi
        else
            warn "下载失败，HTTP状态码: $response"
            return 1
        fi
    }

    # 从WebDAV下载文件
    download_from_webdav() {
        local user="$1"
        local pass="$2"
        local need_upload=false
        local key_exists=false
        
        info "正在从WebDAV下载文件..."
        
        # 检查目录是否存在
        if ! curl -s -k -L -I -u "$user:$pass" "$WEBDAV_FULL_URL/" | grep -q "HTTP/.*[[:space:]]2"; then
            info "WebDAV目录不存在，将在上传时创建"
            need_upload=true
        fi

        # 创建临时目录用于验证下载的文件
        local temp_dir
        temp_dir=$(mktemp -d)
        
        # 下载私钥到临时目录
        if download_file "$WEBDAV_FULL_URL/$KEY_NAME" "${temp_dir}/${KEY_NAME}" "$user" "$pass"; then
            info "WebDAV上存在密钥，正在下载..."
            
            # 下载公钥到临时目录
            if download_file "$WEBDAV_FULL_URL/${KEY_NAME}.pub" "${temp_dir}/${KEY_NAME}.pub" "$user" "$pass"; then
                # 验证密钥对
                chmod 600 "${temp_dir}/${KEY_NAME}"
                if ssh-keygen -l -f "${temp_dir}/${KEY_NAME}" > /dev/null 2>&1; then
                    info "成功下载有效的密钥对"
                    info "使用WebDAV上的现有密钥"
                    # 移动验证过的密钥到最终位置
                    mv "${temp_dir}/${KEY_NAME}" "$SSH_DIR/$KEY_NAME"
                    mv "${temp_dir}/${KEY_NAME}.pub" "$SSH_DIR/${KEY_NAME}.pub"
                    chmod 600 "$SSH_DIR/$KEY_NAME"
                    chmod 644 "$SSH_DIR/${KEY_NAME}.pub"
                    key_exists=true
                else
                    warn "下载的密钥对无效，需要生成新的密钥对"
                    need_upload=true
                fi
            else
                warn "公钥下载失败，需要生成新的密钥对"
                need_upload=true
            fi
        else
            info "WebDAV上不存在密钥，需要生成新的密钥对"
            need_upload=true
        fi

        # 清理临时目录
        rm -rf "$temp_dir"
        
        # 下载hosts文件
        local temp_remote="$SSH_MANAGER_DIR/hosts.remote"
        if ! download_file "$WEBDAV_FULL_URL/hosts.md" "$temp_remote" "$user" "$pass"; then
            warn "下载hosts文件失败"
            rm -f "$temp_remote"
        else
            mv "$temp_remote" "$HOSTS_FILE"
            chmod 600 "$HOSTS_FILE"
            info "hosts文件下载成功"
        fi
        
        # 如果没有有效的密钥，生成新的
        if [ "$key_exists" = false ]; then
            info "生成新的密钥对..."
            if ! generate_keys; then
                error "生成密钥对失败"
                return 1
            fi
            need_upload=true
        fi
        
        # 如果需要，执行上传操作
        if [ "$need_upload" = true ]; then
            info "上传新生成的密钥到WebDAV..."
            if ! upload_to_webdav "$user" "$pass"; then
                error "密钥上传失败"
                return 1
            fi
        fi
        
        return 0
    }

    # 从WebDAV只下载hosts文件
    download_hosts_file() {
        local user="$1"
        local pass="$2"
        
        info "正在从WebDAV下载hosts文件..."
        
        # 检查目录是否存在
        if ! curl -s -k -L -I -u "$user:$pass" "${WEBDAV_FULL_URL}/" | grep -q "HTTP/.*[[:space:]]2"; then
            error "WebDAV目录不存在"
            return 1
        fi
        
        # 下载hosts文件
        local temp_remote="$SSH_MANAGER_DIR/hosts.remote"
        if ! download_file "${WEBDAV_FULL_URL}/hosts.md" "$temp_remote" "$user" "$pass"; then
            error "下载hosts文件失败"
            rm -f "$temp_remote"
            return 1
        fi
        
        mv "$temp_remote" "$HOSTS_FILE"
        chmod 600 "$HOSTS_FILE"
        info "hosts文件下载成功"
        return 0
    }

    # 上传文件到WebDAV
    upload_to_webdav() {
        local user="$1"
        local pass="$2"
        
        info "正在上传文件到WebDAV..."
        
        # 确保目标目录存在
        if ! curl -s -k -X MKCOL -u "$user:$pass" "${WEBDAV_FULL_URL}/" > /dev/null 2>&1; then
            warn "创建WebDAV目录失败，目录可能已存在"
        fi
        
        local upload_failed=false
        
        # 检查WebDAV上是否已存在密钥文件
        if ! curl -s -k -I -u "$user:$pass" "${WEBDAV_FULL_URL}/${KEY_NAME}" | grep -q "HTTP/.*[[:space:]]2"; then
            info "WebDAV上不存在密钥，准备上传..."
            # 上传密钥文件
            if [ -f "$SSH_DIR/$KEY_NAME" ]; then
                info "上传SSH密钥..."
                if ! curl -s -k -T "$SSH_DIR/$KEY_NAME" -u "$user:$pass" "${WEBDAV_FULL_URL}/${KEY_NAME}" || \
                ! curl -s -k -T "$SSH_DIR/${KEY_NAME}.pub" -u "$user:$pass" "${WEBDAV_FULL_URL}/${KEY_NAME}.pub"; then
                    error "SSH密钥上传失败"
                    upload_failed=true
                else
                    success "SSH密钥上传成功"
                fi
            fi
        else
            info "WebDAV上已存在密钥，跳过上传"
        fi
        
        # 上传hosts文件前先删除现有文件
        if [ -f "$HOSTS_FILE" ]; then
            info "删除WebDAV上的现有hosts文件..."
            curl -s -k -X DELETE -u "$user:$pass" "${WEBDAV_FULL_URL}/hosts.md" > /dev/null 2>&1
            
            info "上传新的hosts文件..."
            if ! curl -s -k -T "$HOSTS_FILE" -u "$user:$pass" "${WEBDAV_FULL_URL}/hosts.md"; then
                error "hosts文件上传失败"
                upload_failed=true
            else
                success "hosts文件上传成功"
            fi
        fi
        
        if [ "$upload_failed" = true ]; then
            return 1
        fi
        
        return 0
    }

    # 测试主机连接
    test_host_connection() {
        local host="$1"
        local ip="$2"
        local port="$3"
        local key_file="$SSH_MANAGER_DIR/$KEY_NAME"

        # 确保私钥权限正确
        chmod 600 "$key_file"
        
        # 使用下载的私钥测试连接，增加详细输出用于调试
        if ssh -v -i "$key_file" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -p "$port" "root@$ip" "echo 'Connection test successful'" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    }

    # 测试所有主机连通性
    test_hosts() {
        info "从WebDAV获取最新配置..."
        if ! download_from_webdav "$WEBDAV_USER" "$WEBDAV_PASS"; then
            error "获取配置失败"
            return 1
        fi

        local temp_file="$SSH_MANAGER_DIR/hosts.temp"
        : > "$temp_file"  # 清空或创建临时文件
        local current_time=$(date '+%Y-%m-%d %H:%M:%S')
        local has_changes=0
        
        info "开始测试主机连通性..."
        while IFS='|' read -r host timestamp ip port last_test || [ -n "$host" ]; do
            if [ -n "$host" ] && [ -n "$ip" ] && [ -n "$port" ]; then
                printf "正在测试 %s (%s:%s)..." "$host" "$ip" "$port"
                if test_host_connection "$host" "$ip" "$port"; then
                    echo -e "\033[32m在线\033[0m"
                    # 更新最后测试时间
                    echo "$host|$timestamp|$ip|$port|$current_time" >> "$temp_file"
                    has_changes=1
                else
                    echo -e "\033[31m离线\033[0m"
                    # 仍然更新最后测试时间，因为我们确实进行了测试
                    echo "$host|$timestamp|$ip|$port|$current_time" >> "$temp_file"
                    has_changes=1
                fi
            else
                [ -n "$host" ] && echo "$host|$timestamp|$ip|$port|$last_test" >> "$temp_file"
            fi
        done < "$HOSTS_FILE"

        if [ "$has_changes" -eq 1 ]; then
            mv "$temp_file" "$HOSTS_FILE"
            chmod 600 "$HOSTS_FILE"
            
            info "上传更新后的主机列表..."
            if ! upload_to_webdav "$WEBDAV_USER" "$WEBDAV_PASS"; then
                error "上传更新后的主机列表失败"
                return 1
            fi
            success "主机列表已更新"
        else
            rm -f "$temp_file"
            info "主机状态未发生变化"
        fi
        
        return 0
    }

    # 显示授权主机列表
    list_hosts() {
        info "从WebDAV获取最新主机列表..."
        if ! download_hosts_file "$WEBDAV_USER" "$WEBDAV_PASS"; then
            error "获取主机列表失败"
            return 1
        fi

        # 确保文件存在且有内容
        if [ ! -f "$HOSTS_FILE" ]; then
            error "主机列表文件不存在"
            return 1
        fi

        # 检查文件内容
        if [ ! -s "$HOSTS_FILE" ]; then
            info "主机列表为空"
            return 0
        fi

        echo
        info "授权主机列表："
        
        # 定义颜色代码
        local GREEN=$(echo -e "\033[32m")
        local RED=$(echo -e "\033[31m")
        local YELLOW=$(echo -e "\033[33m")
        local NC=$(echo -e "\033[0m")
        
        # 打印表头
        printf "%-16s %-14s %-7s %-19s %-19s %s\n" \
            "主机名" "公网IP" "端口" "授权时间" "最后测试时间" "状态"
        
        # 打印分隔线
        echo "--------------------------------------------------------------------------------"
        
        # 使用临时文件确保文件格式正确
        local temp_hosts="${HOSTS_FILE}.tmp"
        tr -d '\r' < "$HOSTS_FILE" > "$temp_hosts"
        
        # 显示文件内容以便调试
        info "主机列表文件内容："
        cat "$temp_hosts"
        echo
        
        # 读取并显示主机列表
        while IFS='|' read -r host timestamp ip port last_test; do
            if [ -n "$host" ]; then
                if [ -n "$ip" ] && [ -n "$port" ]; then
                    # 使用相同的测试连接函数
                    if test_host_connection "$host" "$ip" "$port"; then
                        echo -e "$(printf "%-16s %-14s %-7s %-19s %-19s " \
                            "$host" "$ip" "$port" "$timestamp" "$last_test")${GREEN}在线${NC}"
                    else
                        echo -e "$(printf "%-16s %-14s %-7s %-19s %-19s " \
                            "$host" "$ip" "$port" "$timestamp" "$last_test")${RED}离线${NC}"
                    fi
                else
                    echo -e "$(printf "%-16s %-14s %-7s %-19s %-19s " \
                        "$host" "$ip" "$port" "$timestamp" "$last_test")${YELLOW}未知${NC}"
                fi
            fi
        done < "$temp_hosts"
        
        # 清理临时文件
        rm -f "$temp_hosts"
    }

    # 测试主机SSH连接
    test_ssh_connection() {
        local host="$1"
        local port="$2"
        local ip="$3"
        local test_time
        test_time="$(date '+%Y-%m-%d %H:%M:%S')"
        
        if [ -z "$ip" ] || [ -z "$port" ]; then
            error "无效的IP地址或端口: $host"
            echo ""
            return 1
        fi
        
        info "测试连接 $host (${ip}:${port})..."
        
        # 使用ssh命令测试连接
        if ssh -i "$SSH_DIR/$KEY_NAME" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p "$port" "root@$ip" "echo 'Connection successful'" >/dev/null 2>&1; then
            success "连接成功: $host (${ip}:${port})"
            echo "$test_time"
            return 0
        else
            error "连接失败: $host (${ip}:${port})"
            echo ""
            return 1
        fi
    }

    # 授权当前主机（仅在新主机首次运行时调用）
    authorize_current_host() {
        local hostname
        local public_ip
        local ssh_port
        local current_time
        
        hostname=$(hostname)
        if ! public_ip=$(get_remote_public_ip); then
            error "无法获取公网IP地址"
            return 1
        fi
        
        if ! ssh_port=$(get_ssh_port); then
            error "无法获取SSH端口"
            return 1
        fi
        
        # 确保从WebDAV获取最新密钥
        info "从WebDAV同步密钥..."
        if ! download_from_webdav "$WEBDAV_USER" "$WEBDAV_PASS"; then
            warn "从WebDAV获取密钥失败，将生成新的密钥对"
            if ! generate_keys; then
                error "生成密钥对失败"
                return 1
            fi
        fi

        # 部署公钥到本地authorized_keys
        if ! deploy_local_key; then
            error "部署公钥到本机失败"
            return 1
        fi
        
        current_time=$(date "+%Y-%m-%d %H:%M:%S")
        
        # 更新主机记录
        if ! merge_host_record "$hostname" "$current_time" "$public_ip" "$ssh_port"; then
            error "更新主机记录失败"
            return 1
        fi
        
        success "已更新当前主机 $hostname 的授权信息"
        return 0
    }

    # 部署公钥到本地authorized_keys
    deploy_local_key() {
        local pub_key="$SSH_DIR/${KEY_NAME}.pub"
        local auth_keys="$HOME/.ssh/authorized_keys"
        local ssh_dir="$HOME/.ssh"

        # 确保.ssh目录存在且权限正确
        if [ ! -d "$ssh_dir" ]; then
            mkdir -p "$ssh_dir"
            chmod 700 "$ssh_dir"
        fi

        # 确保authorized_keys文件存在
        if [ ! -f "$auth_keys" ]; then
            touch "$auth_keys"
        fi
        chmod 600 "$auth_keys"

        # 检查公钥是否已存在于authorized_keys中
        if [ -f "$pub_key" ]; then
            local pub_key_content
            pub_key_content=$(cat "$pub_key")
            if ! grep -qF "$pub_key_content" "$auth_keys"; then
                # 追加公钥到authorized_keys
                echo "$pub_key_content" >> "$auth_keys"
                success "已将公钥添加到 authorized_keys"
            else
                info "公钥已存在于 authorized_keys 中"
            fi
        else
            error "公钥文件不存在: $pub_key"
            return 1
        fi

        return 0
    }

    # 显示功能帮助信息
    show_feature_help() {
        local feature="$1"
        case $feature in
            "test")
                echo "测试主机连通性功能说明："
                echo "此功能用于测试所有授权主机的SSH连接状态。"
                echo
                echo "主要步骤："
                echo "1. 对每个授权主机进行SSH连接测试"
                echo "2. 更新每个主机的最后测试时间"
                echo "3. 显示测试结果"
                ;;
            "sync")
                echo "从WebDAV同步功能说明："
                echo "此功能用于从WebDAV服务器同步SSH密钥和主机授权列表。"
                echo
                echo "主要步骤："
                echo "1. 检查并下载WebDAV上的SSH密钥"
                echo "2. 验证密钥的有效性"
                echo "3. 同步主机授权列表"
                echo
                echo "注意事项："
                echo "- 确保WebDAV服务器可访问"
                echo "- 需要正确的用户名和密码"
                echo "- 同步过程中不会删除本地已有的授权"
                ;;
            "hosts")
                echo "授权主机列表功能说明："
                echo "此功能显示所有已授权的主机及其详细信息。"
                echo
                echo "显示信息："
                echo "- 主机名"
                echo "- 公网IP"
                echo "- SSH端口"
                echo "- 授权时间"
                echo "- 最后测试时间"
                echo "- 连接状态"
                echo
                echo "注意事项："
                echo "- 时间戳格式：YYYY-MM-DD HH:MM:SS"
                echo "- 连接状态实时检测"
                echo "- 支持自动更新主机信息"
                ;;
            "help")
                show_help
                ;;
            *)
                error "未知的功能选项"
                ;;
        esac
    }

    # 处理菜单选择
    handle_menu() {
        while true; do
            echo
            echo "请选择操作："
            echo "1) 授权当前主机"
            echo "2) 查看授权主机列表"
            echo "3) 从WebDAV同步"
            echo "4) 上传授权列表到WebDAV"
            echo "5) 测试所有主机连通性"
            echo "6) 帮助"
            echo "0) 退出"
            echo
            read -r -p "请输入选项编号: " choice
            
            case $choice in
                1)
                    authorize_current_host
                    ;;
                2)
                    list_hosts
                    ;;
                3)
                    if [ -f "$CONFIG_FILE" ]; then
                        source "$CONFIG_FILE"
                        download_from_webdav "$WEBDAV_USER" "$WEBDAV_PASS"
                    else
                        error "未找到配置文件"
                    fi
                    ;;
                4)
                    if [ -f "$CONFIG_FILE" ]; then
                        source "$CONFIG_FILE"
                        upload_to_webdav "$WEBDAV_USER" "$WEBDAV_PASS"
                    else
                        error "未找到配置文件"
                    fi
                    ;;
                5)
                    test_hosts
                    list_hosts
                    ;;
                6)
                    show_help
                    ;;
                0)
                    info "正在退出..."
                    rm -f "$CONFIG_FILE"
                    exit 0
                    ;;
                *)
                    error "无效的选项"
                    ;;
            esac
        done
    }

    # 主程序入口
    main() {
        if [ $# -eq 0 ]; then
            # 如果没有参数，直接显示交互式菜单
            if [ -f "$CONFIG_FILE" ]; then
                # 加载已保存的配置
                source "$CONFIG_FILE"
                if [ -n "$WEBDAV_USER" ] && [ -n "$WEBDAV_PASS" ]; then
                    info "使用已保存的WebDAV配置"
                    # 从WebDAV下载最新的主机列表
                    if ! download_from_webdav "$WEBDAV_USER" "$WEBDAV_PASS"; then
                        error "从WebDAV下载配置失败"
                        exit 1
                    fi
                    handle_menu
                else
                    error "未找到WebDAV配置信息"
                    show_help
                    exit 1
                fi
            else
                error "未找到配置文件，请先使用用户名和密码参数运行脚本进行初始化"
                show_help
                exit 1
            fi
        elif [ $# -eq 2 ]; then
            WEBDAV_USER="$1"
            WEBDAV_PASS="$2"
            
            # 测试WebDAV连接
            if ! test_webdav "$WEBDAV_USER" "$WEBDAV_PASS"; then
                error "WebDAV连接测试失败，请检查凭据"
                exit 1
            fi
            
            # 保存配置到文件
            mkdir -p "$(dirname "$CONFIG_FILE")"
            echo "WEBDAV_USER='$WEBDAV_USER'" > "$CONFIG_FILE"
            echo "WEBDAV_PASS='$WEBDAV_PASS'" >> "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
            
            # 初始化环境
            init_env
            
            # 配置SSHD
            if ! configure_sshd; then
                error "SSHD配置失败"
                exit 1
            fi
            
            # 从WebDAV下载配置
            info "从WebDAV下载配置..."
            if ! download_from_webdav "$WEBDAV_USER" "$WEBDAV_PASS"; then
                warn "从WebDAV下载配置失败，将创建新的配置"
            fi
            
            # 授权当前主机
            if ! authorize_current_host; then
                error "授权当前主机失败"
                exit 1
            fi
            
            # 上传更新后的主机列表到WebDAV
            if [ -f "$HOSTS_FILE" ]; then
                if ! upload_to_webdav "$WEBDAV_USER" "$WEBDAV_PASS"; then
                    error "主机列表上传失败"
                    exit 1
                fi
            fi
            
            success "初始配置完成"
            
            # 显示交互式菜单
            handle_menu
        else
            show_help
            exit 1
        fi
    }

    # 配置SSHD
    configure_sshd() {
        local sshd_config="/etc/ssh/sshd_config"
        local needs_restart=false
        local backup_file="${sshd_config}.backup.$(date +%Y%m%d_%H%M%S)"
        
        # 检查是否有root权限
        if [ "$(id -u)" -ne 0 ]; then
            if command -v sudo >/dev/null 2>&1; then
                info "使用sudo获取权限..."
            else
                error "需要root权限且系统未安装sudo"
                return 1
            fi
        fi
        
        # 备份原配置文件
        info "备份当前SSH配置..."
        if [ -f "$sshd_config" ]; then
            if ! sudo cp "$sshd_config" "$backup_file" 2>/dev/null; then
                error "无法创建配置文件备份"
                return 1
            fi
            info "已创建SSH配置备份：$backup_file"
        else
            error "找不到SSH配置文件：$sshd_config"
            return 1
        fi
        
        # 配置PubkeyAuthentication
        if ! sudo grep -q "^PubkeyAuthentication yes" "$sshd_config" 2>/dev/null; then
            info "启用公钥认证..."
            sudo sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$sshd_config" 2>/dev/null
            needs_restart=true
        fi
        
        # 配置AuthorizedKeysFile
        if ! sudo grep -q "^AuthorizedKeysFile.*authorized_keys" "$sshd_config" 2>/dev/null; then
            info "配置授权密钥文件路径..."
            sudo sed -i 's/^#*AuthorizedKeysFile.*/AuthorizedKeysFile .ssh\/authorized_keys/' "$sshd_config" 2>/dev/null
            needs_restart=true
        fi
        
        # 配置StrictModes
        if ! sudo grep -q "^StrictModes yes" "$sshd_config" 2>/dev/null; then
            info "配置StrictModes..."
            sudo sed -i 's/^#*StrictModes.*/StrictModes yes/' "$sshd_config" 2>/dev/null
            needs_restart=true
        fi
        
        # 如果需要，重启SSH服务
        if [ "$needs_restart" = true ]; then
            info "重启SSH服务..."
            if command -v systemctl >/dev/null 2>&1; then
                # systemd系统（新版Ubuntu/Debian）
                if systemctl is-active --quiet ssh; then
                    sudo systemctl restart ssh
                elif systemctl is-active --quiet sshd; then
                    sudo systemctl restart sshd
                else
                    error "SSH服务未运行"
                    return 1
                fi
            elif command -v service >/dev/null 2>&1; then
                # 传统init.d系统（旧版Ubuntu/Debian）
                if service ssh status >/dev/null 2>&1; then
                    sudo service ssh restart
                elif service sshd status >/dev/null 2>&1; then
                    sudo service sshd restart
                else
                    error "SSH服务未运行"
                    return 1
                fi
            else
                error "无法找到可用的SSH服务管理命令"
                return 1
            fi
            
            if [ $? -eq 0 ]; then
                success "SSH服务已重启"
            else
                error "SSH服务重启失败"
                return 1
            fi
        else
            info "SSH配置已是最新，无需重启"
        fi
        
        return 0
    }

    # 获取公网IP
    get_public_ip() {
        local ip=""
        # 首先尝试获取本地IP
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        
        # 如果本地IP获取失败，尝试获取公网IP
        if [ -z "$ip" ]; then
            ip=$(curl -s https://api.ipify.org 2>/dev/null) || \
            ip=$(curl -s http://checkip.amazonaws.com 2>/dev/null) || \
            ip=$(curl -s https://api.ip.sb/ip 2>/dev/null) || \
            ip=$(curl -s https://ipinfo.io/ip 2>/dev/null)
        fi
        
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
        
        return 1
    }

    # 获取SSH端口
    get_ssh_port() {
        local port=""
        # 首先尝试从sshd_config获取端口
        if [ -f "/etc/ssh/sshd_config" ]; then
            port=$(sudo grep -E "^Port [0-9]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
        fi
        
        # 如果没有找到端口配置，使用默认端口22
        if [ -z "$port" ]; then
            port="22"
        fi
        
        echo "$port"
    }

    # 获取远程主机公网IP
    get_remote_public_ip() {
        local ip=""
        # 使用多个IP查询服务
        ip=$(curl -s https://api.ipify.org 2>/dev/null) || \
        ip=$(curl -s http://checkip.amazonaws.com 2>/dev/null) || \
        ip=$(curl -s https://api.ip.sb/ip 2>/dev/null) || \
        ip=$(curl -s https://ipinfo.io/ip 2>/dev/null)
        
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
        return 1
    }

    # 合并主机记录
    merge_host_record() {
        local current_host="$1"
        local current_time="$2"
        local current_ip="$3"
        local current_port="$4"
        local temp_file="${HOSTS_FILE}.tmp"
        local found=false
        
        # 创建临时文件
        : > "$temp_file"
        chmod 600 "$temp_file"
        
        # 如果主机列表文件不存在或为空，直接添加新记录
        if [ ! -f "$HOSTS_FILE" ] || [ ! -s "$HOSTS_FILE" ]; then
            printf "%s|%s|%s|%s|%s\n" "$current_host" "$current_time" "$current_ip" "$current_port" "$current_time" > "$HOSTS_FILE"
            chmod 600 "$HOSTS_FILE"
            return 0
        fi
        
        # 更新或添加主机记录
        while IFS='|' read -r host timestamp ip port last_test; do
            if [ -n "$host" ]; then
                if [ "$host" = "$current_host" ]; then
                    # 更新现有记录
                    printf "%s|%s|%s|%s|%s\n" "$current_host" "$current_time" "$current_ip" "$current_port" "$current_time" >> "$temp_file"
                    found=true
                else
                    # 保留其他主机记录
                    printf "%s|%s|%s|%s|%s\n" "$host" "$timestamp" "$ip" "$port" "$last_test" >> "$temp_file"
                fi
            fi
        done < "$HOSTS_FILE"

        # 如果是新主机，添加新记录
        if [ "$found" = false ]; then
            printf "%s|%s|%s|%s|%s\n" "$current_host" "$current_time" "$current_ip" "$current_port" "$current_time" >> "$temp_file"
        fi
        
        # 替换原文件
        mv "$temp_file" "$HOSTS_FILE"
        chmod 600 "$HOSTS_FILE"
        
        return 0
    }

    # 执行主程序
    main "$@"
