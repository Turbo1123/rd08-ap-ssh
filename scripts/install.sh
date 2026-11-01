#!/bin/sh
# RD08 / BE6500 Pro: 安装持久化 dropbear（仅公钥、仅 LAN、仅内网）
#
# 在已 root 的设备上执行：
#   AP_IP=192.168.1.10 PUBKEY_FILE=/tmp/id_ed25519.pub sh install.sh
#
# 依赖：dropbearkey / dropbear / cron 均为固件自带
set -eu

AP_IP=${AP_IP:?请设置 AP_IP（设备 LAN 地址）}
PUBKEY_FILE=${PUBKEY_FILE:?请设置 PUBKEY_FILE（公钥路径）}
PORT=${PORT:-22222}
BASE=${BASE:-/data/admin-ssh}
TPL=${TPL:-$(dirname "$0")/start-ssh.sh.template}

umask 077

[ "$(id -u)" = 0 ] || { echo "需要 root 执行"; exit 1; }
[ -s "$PUBKEY_FILE" ] || { echo "公钥不存在: $PUBKEY_FILE"; exit 1; }
[ -f "$TPL" ] || { echo "模板不存在: $TPL"; exit 1; }

# 已有目录但不是本脚本建的，拒绝覆盖
if [ -e "$BASE" ] && [ ! -f "$BASE/managed-rd08" ]; then
    echo "$BASE 已存在且非本脚本管理，拒绝覆盖"
    exit 1
fi

mkdir -p "$BASE/backup"
stamp=$(date +%Y%m%d-%H%M%S)

# 1) 公钥（只认这一把）
cp "$PUBKEY_FILE" "$BASE/authorized_keys"
chmod 600 "$BASE/authorized_keys"

# 2) hostkey
if [ ! -s "$BASE/dropbear_rsa_host_key" ]; then
    dropbearkey -t rsa -s 3072 -f "$BASE/dropbear_rsa_host_key" >/dev/null
fi
chmod 600 "$BASE/dropbear_rsa_host_key"

# 3) 看门狗（把 IP/PORT 固化进脚本）
sed -e "s/@AP_IP@/$AP_IP/g" -e "s/@PORT@/$PORT/g" "$TPL" > "$BASE/start-ssh.sh"
chmod 700 "$BASE/start-ssh.sh"

# 4) crontab：幂等追加
if ! grep -q "$BASE/start-ssh.sh" /etc/crontabs/root; then
    cp -p /etc/crontabs/root "$BASE/backup/crontab-root.before-$stamp"
    printf '%s\n' "* * * * * $BASE/start-ssh.sh >/dev/null 2>&1" >> /etc/crontabs/root
    touch /etc/crontabs      # busybox crond 只在目录 mtime 变化时重读
fi

# 5) 标记 + 立刻跑一次
: > "$BASE/managed-rd08"
"$BASE/start-ssh.sh" || true
sleep 1

echo "---"
if netstat -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "OK: dropbear 正在 $AP_IP:$PORT 监听"
else
    echo "WARN: 端口未监听，手动执行 $BASE/start-ssh.sh 看错误"
fi
echo "客户端: ssh -p $PORT root@$AP_IP"
