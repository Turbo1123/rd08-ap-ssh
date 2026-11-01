# 验证：确认这套 SSH 真的"重启不掉"

两个测试都做，缺一不可。第二个才是重点。

## 测试 1：杀进程，看是否自愈

```sh
# 设备上
killall dropbear
```

然后在电脑上每隔 5 秒探一次：

```sh
for i in $(seq 1 24); do
  sleep 5
  nc -z -G 2 <AP_IP> 22222 && { echo "恢复，用时约 $((i*5))s"; break; }
done
```

预期：**60 秒内恢复**（取决于 cron 的整分钟节拍）。

如果没恢复，按顺序查：

```sh
cat /etc/crontabs/root | grep start-ssh     # 行在不在
ps | grep "[c]rond"                          # crond 在不在跑
sh -x /data/admin-ssh/start-ssh.sh           # 手动跑，看卡在哪
```

## 测试 2：重启，看是否自动回来

```sh
# 设备上
reboot
```

电脑上同时记两件事：

```sh
# 1) 端口恢复时间
date; while ! nc -z -G 2 <AP_IP> 22222; do sleep 5; done; date

# 2) 恢复后立刻确认软链是"新"的（mtime 应为重启之后）
ssh ... 'uptime; ls -l /etc/dropbear/authorized_keys'
```

预期：

- 端口在 **90 秒左右**恢复（固件启动 + cron 第一个节拍）
- `uptime` 显示 1~2 分钟
- `/etc/dropbear/authorized_keys` 的 mtime 是**重启后**的时间 —— 证明软链是看门狗重建的，
  而不是重启前的残留（这一点最能说明 `/etc` 是 ramfs、方案确实生效）

## 恢复后的自检

```sh
id                                   # uid=0
netstat -ltnp | grep 22222           # 只有一个 LISTEN
ps | grep "[d]ropbear"               # 主进程 + 当前会话子进程
```
