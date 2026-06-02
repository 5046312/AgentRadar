# AgentRadar — Claude Code 状态栏监控器

> macOS 原生菜单栏 App，常驻状态栏，红绿灯+脉冲动画展示多个 Claude Code 任务运行状态，悬浮显示明细。

## 一、可行性结论

**可行**。两个数据源已确认：

1. **会话 JSONL 文件**：每个 Claude Code 会话实时追加到 `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`，每条记录含 `timestamp` / `message.role` / `stop_reason` / `tool_use` / `gitBranch` / `cwd`。
2. **Hook 机制**：Claude Code 支持 `Stop` / `Notification` / `PreToolUse` / `PostToolUse` / `UserPromptSubmit` / `SubagentStop` 等钩子，命令行写入即可，可用 shell 脚本把事件追加到 `~/.agentradar/events.jsonl`，给 App 提供可靠的状态转换信号。

环境：macOS 15.7、Swift 6.1.2、Command Line Tools（无完整 Xcode）。所以使用 **SwiftPM 可执行包 + 手工 .app bundle 打包脚本**，不依赖 Xcode 项目。

## 二、状态推断模型

每个 session 状态枚举：

| 状态 | 颜色 | 触发 |
|------|------|------|
| `running` | 绿色脉冲 | 最近 ≤10s 有新 entry，且最后一条是 assistant 含 tool_use 或 user 含 tool_result |
| `waiting` | 黄色 | Hook 收到 `Notification`（需要用户输入/确认） |
| `idle` | 灰色 | 最近 >30s 无新 entry |
| `completed` | 绿色闪 3s 后转灰 | Hook 收到 `Stop` |
| `error` | 红色 | 进程异常或 hook 报错（v2 再做，先预留枚举） |

聚合策略（状态栏总览）：
- 任一 `error` → 红灯亮
- 任一 `waiting` → 黄灯亮
- 任一 `running` → 绿灯脉冲
- 全部 `idle` → 三个灯都暗灰
- 数字角标显示活跃任务数

## 三、UI 设计

### 状态栏

自定义 `NSView`，宽 ~52px：
- 三个 8px 圆点（红/黄/绿，仿 mac 窗口红绿灯），按状态高亮
- 绿灯脉冲：`CABasicAnimation` opacity 0.4 ↔ 1.0，duration 0.8s，autoreverses
- 完成闪烁：scale 1.0 → 1.3 → 1.0，3s 后归位
- 右侧小数字：活跃任务数（>0 时显示）

### 悬浮 Popover

`NSPopover` + `NSHostingController(rootView: PopoverContent)`，触发方式 `.transient`（点击或鼠标移入）：
- 顶部：总览统计行（X 个运行 / Y 个等待 / Z 个完成）
- 中间：会话列表，每行
  - 左侧状态点（彩色）
  - 项目名（来自 cwd 末段）+ git branch 灰字
  - 当前 tool 名（来自最新 message 的 tool_use.name）或最后助手消息前 60 字
  - 右侧：相对时间（"3s ago"）
- 点击行 → 通过 `NSWorkspace` 打开 cwd 目录
- 底部：设置按钮、退出按钮

## 四、模块拆分

```
Sources/AgentRadar/
├── App.swift                       # @main 入口
├── AppDelegate.swift               # 装配 StatusBarController + Stores
├── Models/
│   ├── Session.swift               # Session 结构 + SessionStatus 枚举
│   └── HookEvent.swift             # hook 事件解析
├── Core/
│   ├── SessionStore.swift          # @Observable，持有所有 sessions，UI 订阅
│   ├── SessionMonitor.swift        # FSEventStream 监听 ~/.claude/projects
│   ├── JSONLReader.swift           # 增量读 jsonl，解析为 Session 摘要
│   └── HookEventReader.swift       # tail ~/.agentradar/events.jsonl
├── UI/
│   ├── StatusBarController.swift   # NSStatusItem + 自定义 NSView
│   ├── TrafficLightView.swift      # CALayer 三圆点 + 动画
│   ├── PopoverContent.swift        # SwiftUI 主视图
│   └── SessionRow.swift            # SwiftUI 行视图
└── Util/
    └── PathUtils.swift             # 路径解码（projects 目录用 - 替换 /）
```

根目录：
```
AgentRadar/
├── PLAN.md                  # 本文档
├── Package.swift            # SPM 配置
├── Info.plist               # bundle 元数据，LSUIElement=true
├── build.sh                 # 构建 + 打包 .app
├── install-hooks.sh         # 注入 hooks 到 ~/.claude/settings.json
└── README.md
```

## 五、构建与运行

```bash
./build.sh                # SPM release + 打包 AgentRadar.app
open ./AgentRadar.app     # 启动
./install-hooks.sh        # 一次性注入 hooks（可选，不装也能跑）
```

## 六、Hook 注入方案

`install-hooks.sh` 修改 `~/.claude/settings.json`，加入：
```json
{
  "hooks": {
    "Stop":           [{"hooks": [{"type": "command", "command": "echo {...} >> ~/.agentradar/events.jsonl"}]}],
    "Notification":   [{"hooks": [{"type": "command", "command": "..."}]}],
    "PreToolUse":     [{"hooks": [{"type": "command", "command": "..."}]}],
    "PostToolUse":    [{"hooks": [{"type": "command", "command": "..."}]}],
    "UserPromptSubmit":[{"hooks":[{"type": "command", "command": "..."}]}]
  }
}
```

Hook 输入是 stdin JSON，命令读 stdin 并附加 timestamp + event_type 写入 events.jsonl。

## 七、性能预算

- 内存常驻 < 50 MB
- CPU 空闲 < 0.1%
- FSEvents latency 0.5s
- JSONL 增量读：保存每个文件已读到的 byte offset，避免全量重读
- UI 更新合并：DispatchQueue 主线程 0.1s debounce

## 八、迭代步骤

1. **v0.1**：Package.swift + 空壳 App 启动，状态栏放静态红绿灯
2. **v0.2**：JSONLReader 解析单个文件 → 控制台打印
3. **v0.3**：SessionMonitor 接 FSEvents，SessionStore 全量装配
4. **v0.4**：TrafficLightView 动画 + 状态聚合
5. **v0.5**：Popover + 会话列表
6. **v0.6**：HookEventReader + install-hooks.sh
7. **v0.7**：打包 .app + 自启动设置项
