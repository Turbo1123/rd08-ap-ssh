# RD08 / BE6500 Pro：持久化 SSH 管理通道

给小米 RD08（BE6500 Pro，固件 1.1.96，release 通道，有线 AP 模式）装一套**重启不掉的、仅公钥、仅内网**的 SSH 管理通道。

> **本仓库分两部分**：
>
> 1. **取得 root**（仅 ≤ 1.1.96）：见 [安全公告第 3 节](docs/advisory-2026-11-01-rd08-auth-rce.md#3-复现196)，
>    或完整的 [从零开始的分步教程](docs/guide-full-root.md)，含登录取 token、注入、装 dropbear、持久化、验证；
> 2. **root 之后的固化**：本 README 与 `scripts/`，让 SSH 重启不掉。
>
> ⚠️ **安全公告**：RD08 固件 **≤ 1.1.96** 存在认证后命令注入（`set_macfilter_rules` 的 `name` 参数），
> 已在 **1.1.123** 修复（路由被移除）。如果你还在这两个版本之间，**请先升级并自查**，
> 详见 [docs/advisory-2026-11-01-rd08-auth-rce.md](docs/advisory-2026-11-01-rd08-auth-rce.md)。
>
> 请只在自己的设备上使用。

---

## 1. 为什么原厂 SSH 用不了

两个坑叠在一起：

1. **原厂 dropbear 被 release 通道关掉**
   `/etc/init.d/dropbear` 的 `start_service()` 里判断：

   ```sh
   flg_ssh=`nvram get ssh_en`
   channel=`uci get /usr/share/xiaoqiang/xiaoqiang_version.version.CHANNEL`
   if [ "$flg_ssh" != "1" -o "$channel" = "release" ]; then
       return 0
   fi
   ```

   只要通道是 `release`，就算打开 `ssh_en` 也不会起。

2. **文件系统不配合**
   - `/`、`/root` 是 squashfs **只读**，`mkdir /root/.ssh` 直接报 `Read-only file system`
   - `/etc` 是 **ramfs**，重启就被原厂重新铺一遍，放进去的 `authorized_keys` 必然丢

所以「手动起一个 dropbear」只能撑到下次重启。

## 2. 设备文件系统速查

| 路径 | 类型 | 是否持久 | 说明 |
|---|---|---|---|
| `/` | squashfs | 只读 | 固件本体 |
| `/root` | squashfs | 只读 | 不能放 `.ssh` |
| `/etc` | ramfs | ❌ 重启丢 | 原厂每次启动重铺 |
| `/etc/config` | sec_cfg 卷 | ✅ 持久 | uci 配置 |
| `/etc/crontabs` | sec_cfg 卷 | ✅ 持久 | cron 表 |
| `/data` | ubifs | ✅ 持久 | 放我们的东西 |
| `/tmp` | tmpfs | ❌ | pid、临时文件 |

结论：**能存东西的只有 `/data` 和 `/etc/config`、`/etc/crontabs`；能自动执行的只有 cron。**

## 3. 方案

```
cron（每分钟）
  └─ /data/admin-ssh/start-ssh.sh
       ├─ 重建 /etc/dropbear/authorized_keys -> /data/admin-ssh/authorized_keys
       ├─ 查 /proc/net/tcp：22222 已 LISTEN ？→ 退出
       └─ 否则拉起 dropbear（仅公钥、禁转发、只绑 LAN）
```

- 密钥、hostkey、看门狗脚本都放 `/data/admin-ssh`（持久）
- `/etc/dropbear/authorized_keys` 只是软链，每分钟由看门狗重建，ramfs 丢不丢无所谓
- 存活判断用内核 socket 状态，不用 pid 文件（dropbear 退出时会 unlink pidfile，靠 pid 文件判断有竞态）

## 4. 安装

把公钥和脚本传到设备上，然后：

```sh
# 设备上，root 身份
AP_IP=192.168.1.10 \
PUBKEY_FILE=/tmp/id_ed25519.pub \
sh scripts/install.sh
```

安装脚本会：

1. 建 `/data/admin-ssh`，写入 `authorized_keys`（600）
2. 生成 3072 位 RSA hostkey（`dropbearkey`）
3. 用模板生成 `start-ssh.sh`（把 `AP_IP`、`PORT` 填进去）
4. 向 `/etc/crontabs/root` 追加一行（已存在则跳过），并 `touch /etc/crontabs`
5. 立刻执行一次看门狗

> **坑**：busybox crond 只在**目录** mtime 变化时重读 crontab。
> 直接 append 文件不会生效，必须 `touch /etc/crontabs` 或 `/etc/init.d/cron restart`。

## 5. 客户端

`~/.ssh/config`：

```
Host rd08-ap
    HostName 192.168.1.10
    Port 22222
    User root
    IdentityFile ~/.ssh/id_ed25519
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
```

或直接：

```sh
ssh -i ~/.ssh/id_ed25519 -p 22222 \
    -o HostKeyAlgorithms=+ssh-rsa \
    -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    root@192.168.1.10
```

**为什么必须放开 `+ssh-rsa`**：该固件的 dropbear 是 2017.75，编译时只带 RSA，且只支持 `ssh-rsa`（SHA1 签名）。新版 OpenSSH 默认禁用，不放开会直接
`no matching host key type`。仅内网使用可以接受；不要把这个端口暴露到公网。

## 6. 验证

见 [docs/verification.md](docs/verification.md)，两个必做测试：

- **杀进程自愈**：`killall dropbear`，60 秒内端口应重新监听
- **重启不掉**：`reboot`，记录端口恢复耗时（本机实测约 +95 秒），并确认
  `/etc/dropbear/authorized_keys` 软链的 mtime 是重启后的时间

## 7. 回滚

```sh
sed -i '/admin-ssh\/start-ssh.sh/d' /etc/crontabs/root
touch /etc/crontabs
killall dropbear
rm -rf /data/admin-ssh
```

## 8. 已知限制

| 限制 | 说明 |
|---|---|
| 重启后最长 60 秒无 SSH | cron 每分钟才检查一次；网页管理不受影响 |
| 只有 RSA / ssh-rsa | dropbear 2017.75 未编译 ECC，只能 SHA1 签名 |
| 固件升级会清掉 | 升级或恢复出厂会重置 `/data` 与 crontab，需重装 |
| 只绑 LAN IP | `-p $AP_IP:$PORT`，换 IP 需改脚本 |

## 9. 安全默认值

- `-s`：禁用所有密码登录（只认公钥）
- `-g`：禁用 root 密码登录（双保险）
- `-j -k`：禁用本地/远程端口转发
- `-T 3`：最多 3 次认证尝试
- 监听地址固定为 LAN IP，不监听 `0.0.0.0`

## 10. 目录

```
scripts/install.sh               安装脚本
scripts/start-ssh.sh.template    看门狗模板
scripts/apssh                    客户端快捷脚本
docs/verification.md             验证步骤
docs/advisory-2026-11-01-rd08-auth-rce.md   安全公告（≤1.1.96 受影响，1.1.123 修复）
```

## License

[MIT](LICENSE) —— 随便用、随便改、随便商用，保留版权声明即可。

### 合法使用声明

本仓库仅用于**自有设备**或**已获书面授权**的设备的安全测试与运维。

- 在未获授权的设备上使用本仓库的任何内容，属于未授权访问，可能违反《网络安全法》《刑法》第 285 条等法律法规；
- 许可证不构成对违法行为的授权，也无法豁免法律责任；
- 使用前请确认固件版本：**≤ 1.1.96 存在已公开的认证后命令注入，请先升级到 1.1.123**（见 [安全公告](docs/advisory-2026-11-01-rd08-auth-rce.md)）。
