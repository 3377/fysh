#!/bin/bash

# 更新系统包列表
echo "正在更新系统..."
apt-get update

# 安装必要的依赖包
echo "安装依赖包..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# 添加 Docker 的官方 GPG 密钥
echo "添加 Docker 官方 GPG 密钥..."
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# 设置 Docker 稳定版仓库
echo "添加 Docker 仓库..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 更新包索引
echo "更新包索引..."
apt-get update

# 安装 Docker Engine
echo "安装 Docker..."
apt-get install -y docker-ce docker-ce-cli containerd.io

# 安装 Docker Compose
echo "安装 Docker Compose..."
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 启动 Docker 服务
echo "启动 Docker 服务..."
systemctl start docker
systemctl enable docker

# 验证安装
echo "验证安装..."
docker --version
docker-compose --version

echo "Docker 和 Docker Compose 安装完成！"
