#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本需要以 root 权限运行。请使用 sudo 执行。"
    exit 1
fi

export LC_ALL=C
export LANG=C

DOWNLOAD_URL="https://github.com/anytls/anytls-go/releases/download/v0.0.8/anytls_0.0.8_linux_amd64.zip"
ZIP_FILE_NAME="anytls_0.0.8_linux_amd64.zip"
BINARY_NAME="anytls-server"
INSTALL_DIR="/usr/local/bin"
SERVICE_NAME="anytls.service"
SERVICE_FILE_PATH="/etc/systemd/system/${SERVICE_NAME}"
DEFAULT_PORT="8443"

check_and_install_dependency() {
    local cmd="$1"
    local package_name="$2"
    if ! command -v "$cmd" &> /dev/null; then
        echo "检测到 '$cmd' 命令未安装。"
        read -p "是否尝试自动安装 '$package_name'? (y/n): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            if command -v apt-get &> /dev/null; then
                echo "正在使用 apt-get 安装 '$package_name'..."
                apt-get update && apt-get install -y "$package_name"
            elif command -v yum &> /dev/null; then
                echo "正在使用 yum 安装 '$package_name'..."
                yum install -y "$package_name"
            elif command -v dnf &> /dev/null; then
                echo "正在使用 dnf 安装 '$package_name'..."
                dnf install -y "$package_name"
            else
                echo "无法确定包管理器。请手动安装 '$package_name' 后再运行脚本。"
                exit 1
            fi
            if ! command -v "$cmd" &> /dev/null; then
                 echo "安装 '$package_name' 失败。请手动安装后再运行脚本。"
                 exit 1
            fi
        else
            echo "请先安装 '$package_name' 后再运行脚本。"
            exit 1
        fi
    fi
}

echo "正在检查依赖..."
check_and_install_dependency "curl" "curl"
check_and_install_dependency "unzip" "unzip"
check_and_install_dependency "openssl" "openssl"
echo "依赖检查完成。"
echo ""

set -e

echo "开始安装 anytls-server..."
echo ""

TEMP_DOWNLOAD_DIR=$(mktemp -d)
echo "临时工作目录: ${TEMP_DOWNLOAD_DIR}"
cd "${TEMP_DOWNLOAD_DIR}"

echo "正在从 ${DOWNLOAD_URL} 下载 ${BINARY_NAME}..."
curl -L -o "${ZIP_FILE_NAME}" "${DOWNLOAD_URL}"
echo "下载完成。"
echo ""

echo "正在解压 ${ZIP_FILE_NAME}..."
unzip -o "${ZIP_FILE_NAME}"
if [ ! -f "${BINARY_NAME}" ]; then
    echo "错误：解压后未在当前目录找到 '${BINARY_NAME}' 文件。"
    echo "请检查ZIP包内容。解压后的文件列表："
    ls -l
    cd ..
    rm -rf "${TEMP_DOWNLOAD_DIR}"
    exit 1
fi
echo "解压完成，找到 ${BINARY_NAME}。"
echo ""

echo "正在将 ${BINARY_NAME} 安装到 ${INSTALL_DIR}/${BINARY_NAME}..."
mv "${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
echo "${BINARY_NAME} 安装完成并已设置执行权限。"
echo ""

CUSTOM_PORT=""
while true; do
    read -p "请输入 anytls 服务端口 (默认为 ${DEFAULT_PORT}): " INPUT_PORT
    if [ -z "$INPUT_PORT" ]; then
        CUSTOM_PORT="${DEFAULT_PORT}"
        echo "使用默认端口: ${CUSTOM_PORT}"
        break
    elif [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then
        CUSTOM_PORT="$INPUT_PORT"
        echo "使用自定义端口: ${CUSTOM_PORT}"
        break
    else
        echo "无效的端口号 '${INPUT_PORT}'。请输入 1-65535 之间的数字，或直接回车使用默认端口。"
    fi
done
echo ""

ANYTLS_PASSWORD=""
read -p "是否自动生成 anytls 密码? (y/n，默认为 y): " auto_gen_pass
if [[ "$auto_gen_pass" =~ ^[Nn]$ ]]; then
    while true; do
        read -s -p "请输入您的 anytls 密码: " ANYTLS_PASSWORD
        echo
        read -s -p "请再次输入密码以确认: " ANYTLS_PASSWORD_CONFIRM
        echo
        if [ "${ANYTLS_PASSWORD}" == "${ANYTLS_PASSWORD_CONFIRM}" ]; then
            if [ -z "${ANYTLS_PASSWORD}" ]; then
                echo "密码不能为空，请重新输入。"
            else
                break
            fi
        else
            echo "两次输入的密码不一致，请重新输入。"
        fi
    done
else
    ANYTLS_PASSWORD=$(openssl rand -base64 16)
    echo "已自动生成密码。"
fi
echo "您的 anytls 密码已设置。"
echo ""

echo "正在创建 systemd 服务文件 ${SERVICE_FILE_PATH}..."
cat <<EOF > "${SERVICE_FILE_PATH}"
[Unit]
Description=anytls-go proxy service
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${BINARY_NAME} -l 0.0.0.0:${CUSTOM_PORT} -p ${ANYTLS_PASSWORD}
Restart=on-failure
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=anytls-go

[Install]
WantedBy=multi-user.target
EOF
echo "systemd 服务文件创建完成。"
echo ""

echo "正在重载 systemd 守护进程..."
systemctl daemon-reload
echo "正在启用 anytls 服务以开机自启..."
systemctl enable "${SERVICE_NAME}"
echo "正在启动 anytls 服务..."
systemctl restart "${SERVICE_NAME}"

sleep 2
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo "anytls 服务已成功启动并正在运行。"
else
    echo "警告：anytls 服务可能未能成功启动。"
    echo "请稍后使用 'systemctl status ${SERVICE_NAME}' 和 'journalctl -u ${SERVICE_NAME}' 命令检查服务状态和日志。"
fi
echo ""

SERVER_IP=""
echo "正在尝试获取服务器公网IP地址..."
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me || curl -s --connect-timeout 5 ip.sb || curl -s --connect-timeout 5 whatismyip.akamai.com)

if [ -z "$SERVER_IP" ]; then
    echo "获取公网IP失败，尝试获取本地网络接口IP..."
    SERVER_IP=$(hostname -I | awk '{for(i=1;i<=NF;i++){if($i!="127.0.0.1" && $i!~/^::1$/ && $i!~/^fe80:/){print $i; exit}}}')
fi

if [ -z "$SERVER_IP" ]; then
    SERVER_IP="<无法自动获取,请手动填写>"
fi

echo "--------------------------------------------------"
echo " anytls-server 安装和配置完成！"
echo "--------------------------------------------------"
echo "请务必妥善保存以下连接信息："
echo ""
echo "  服务器 IP  : ${SERVER_IP}"
echo "  服务器端口 : ${CUSTOM_PORT}"
echo "  连接密码   : ${ANYTLS_PASSWORD}"
echo ""
echo "--------------------------------------------------"
echo "如果服务未成功启动，请检查日志："
echo "  systemctl status ${SERVICE_NAME}"
echo "  journalctl -u ${SERVICE_NAME}"
echo "--------------------------------------------------"
echo ""

echo "正在清理临时文件..."
cd ..
rm -rf "${TEMP_DOWNLOAD_DIR}"
echo "清理完成。"
echo ""

echo "一键安装脚本执行完毕。"
