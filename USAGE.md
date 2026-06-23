# OCular 被动监控脚本使用说明

> **给 AI agent 的一句话任务指令**：你是终端取证分析员。请**只读**分析 `logs/ocular-monitor-<时间戳>/` 目录下的日志，严格按本文「第五节」的规则、重点与输出要求，产出一份 OCular 监控能力取证报告。结论必须绑定证据、区分证据强度、标明采集盲区；不得修改日志、不得干预 OCular、不得外发任何数据。

## 一、启动

```sh
# 1. 先缓存 sudo 凭证（避免后台 fs_usage 被挂起）
sudo -v

# 2. 启动监控
~/find-mtor/ocular-passive-monitor.sh
```

脚本启动后会提示 `Password:` —— 输入你的开机密码，出现 `Starting fs_usage (needs sudo)...` 即代表全部采集组件已就绪。

> **注意**：脚本会占用当前终端前台，不要关闭该终端窗口。
> 若想在后台保持，可用 `tmux` 或开一个新的终端标签来运行。

日志默认输出到：
```
~/find-mtor/logs/ocular-monitor-<日期时间>/
```

---

## 二、结束

在运行脚本的终端按 **Ctrl-C**。

脚本会自动清理所有后台进程（`log stream`、`fs_usage`），并打印日志目录路径。

---

## 三、日志结构

```
logs/ocular-monitor-<时间戳>/
├── tcc-snapshot.log    # 权限快照（谁有屏幕录制/完全磁盘/辅助功能）。auth_value：0=未授权 2=已授权
├── processes.log       # 每 5 秒的 OCular 进程列表（pgrep）
├── ps.log              # 每 5 秒的 CPU/内存/状态（看哪些 L* 组件在跑）
├── open-files.log      # OCular 打开的可疑文件（图片/.dat/临时目录）+ 被注入进程加载的 dylib
├── network.log         # OCular 进程的网络连接（5 秒快照，会漏瞬时连接，见 5.2）
├── unified-log.log     # 系统统一日志（截屏/OCular 相关事件；注意 tccd 误报，见 5.2）
└── fs-usage.log        # 实时文件操作（判断截屏落盘/历史采集的关键；可能有盲区，见 5.2）
```

> **注入检测线索**：`open-files.log` 里某个非-OCular 进程（如浏览器）加载了 `/usr/local/.OCular/dylib/*.dylib`，即表示它被 OCular 注入监控。关键注入库：`libdobby.dylib`、`libfunchookArm64.dylib`（hook 引擎）、`libSC.dylib`、`libDtSSLFrame64.dylib`（SSL/TLS 拦截/解 HTTPS）、`libDtActionFrame64.dylib`、`PMHooklib.dylib`、`ContentMatch.dylib`（DLP 内容匹配）。

---

## 四、分析：关键命令

### 4.1 有没有截图文件写入

```sh
D=~/find-mtor/logs/ocular-monitor-<时间戳>

# 有没有 ScreenShot / 图片文件被写
grep -iE 'ScreenShot|\.png|\.jpg|\.bmp' "$D/fs-usage.log"
```

### 4.2 OCular 做了哪些文件操作

```sh
# 所有 OCular 相关进程的文件读写
cat "$D/fs-usage.log" | head -100

# 只看写操作
grep -i 'WrData\|write\|mkdir\|rename\|create' "$D/fs-usage.log" | head -50
```

### 4.3 系统日志里有没有截屏事件

```sh
grep -iE 'ScreenCapture|CGDisplayStream|kTCCServiceScreenCapture' "$D/unified-log.log" | head -30
```

### 4.4 有没有对外网的连接

```sh
# 过滤掉本地回环，只看外网 IP
grep -E 'TCP|UDP' "$D/network.log" | grep -vE '127\.0\.0\.1|\*:\*' | sort -u | head -30
```

### 4.5 权限有没有变化

```sh
cat "$D/tcc-snapshot.log"
# 重点看：kTCCServiceScreenCapture 对应 com.tec-development.OCular 的 auth_value
# 0 = 未授权，2 = 已授权
```

---

## 五、交给 Agent 的日志分析规则（核心）

> 本节是给「任意 AI agent」的分析协议。把整个 `logs/ocular-monitor-<时间戳>/` 目录路径连同本说明一起交给它，它应当**只读分析**这些日志，按下面的规则、重点和输出要求产出报告。**不得修改、删除、上传任何文件，不得干预 OCular 进程。**

### 5.0 背景知识（分析前必须先建立的认知）

OCular（`com.tec-development.*` / `teclink`，安装在 `/usr/local/.OCular/`）是一套企业终端监控/DLP 套件。关键进程及职责：

| 进程 | 职责 |
|---|---|
| `OCular` | 主体常驻、调度 |
| `LAgent` / `LAgentUser` | 代理主程序 / 用户态代理 |
| `LMonitor` / `LMonitor2` | 行为监控（含读 TCC.db 判断截屏权限） |
| `LInject` | 向目标进程注入 hook 库 |
| `LSensitive` | 敏感内容/DLP 检测 |
| `LSDConfig` | 采集本地数据（如 Firefox 历史库 → `FirefoxHistory.dat`） |
| `LSDHelper` | 拥有完全磁盘访问/辅助功能权限的特权助手 |
| `LSGTransmit` | **数据上传器**（往服务端传采集结果） |
| `LVncMac` / `LVnctransfer` | 远程桌面/VNC（抓屏依赖屏幕录制权限） |
| `LWMHelper` / `OfficeWaterMark` | 水印 |

注入用的 hook 库在 `/usr/local/.OCular/dylib/`：`libdobby.dylib`、`libfunchookArm64.dylib`、`libSC.dylib`、`libDtSSLFrame64.dylib`（SSL/TLS 拦截）、`libDtActionFrame64.dylib`、`PMHooklib.dylib`、`ContentMatch.dylib`（DLP 匹配）等。**某浏览器/进程的 lsof 里出现这些 dylib = 它被注入监控。**

### 5.1 证据分级（防止误判，最重要）

分析时必须区分证据强度，并在报告中标注：

- **直接证据（可下定论）**：fs_usage 里真实的文件写入（如截图落盘、`*History.dat` 重写）；lsof 里进程实际加载了 `.OCular/dylib/*.dylib`；TCC.db 快照里的 `auth_value`。
- **间接证据（只能推断）**：进程在跑但没看到具体行为；network 快照里的连接（5 秒一次，可能漏掉瞬时连接）。
- **无关证据（必须排除）**：见下方「已知误报」。

### 5.2 已知误报与陷阱（务必排除，否则会得出错误结论）

1. **`kTCCServiceScreenCapture` 的 AUTHREQ 不等于 OCular 在截屏。**
   unified-log 里 `tccd ... service=kTCCServiceScreenCapture ... AUTHREQ` 的发起方要看 `msgID` 前缀的 pid：
   - `msgID=149.*` = **WindowServer/SkyLight**（系统）
   - `msgID=22875.*`（或当前 replayd 的 pid）= **replayd/ReplayKit**（系统）
   这些是系统进程，**不是 OCular**。只有当发起进程确属 OCular 系才算数。
2. **OCular 判断截屏权限是直接读 TCC.db**（在 LMonitor/LMonitor2 二进制里有 `SELECT ... kTCCServiceScreenCapture`），这个动作**不会出现在 tccd 日志**里。所以「tccd 没有 OCular 的截屏请求」≠「OCular 不关心截屏」。以 TCC.db 快照里的 `auth_value` 为准。
3. **fs_usage 可能有覆盖盲区**：`fs_usage` 后台运行时若 sudo 凭证过期会被 SIGTTOU 挂起而静默停止。**分析前必须先核对 `fs-usage.log` 的最后一条时间戳 vs 采集结束时间**，确认它实际覆盖了多长窗口，并在报告里写明「fs_usage 仅覆盖前 X 分钟」。在未覆盖的时间里「没有截图落盘」**不能下结论**。
4. **network.log 是 5 秒一次的 lsof 快照**，`LSGTransmit` 这类批量上传是短时连接，极可能落在两次快照之间被漏掉。**「快照里没看到外联」≠「从未外传」**，只能说「采集窗口内未捕获到外联」，要下定论需 tcpdump 抓包。

### 5.3 分析重点（按优先级，逐项给结论）

| 优先级 | 关注能力 | 怎么判定 |
|---|---|---|
| P0 | **截屏 / 录屏** | TCC `kTCCServiceScreenCapture` 的 auth_value；fs_usage 有无 `.png/.jpg/ScreenShot` 落盘；unified-log 有无**确属 OCular** 的 `CGDisplayStream/SCStream`；`LVncMac/LVnctransfer` 是否在跑 |
| P0 | **数据外传去向** | network.log 里 OCular 系进程的 ESTABLISHED 外网 IP/端口；`LSGTransmit` 的连接对端；（窗口内无 → 标注「未捕获」并建议抓包） |
| P1 | **浏览器监控** | 对每个浏览器进程 lsof，看是否加载 `.OCular/dylib/*.dylib`（注入）；fs_usage 看 `*History.dat` 本地采集。**逐浏览器给出 注入/本地采集/未监控**（已知：Chrome/Safari/Electron=注入，Firefox=本地读库，Edge=未监控——需每次复核） |
| P1 | **键盘/输入监控** | TCC 的 `kTCCServiceAccessibility`、`kTCCServicePostEvent` 授权；相关进程是否持有 |
| P2 | **文件/剪贴板 DLP** | `LSensitive`、`ContentMatch.dylib` 活动；fs_usage 里对用户文档的读取 |
| P2 | **权限全貌** | tcc-snapshot.log 里所有 `com.tec-development.*` / OCular 系组件的授权项 |
| P2 | **进程存活** | ps.log 里哪些 L* 组件在跑、CPU/内存、是否有 LWatchDog 守护 |

### 5.4 输出内容要求（报告必须包含以下结构）

1. **采集元信息**：采集起止时间、总时长；**每个日志文件的实际覆盖窗口**（尤其 fs_usage 的盲区），以及由此带来的置信度说明。
2. **结论摘要表**：对 5.3 每项能力给一行，状态仅限以下四种（禁止自创），依据 **≤ 25 字**：

   | 状态 | 精确含义 |
   |---|---|
   | `✅ 已确认` | 有直接证据（fs_usage 写入 / lsof 加载 dylib / TCC auth_value）|
   | `❌ 未检出` | 采集窗口内无证据（≠ 肯定未发生，受覆盖范围限制）|
   | `⚠️ 具备·受限` | 具备该能力，但当前权限阻断其执行 |
   | `❓ 无法判断` | 采集方式覆盖不到，须补采才能定论 |

   输出格式（Markdown 表格）：`| 优先级 | 能力 | 状态 | 依据 |`
3. **证据明细**：每条结论后面附**可复现的证据**——日志文件名 + 关键行/时间戳，或可重跑的 grep 命令。直接证据与间接证据分开标注（见 5.1）。
4. **浏览器监控矩阵**：逐浏览器列出「是否被监控 / 机制（注入 or 本地读库）/ 证据」。
5. **采集盲区与未决项**：明确写出哪些问题因为采集方式受限**无法下定论**（如外传去向需抓包），并给出补采建议。
6. **风险提示**：当前被权限挡住、但一旦授权即可启用的能力（如截屏）。

### 5.5 分析纪律

- 结论必须**绑定证据**，禁止臆测；拿不准就标 `❓ 无法判断` 而不是猜。
- 发现与历史结论冲突时，**以日志为准**并明确指出修正了哪条旧结论。
- 不确定证据强度时，宁可下调（间接/数据不足），不可夸大。
- 全程**只读**：不修改日志、不触碰 OCular、不外发任何数据。

---

## 六、常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| `fs-usage.log` 为空 / 0 字节 | sudo 凭证过期，fs_usage 后台被挂起 | 重新 `sudo -v` 后手动补起（见下） |
| `unified-log.log` 只有一行报错 | zsh 内置 `log` 命令覆盖了 `/usr/bin/log`（已修复） | 已使用绝对路径，无需处理 |
| `network.log` 噪音多 | lsof 无 `-a` 参数时是 OR 语义（已修复） | 已用 `lsof -a -i -p` |

### 手动补起 fs_usage（若中途失效）

```sh
D=~/find-mtor/logs/ocular-monitor-<时间戳>
targets='OCular|LAgent|LAgentUser|LMonitor|LMonitor2|LInject|LSensitive|LSDHelper|LVnctransfer|LWMHelper'

sudo -v   # 先刷新凭证
sudo -n fs_usage -w -f filesys 2>/dev/null \
  | rg --line-buffered -i "$targets|/\.OCular/|ScreenShot" \
  >> "$D/fs-usage.log" 2>&1 &
echo "fs_usage pid=$!"
```

---

## 七、注意事项

- 脚本**只读不改**，不会干扰 OCular 运行，完全被动。
- `fs_usage` 需要 root，建议采集前先 `sudo -v`。
- 建议**至少跑 10–30 分钟**，期间正常使用电脑，截屏行为可能是周期性的。
- 终端需要**完全磁盘访问权限**才能读 TCC.db；若读不到会在启动时有警告。
