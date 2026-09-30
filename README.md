# zcode-token-meter

ZCode 的 token 用量置顶悬浮窗：按可调速率（默认 2s）只读轮询 `~/.zcode/cli/db/db.sqlite`，实时显示 TTFT、解码速度、上下文占用与累计 token。独立进程，不依赖、不影响 ZCode 客户端本体。

## 跟随 ZCode 启停（默认开启，无需手动启动）

- **启动**：token-meter 插件的 `overlay-launch.mjs` 挂在 SessionStart / UserPromptSubmit 上，发现悬浮窗没在跑（查 `~/.zcode/zcode-token-meter.json` 里的 pid）就 detached 拉起一次，幂等。
- **关闭**：悬浮窗每 5s 探测 `ZCode.exe`，连续两次探测不到即自动退出（约 10s 后消失）。
- **窗口停靠（owner.ps1 常驻守护）**：
  - **位置跟随**：悬浮窗保持相对 ZCode 主窗口的偏移（WinEvent 实时监听移动/缩放），且始终钳制在 ZCode 窗口矩形内（6px 边距）——像应用内嵌面板；手动拖动即更新偏移
  - **层级（owned window）**：悬浮窗绑定为 ZCode 主窗口的 owned window——永远在宿主上方、被其他窗口一起盖住、最小化自动隐藏，全部系统原生语义、零轮询零拉锯；ZCode 重建窗口时守护自动重绑。**注意**：不要用 insertAfter 插到"ZCode 正上方"的槽位——某些隐形全屏窗（如 OP.GG）占据该槽并吞掉插入者的渲染。仅两处主动隐藏：ZCode 最小化、主窗口消失（更新交接等）
  - **更新/换代保护**：ZCode 主窗口消失约 1.2s（更新交接、进托盘、关闭）自动隐藏，回来即恢复；更新器的强制升级弹窗（模态小窗）不会被误认为主窗口（按 owner 关系 + 尺寸双重过滤），悬浮窗也不会盖在更新按钮上
  - 层级为置顶窗；开关：`ZCODE_TOKEN_METER_OVERLAY_ZORDER=0`（退回独立置顶、无停靠）。已知边界：ZCode 在前台但停留在非对话页面（设置等）时仍会显示——页面路由从进程外部不可探测（窗口标题/菜单恒定、UIA 树未启用），如需精确可给 ZCode 加 `--remote-debugging-port` 走 CDP
- 手动启动仍可用：`npm start`。关闭跟随：环境变量 `ZCODE_TOKEN_METER_OVERLAY=0`（hook 不再拉起）或 `ZCODE_TOKEN_METER_OVERLAY_FOLLOW=0`（悬浮窗不再自动退出）。
- 已知边界：pid 复用极端情况下会误判"已在跑"，重启 ZCode 会话即可恢复。

## 字号与窗口自适应

- **分辨率自适应**：以 1920x1080 为 1.0 基准按所在屏工作区比例自动缩放（比例 <1.15 视为 1，1080p 级屏幕保持不变；上限 1.6、下限 0.75），拖到分辨率不同的显示器自动重算；与用户字号倍率相乘生效
- 三种调法：标题行 **Aa 按钮**循环预设（85%/100%/115%/130%）、**Ctrl+滚轮**连续缩放（75%–160%）、**右键菜单**选预设。
- 窗口宽度随字号等比缩放，高度由渲染层实测内容高度自动适配（数据态/等待态高度不同也跟着变），并自动夹回屏幕工作区内。
- 字号持久化在 `~/.zcode/zcode-token-meter.json` 的 `scale`。

## 显示内容（默认 260x~168，随内容/字号自适应）

- **解码 tok/s（本轮）**：当前轮所有已完成请求的合并解码速度，与 turn-summary.mjs 同口径（output / Σ(duration−ttft)）
- **空闲自适应轮询**：每 tick 先 stat db.sqlite/-wal/-shm 的 mtime（微秒级），变了才真正查询——空闲时几乎零开销；持续 3 分钟无数据变化则探测间隔从 2s 拉长到 10s（`ZCODE_TOKEN_METER_OVERLAY_IDLE_MS` 可调），有新写入或悬浮窗恢复显示立即回到 2s；被遮挡隐藏期间暂停轮询。底部"更新 Xs 前"如实反映数据年龄。
- **会话双重检测**：**当前对话**＝最近一次用户亲手输入（`input_history`）所在的顶层会话——定时/后台会话的周期触发不写该表，抢不走显示；**活跃对话**＝`time_updated` 最新的顶层会话（含定时任务），与当前对话不同时标题栏亮黄色脉动点，悬停显示会话标题。找不到输入记录时退回"最新 main_turn 会话"。全新会话无请求记录时显示"等待数据"。
- **归档过滤**：归档/删除状态存于 `~/.zcode/v2/tasks-index.sqlite`（`tasks.archived`/`tasks.deleted`，主库 `session.time_archived` 恒为 NULL）——选择菜单、双重检测、固定校验均已排除；固定中的会话被归档时自动回落"自动"模式。索引库缺失时不过滤。
- **TTFT 最快** + 本轮请求完成数；**ctx 行**：上下文占窗口比与缓存率（双段进度条）
- **累计行**：会话读入/新处理/生成累计
- **柱状图**：每轮 token 消耗，三层堆叠——命中（缓存读，绿）/未命中（新处理，琥珀）/输出（蓝）；**固定柱宽**（13 根铺满图表的宽度，最新一轮贴右，更旧的轮从左侧滚出）；**整柱高度线性正比该轮总消耗**（窗口内最大轮为满高，柱间可比），柱内三层按 √ 比例拆分保证小层可见；**悬停柱子显示该轮精确数值**（第-N 轮/命中/未中/输出/合计，其余柱变淡聚焦，跨 2s 重绘保持悬停态）

## 交互

- **会话切换（⟳ 按钮）**：弹出菜单——"自动(双重检测)"或最近 8 个顶层会话（标题 + 相对活跃时间）；选中即**固定显示**该会话（`pinSid` 持久化，会话消失自动回落）
  - **琥珀描边徽章 = 固定中**：固定模式下不参与自动切换，切对话后悬浮窗不跟随属正常现象——点 ⟳ 选"自动(双重检测)"即可恢复跟随（徽章恢复灰色）
- **胶囊模式**：标题栏 **—** 按钮缩为药丸小窗（约 180x33，仅 ⚡ tok/s · TTFT + ▢ 恢复按钮），状态持久化，重启保持；样式与完整卡同源（同配色/边框/阴影）
- 整卡可拖动（=更新相对 ZCode 窗口的停靠偏移）；拖到别的显示器会按其分辨率自动重算大小
- 右上 ✕ 退出；`screen-saver` 层级置顶，可压过系统设置等窗口
- 单实例：重复启动会把已有窗口顶到前面

## 配套文件

| 文件 | 作用 |
|---|---|
| `meter.mjs` | 数据层，纯 Node 可独立运行：`node meter.mjs` 输出 JSON 快照 |
| `main.mjs` | Electron 主进程：窗口、mtime 闸门轮询、字号/胶囊/固定会话持久化、ZCode 存活检测 |
| `owner.ps1` | 停靠守护：位置跟随、可见性判定、更新换代保护（纯 ASCII，勿加中文注释——PS 5.1 无 BOM 按 GBK 解析） |
| `renderer.html` | 卡片 UI（指标、胶囊态、柱状图与悬停 tooltip） |
| `preload.cjs` | contextBridge，只暴露收快照与退出 |
| 插件 `hooks/overlay-launch.mjs` + `hooks.json` | 会话开始时拉起悬浮窗 |

## 环境变量（与 token-meter 插件一致）

- `ZCODE_METER_DB`：覆盖 db.sqlite 路径
- `ZCODE_TOKEN_METER_CTX_LIMIT`：覆盖上下文总量（默认 1000000）
- `ZCODE_TOKEN_METER_OVERLAY_POLL_MS`：数据轮询间隔（默认 2000，下限 500）
- `ZCODE_TOKEN_METER_OVERLAY_DIR`：悬浮窗项目目录（hook 拉起用，默认 `D:/workspace/zcode-token-meter`）
- `ZCODE_TOKEN_METER_OVERLAY_PROC`：存活检测的进程名（默认 `ZCode.exe`）

## 已踩的坑

- Windows 上 `transparent: true` 无边框窗口必须配 `thickFrame: false`，否则多显示器 DPI 缩放下内容与窗口错位、右侧/底部被裁（实测复现并修复）。
- 外部截图/取坐标（PowerShell GetWindowRect）与 Electron DIP 坐标在非 100% 缩放屏上不一致，调试时以同脚本内联取矩形+截图为准。
- PowerShell 5.1 把无 BOM 的 UTF-8 按 GBK 解析：含中文的 .ps1 必须带 BOM 或纯 ASCII，否则 here-string 被腐蚀、Add-Type 静默失败。
- Win32 枚举回调里禁止调 `GetWindowText`（对垂死窗口挂起并中断整个枚举），读标题用 `SendMessageTimeout(WM_GETTEXT)`；枚举/事件委托必须钉在静态字段防 GC。
- ZCode 有全尺寸的 DWM cloaked 窗口（`IsWindowVisible=true` 但不显示），按"最大可见窗口"查找必被劫持，须按 `DWMWA_CLOAKED` 过滤。
- Electron 子进程比主进程窗口活得久，按单 pid 找窗口会空转；按"可执行文件路径在项目目录下"圈定进程、按配置尺寸匹配窗口（不以可见为条件，否则隐藏后死锁）。
