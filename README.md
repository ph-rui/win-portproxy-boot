# win-portproxy-boot

让 Windows 的 `netsh interface portproxy` 规则在**开机后真正生效**。

适用于这种典型症状：

```text
> netsh interface portproxy show all
侦听 ipv4:                 连接到 ipv4:
地址            端口        地址            端口
--------------- ----------  --------------- ----------
192.168.90.251  40001       172.16.66.48    40001     ← 规则都在
192.168.90.251  7890        172.16.66.48    7890
```

规则一条不少，但**端口就是不通**；手动删掉再加一遍，或者重启 `IP Helper` 服务，又恢复正常。

## 为什么会这样

1. portproxy 规则是持久化的，存在注册表
   `HKLM\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp`，由 **IP Helper (`iphlpsvc`)** 服务在开机时加载。
2. 开机时 `iphlpsvc` 往往比网卡/IP 就绪得更早。此时它去绑定 `listenaddress` 会失败，而**失败是静默的**：规则照样留在表里（所以 `show` 能看到），但没有监听 socket，流量自然不通。
3. 关键坑：**对已存在的规则再执行 `netsh ... add` 是空操作**，不会重新绑定 socket。所以"开机时把规则再下发一遍"这种常见做法完全无效，必须 `delete` + `add`，或者重启 `iphlpsvc`。

本项目就是把第 3 点做成一个开机任务自动兜底。

## 它做什么

`ApplyPortProxy.ps1` 的执行流程：

1. 从注册表读出所有 `v4tov4` 规则
2. **轮询等待规则里的 `listenaddress` 真正出现在本机网卡上**（默认最多 5 分钟）
3. 下发规则
4. 逐条校验是否真的有 `LISTENING` socket
5. 缺监听的规则 → `delete` + `add`，最多重试 8 轮
6. 仍然不行 → 重启 `iphlpsvc` 再修一轮，最多 4 轮
7. 写日志，并在脚本目录生成 `rules_backup.txt`（可直接粘贴执行的一串 `netsh add` 命令）

规则列表每次都从注册表读，所以你平时照常用 `netsh` 增删规则即可，不需要改脚本。

`Install-BootTask.ps1` 注册的计划任务：

| 项目 | 值 |
|---|---|
| 任务名 | `PortProxyBoot`（可用 `-TaskName` 改） |
| 运行身份 | `NT AUTHORITY\SYSTEM`，最高权限 |
| 触发 | 系统启动后 20 秒（可用 `-Delay` 改） |
| 失败重试 | 3 次，间隔 1 分钟 |
| 超时 | 20 分钟 |

## 安装

用**管理员** PowerShell 在本目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-BootTask.ps1
```

安装完会立刻跑一次 `ApplyPortProxy.ps1`，不重启也能生效。

## 验证

看日志 `apply_log.txt`（脚本同目录），每条规则一行：

```text
2026-10-28 10:29:44 local ips ready: 172.16.66.163,192.168.90.251
2026-10-28 10:29:44 LISTENING     192.168.90.251:40001 -> 172.16.66.48:40001
2026-10-28 10:29:44 NOT-LISTENING 192.168.90.251:7890  -> 172.16.66.48:7890
2026-10-28 10:29:44 === apply done ===
```

手动跑一次（不重启）：

```powershell
powershell -ExecutionPolicy Bypass -File .\ApplyPortProxy.ps1
```

查看任务（**必须用管理员**，`SYSTEM` 任务的 ACL 对普通用户不可读，普通身份打开任务计划程序会"看不到这个任务"）：

```powershell
Get-ScheduledTask PortProxyBoot | Format-List TaskName,State
Get-ScheduledTaskInfo PortProxyBoot
```

## 卸载

任务删除，规则保留：

```powershell
powershell -ExecutionPolicy Bypass -File .\Uninstall-BootTask.ps1
```

## 注意事项

- 脚本按**注册表里的规则**工作，`listenaddress` 建议是本机固定 IP。如果用的是 DHCP 且地址变了，日志里会出现 `WARN local ip still missing`，需要改规则里的 `listenaddress`。
- 需要管理员权限：`netsh portproxy` 写操作本身要求提权。
- 恢复路径里会短暂 `delete` 规则；规则值会先读进内存并写到 `rules_backup.txt`，`add` 失败会在日志里记录 `add failed`。
- 退出码：全部规则 `LISTENING` 为 `0`，否则为 `1`。
- 在 Windows 10 / Server 2019 上验证（`iphlpsvc` + `netsh` 行为自 Vista 起一致）。

## 文件说明

| 文件 | 说明 |
|---|---|
| `ApplyPortProxy.ps1` | 核心逻辑：等待 IP → 下发 → 校验 → 修复 → 记录 |
| `Install-BootTask.ps1` | 注册开机计划任务（SYSTEM，启动后 20 秒） |
| `Uninstall-BootTask.ps1` | 删除计划任务 |
| `rules_backup.txt` | 运行时生成，当前规则的 `netsh add` 命令备份 |

## 许可

未指定 License。如需开源授权请自行添加（例如 MIT）。
