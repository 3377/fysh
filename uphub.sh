#!/bin/bash

# 检查参数数量
if [ "$#" -ne 2 ]; then
    echo "用法: $0 <DockerHub用户名> <DockerHub密码>"
    exit 1
fi

# 从参数中获取用户名和密码
DOCKERHUB_USERNAME="$1"  # DockerHub用户名
DOCKERHUB_PASSWORD="$2"  # 密码
DOCKERHUB_REPO="drfyup"  # 仓库名称

# 显示本地所有镜像
echo "本地镜像列表："
docker images

# 获取最新的镜像信息
LATEST_IMAGE=$(docker images --format "{{.Repository}}:{{.Tag}}" | head -n 1)
LATEST_IMAGE_NAME=$(echo $LATEST_IMAGE | cut -d':' -f1)
LATEST_IMAGE_TAG=$(echo $LATEST_IMAGE | cut -d':' -f2)

# 交互式输入镜像信息，默认使用最新的镜像
echo -e "\n您可以使用 REPOSITORY 或 IMAGE ID 来指定镜像"
read -p "请输入要上传的镜像名称（REPOSITORY 或 IMAGE ID，默认为 $LATEST_IMAGE_NAME）: " IMAGE_NAME
IMAGE_NAME=${IMAGE_NAME:-$LATEST_IMAGE_NAME}  # 如果未输入，使用最新镜像名

# 输入本地镜像标签，默认使用最新镜像的标签
read -p "请输入本地镜像标签（TAG，默认为 $LATEST_IMAGE_TAG）: " IMAGE_TAG
IMAGE_TAG=${IMAGE_TAG:-$LATEST_IMAGE_TAG}  # 如果未输入，使用最新镜像标签

# 列出相同标签并询问要上传到 DockerHub 的镜像名称
read -p "请输入要上传到 DockerHub 的镜像名称（默认为 $IMAGE_NAME）: " UPLOAD_IMAGE_NAME
UPLOAD_IMAGE_NAME=${UPLOAD_IMAGE_NAME:-$IMAGE_NAME}  # 如果未输入，使用 IMAGE_NAME

# 列出要上传的标签，默认为相同标签
read -p "请输入要上传到 DockerHub 的新标签（默认为 $IMAGE_TAG，直接回车则使用相同标签）: " UPLOAD_TAG
UPLOAD_TAG=${UPLOAD_TAG:-$IMAGE_TAG}  # 如果未输入，使用 IMAGE_TAG

# 验证镜像是否存在
if ! docker image inspect "$IMAGE_NAME:$IMAGE_TAG" >/dev/null 2>&1; then
    echo "错误：找不到指定的镜像，请检查镜像名称和标签是否正确"
    exit 1
fi

# 登录到 DockerHub
echo "正在登录 DockerHub..."
echo "$DOCKERHUB_PASSWORD" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin

# 检查登录状态
if [ $? -ne 0 ]; then
    echo "DockerHub 登录失败，请检查用户名和密码"
    exit 1
fi

# 给镜像打标签
echo "正在给镜像打标签..."
docker tag "$IMAGE_NAME:$IMAGE_TAG" "$DOCKERHUB_USERNAME/$UPLOAD_IMAGE_NAME:$UPLOAD_TAG"

# 检查标签是否成功
if [ $? -ne 0 ]; then
    echo "镜像标签创建失败"
    exit 1
fi

# 推送镜像到 DockerHub
echo "正在推送镜像到 DockerHub..."
docker push "$DOCKERHUB_USERNAME/$UPLOAD_IMAGE_NAME:$UPLOAD_TAG"

# 检查推送状态
if [ $? -ne 0 ]; then
    echo "镜像推送失败"
    exit 1
fi

echo "镜像上传成功！"
echo "镜像已上传到: $DOCKERHUB_USERNAME/$UPLOAD_IMAGE_NAME:$UPLOAD_TAG"

# 自动清理本地标签（移除询问步骤）
echo "正在清理本地新建的标签..."
docker rmi "$DOCKERHUB_USERNAME/$UPLOAD_IMAGE_NAME:$UPLOAD_TAG"
echo "本地标签已清理"

# 登出 DockerHub
docker logout
