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

# 交互式输入镜像信息
echo -e "\n您可以使用 REPOSITORY 或 IMAGE ID 来指定镜像"
read -p "请输入要上传的镜像名称（REPOSITORY 或 IMAGE ID）: " IMAGE_NAME

# 输入本地镜像标签，默认值为 latest
read -p "请输入本地镜像标签（TAG，默认为 latest）: " IMAGE_TAG
IMAGE_TAG=${IMAGE_TAG:-latest}  # 如果未输入，使用 latest

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

# 询问是否清理本地标签
read -p "是否清理本地新建的标签？(y/n): " CLEAN_TAG
if [ "$CLEAN_TAG" = "y" ] || [ "$CLEAN_TAG" = "Y" ]; then
    docker rmi "$DOCKERHUB_USERNAME/$UPLOAD_IMAGE_NAME:$UPLOAD_TAG"
    echo "本地标签已清理"
fi

# 登出 DockerHub
docker logout
