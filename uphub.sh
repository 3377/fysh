#!/bin/bash

# 定义固定变量
DOCKERHUB_USERNAME="drfyup"  # DockerHub用户名，不要包含@qq.com
DOCKERHUB_PASSWORD="你的dockerhub密码"

# 显示本地所有镜像
echo "本地镜像列表："
docker images

# 交互式输入镜像信息
echo -e "\n您可以使用 REPOSITORY 或 IMAGE ID 来指定镜像"
read -p "请输入要上传的镜像名称（REPOSITORY 或 IMAGE ID）: " IMAGE_NAME
read -p "请输入本地镜像标签（TAG）: " IMAGE_TAG

# 从IMAGE_NAME中提取默认仓库名
# 如果IMAGE_NAME包含/，取最后一部分；否则直接使用IMAGE_NAME
DEFAULT_REPO=$(echo "$IMAGE_NAME" | awk -F'/' '{print $NF}')

# 输入目标仓库信息
read -p "请输入要上传到 DockerHub 的仓库名称（直接回车使用：$DEFAULT_REPO）: " UPLOAD_REPO
read -p "请输入要上传到 DockerHub 的标签（直接回车使用：$IMAGE_TAG）: " UPLOAD_TAG

# 设置默认值
if [ -z "$UPLOAD_REPO" ]; then
    UPLOAD_REPO=$DEFAULT_REPO
    echo "将使用本地镜像名称作为仓库名: $UPLOAD_REPO"
fi

if [ -z "$UPLOAD_TAG" ]; then
    UPLOAD_TAG=$IMAGE_TAG
    echo "将使用本地标签: $IMAGE_TAG"
fi

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
docker tag "$IMAGE_NAME:$IMAGE_TAG" "$DOCKERHUB_USERNAME/$UPLOAD_REPO:$UPLOAD_TAG"

# 检查标签是否成功
if [ $? -ne 0 ]; then
    echo "镜像标签创建失败"
    exit 1
fi

# 推送镜像到 DockerHub
echo "正在推送镜像到 DockerHub..."
docker push "$DOCKERHUB_USERNAME/$UPLOAD_REPO:$UPLOAD_TAG"

# 检查推送状态
if [ $? -ne 0 ]; then
    echo "镜像推送失败"
    exit 1
fi

echo "镜像上传成功！"
echo "镜像已上传到: $DOCKERHUB_USERNAME/$UPLOAD_REPO:$UPLOAD_TAG"

# 询问是否清理本地标签
read -p "是否清理本地新建的标签？(y/n): " CLEAN_TAG
if [ "$CLEAN_TAG" = "y" ] || [ "$CLEAN_TAG" = "Y" ]; then
    docker rmi "$DOCKERHUB_USERNAME/$UPLOAD_REPO:$UPLOAD_TAG"
    echo "本地标签已清理"
fi

# 登出 DockerHub
docker logout
