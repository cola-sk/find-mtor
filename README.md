# find-mtor

macOS 上用于 OCular 的被动监控与证据采集脚本。

本仓库提供一个只读监控脚本，用于采集 OCular 相关组件的进程、文件系统、网络连接、系统统一日志和 TCC 权限证据。采集到的日志用于后续取证分析；脚本不会修改 OCular 状态。

## 快速开始

```sh
# 先缓存 sudo 凭证，避免后台 fs_usage 启动失败或被挂起。
sudo -v

# 启动被动监控。
~/find-mtor/ocular-passive-monitor.sh
```

监控启动后，脚本会在控制台输出当前设备本地时间、日志目录和停止方式。按 `Ctrl-C` 结束监控。

也可以指定自定义输出目录：

```sh
~/find-mtor/ocular-passive-monitor.sh /path/to/output-dir
```

## 输出目录

默认日志目录：

```txt
~/find-mtor/logs/ocular-monitor-<时间戳>/
```

脚本会写入以下日志：

- `tcc-snapshot.log`：用户和系统 TCC 权限快照。
- `processes.log`：OCular 相关进程快照。
- `ps.log`：CPU、内存、状态和运行时长快照。
- `open-files.log`：可疑打开文件，以及进程加载的 OCular dylib。
- `network.log`：OCular 相关 socket 快照。
- `unified-log.log`：相关 macOS unified log 事件。
- `fs-usage.log`：来自 `fs_usage` 的文件系统活动。

结束监控时，脚本会清理后台采集进程，并输出总运行时长，格式为 `xh ymin`。

## 分析说明

完整采集说明、分析命令、已知误报、证据分级规则和报告结构见 [USAGE.md](./USAGE.md)。

关键约束：

- `network.log` 是周期性快照，短连接可能漏捕。
- 下结论前必须核对 `fs-usage.log` 的实际覆盖窗口。
- 每条结论都必须绑定具体日志证据。
- 分析过程保持只读：不修改日志、不干预 OCular 进程、不改动采集产物。

## 运行要求

- macOS。
- `zsh`。
- `sqlite3`。
- 可使用 `sudo`，用于读取系统 TCC 和运行 `fs_usage`。
- 推荐安装 `ripgrep`（`rg`）；未安装时脚本会回退到 `grep -E`。

