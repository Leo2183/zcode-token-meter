# token-meter overlay

token-meter 的置顶悬浮窗：按可调速率（默认 2s）只读轮询 `~/.zcode/cli/db/db.sqlite`，实时显示 TTFT、解码速度、上下文占用与累计 token。独立进程，不依赖、不影响 ZCode 客户端本体。

## 跟随 ZCode 启停（默认开启，无需手动启动）

- **启动**：token-meter 插件的 `overlay-launch.mjs` 挂在 SessionStart / UserPromptSubmit 上，发现悬浮窗没在跑（查 `~/.zcode/zcode-token-meter.json` 里的 pid）就 detached 拉起一次，幂等。
- **关闭**：悬浮窗每 5s 探测 `ZCode.exe`，连续两次探测不到即自动退出（约 10s 后消失）。
- **z 序跟随（按屏幕遮挡判定）**：`follow.ps1` 每 400ms 探测——ZCode 最小化、或前台窗口与 ZCode **同屏且矩形相交**（真遮挡）时隐藏；前台在**别的屏幕**（如在副屏操作其他应用）或同屏但不与 ZCode 重叠时**保持显示**；ZCode 回前台自动恢复；点击悬浮窗自身不算失焦。探测进程异常退出则回退为常显。开关：`ZCODE_TOKEN_METER_OVERLAY_ZORDER=0`。已知取巧：ZCode 最大化时系统矩形含 8px 隐形边框，点任务栏会被判为遮挡而隐藏。
- 手动启动仍可用：`npm start`。关闭跟随：环境变量 `ZCODE_TOKEN_METER_OVERLAY=0`（hook 不再拉起）或 `ZCODE_TOKEN_METER_OVERLAY_FOLLOW=0`（悬浮窗不再自动退出）。
- 已知边界：pid 复用极端情况下会误判"已在跑"，重启 ZCode 会话即可恢复。

## 字号与窗口自适应

- 三种调法：标题行 **Aa 按钮**循环预设（85%/100%/115%/130%）、**Ctrl+滚轮**连续缩放（75%–160%）、**右键菜单**选预设。
- 窗口宽度随字号等比缩放，高度由渲染层实测内容高度自动适配（数据态/等待态高度不同也跟着变），并自动夹回屏幕工作区内。
- 字号持久化在 `~/.zcode/zcode-token-meter.json` 的 `scale`。

## 显示内容（默认 260x~168，随内容/字号自适应）

- **解码 tok/s（本轮）**：当前轮所有已完成请求的合并解码速度，与 turn-summary.mjs 同口径（output / Σ(duration−ttft)）
- **空闲自适应轮询**：每 tick 先 stat db.sqlite/-wal/-shm 的 mtime（微秒级），变了才真正查询——空闲时几乎零开销；持续 3 分钟无数据变化则探测间隔从 2s 拉长到 10s（`ZCODE_TOKEN_METER_OVERLAY_IDLE_MS` 可调），有新写入或悬浮窗恢复显示立即回到 2s；被 z 序跟随隐藏期间暂停轮询。底部"更新 Xs 前"如实反映数据年龄。
- **会话跟随**：取 `session.time_updated` 最新的顶层会话（排除子代理/归档）——消息、工具等事件落库即刷新，切换对话后无需等模型输出完成；若 ZCode 打开会话时不写库，则最迟在第一条消息发出时跟随；全新会话无请求记录时显示"等待数据"
- **TTFT 最快** + 本轮请求完成数；**ctx 行**：上下文占窗口比与缓存率（双段进度条）
- **累计行**：会话读入/新处理/生成累计
- **柱状图**：每轮 token 消耗，三层堆叠——命中（缓存读，绿）/未命中（新处理，琥珀）/输出（蓝）；**固定柱宽**（13 根铺满图表的宽度，最新一轮贴右，更旧的轮从左侧滚出）；**整柱高度线性正比该轮总消耗**（窗口内最大轮为满高，柱间可比），柱内三层按 √ 比例拆分保证小层可见；**悬停柱子显示该轮精确数值**（第-N 轮/命中/未中/输出/合计，其余柱变淡聚焦，跨 2s 重绘保持悬停态）

## 交互

- **胶囊模式**：标题栏 **—** 按钮缩为药丸小窗（约 180x33，仅 ⚡ tok/s · TTFT + ▢ 恢复按钮），状态持久化，重启保持；样式与完整卡同源（同配色/边框/阴影）
- 整卡可拖动，位置记忆在 `~/.zcode/zcode-token-meter.json`（移出屏幕会自动回到主屏右上角）
- 右上 ✕ 退出；`screen-saver` 层级置顶，可压过系统设置等窗口
- 单实例：重复启动会把已有窗口顶到前面

## 配套文件

| 文件 | 作用 |
|---|---|
| `meter.mjs` | 数据层，纯 Node 可独立运行：`node meter.mjs` 输出 JSON 快照 |
| `main.mjs` | Electron 主进程：窗口、轮询、位置/pid 记忆、ZCode 存活检测 |
| `renderer.html` | 卡片 UI（含折线图） |
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
