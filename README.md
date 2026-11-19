# ade.nvim

> **改名说明**：本插件原名 `acp.nvim`，现已改名为 `ade.nvim`。改名是直接切换，
> **不保留兼容层**：旧的 `require("acp")` 和 `:Acp` 系列命令都不再存在，必须改配置
> （安装 spec、`require("ade").setup(...)`、键位与补全配置里的模块路径）。
> 旧数据目录会在首次启动时自动迁移，已安装的托管 Agent 和未发送的草稿无需重装或重写。
> 指 ACP 协议、ACP agent 或外部程序的名称不变。
>
> | 项目 | 旧 | 新 |
> |---|---|---|
> | 模块 | `require("acp")`、`acp.*` | `require("ade")`、`ade.*` |
> | 命令 | `:Acp`、`:AcpLog`、`:AcpDebug`、`:AcpCompletionRefresh` | `:Ade`、`:AdeLog`、`:AdeDebug`、`:AdeCompletionRefresh` |
> | healthcheck | `:checkhealth acp` | `:checkhealth ade` |
> | 高亮组前缀 | `Acp*`（如 `AcpUser`、`AcpReviewAdd`） | `Ade*`（如 `AdeUser`、`AdeReviewAdd`） |
> | filetype | `acp_chat`、`acp_input` | `ade_chat`、`ade_input` |
> | 补全 source | nvim-cmp `name = "acp"`、blink `providers.acp` | `name = "ade"`、`providers.ade` |
> | 数据目录 | `stdpath("data")/acp/`、`stdpath("state")/acp/` | `stdpath("data")/ade/`、`stdpath("state")/ade/` |
> | 帮助 | `:help acp.nvim` | `:help ade.nvim` |
>
> `require("acp")` 不会被别名到 `ade`：改配置后请重启 Neovim，让旧的 `package.loaded`
> 与 `plugin/acp.lua` 一起消失。

Neovim 原生的 [Agent Client Protocol](https://agentclientprotocol.com) 客户端，界面参照
[Zed 的 Agent Panel](https://zed.dev/docs/ai/agent-panel)，默认连接
[OpenCode](https://opencode.ai)。默认使用原生分屏布局，也可交给
[edgy.nvim](https://github.com/folke/edgy.nvim) 等外部布局管理器。

不是把 OpenCode 的 TUI 塞进终端窗口，而是用 Neovim 的 buffer、split 和 extmark 自己渲染
对话记录、工具调用和输入框。

```
┌──────────────────────────┬──────────────────────────────┐
│                          │ opencode · 重构认证中间件      │ ← winbar
│                          ├──────────────────────────────┤
│                          │ ❯ 你  [auth.lua] [选区 12-40] │
│                          │   把 token 校验提取成一个函数   │
│                          │                              │
│         编辑区            │ ▤ 计划                        │
│                          │   ✓ 阅读当前实现               │
│                          │   ◌ 提取校验逻辑               │
│                          │                              │
│                          │ ⏺ 我会先读取中间件，然后把…      │
│                          │                              │
│                          │ ▸ ✓ 编辑 auth.lua       完成  │
│                          │     +18 -11                  │
│                          ├──────────────────────────────┤
│                          │ Build · Claude Sonnet 5       │ ← 输入 winbar
│                          │ [auth.lua]                   │
│                          │ 输入消息…                     │
│                          │                        生成中 │
└──────────────────────────┴──────────────────────────────┘
```

## 特性

- **Zed 风格转录**：消息卡片、Markdown、代码块、可折叠工具调用、计划清单、压缩分隔线。
- **独立的输入区**：多行编辑、每个会话独立草稿、上下文附件、消息队列。
- **工具栏**：左侧是模式徽标、模型名与可选用量，右侧是状态图标 / 动画与队列数量；模式和模型可点击，窄窗口优先保留状态。
- **随窗口实时重排**：winbar 由表达式在每次重绘时按真实窗口宽度计算，resize、拆分或布局插件调整后不会出现截断标记或错位。
- **转录随宽度重排**：聊天窗口宽度变化后自动重新排列表格、卡片和分隔线；连续拖动采用
  100ms 防抖，期间流式内容照常更新。阅读历史时尽量保持所在 block 与视口，不误报新消息。
- **全局状态栏友好**：所有操作信息走 winbar，`laststatus=0/2/3` 都能正常工作；
  不修改 `statusline` 或 `laststatus`，另外提供可选的状态栏组件。
- **edgy 兼容**：两个普通视图（`ade_chat` / `ade_input`），由 edgy 决定位置与尺寸。
- **纯 Lua，零运行时依赖**：不强制依赖补全框架、UI 框架或图标字体。
- **优先适配 OpenCode**：模型 / 模式选择、slash 命令补全、历史会话与删除，渲染 Agent 提供的子代理、重试、压缩与用量信息。

## 依赖

- Neovim 0.13 或更新（0.13 尚未正式发布时请使用 nightly）
- 代码块语法高亮可选依赖对应语言的 Tree-sitter parser 与 highlights query；缺失时显示纯文本，不影响对话。
- 一个已登录的 ACP Agent。默认是 OpenCode；首次使用可以打开 `:Ade` 后运行 `:Ade login`，
  插件会执行 Agent 自己提供的登录方式：

```bash
opencode auth login      # 也可以在终端里手动完成
```

## 安装

### lazy.nvim

```lua
{
  "btstream/ade.nvim",
  dependencies = { "folke/edgy.nvim" }, -- 可选，但推荐
  cmd = { "Ade", "AdeLog", "AdeDebug" },
  opts = {},
}
```

最小配置即可使用：

```lua
require("ade").setup({})
```

## 使用

| 命令 | 说明 |
|---|---|
| `:Ade` 或 `:Ade toggle` | 打开 / 隐藏面板 |
| `:Ade open` / `:Ade hide` | 显式打开 / 隐藏 |
| `:Ade new` | 新建会话 |
| `:Ade stop` | 中止当前回合 |
| `:Ade sessions` | 打开会话浏览器：`<CR>` 切换、`<C-d>` 删除、输入即过滤 |
| `:Ade delete` | 打开同一个会话浏览器，用 `<C-d>` 删除选中会话 |
| `:Ade model` / `:Ade mode` | 切换模型 / 模式 |
| `:Ade reconnect` | Agent 崩溃后重连并恢复当前会话 |
| `:Ade disconnect` | 停止 Agent 进程（保留面板） |
| `:Ade permission` | 重新打开待确认的权限请求 |
| `:Ade file` | 附加当前文件 |
| `:Ade diagnostics` | 附加当前 buffer 的诊断 |
| `:Ade team` | 团队面板；`:Ade team start [流程]` / `:Ade team close`（见下文） |
| `:Ade workflows` | 列出 / 查看 / 删除命名流程 |
| `:AdeLog` | 打开日志 |
| `:AdeDebug` | 打印控制器状态 |

### 工作指示器

输入区的 spinner 默认每 120ms 更新，使用 libuv timer 并合并 UI 回调；焦点在其他窗口时
也会明确刷新 ade.nvim 的 winbar。隐藏面板或切到其他标签页时停止，返回后恢复。已停止/关闭的
timer 会在下一次状态、窗口或焦点同步时重建，不需要重启插件。

卡住时查看 `:AdeDebug` 的 `spinner`：

- `state` / `timer_active`：区分正常动画、隐藏、关闭动画和失效 timer。
- `ticks` / `frame_changes`：帧推进情况；`max_tick_gap_ms` 是历史最大 tick 间隔，
  应与 `interval_ms` 比较，而不是当作纯阻塞耗时。
- `max_schedule_delay_ms` / `max_refresh_delay_ms`：UI 队列等待时间。
- `bar_evaluations` / `last_evaluated_frame`：winbar 表达式是否在更新，不代表物理屏幕已经绘制。
- `redraw_backend`、错误计数、`active_errors` / `last_error`：重绘方式及当前/历史错误。

重复错误只在每个错误阶段首次发生时记日志。`last_bar_status=waiting` 是等待权限，
`state=static` 是关闭了动画，都不是 spinner 卡死。libuv 同样无法在主循环阻塞时绘制：
JSON 解码、单块排版或 Treesitter 解析很重时仍可能暂停，恢复后会跳过错过的帧。
可结合 `render.timings`（需 `ui.render.profile=true`）和 transport 统计定位重型任务。

带 UI 的回归：`python3 tests/integration_spinner.py`（额外需要测试依赖 `pynvim`，插件本身不需要）。

### 输入区

进入 `ade_input` 窗口或缓冲区时自动切换到插入模式，离开时退出插入模式，避免把输入
状态带到转录区或编辑窗口。按 `<Esc>` 可暂时在输入区使用普通模式；再次进入时恢复插入。

下表的按键都是默认值，全部可以通过 `keymaps.input` 修改。

| 按键 | 配置字段 | 说明 |
|---|---|---|
| `<C-s>` | `send` | 发送；回合进行中且输入框为空时改为中止 |
| `<C-c>`（普通模式） | `cancel` | 中止当前回合 |
| `q`（普通模式） | `close_panel` | 隐藏面板（不中断会话） |
| `<C-]>`（普通模式） | `add_selection` | 附加当前选区 |
| `M` / `<M-m>` | `pick_model` | 普通模式 / 输入时选择模型 |
| `m` / `<M-b>` | `pick_mode` | 普通模式 / 输入时选择模式 |
| `gT` / `<M-e>` | `pick_thinking` | 普通模式 / 输入时选择 Thinking Level |
| `L`（普通模式） | `pick_session` | 历史会话 |
| `<M-a>` | `focus_choice` | 进入待回答的选择卡片（提问 / 权限） |
| `<C-x><C-u>` | — | 补全 `/命令` 或 `@文件`（Vim 内置触发，不受 `keymaps` 控制） |
| `<leader>ai`（任意 buffer） | `keymaps.inline` | 在光标/选区上开始内联编辑 |
| `@path/to/file` | — | 发送时自动作为附件 |
| 点击 winbar 的模型 / 模式 / Thinking Level | — | 打开选择器（鼠标区域，不是键位） |

### 转录区

同样，全部可以通过 `keymaps.chat` 修改。

| 按键 | 配置字段 | 说明 |
|---|---|---|
| `i` / `<C-s>` | `focus_input` | 聚焦输入框 |
| `<CR>` | `open_location` | 打开光标所在位置的文件 |
| `<Tab>` | `toggle_block` | 展开 / 折叠工具调用或思考块；不可折叠时聚焦输入框 |
| `[b` / `]b` | `prev_block` / `next_block` | 上一个 / 下一个消息块 |
| `G` / `gg` | `scroll_bottom` / `scroll_top` | 最新 / 最早 |
| `S` | `add_selection` | 附加当前选区 |
| `F` | `add_file` | 附加当前文件 |
| `R` | `add_diagnostics` | 附加诊断 |
| `M` / `m` | `pick_model` / `pick_mode` | 选择模型 / 模式 |
| `gT` | `pick_thinking` | 选择 Thinking Level |
| `<C-n>` | `new_session` | 新建会话 |
| `L` | `pick_session` | 历史会话 |
| `<M-a>` | `focus_choice` | 进入待回答的选择卡片（提问 / 权限） |
| `g?` | `help` | 帮助（列表按当前配置生成） |
| `q` | `close_panel` | 隐藏面板 |

转录区只读：从输入框或其他窗口直接切入时也会退出插入模式。默认 `i` / `<C-s>`
切到输入框，`S` / `R` 仍执行附加选区 / 诊断；未绑定业务动作的插入入口（如 `a`、
`o`、`A`）静默忽略。关闭 `focus_input` 后，`i` 也静默忽略。`keymaps.chat` 配置的
业务映射优先于这些兜底映射。

所有按键都是 buffer-local，不会污染全局映射。

### 输入区补全：blink.cmp / nvim-cmp / 原生菜单

`/` 补全当前 Agent 提供的命令名称和说明，`@` 模糊查找项目文件。只在 `ade_input`
生效，不补全聊天转录、不调用命令、不自动发送消息。两个框架**二选一**，均为可选依赖。

**blink.cmp**：将下面配置合并进已有 `setup` / lazy.nvim `opts`，不要再次调用 setup：

```lua
sources = {
  per_filetype = { ade_input = { "ade" } },
  providers = {
    ade = { name = "ade", module = "ade.completion.blink" },
  },
}
```

参见 [`examples/completion_blink.lua`](examples/completion_blink.lua)。接受候选使用现有 blink
按键；若自定义 `enabled` 排除了 `nofile` buffer，请为 `ade_input` 放行。

**nvim-cmp**：在 nvim-cmp 和 ade.nvim 都能被 require 后注册 source，配置仅作用于输入区：

```lua
local cmp = require("cmp")
require("ade.completion.cmp").setup() -- 幂等注册名为 ade 的 source
cmp.setup.filetype("ade_input", {
  enabled = true,
  sources = { { name = "ade", keyword_length = 0 } },
  matching = { disallow_symbol_nonprefix_matching = false },
})
```

完整 lazy.nvim 示例及 Enter 确认映射见 [`examples/completion_cmp.lua`](examples/completion_cmp.lua)。
本插件不修改两个框架的全局 sources 或按键。建议保持 `<C-s>` 发送、使用补全框架按键确认；
若把发送也绑定到 `<CR>`，需要自行做“菜单有选中项时确认，否则发送”的条件映射，避免误发送。

**不安装框架**：仍可用 `<C-x><C-u>`，文件索引异步完成后显示原生菜单。支持例如：

```text
@lua/ade/ui/chat.lua
@Makefile
@"docs/中文 file.txt"
```

补全和发送共用引用语法；带空格、引号、反斜杠等字符的路径会自动使用 JSON 字符串引用。
邮箱中的 `@` 不触发文件补全。提交时才检查和附加可读文件，补全过程不会读取所有文件正文。

#### 项目文件发现与缓存

默认从当前**会话目录**寻找 Git 根目录；非 Git 项目使用会话目录。自动选择 `rg --files`、
`fd` / `fdfind`、`git ls-files`，均异步执行并覆盖递归文件；不仅搜索已打开的 buffer。
最后回退到异步目录遍历，无外部工具也能使用。内置遍历不解析 ignore 文件，建议安装 rg / fd。

```lua
require("ade").setup({
  completion = {
    native = true,      -- 保留原生触发；不会自动与框架同时弹两个菜单
    max_items = 200,    -- 只限制原生菜单，先在完整索引中匹配再截取
    picker = "vim",    -- "vim" | "fzf-lua" | "snacks" | "telescope"
    files = {
      backend = "auto", -- 或 "rg" | "fd" | "git" | "builtin"
      root = false,    -- 或绝对路径 / function(session_cwd) return root end
      hidden = true,
      ignored = false,
      cache_ms = 10000,
      max_bytes = 16 * 1024 * 1024,
      max_projects = 4,
      command = false, -- 自定义 argv，cwd=root，输出 NUL 分隔的相对路径
    },
  },
  keymaps = { input = { pick_file = "<M-f>" } }, -- 可选，默认不占用按键
})
```

框架获得完整索引并自行模糊排序，不会先截断前 200 个文件。`max_bytes` 是索引路径和条目
开销的估算预算，不是总 RSS 上限；超限会明确报错而非提供不完整索引，可在 `:AdeLog` 查看原因。
隐藏和忽略规则遵循所选工具；`.git` 元数据固定排除。`ignored=true` 可能纳入敏感的被忽略文件，
请谨慎启用。缓存按项目/选项复用，过期重建；`:AdeCompletionRefresh` 清理缓存，下一次请求重新扫描。
会话在仓库子目录时，插入路径相对会话目录，必要时使用 `../`，确保发送时能解析到同一文件。

#### 使用 fzf / 其它文件选择器

打开输入区后，`:Ade files` 或 `require("ade").pick_file()` 使用上述 `completion.picker`
选择器；也可单次指定：

```lua
require("ade").pick_file({ backend = "fzf-lua" })
```

fzf-lua、Telescope 和 Snacks 都复用同一个完整项目索引；`"vim"` 使用 `vim.ui.select`，
也支持已有的 dressing / UI 接管。选择结果插入 `@路径`，**不打开文件、不发送消息**。
与原有 `:Ade file`（附加当前文件）不同。原始 fzf 二进制不是补全菜单的强依赖，
fzf-lua 只是可选的交互式搜索入口，不会在每次按键时重新扫描项目或弹出终端。

### 图像附件

输入区可以附加图像，以 ACP `image` 内容块发送，这需要 Agent 声明
`promptCapabilities.image`（OpenCode 支持）。未声明的 Agent 不会让整条消息失败：
发送时图像会降级为 `resource_link`（带上磁盘上的 URI），消息其余文本照常送达。
这比直接拒绝更有用——Agent 至少能看到图片所在的文件。

```lua
require("ade").setup({
  context = {
    images = {
      enabled = true,
      max_bytes = 3 * 1024 * 1024, -- 单张上限
      max_per_message = 4,
      clipboard = "auto",  -- 或 false，或自定义 argv
      path_mode = "link",  -- @shot.png 默认按 resource_link
      ttl_hours = 24,
      max_cache_bytes = 64 * 1024 * 1024,
    },
  },
})
```

三种用法：

| 方式 | 说明 |
|---|---|
| `:Ade image` | 读取系统剪贴板中的截图并附加 |
| `:Ade image path/to.png` | 附加指定文件 |
| 直接粘贴 / 拖拽图像文件路径 | 只对输入区生效，识别 `file://`、引号和转义路径 |

`require("ade").paste_image()`、`require("ade").add_image(path)` 是对应 API。
`paste_image` 默认绑定 `<C-v>`（普通模式和插入模式），与 OpenCode TUI、pi 的习惯一致。
这会覆盖输入区的 `i_CTRL-V`（字面量插入）和普通模式 `CTRL-V`（块选择）；只在
`ade_input` 内生效，不影响其它 buffer。需要改用其它键时：

```lua
keymaps = { input = { paste_image = "<M-v>" } },
```

附加图像会在 **`ade_input` 的粘贴光标处**显示浅黄色底、深色粗体的行内标签 `[Image 1]`，
多张图片使用独立编号，不再放到 winbar。可通过 `ui.highlights.AdeInputImage` 覆盖样式。
标签是可编辑占位符，不是图片预览：粘贴后光标位于标签之后，可正常移动到两侧。
标签后按退格、标签前按 Delete 可整块删除图片附件；支持撤销/重做。
发送时只移除受跟踪的图片占位符，不会移除用户自己输入的同名文字；图片仍单独作为附件发送。
文字和图片按输入区的实际位置交错发送为 ACP 内容块，聊天记录也在原位置显示对应编号，
不会把图片统一挪到消息头或末尾。排队时会冻结位置，后续草稿编辑不会改变已排队消息。
剪贴板读取是异步的，位置会跟随读取期间的文本编辑；若用户清空或切换草稿，旧结果会丢弃。
用户离开窗口或主动退出插入模式后，回调不会抢回焦点或重新进入插入模式。

**为什么不用终端的粘贴快捷键**：终端只在 bracketed paste 中传文本，截图不会传给
Neovim；OSC 5522 需要终端专用协商并改变普通粘贴处理，本插件暂不接入。
目前剪贴板图像由本插件主动读取
（`wl-paste` / `xclip` / `pngpaste` / `powershell.exe`），
与 OpenCode TUI、pi 等终端客户端的做法一致。

图像数据只在发送时编码：草稿、本地队列和会话块里只有路径、大小和摘要，避免 base64
在三个地方各放大 33%。字节按 sha256 存在 `stdpath("state")/ade/images`（目录 0700、
文件 0600，按 `ttl_hours` 与 `max_cache_bytes` 回收）。`max_bytes` 会与
`transport.max_line_bytes` 交叉校验，配置阶段就拒绝无法装进一条消息的上限。
清理时保护草稿（含持久化）、内存队列与会话块仍引用的图片；活跃引用可能使缓存超过预算。
`path_mode = "inline"` 时 `@shot.png` 会内嵌字节；默认 `link` 只发送引用，避免每次提及
都把整张图重新编码。协议日志会把 base64 载荷替换为 `<base64 N bytes>`。

### 选区与未保存的 buffer

`@文件`、`S`（附加选区）和 `R`（附加诊断）的内容能否内嵌，取决于 Agent 是否声明
`promptCapabilities.embeddedContext`（mock 的 OpenCode 与 Claude 声明，pi 不声明）：

| 附件 | Agent 声明 `embeddedContext` | 未声明 |
|---|---|---|
| 未保存的 buffer | `resource`（内嵌文本） | `resource_link` + 一段包含同样文本的 `text` 块 |
| Visual 选区 | `resource`（内嵌文本） | 同上 |
| 普通文件（已保存） | `resource_link` | `resource_link` |

关键是**未声明时仍然把文本发过去**：只发一个 `file://...#L10:20` 链接的话，Agent 得自己去
读文件，而你未保存的修改它根本看不到。这个判断发生在**发送时**，不是附加时——附件可能在
草稿里放很久，期间可能重连或切换 Agent，附加时的能力判断早就过期了。

### 内联编辑

`require("ade").inline()`（默认 `<leader>ai`，普通和 Visual 模式）在光标处或选区上方
打开输入框，让 Agent 修改当前 buffer。字符/行选区默认按整行处理，块选区保留列范围；
`inline.expand_selection = false` 保留字符选区的精确范围。无选区（普通模式）时不会把请求
限制成“只能在光标处插入”：Agent 按用户请求修改副本，光标位置只作为提示。
`inline.scope = "context"` 时改为只允许修改光标周围的上下文窗口。

通过当前 session 提交正常 prompt 回合，回复保留在聊天记录中，不创建新 session。
当前回合或队列未完成时拒绝 inline 提交；inline 运行时，普通聊天仍可排队。
要求 Agent 编辑同目录下的私有副本（`.ade-inline-*`）：

- 读/搜索/思考/取回默认放行；编辑权限仅授权本次登记的副本，其它写入或命令默认拒绝。
  `inline.allow_commands` 只放开 shell 命令（`execute`）；`delete`、`move` 与未知 kind 需要
  用 `inline.allow_kinds` 显式列出。
- 结果按选区范围过滤，精确字符/块选区不扩大为整行；越界改动提示丢弃数量。
- 等待或审查期间源内容、文件名或换行约定变化时，拒绝应用冲突结果。
- 回合进行期间源 buffer 被锁定：既不能编辑，`:w`/`:update`/自动保存也不会写盘，并提示
  `inline edit in progress`。取消（`:Ade inline-stop`）或回合结束才解锁；应用结果和审查前
  必定先解锁。
- 回合结束后会比对源文件在磁盘上的 mtime、大小与内容 hash。Agent 或其它程序在回合中改了原文件
  时中止应用，并让你选择「从磁盘重新加载 / 保留 buffer / 查看差异」。
- 当前模式若会自动批准编辑（Claude 的 acceptEdits、bypassPermissions、auto），
  `inline.guard_mode` 默认会提示一次：`"ask"` 提示后继续，`"switch"` 临时切到最安全的模式并在
  结束后切回，`"off"` 只依赖上面的磁盘检测。
- 回合中 Agent 的提问（elicitation 或以权限包装的 select/confirm）交给用户回答，不会被自动答应。
- 生成的内联 prompt 在聊天记录里折叠成一行摘要，展开可看完整说明。
- 副本权限为 0600，默认大小上限 `inline.max_copy_bytes = 8 * 1024 * 1024`；
  请求结算后删除，正常退出清理；下次使用时尝试清理超过一天且所属进程已退出的孤儿。
  目录不可写时退回 `stdpath("state")`。

这些是 ACP 权限请求约束，不是操作系统沙箱；无法阻止绕过权限协议的 Agent 直接修改文件。

审查方式可配置，默认逐块审查：

```lua
inline = {
  review = {
    mode = "diff", -- "diff" 逐块确认；"write" 直接写回（仍可一次撤销）
    by_filetype = {
      markdown = "write",
      text = "write",
      ["*"] = "diff",
    },
  },
},
keymaps = { inline = { normal = "<leader>ai", visual = "<leader>ai" } },
```

diff 默认在新 tabpage 里打开并排的真实窗口：
`3-column` 为「原文 │ 结果 │ 提案」，`2-column` 去掉只读的原文，只留「结果 │ 提案」。
各栏**不使用** Vim 的 diff 模式（它会把同一 tab 里所有 diff 窗口互相比较，无法表达
「原文↔结果」「结果↔提案」两组对比）：插件按同一份对齐表给每栏插入 filler 行，三栏行数
完全相同，`scrollbind`/`cursorbind` 由 Neovim 原生同步，语法高亮按文件自身语言启动。
默认**不折叠**任何行：分栏的窗口选项显式设成不折叠（`foldmethod=manual`、`foldlevel=99`），
因此既不会折叠无关上下文，也不会继承用户全局的 `foldmethod`/`foldlevel`；
显式设置 `fold = true` 才折叠离变更超过 `context` 行的未修改行。
结果列初始等于原文；源 buffer 在审查期间不变，全部决定后一次应用接受的块。
宽度不足 `min_split_width`，或 `target = "float"` 时，回退为复用工具卡片渲染的
card 视图（同样的 diff 背景与语法高亮）。

- 光标停在某个变更块上，`ga`/`gr` 接受/拒绝该块；Visual 选区可一次处理被覆盖的所有块。
  三栏的显示行一一对应，所以在**任意一栏**都可以选择和决定。默认（`advance = true`）处理完
  一个块后自动跳到下一个待处理的块。
- `]c` / `[c`（或 `]h` / `[h`）按审查顺序循环跳到下一个/上一个块，已决定的块仍可访问；
  光标留在当前栏。`u` 把当前块的决定清回 pending。
- `g2` / `g3` 全部接受 / 全部拒绝，`g1` 全部接受并永久改用直接写回，
  `q` / `<Esc>` 拒绝剩余部分并关闭；`:Ade inline-reset` 清除 always-accept。
- 结果列只用于展示决定结果，是 `nomodifiable`；手动编辑会被下一次决定覆盖，因此被禁止。
- 审查不修改 `diffopt`，也不开启任何窗口的 `diff`。
- 按结果到达时的 filetype 解析：精确 filetype、复合 filetype 的第一段、`"*"`、默认值。

`:Ade inline [diff|write]`、`:Ade inline-stop`、`:Ade inline-reset` 是对应命令。
命令支持行范围（如 `:'<,'>Ade inline diff`）。显式 `diff|write` 优先于 always-accept
和 filetype 配置；`<C-d>` 切换本次模式。同一时间只运行一个 inline 请求。

浮窗外观可配置；颜色仍由 highlight group 决定：

```lua
inline = {
  window = {
    border = "rounded",     -- none/single/double/rounded/solid/shadow，或 8 个字符
    title_pos = "left",     -- left | center | right
    style = "minimal",      -- minimal | default
    highlights = {          -- 只映射窗口 chrome，可用 ui.highlights 改颜色
      normal = "AdeInlinePrompt",
      border = "AdeInlineBorder",
      title = "AdeInlineTitle",
    },
    prompt = {
      placement = "cursor", -- cursor（跟随光标）| window（窗口左上）
      width = 72,
      height = 3,
      offset = { row = 0, col = 0 },
      follow_cursor = true,
    },
    review = {
      placement = "center",      -- center | cursor（仅 target = "float" 时生效）
      width = 140,
      height = 25,
      target = "buffer",         -- buffer（新 tab 真实窗口）| float（浮窗）
      layout = "3-column",       -- 3-column | 2-column
      min_split_width = 90,      -- 更窄时回退 card 渲染
      context = 3,               -- 上下文行数：card 回退保留的行，fold = true 时不折叠的行
      syntax = true,             -- card 回退使用文件自身语法
      advance = true,            -- 决定后自动跳到下一个 pending 块
      max_rows = 4000,           -- card 回退的行数上限
      fold = false,              -- 折叠离变更超过 context 行的未修改行（默认关闭）
      sync_scroll = true,        -- scrollbind/cursorbind
      relative_number = false,   -- 相对行号（按真实行计算，跳过 filler）
      hints = true,              -- 在当前块后显示 ga/gr 提示
      -- 已废弃并被忽略：审查行号栏不再画折叠列（始终 foldcolumn=0），
      -- 保留该键只为让旧配置继续通过校验。
      foldcolumn = 0,
    },
  },
},
```

`placement = "cursor"` 优先放在光标下方，空间不足时翻到上方，水平位置跟随光标列，
并始终夹在屏幕内；`follow_cursor = false` 可让输入框停在打开时的位置。

审查界面的外观（与常见的三栏 merge 视图一致）：

- 三栏共用同一份对齐：块内的行用 `linematch` 按相似度配对，块里没有任何相似行
  （整段改写、翻译）时改为从上到下配对。有对应的行是 `modify`，两侧都有内容；只在原文中
  存在的是 `delete`，只在提案中存在的是 `add`，对面一定是 `╱` filler。着色与对齐来自
  同一份数据，不会出现 modify 行对着 filler 的情况。
- 每一栏只显示**它自己这一侧**相对结果的变化：

  | 栏 | pending | 已接受 | 已拒绝 |
  |---|---|---|---|
  | 原文 | `AdeReviewDelete` + 字符级 `AdeReviewDeleteText` | `AdeReviewDimmed`（被替换） | 无底色（保留） |
  | 结果 | `AdeReviewPending` | `AdeReviewAdd` + 字符级 `AdeReviewAddText` | 无底色 |
  | 提案 | `AdeReviewAdd` + 字符级 `AdeReviewAddText` | `AdeReviewAdd`（已采用） | `AdeReviewDimmed`（被丢弃） |

- 字符级标记只用于相似的行对；一行里超过一半都变了（改写、翻译）时只用整行底色，避免满行碎片。
- 行号列由 `statuscolumn` 绘制：最左一格是块的状态条（`▎`，已接受/已拒绝块的首行为 `✓`/`✗`），
  颜色为 `AdeReviewStatePending/Current/Accepted/Rejected`，三栏同一行同色；后面是**真实行号**
  （原文/提案保留各自文件的行号，结果列按当前结果计数），filler 行没有行号。
  行号列里没有折叠列（`foldcolumn` 恒为 0，`foldcolumn` 配置项已废弃并被忽略）。
- 光标所在块在结果列行尾显示 `ga accept · gr reject · ]c next`（`AdeReviewHint`，`hints = false` 关闭）。
- `winbar` 每栏一个彩色徽章（`A` 原文 / `→` 结果 / `B` 提案），只有结果列显示
  `hunk i/n · ✓/✗/pending` 计数。
- 光标行使用 `AdeReviewCursorLine`（复制主题 `CursorLine` 的底色、去掉下划线），
  避免 `cursorbind` 把下划线画到三栏。
- filler 用 `AdeReviewFiller`：固定的低对比灰 `fg`，不跟随主题。
- 所有组都是**静态定义**：运行期不做混色。`AdeReviewAdd/Delete/Pending` 的底色复制自主题的
  `DiffAdd/DiffDelete/DiffChange`，字符级标记复制自 `DiffText`（只复制 `bg`，不带主题的前景与下划线；
  `ColorScheme` 时重新复制）。主题的颜色区分度不够时，用 `ui.highlights` 覆盖。
- card 回退沿用 `AdeDiffAdd/AdeDiffDelete`，状态用 `AdeInlineAccepted/Rejected`。

审查配色示例（放入 `setup()`，颜色按你的主题调整）：

```lua
ui = {
  highlights = {
    AdeReviewAdd = { bg = "#243c2c" },        -- 新增 / 提案侧
    AdeReviewDelete = { bg = "#44292e" },     -- 删除 / 原文侧
    AdeReviewPending = { bg = "#26384a" },    -- 结果列中未决定的块
    AdeReviewAddText = { bg = "#2f5a3a" },    -- 提案侧变化的字符
    AdeReviewDeleteText = { bg = "#6a3038" }, -- 原文侧变化的字符
    AdeReviewFiller = { fg = "#4b5260" },
  },
}
```

也可在 `setup()` 之后用 `vim.api.nvim_set_hl(0, "AdeReviewPending", { bg = "#26384a" })`
即时调整；希望切换主题后仍保留配置时，推荐使用上面的 `ui.highlights`。
card 里的 diff 使用 `AdeDiffAdd/AdeDiffDelete`。

审查窗口的行为约束：

- 窗格选项只写窗口局部值，打开后会立刻把选项的“新窗口继承值”还给用户；审查期间
  新开的补全、通知等浮窗不会继承审查的 `statuscolumn`、折叠、`winhighlight` 等选项。
- 若外部仍换掉了窗格 buffer（例如手动关掉 `winfixbuf` 后 `:edit`），重新进入时会把
  审查 buffer 放回并恢复选项。
- 三个窗口都设置 `winfixbuf`，`:edit`、`:enew`、`:bnext` 和插件“在此打开”都会被拒绝
  （`E1513`），因此结果列不会变成真实文件的 buffer。关闭窗口仍然允许。
- 每栏按文件语言显式 `vim.treesitter.start()`，包括 `lua`/`markdown` 之外 Neovim 没有自带
  ftplugin 的语言（Python、JavaScript、TypeScript、Go 等）；没有对应 parser 时静默回退到
  legacy `syntax`，无 parser 也没 syntax 时就是纯文本。

### 可选的懒渲染与历史分页

默认仍使用全文渲染。建议先开启 A，确认效果后再开启 B：

```lua
ui = {
  render = {
    lazy_syntax = true, -- A：仅在视口附近解析/绘制代码、diff 语法颜色
    profile = false,   -- true 时在 :AdeDebug 的 render.timings 查看分层耗时
    budget_ms = 4,     -- 共享调度器的主循环软预算；同步操作不可抢占
    overscan = 1,      -- 可见区上下各预加载一屏
    commit_rows = 2000, -- 超过此行数时提交也分片；0 关闭
    pagination = {
      enabled = false, -- B：需要时显式开启，默认不改变原生搜索/复制语义
      page_blocks = 64,
      max_blocks = 192,
      page_bytes = 256 * 1024,
    },
  },
}
```

- **A** 保留完整 buffer 文本、基础高亮、conceal、卡片背景和跳转信息，只延迟语法装饰。
  原生搜索和复制不变；文本仍走已有增量排版路径，不因懒高亮重建稳定历史。
- **B** 首先显示最近一页，之后的新消息始终自动追加，无论你正在看哪里；只有更早的历史
  按需加载，接近顶部时自动预取。顶部保留“更早消息”提示，可按键加载。
  `gg` 加载最早保留内容，`G` 回到最新并跟随，`[b` / `]b` 可跨页。
- 分页只改变显示范围，不修改 Session/Agent 历史。原生 `/` 和 Visual 复制只覆盖当前
  已加载文本，不提供跨未加载历史的原生搜索。`Chat:transcript()` 的显式完整导出仍包含
  Session 保留的全文，但该操作会临时全量排版。
- 接收尾部、分页排版、语法装饰和大型提交使用共享工作调度器。stdout 解析超出接收预算时，
  未处理的尾部保序排队，并计入积压限制；溢出时明确断连。分页排版中的表格和 Markdown 在结构行边界让出；
  超过 `commit_rows` 的首次布局/翻页提交按行分片写入。单个 JSON 解码、单次 Treesitter
  解析、diff 计算、非分页排版、单条超大消息分帧仍不可抢占。接收首次回调与消息派发仍使用独立接收预算。
- Visual/Select 选区活动时暂停分页排版与回收，退出后刷新。当前可见块不会因分页而被
  回收，因此受保护范围可能暂时超过预算；单个大块也不会被强行拆开。
- `page_bytes` 是每次新增页面的源载荷目标，不是 RSS 上限。为同时保留阅读位置与最新输出，
  往回加载时窗口可以超过 `max_blocks`；返回底部再收缩。A 不减少全文行缓存，B 减少初始物化范围。

运行 `nvim --headless -u tests/minimal_init.lua -l tests/perf_lazy.lua` 可比较全文、A、B 的
首个布局提交耗时、语法解析、extmark 数量和 Lua 内存。具体耗时取决于内容和本机环境。
`tests/integration_lazy.lua [native|edgy|reconnect]` 用相同方式运行开启 A+B 的集成检查。

工具调用卡片折叠时只显示标题和一行预览。展开后，`execute`（shell）调用会在输出
之前以 `$ 命令` 的形式给出完整命令行——优先取 agent 的 `rawInput.command`，没有
结构化输入时退回标题；标题栏为了适配面板宽度仍会截断长命令，卡片里的是完整文本。
命令与输出之间留一个空行，多行命令（heredoc 等）逐行显示。

文件修改的卡片标题会区分 **Edit** 与 **Write**：ACP 本身没有 `write` kind，创建/
覆盖文件也报成 `edit`，所以插件按工具输入判断——带旧内容（`oldString` / `oldText`
/ `patchText`）的是 Edit，只有新内容（`content` 等）的是 Write；输入还没到时就退回
标题里的 `write` / `create`。

`edit` / `write` / `patch` 的卡片展开后直接在卡片里画出 diff：删除行用主题的
`DiffDelete` 背景、新增行用 `DiffAdd`，`+` / `-` 号单独配色，上下文行沿用卡片底色。
只有一个 hunk 时不显示 `@@` 头，多个 hunk 才用它分隔；一次涉及多个文件时，文件之间
画一条分隔线。行数超过 `ui.diff.max_lines`
或体积超过 `ui.diff.max_bytes` 时以一行提示收尾，不会把整个文件倒进 buffer。

diff 行还会按**被编辑文件自己的文件类型**着色：`.lua` 用 Lua 语法、`.py` 用 Python
语法，颜色取自 treesitter 的 `@capture` 组，所以和你在普通 buffer 里看到的一致。
红绿背景与语法前景同时生效。实现上只把「要显示的那几行」拼成片段解析，成本与文件
大小无关（30 行约 0.6 ms，800 行约 13 ms），结果按内容缓存，流式刷新命中缓存几乎零
成本。文件类型未安装 parser、扩展名未知或行数超过 `ui.diff.max_syntax_rows` 时
静默退化为纯文本，diff 本身不受影响。设 `ui.diff.syntax = false` 可整体关闭。

这些卡片**默认展开**，因为改动本身就是要看的内容；agent 还在执行时就能看到
`rawInput` 里的变更，完成后替换成权威的 diff。

- 用户按 `<Tab>` 手动折叠后，后续更新不会再把它弹开；
- 从历史会话加载（`:Ade sessions`）或重连恢复的卡片默认折叠，避免一次展开几十个
  diff；回放提交后，再新产生的 diff 恢复默认展开，历史卡片保持折叠；
- 同进程内切回仍在运行的缓存会话时，展开状态原样保留；
- `write` 拿不到旧文件内容，因此按“全新增”展示并标注 `(new content)`。

配置示例：

```lua
require("ade").setup({
  keymaps = {
    input = {
      send = "<C-CR>",                       -- 单个键
      pick_model = { n = "M", i = "<M-m>" }, -- 按模式分别指定
    },
    chat = {
      focus_input = { "i", "<C-s>" },        -- 多个键
      toggle_block = "<C-t>",
      scroll_top = false,                    -- 关闭该绑定
    },
  },
})
```

每个字段接受四种写法：单个键、键的列表、`{ n = ..., i = ... }` 模式表、`false`
（关闭）。配置里只会绑定该动作实际声明的模式，例如转录区没有输入模式，写成
`pick_model = { n = "T", i = "<M-t>" }` 时 `i` 那一项会被忽略。两个动作在同一模式
抢同一个键会在 `setup()` 时报错（`<Tab>` 与 `<C-i>`、`<CR>` 与 `<C-m>` 视为同一个键），
而不是让后一个悄悄生效。

按键必须写在其所属视图下。`keymaps.send` 这类扁平写法会直接报错，并在报错里指出
应该写成 `keymaps.input.send`——静默忽略一个写错位置的按键最难排查。

## 安装 Agent

不需要 `npm install -g`：ade.nvim 可以把 ACP adapter 装到 Neovim 的数据目录里。

```vim
:Ade agents           " 打开管理界面（类似 :Mason）
:Ade install claude   " 开始安装并打开管理界面显示进度
:Ade install pi
:Ade update           " 更新所有有新版本的托管 Agent
:Ade uninstall pi
```

安装位置是 `stdpath("data")/ade/agents/<agent>/releases/<版本>/`，与插件目录、项目目录
和全局 npm 目录都分开。每个 Agent 只保留一个版本：更新成功后旧版本被删除（正在被某个
会话使用的版本除外）。安装完成**不会**自动切换 Agent、打开会话或登录。

管理界面与 `:Mason` 的用法一致：按状态分组（Running / Installed / Available /
Not managed），光标停在哪个 Agent 上按键就作用于它。安装在后台进行，可以同时装多个，
npm 输出实时显示在对应行下面；打开时会在后台用 `npm view` 检查新版本（不安装任何东西）。

服务后端（`backend = "service"`，且运行中的服务声明 `install` 特性）会把安装、更新、
卸载交给 `nvim_ade_server` 执行（`service/PROTOCOL.md` 第 16 节）：npm 在服务里运行，
**退出 Neovim 后安装会继续**；多个 Neovim 共用同一把 Agent 锁，其他前端发起的任务会显示
为进行中，按 `x` 可以取消自己发起的任务。直连后端、Windows 或旧服务仍然由 Neovim
自己运行 npm，行为不变，此时没有取消机制。

| 按键 | 动作 |
|---|---|
| `i` | 安装（已安装时重新安装，可用于修复） |
| `u` | 更新；已是最新版时什么都不做 |
| `U` | 更新所有有新版本的托管 Agent |
| `X` | 卸载托管副本 |
| `C` | 检查新版本 |
| `x` | 取消正在运行的任务（仅服务后端） |
| `<CR>` | 展开/收起详情（包名、目录、依赖、最近日志） |
| `s` | 把聊天切换到这个 Agent |
| `g?` | 帮助 |
| `q` / `<Esc>` | 关闭 |

| 命令 | 说明 |
|---|---|
| `:Ade agents` | 打开管理界面 |
| `:Ade install <id> [version]` | 安装；版本可写精确版本或省略（用 latest）。不带参数时打开管理界面 |
| `:Ade update [<id> [version]]` | 更新一个；不带参数时更新全部有新版本的 |
| `:Ade uninstall <id>` | 移除托管副本；凭据和会话历史不受影响 |

想在启动后自动安装缺失的 Agent，可以写 `manager.ensure_installed = { "claude", "pi" }`。

首版只托管 Claude（`@agentclientprotocol/claude-agent-acp`）和 pi
（`@geohar/pi-acp`，即 [georgeharker/pi-acp](https://github.com/georgeharker/pi-acp)）。
OpenCode 以独立 CLI 分发，仍需自行安装，管理器只报告它是否在 PATH 上。

### 安装前需要知道的

- 需要 **Node.js 22+** 和 npm；管理器不安装它们。
- 安装会运行 npm，第三方包因此可以执行安装脚本，**不是沙箱**。和 Mason 一样，按 `i`
  就是确认；想在每次安装/卸载前再弹一次确认，设 `manager.confirm = true`。
- pi 的 adapter 还需要 **pi CLI v0.80.4+** 单独安装：只装 adapter 无法运行。
- 更新失败时旧版本保持可用；安装到一半的目录会被清理。

### 三种启动来源

每个 Agent 可以用 `source` 指定从哪里启动：

```lua
require("ade").setup({
  agent = "claude",
  agents = {
    claude = { source = "auto" },   -- 默认
  },
})
```

| `source` | 行为 |
|---|---|
| `"auto"`（默认） | 有健康的托管安装就用它；否则用预设命令 |
| `"managed"` | 只用托管安装；没有或损坏时明确报错，**不会**悄悄回退 |
| `"external"` | 只用配置的命令，完全不看托管安装 |

你自己写过 `command` 或 `args` 时，该 Agent 始终按 external 处理——显式配置不会被
托管安装覆盖。只改 `env` 或 `profile` 不算覆盖启动命令。

托管安装损坏时 `auto` 会报错而不是换一个版本运行；想严格禁止 npx 回退时用
`source = "managed"`。

## 团队、看板与流程（teams，实验性）

服务声明 `teams` 能力（服务 **0.7.1+**，api_version **6**）时，可以把工作交给一个小
团队：你正在聊天的会话就是 **leader**，它按需启动 **worker**（独立的 agent 会话，
可以在各自的 git worktree 里工作），worker 之间通过服务总线（bus）传消息，你通过
**选择组件**审批和回答问题。团队和看板存在服务的 SQLite 事件日志里，Neovim 退出后
继续运行；服务重启后未关闭的团队变为挂起，恢复 leader 会话后继续。

团队有一块**看板**（列、卡片、负责人、阶段）：leader 管结构（列、建卡/删卡、挪列、
指派负责人），worker 只写自己负责卡片的正文和键值。卡片是给你看的，不是 agent 之间
的信息通道——agent 没有读取卡片的工具，看板变化也不会叫醒任何 agent。默认流程下，
一个阶段的卡片都完成后 leader 汇总一次请你确认提交，不按卡片逐个问。看板最多 16
列、200 张未归档卡片、500 张已归档卡片（超出时丢弃最旧的），整块最多 256 KiB；卡片
正文最多 8 KiB，`fields` 最多 12 个键、每个值最多 120 字符。超出时服务拒绝这次写入，
看板保持不变。

**命名流程**是一份“流程说明 + 团队组成”：内置 `default`、配置里的 `teams.workflows`、
leader 保存到服务的项目级/用户级流程；同名时按 config > project > user > builtin
解析。项目级流程按 git 仓库的公共目录区分，同一个仓库的 worktree 共用。默认流程的
正文可以用 `teams.workflows.default` 整体替换。流程里的 `leader.agent` 必须是已配置的
agent，`leader.role` 最多 4 KiB。每个项目或用户的已存流程最多 100 个；与配置里的流程
同名时 `workflow_save` 被拒绝（配置的流程遮住它）。

最小配置：

```lua
teams = {
  enabled = false,             -- true: leader 建团队后按 default 流程自动组队
  default = "dev",             -- 默认流程名（teams.workflows 里的名字或 "default"）
  workflows = {
    dev = {
      summary = "两个 opencode 写代码，leader 审查",
      columns = { "待开发", "进行中", "审查中", "等你决定" },
      team = {
        { name = "w1", template = "opencode", model = "xxx", task = "T1" },
        { name = "w2", template = "opencode", model = "xxx" },
      },
    },
  },
  spawn_from_chat = true,      -- 允许 leader 从聊天里组队
  max_workers = 3,             -- 每个团队最多 3 个 worker（1..8）
  spawn_confirm = { auto = {} }, -- 列出的模板无需人工确认
  limits = { max_turns_per_task = 30, max_turns_total = 200 },
  templates = {
    opencode = {
      agent = "opencode",      -- 必须是已配置的 agent
      model = "xxx",           -- 默认模型；spawn 不带 model 时用它
      models = { "xxx", "yyy" }, -- 允许 leader 指定的模型；省略 = 不限
      worktree = true,         -- 独立 git worktree（默认 false）
    },
    pi = { agent = "pi" },
  },
  dashboard = { wide = 160 },  -- 面板宽度 >= 160 列时用 tabpage
}
```

旧的 `teams.definitions` 和 `teams.workflow` 已删除：配置里出现时 setup 直接报错（错误
里给出新写法），不做迁移。预定义团队改用 `teams.workflows`（原来的 `workers` 列表对应
流程里的 `team`），替换默认流程正文改用 `teams.workflows.default`。流程必须有
`summary` 或 `text` 之一：只写 `text` 时 `summary` 取正文第一行；只列成员、两者都不写
时 setup 报错。所以旧写法改名时通常要补一行 `summary`：

```lua
-- 旧：teams.definitions.dev = { workers = { { name = "w1", template = "opencode" } } }
teams = {
  workflows = {
    dev = {
      summary = "一个 opencode worker",
      team = { { name = "w1", template = "opencode" } },
    },
  },
}
```

流程成员数不能超过 `teams.max_workers`（默认 3，范围 1..8）：配置校验会拒绝超过的流程
（setup 报错，写明流程名和两个数字）；运行中剩余成员会超过上限时 `team.start` 整体拒绝
（`-32061`），一个都不启动。

启动团队的三种方式：

| 方式 | 说明 |
|---|---|
| 对话 | 直接告诉 leader 要做什么；它复述计划、你确认后组队，每次 spawn 在选择组件里确认（可一次全部批准） |
| `:Ade team start [流程]` | 按命名流程启动；没给名字时弹出流程选择器，已存在的名字跳过，不用逐个确认；成功后自动打开面板 |
| `teams.enabled = true` | leader 建团队且还没有 worker 时，前端调用一次 `team.start` 按 `default` 流程启动；重连不会重复 |

命令：

| 命令 | 作用 |
|---|---|
| `:Ade team` | 打开统一面板（成员 / 看板；卡片 `<CR>` 看详情）；没有团队时显示可用流程（光标所在流程按 `S` 启动，`<CR>` 看全文） |
| `:Ade team start [流程]` | 按流程启动团队 |
| `:Ade team close` | 确认后结束当前 cwd 的团队 |
| `:Ade team answer [名字]` | 显示待处理的选项；带名字时用输入框回答该成员的无选项提问 |
| `:Ade workflows` | 列出/查看/删除命名流程（`<CR>` 全文，`d` 删除，`q` 关闭） |

补全：`:Ade team <Tab>` 补全 `start` / `close`；`:Ade team start <Tab>` 补全配置里的
流程名、已知的服务流程名和 `default`。

`:Ade team start` 依次：选流程 → 是否切换 leader agent → 已有团队怎么处理 → 输入任务
→ 确保 leader 会话 → `team.start` → 打开面板。取消任务输入时什么都不动：不关团队、
不切换 agent、不新建会话。旧服务（api_version 5）上没有 team.start、看板和流程接口：
前端提示“服务版本过旧；空闲后会自动更新，或用 `:Ade service stop` 手动重启”，不会
反复重试看板。

面板宽屏（`teams.dashboard.wide`，默认 160）在独立 tabpage 里分两栏：成员和看板；
观察时右侧再加一列。窄屏用居中浮窗，只有成员和看板。标题只在 tabline。成员栏宽度
由 `teams.dashboard.members_width`（默认 32，16..120）决定，手动拖动后本次打开期间
保持。按键作用于光标下的对象：`<CR>` 打开/切换观察窗口（卡片打开详情浮窗），
`m` 给成员发消息/就卡片给 leader 发消息，`H` 看卡片历史版本，`a` 回答成员提问，
`!` 打开待处理的选择（提问、spawn、权限、回合上限），`w` 打开观察窗口，
`p`/`r`/`c` 暂停/恢复/取消，`D` 删除已退出 worker 的 worktree，`L` 跳到 leader
聊天，`s` 按模板启动 worker，`R` 重置回合上限，`x` 结束团队，`<Tab>`/`<S-Tab>`
切换窗口，`zh`/`zl` 横向滚动看板，`g?` 帮助，`q` 关闭。观察窗口里 worker 是只读的完整回放（工具、diff、plan、回合分组
都在），leader 显示聊天会话本身并**带输入区**，可以直接对话。worker 观察窗口下方也有
输入区：`<C-s>` 排队发给该 worker 并抄送 leader；`<M-CR>` 连按两次先打断当前回合再
优先送达（`teams.dashboard.keys.interrupt` 可改）；草稿按 worker 分开保存。输入区
filetype 是 `ade_team_input`：blink/cmp 的 `per_filetype` 只写了 `ade_input` 时要补上；
图片/附件不在该输入区提供。

需要你从选项里选时（带选项的提问、spawn 申请、权限、回合上限、agent 自己的权限和
表单），聊天窗口底部会浮出一张选择卡片：Tab/Shift-Tab 切题，↑↓ 或 j/k 选择，数字直选，
Space 多选，Enter 确认，Esc 稍后（团队权限也是稍后；只有 agent 自己的权限/表单是取消）。卡片高度随内容
自动调整（最多占聊天窗口约 60%，超出时在卡片内滚动），转录区底部会留出等高的空白，最新输出不会被挡住。
卡片用独立缓冲区（filetype `ade_choice`，带 `b:ade_choice`），输入框和草稿保持可见、不受影响。
光标在聊天或输入窗口时卡片会直接获得焦点；否则只提示，回到面板后按 `<M-a>`（`keymaps.chat.focus_choice` /
`keymaps.input.focus_choice`）进入卡片。没有选项的提问只提示，用 `:Ade team answer [名字]` 回答。

**持久化**：团队、参与者、排队消息和每个团队最近 200 条消息正文、看板、卡片历史、
命名流程写入服务的事件日志数据库（权限 0600）；看板与卡片历史随团队删除，命名流程
不随团队删除。模板的 `key`/`env`/`launch` 不落盘，恢复时要由前端重新提供配置。
挂起超过 7 天的团队会被删除（worktree/分支保留）。恢复出的会话不是存储的 leader
时，团队保持挂起，在面板按 `x` 关闭；leader 注入不会被挂起团队阻塞。`--event-log off` 时 `teams` 特性
不声明、`team.*` 返回 `-32601`，团队/看板/流程都不落盘也不恢复。

`worktree = true` 的模板由服务在 `stdpath("data")/ade/worktrees/` 下创建 worktree
（分支 `ade/<team>-<stamp>/<name>`）。worktree 只包含**已提交**内容：团队目录有未提交
改动时提示 `dirty_tree`，worker 从最后一次提交开始。worker 退出或团队关闭后 worktree
与分支都保留，用面板 `D` 删除（可选 force；未合并分支保留）。

直连模式、旧服务或 `spawn_from_chat = false` 时不注入 team MCP server，单 agent 体验
不变。leader 的说明分两层：基础说明在每个可当 leader 的会话建立时随 MCP `initialize`
的 `instructions` 下发（最多 2 KiB，约 300 token；claude/opencode 会放进上下文、可被
提示缓存，pi 需要自己调 `mcp({instructions=…})` 且工具走 `mcp` 代理），不组队也有这份
固定开销；流程全文、成员和任务只在组队时通过一条 notice 发一次。

细节见 `:help ade-teams`。

## 服务后端（nvim_ade_server）

Agent 可以交给 Rust 后台服务 `nvim_ade_server` 持有，这样 Neovim 退出后 agent 继续工作，
重新打开时按同一个 key 附着回同一个实例。默认 `backend = "auto"`：服务可用就用它，
没有安装服务则安静回退 Lua 直连（只提示一次），不装服务也能照常使用：

| `backend` | 行为 |
|---|---|
| `"direct"` | Neovim 自己启动并持有 agent，与旧行为完全一致 |
| `"service"` | 通过服务通道收发 ACP；服务不可用时明确报错，**不回退** |
| `"auto"`（默认） | 服务可用就用服务，不可用只提示一次然后回退直连 |

服务提供 `policy` 能力（0.5.0+）时，权限的自动允许由**服务**执行：`permissions.auto_allow`
会以规则集下发给服务，所以即使 Neovim 退出、没有前端附着，agent 的权限请求仍按你的策略
自动回答（无人值守时依然生效）；需要人工决定的问题仍然转发给用户。inline 回合会在发送
`session/prompt` 之前单独下发只作用于该回合的规则（只能改私有副本，按 `inline.allow_writes`
/ `inline.allow_commands` / `inline.allow_kinds` 放开，其余拒绝，回合结束自动删除）。服务
做了决定时，聊天里会显示 “auto-allowed / auto-rejected / auto-cancelled” 提示，重放的历史
也会保留这些记录。旧服务或直连模式下仍由 Neovim 自己的 Lua 策略执行，行为不变。

### 安装

推荐在插件管理器里挂一个 build 钩子（lazy.nvim）：

```lua
{
  "btstream/ade.nvim",
  build = function()
    require("ade.service.install").run()
  end,
}
```

其他插件管理器（vim-plug 的 `do`、packer 的 `run` 等）在安装或更新后执行一次
`:Ade service install` 即可。两者行为相同：

1. 已经装了需要的版本就跳过；
2. 优先下载对应平台的预编译包，并用发行版里的 `SHA256SUMS` 校验（不一致直接拒绝）；
3. 下载不可用（无网络、平台不在构建矩阵、该版本还没发布）时用 `cargo` 本地编译。服务使用
   `service/rust-toolchain.toml` 锁定日期的 nightly 工具链，**建议安装 rustup**，它会自动获取
   指定的 nightly；编译仍然失败时，提示会写明需要 rustup，或者改用 `service.path` 指向你自己
   编译的二进制；
4. 两种方式都失败时给出提示，插件继续以直连模式工作，不会因此不可用。

自己编译了二进制，或者想用别的安装位置，设置 `service.path`：设置后只运行
`<path> version` 做版本检查，不下载也不编译。

```lua
require("ade").setup({
  service = {
    path = "/opt/ade/bin/nvim_ade_server", -- 可选
    release_base = "https://github.com/btstream/ade.nvim/releases/download", -- 可选，必须 https
    install_timeout = 10 * 60 * 1000,      -- 下载或编译的总超时
    start_timeout = 5000,                  -- 等待服务就绪的超时
    keep_alive = true,                     -- 退出 Neovim 时让 agent 继续运行
    idle_timeout = 1800,                   -- 空闲多少秒后服务自行退出（60-86400）
    event_log = true,                      -- 记录事件日志，供下次打开时重放
    event_log_max_mb = 256,                -- 每个实例的日志上限（16-4096 MiB）
    restore = true,                        -- 打开时恢复上次在这个目录里的会话
    restore_on_restart = true,             -- 服务/agent 停止后也尝试恢复（默认）
    reconnect_attempts = 8,                -- 意外断线后的自动重连次数（0 关闭）
  },
  backend = "auto",                        -- "direct" | "service" | "auto"（默认 auto）
})
```

`keep_alive = false` 会让每次退出（关闭 Neovim、切换 agent）都停掉 agent，
等价于直连模式的行为。

**事件日志与恢复**：服务把 agent 的 `session/update`，以及前台发出的 prompt、模型/模式变更，
记到服务目录下的事件日志里，这样重新打开 Neovim 时能重放离开期间的内容。日志**只在 agent
实例存活期间保留**：实例停止或服务重启就删除整个日志文件。设 `event_log = false` 关闭记录，
此后重新打开看不到离开期间的内容（重连后只能从那一刻开始）。

**退出不会关闭会话**：退出 Neovim 时如果客户端会 detach（agent 继续运行），不会发送
`session/close`，会话留在服务里等下次打开。只有显式关闭、删除或切换会话才发 close（服务照旧
忘记该会话）。`keep_alive = false`、直连后端等会停掉 agent 的路径仍然照常关闭。

`restore = true`（默认）时，附着到一个**已经在运行**的实例后，如果服务报告这个工作目录下有
会话，就自动重新打开**最近有活动**的那个，而不是新建空会话；没有匹配的、agent 不支持
`session/load`、或加载失败时回退到新建，并提示一次原因。

`restore_on_restart = true`（默认）时，ADE 会按 agent 配置名和工作目录记住最后选中的会话。
下一次打开 ADE 如果启动了新的服务端 agent 实例，就尝试加载该会话。两种自动恢复可以
分别开关；显式新建不会触发自动恢复。仅支持 `session/resume` 的 agent 可以接续上下文，
但不会回放历史。会话已不存在时会清除指针并新建；临时错误保留指针，再次打开可重试。
本地 `stdpath("state")/ade/last_sessions/` 只保存会话 ID 和定位信息，不保存历史、队列或凭据。

**自动重连**：服务后端下，连接**意外**断开（不是 `:Ade service stop`、`:Ade disconnect`、
关闭编辑器）时会自动重连，退避 0.5s、1s、2s、4s、8s，之后每 15s，最多
`reconnect_attempts` 次（默认 8，约一分钟）。重连期间状态栏显示 `reconnecting (n/8)`，
成功后提示一次；全部失败后停止并提示，仍可手动 `:Ade reconnect`。

**版本不一致**：插件更新后旧服务可能还在运行。版本不同但 `api_version` 相同时，服务空闲
就自动重启到新版本；有任务在跑时先用着旧的，提示一次“任务结束后会自动重启”。
`api_version` 不同则先用服务报告的版本再握手一次，再按同样规则处理。

重启服务会**连带停掉服务里还活着的 agent**（它们是服务的子进程），通知里会写明
`restarting nvim_ade_server (X -> Y); N idle agent(s) will restart with it`。空闲判据保证
没有进行中的回合、没有待处理的权限/elicitation 请求、也没有别的 Neovim 附着；重启后会话
依赖 agent 自己的 `session/load` 恢复。

`release_base` 必须是 `https://`：压缩包和 `SHA256SUMS` 来自同一个地址，若允许明文 http，
中间人可以同时替换两者，校验就失去意义；下载时也会用 `curl --proto =https --proto-redir =https`
禁止跟随重定向降级。唯一例外是回环地址（`localhost`、`127.0.0.1`、`[::1]`）可以用
`http://`，方便本地测试服务器。此外，URL 里出现反斜杠、空白或控制字符、或 authority 里带
`@`（userinfo）都会被直接拒绝——这些写法在不同 URL 解析器里含义不一致（例如浏览器会把
`http://evil.example\@127.0.0.1/` 的反斜杠当作路径分隔符），不适合用来指定发布源。

### 命令与健康检查

| 命令 | 说明 |
|---|---|
| `:Ade service install` | 安装服务（异步，进度用通知显示） |
| `:Ade service status` | 已安装版本、二进制路径、是否在运行、`api_version` 是否匹配 |
| `:Ade service start` | 在后台启动服务（已运行则直接复用） |
| `:Ade service stop` | 让服务退出 |
| `:Ade service agents` | 列出服务持有的 agent 实例：id、agent、cwd、pid、运行时长、附着数、进行中的回合、待处理请求 |
| `:Ade service kill <instance>` | 停掉一个实例（agent 进程立即结束） |

服务模式下 `:Ade disconnect` 会真正停止 agent；关闭 Neovim（或切换 agent）时则按
`service.keep_alive` 决定是 detach（保留）还是 stop。

`:checkhealth ade` 里的 “ade.nvim service” 一节与 `status` 内容一致，只报告不修改。
服务目录、socket 和令牌路径遵循同一套规则：优先 `$NVIM_ADE_SERVER_DIR`，其次
`$XDG_RUNTIME_DIR/ade`、`$XDG_STATE_HOME/ade`，最后 `~/.local/state/ade`。

## 配置

```lua
require("ade").setup({
  agent = "opencode",
  agents = {
    -- 内置预设；只覆盖你想改的字段
    opencode = { command = "opencode", args = { "acp" }, profile = "opencode" },
    claude = { command = "claude-agent-acp", args = {}, profile = "claude" },
    pi = { command = "npx", args = { "-y", "@geohar/pi-acp" }, profile = "pi" },
    -- 任何 ACP Agent 都可以这样接入；profile 省略时按名称推断，否则用 generic
    other = { command = "my-agent", args = { "--acp" } },
  },

  -- 会话的工作目录。默认与 Neovim 的 cwd 一致（vim.fn.getcwd()）。
  cwd = nil,

  -- 传给 agent 的 MCP 服务器（ACP McpServer）。stdio 总会被发送；
  -- http/sse 只有 agent 在 mcpCapabilities 中声明时才发送。
  -- 托管安装（见「安装 Agent」）
  manager = {
    root = nil,              -- 默认 stdpath("data") .. "/ade/agents"
    node = "node",
    npm = "npm",
    install_timeout = 300000,
    max_log_bytes = 1024 * 1024,
    confirm = false,         -- true：安装/卸载前弹确认框
    ensure_installed = {},   -- 例如 { "claude", "pi" }：启动后自动安装缺失的
  },

  mcp_servers = {},
  -- 例：
  -- mcp_servers = {
  --   { type = "stdio", command = "npx", args = { "-y", "@modelcontextprotocol/server-filesystem" } },
  --   { type = "http", url = "https://example.test/mcp", headers = { Authorization = "Bearer ..." } },
  -- },

  -- 本地保留的载荷预算，不是 Lua/Neovim RSS 的硬上限。
  memory = {
    max_block_bytes = 1024 * 1024,
    max_session_bytes = 16 * 1024 * 1024,
    max_cached_sessions = 8,
    max_total_bytes = 64 * 1024 * 1024,
    max_queued_messages = 16,
    max_queue_bytes = 4 * 1024 * 1024,
    max_drafts = 20,
  },

  layout = {
    backend = "native",   -- "native" | "external"（edgy 等布局管理器）
    position = "right",
    width = 0.38,         -- 0.05~1 为比例，>1 为绝对列数
    min_width = 42,
    max_width = 120,
    input_height = 8,
    min_input_height = 4,
    max_input_height = 24,
    focus_input_on_open = true,
    restore_focus = true,
    -- 锁定 ade.nvim 窗口，阻止其它 buffer 占用（winfixbuf）
    lock_buffer = true,
  },

  ui = {
    icons = true,         -- false 时使用纯 ASCII
    -- 旧键，等价于 thoughts.default_expanded = true
    show_thoughts = false,
    thoughts = {
      default_expanded = false,      -- 已完成的思考默认展开
      show_collapsed_header = true,  -- 折叠时显示头部
      expand_while_streaming = true, -- 思考进行中实时展开
      collapse_on_finish = true,     -- 思考结束后自动折叠
    },
    follow_output = true,
    wrap = true,
    picker = "vim",       -- "vim" = vim.ui.select（推荐）| "internal" = 内置浮窗
    session_picker = "snacks", -- "snacks"（可用时）| "internal"
    highlights = {},      -- 覆盖任意高亮组，见「外观」
    title = { placement = "auto" },   -- "auto" | "winbar" | "off"
    toolbar = {
      placement = "auto",             -- "auto" | "winbar" | "off"
      show_usage = false,
      animate = true,
      animation_interval = 120,
    },
    separator = {
      form = "dot",                   -- "dot" | "turn" | "off"
    },
    diff = {
      context = 3,                    -- 每个 hunk 保留的上下文行数
      max_lines = 800,                -- 超过后折叠成一行提示
      max_bytes = 512 * 1024,         -- 超过后不计算 diff
      syntax = true,                  -- 用被编辑文件的语法着色 diff
      max_syntax_rows = 800,          -- 超过后跳过着色（保持纯文本）
    },
  },

  keymaps = {
    input = {
      send = "<C-s>",
      cancel = "<C-c>",
      close_panel = "q",
      add_selection = "<C-]>",
      pick_model = { n = "M", i = "<M-m>" },
      pick_mode = { n = "m", i = "<M-b>" },
      pick_thinking = { n = "gT", i = "<M-e>" },
      pick_session = "L",
    },
    chat = {
      close_panel = "q",
      focus_input = { "i", "<C-s>" },
      toggle_block = "<Tab>",
      prev_block = "[b",
      next_block = "]b",
      open_location = "<CR>",
      help = "g?",
      add_selection = "S",
      add_file = "F",
      add_diagnostics = "R",
      pick_model = "M",
      pick_mode = "m",
      pick_thinking = "gT",
      new_session = "<C-n>",
      pick_session = "L",
      scroll_bottom = "G",
      scroll_top = "gg",
    },
  },

  permissions = {
    prompt = "select",
    -- 谨慎使用：自动放行的 option kind
    auto_allow = {},
    -- 权限窗口旁的只读详情（命令、diff、rawInput）
    show_details = true,
  },

  context = {
    max_file_bytes = 512 * 1024,
    max_selection_lines = 2000,
  },

  notices = true,         -- 显示 Agent 的时间线通知

  capabilities = {
    -- 声明给 Agent 的客户端能力；不能用的能力不要打开
    elicitation = { form = true, url = false },
    auth_terminal = true,      -- 终端登录（:Ade login）
    terminal_output_meta = true,   -- 读取 Agent 的终端输出 _meta
    boolean_config_options = true,
    fs = false,
    terminal = false,
  },

  transport = {
    -- 单条 JSON 消息的字节上限；超过会断开连接。日志会给出实际大小
    max_line_bytes = 32 * 1024 * 1024,
    -- 保留多少字节的 agent stderr 用于诊断
    stderr_keep_bytes = 64 * 1024,
    -- 关闭时等待 agent 自行退出的毫秒数，超时后升级为 SIGKILL
    shutdown_timeout = 2000,
    -- 普通请求的超时（毫秒，0 表示不限制）
    request_timeout = 30000,
    -- 单轮对话的绝对上限（毫秒，0 表示不限制）；默认 10 分钟
    prompt_timeout = 600000,
    max_pending_bytes = 64 * 1024 * 1024, -- 未消费接收数据的估算上限；0 = 不限，超限断开
    spill_bytes = 64 * 1024 * 1024,       -- 完整消息异步落盘的工作集目标；不是硬内存上限
    text_chunk_bytes = 64 * 1024,         -- 解码后超大文本的切片大小；0 = 不切片
    dispatch_budget_ms = 4,               -- 每批分发/接收切片后让出主循环；不可抢占单条消息
  },

  log = {
    level = "warn",       -- trace|debug|info|warn|error
    protocol = false,     -- true 时记录（脱敏后的）协议载荷
    max_bytes = 1024 * 1024,
  },
})
```

## 与 edgy.nvim 集成

把布局所有权交给 edgy：

```lua
{
  "folke/edgy.nvim",
  event = "VeryLazy",
  init = function()
    vim.opt.laststatus = 3        -- 面板才能完整折叠
    vim.opt.splitkeep = "screen"  -- 打开侧栏时编辑区不跳动
  end,
  opts = function(_, opts)
    -- 把 ade.nvim 的两个视图加到右侧 edgebar
    require("ade.integrations.edgy").extend(opts)
  end,
}
```

```lua
require("ade").setup({
  layout = { backend = "external" },
})
```

`extend()` 只是把下面两个 view 定义插入你的 `opts.right`，不会覆盖已有配置。

> **注意**：两个视图必须作为**数组元素**写进列表，不能写成具名字段。
> edgy 只遍历 `ipairs(views)`，`right = { { ft = "ade_chat" }, input = { ft = "ade_input" } }`
> 里的 `input` 是具名字段，edgy 会完全忽略它，导致输入框脱离 edgebar、
> 布局错位。

```lua
-- 正确
right = {
  { ft = "ade_chat",  title = "Agent", wo = { winbar = false } },
  { ft = "ade_input", title = "Message", size = { height = 8 }, wo = { winbar = false } },
}

-- 错误：ade_input 是具名字段，edgy 不会管理它
right = {
  { ft = "ade_chat", title = "Agent" },
  input = { ft = "ade_input", title = "Message" },
}
```

ade.nvim 在无法接管时会给出警告，而不是静默错位。

```lua
right = {
  { ft = "ade_chat",  title = "Agent",   size = { width = 0.38 }, wo = { winbar = false, winfixwidth = true } },
  { ft = "ade_input", title = "Message", size = { height = 8 },    wo = { winbar = false, winfixwidth = true } },
}
```

### 谁是 winbar 的所有者

默认 **ade.nvim 拥有两个 winbar**（这里是标题栏和操作栏），edgy 只负责位置和尺寸。
如果你希望 edgy 显示自己的标题栏：

```lua
require("ade.integrations.edgy").views({
  title_winbar = true,  -- chat 视图交给 edgy
  toolbar_winbar = false, -- input 视图也交给 edgy
})
-- 再配合：
require("ade").setup({
  layout = { backend = "external" },
  ui = { title = { placement = "off" }, toolbar = { placement = "off" } },
})
```

`views()` 返回 `{ chat = ..., input = ... }`，不是数组；须把两项放入 edgy 的视图列表，
或直接在配置函数中调用 `extend(opts, { title_winbar = true, toolbar_winbar = false })`。
左侧布局使用 `extend(opts, { position = "left" })`，并同步设置 ade.nvim 的 `layout.position`。

### 布局语义

| 操作 | 行为 |
|---|---|
| `:Ade hide` / `q` | 关闭两个视图，**不中断** Agent 与当前回合 |
| 单独关闭某个视图 | 不会被强行重开；下次 `:Ade open` 才补回 |
| `:Ade toggle` | 任一视图可见时隐藏，否则打开 |

外部布局模式下，ade.nvim 不会持续调整窗口尺寸，也不抢回被布局管理器移动的窗口。

## 状态栏集成

插件**不修改** `vim.o.statusline` 和 `vim.o.laststatus`。所有交互信息都在输入窗口的 winbar 里，
因此 `laststatus=3`（全局状态栏）下也完全正常。

需要把状态放进你自己的状态栏时：

```lua
-- 简短文本，例如 "◆"、"◆ ◌"、"◆ !"
require("ade").statusline()

-- 结构化数据
require("ade").status()
-- {
--   connected = true, connection = "ready",
--   running = false, waiting_permission = false, queued = 0,
--   agent = "opencode", model = "Claude Sonnet 5", mode = "Build",
--   session_id = "ses_...", usage = { used = 42000, size = 200000 },
-- }
```

lualine 示例：

```lua
{
  "ade",
  function()
    return require("ade").statusline()
  end,
  cond = function()
    return require("ade").status().connected
  end,
}
```

heirline 同理，只需调用 `statusline()` 或读取 `status()`。

## 轮次分隔符

默认在每两轮对话之间画一条细分隔线，中间一个圆点：

```
────────────────────────── ● ──────────────────────────
```

`ui.separator.form` 控制样式：

| 值 | 效果 |
|---|---|
| `"dot"` | 细分隔线 + 居中圆点（默认） |
| `"turn"` | 细分隔线 + 轮次，形如 `󰇚 Turn 2` |
| `"off"` | 不画分隔符 |

```lua
require("ade").setup({
  ui = { separator = { form = "turn" } },
})
```

面板太窄、放不下两侧的线时，只保留中间的标记。分隔符本身不绑定任何 block，
光标停在上面时 `<Tab>` 不会误展开相邻的卡片。

## 外观

样式使用**静态定义**，多数链接到 Neovim / Tree-sitter 高亮组；模式徽标默认使用固定
前景和背景色，可通过 `ui.highlights` 覆盖。插件不在运行时混合主题颜色。
正文里的 Markdown（粗体、斜体、删除线、标题、引用、链接）链接
到 treesitter 的 `@markup.*` 捕获组，所以在对话记录里的呈现和普通 Markdown buffer
遵循主题的相应样式，但渲染器并非完整的 Markdown 实现。

`ade_chat` 的标题栏（winbar）与正文共用同一个背景（`AdeNormal`），读起来是对话
记录的页眉，而不是一条独立的色带。`ade_input` 的工具栏仍然用 `StatusLine` 的颜色，
因为它是工具栏而非页眉。

对话记录的标题行拆成了图标和文字两组：`AdeUserIcon` / `AdeUserTitle`、
`AdeAssistantIcon` / `AdeAssistantTitle`。用户标题默认链接到用户图标；助手两组默认均链接到 `Keyword`；
想区分时单独覆盖即可。助手回合开头的 Markdown 标题会用 `AdeAssistantTitle`，
正文中间的标题仍保留各自的 `AdeH1`–`AdeH4` 级别。

diff 卡片使用主题自带的 diff 组，所以红绿配色与你的 review 窗口一致：

| 组 | 默认链接 | 作用 |
|---|---|---|
| `AdeDiffAdd` | `DiffAdd` | 新增行的整行背景 |
| `AdeDiffDelete` | `DiffDelete` | 删除行的整行背景 |
| `AdeDiffAddSign` | `DiffAdd` | `+` 号 |
| `AdeDiffRemoveSign` | `DiffDelete` | `-` 号 |
| `AdeDiffHunk` | `NonText` | 多 hunk 时的 `@@` 分隔行 |
| `AdeDiffMeta` | `Comment` | 卡片内分隔线与“已省略 N 行”提示 |
| `AdeDiffFile` | `Title` | 多文件时的路径表头 |

两处例外，都是为了让表格读起来安静一些：

- 行内代码链接到 `String`。`@markup.raw` 在多数主题里是暖色强调色，放在正文中
  会抢注意力。
- 表格边框链接到 `NonText`。`@punctuation.special` 会被主题染成橙色、品红之类
  的高亮色，整个表格会变成霓虹网格。

两种覆盖方式，都会优先于内置定义：

1. 在 `setup()` 里通过 `ui.highlights` 传入
2. 任何时候直接 `vim.api.nvim_set_hl`

```lua
require("ade").setup({
  ui = {
    highlights = {
      AdeUser = { link = "Identifier" },
      AdeToolTitle = { fg = "#7aa2f7" },
    },
  },
})

-- 等价，但不必重新 setup
vim.api.nvim_set_hl(0, "AdeSeparator", { fg = "#3b4261" })
```

切换 colorscheme 后会重新应用内置定义与 `ui.highlights` 配置。
直接 `nvim_set_hl` 的临时覆盖不保证跨主题保留；需持久化时使用配置或自己的 `ColorScheme` 回调。
Neovim 0.12+ 的工具栏区域继承背景；旧版本使用兼容语法，外部插件重映射 `WinBar` 时颜色可能不同。

可用的组：`AdeNormal` `AdeMuted` `AdeBorder` `AdeTitle` `AdeToolbar` `AdeToolbarAccent`
`AdeToolbarModePlan` `AdeToolbarModeBuild` `AdeToolbarIdle` `AdeToolbarRunning`
`AdeToolbarWaiting` `AdeToolbarCancelling` `AdeUser` `AdeUserChip` `AdeAssistant`
`AdeUserIcon` `AdeUserTitle` `AdeAssistantIcon` `AdeAssistantTitle`
`AdeThought` `AdeToolTitle` `AdeToolTag` `AdeCardBg` `AdeCodeBlockBg` `AdeCodeLang`
`AdeTableHead` `AdeTableBorder` `AdeToolRunning` `AdeToolSuccess` `AdeToolError`
`AdeToolCancelled` `AdeMdCode` `AdeBold` `AdeItalic` `AdeStrike` `AdeMdLink` `AdeH1`
`AdeH2` `AdeH3` `AdeH4` `AdeQuote` `AdeLink` `AdePlan` `AdePlanDone` `AdePlanPending`
`AdeNotice` `AdeNoticeWarn` `AdeNoticeError` `AdePermission` `AdeChild` `AdeSeparator`
`AdeStreaming` `AdeSelection` `AdePinned`

插件自绘的 picker（`ui.picker = "internal"` 的模型/模式/权限选择框，以及
`:Ade sessions` 的内置窗口）另有一套组，默认都链接到主题组：

| 组 | 默认链接 | 作用 |
|---|---|---|
| `AdePickerNormal` | `NormalFloat` | 浮窗背景与普通文字 |
| `AdePickerBorder` | `FloatBorder` | 圆角边框 |
| `AdePickerTitle` | `FloatTitle` | 浮窗标题 |
| `AdePickerSelection` | `AdeSelection` | 光标所在行 |
| `AdePickerItem` | `Normal` | 每行的标题文字 |
| `AdePickerMatch` | `Search` | 过滤时命中的字符 |
| `AdePickerCurrent` | `StatusLine` | 当前会话的箭头、`✓ current` |
| `AdePickerCurrentItem` | `AdeTitle` | 当前行标题（只强调前景，不画背景） |
| `AdePickerDescription` | `Comment` | 行尾右对齐的描述 |
| `AdePickerMeta` | `Comment` | 会话列表里的更新时间 |
| `AdePickerEmpty` | `Comment` | `no match` / `no matching sessions` |
| `AdePickerSeparator` | `NonText` | 列表与页脚之间的分隔线 |
| `AdePickerPrompt` | `AdeToolbarAccent` | 过滤提示符与输入内容 |
| `AdePickerFooter` | `Comment` | 页脚提示与临时状态（`deleting...`） |

浮窗的边框、标题和背景通过 `winhighlight` 映射到前三个组，因此在
`style = "minimal"` 的浮窗里也能单独改色，而不必动全局的 `NormalFloat`。
`AdePickerItem` 链接到 `Normal`：浮窗里 `winhighlight` 已经把 `Normal` 映射到
`AdePickerNormal`，而 snacks 列表里它仍然是列表自己的背景色，不会多出一层浮窗底色。

snacks 后端只接管行内容：它的窗口沿用你已有的 snacks 主题，不套用上面三组。

`ui.icons = false` 为主要图标选择 ASCII 默认集，仍可用 `ui.icon_overrides` 覆盖。

### 自定义输入区 Winbar

```lua
require("ade").setup({
  ui = {
    toolbar = {
      component_separator = { text = " · ", hl = "Comment" },
      sections = {
        left = {
          { "mode", separator = { left = { text = "", hl = "MyModeLeft" }, right = " " } },
          { "attachments", separator = " " },
          { "model", separator = { text = " │ ", hl = "NonText" } },
          "thinking",
        },
        right = { "status", "queue" },
      },
    },
    icon_overrides = {
      status_idle = "○",
      spinner_frames = { "◐", "◓", "◑", "◒" },
      modes = {
        opencode = { build = "B", plan = "P" },
        claude = { default = "D", acceptEdits = "E", plan = "P", auto = "A", bypassPermissions = "!" },
      },
    },
  },
  keymaps = {
    input = { pick_thinking = { n = "gT", i = "<M-e>" } },
    chat = { pick_thinking = "gT" }, -- false 可禁用
  },
})
```

- 默认布局和分隔符定义在 [`lua/ade/config.lua`](lua/ade/config.lua) 的 `ui.toolbar` 中。可分别替换 `left` 和 `right`，用 `{}` 清空一侧。内置组件有 `mode`、`model`、`thinking`、`attachments`、`context`、`cost`、`status`、`queue`。显式列出 `context` 或 `cost` 时，有数据即显示；`show_usage` 控制的是默认布局。
- `ui.toolbar.right_padding` 默认在右侧留一格，设为 `0` 可贴边；空间不足时优先显示组件。
- 组件可写成名字、`function(ctx) ... end` 或 `{ 名字或函数, ... }`。可选字段：`color`（高亮组）、`padding`（数值或 `{left, right}`）、`cond(ctx)`、`fmt(text, ctx)`、`priority`（越高越晚裁剪）。`ctx` 提供 `agent`、`profile`、`mode`、`model`、`thinking` 等当前显示数据；回调在重绘时运行，应快速且无副作用。
- 分隔符支持字符串、`{ text = "...", hl = "高亮组名" }` 或 `false`。组件可用 `separator = { left = ..., right = ... }` 分别指定两边，并可在分区边缘显示端帽。同一分区内，从前一个可见组件的 `right`、后一个可见组件的 `left`、全局默认值依次查找；`false` 停止查找且不画。未指定 `hl` 时，分隔符继承所属组件的高亮；全局分隔符默认跟随前一个可见组件。显式 `hl` 优先，可通过 `vim.api.nvim_set_hl()` 定义。
- 点击 Thinking Level，或调用 `require("ade").pick_thinking()`，可选择当前 agent 提供的档位；没有上报档位时不会显示该组件。
- `icon_overrides.modes` 使用 **agent 配置名 / profile 名 → ACP mode ID**，如 `acceptEdits`；精确的 agent 配置优先于 profile。图标不改变模式权限。单项设为 `false` 可隐藏图标，模式徽标则显示文字。`spinner_frames = false` 禁用帧动画；可用 `status_running` 覆盖静态运行图标。其他图标键名见 [`lua/ade/ui/icons.lua`](lua/ade/ui/icons.lua)。

## 权限与安全

- ACP 本身不是沙箱，插件无法限制 Agent 进程访问文件系统。
- 只声明真正实现的客户端能力；未实现的 `fs/*` 和 `terminal/*` 请求会返回标准 JSON-RPC 错误。
- Agent 提供的标题、路径、链接都按不可信文本渲染，不自动执行、不自动打开。
- 写入由 Agent 自身完成；ade.nvim 不会静默保存或覆盖你的 buffer。
- 日志默认不记录密钥与完整提示词；开启 `log.protocol` 时会先脱敏再截断。

## 行为细节

### 工作目录

会话的工作目录默认就是 **Neovim 的当前目录**（`vim.fn.getcwd()`），面板、Agent
和你看到的是同一个目录。可以用 `cwd` 显式固定：

```lua
require("ade").setup({ cwd = "/home/user/projects/my-app" })
```

`:Ade sessions` 的列表也按这个目录过滤。若该目录下没有会话，ade.nvim 会自动
退回展示 Agent 知道的所有会话，而不是提示「没有会话」。

> 切换到历史会话时，ade.nvim 会使用**该会话自己的目录**发起 `session/load`。
> ACP 规范要求 cwd 与会话一致，Agent 会在不匹配时拒绝该请求。目录末尾的 `/` 会被
> 去掉（根目录除外），避免同一目录因写法不同被判成两个。

### 会话的加载、恢复与关闭

打开历史会话时，ade.nvim 按 Agent 能力选择方式：

| Agent 能力 | 行为 |
|---|---|
| `loadSession` | `session/load`，回放完整历史 |
| 只有 `sessionCapabilities.resume` | `session/resume`，恢复 Agent 端上下文但**不回放历史**，并提示「history is not replayed」 |
| 两者都没有 | 新建会话 |

会话切换、删除会话和退出 Neovim 时，若 Agent 声明了 `sessionCapabilities.close`，
会发送 `session/close` 释放 Agent 端资源；没有该能力的 Agent 会被跳过。退出时是同步
等待响应后再终止进程，避免通知随进程一起消失。

会话列表会跟随 Agent 的 `nextCursor` 翻完所有页，因此标题查找和 picker 不会只看到
第一页。

### MCP 服务器

`mcp_servers` 会在建立会话时交给 Agent：

```lua
require("ade").setup({
  mcp_servers = {
    { type = "stdio", command = "npx", args = { "-y", "@modelcontextprotocol/server-filesystem", "." } },
    { type = "sse", url = "http://localhost:8080/sse" },
  },
})
```

stdio 是 ACP 的基线能力，总会被发送；`http` / `sse` 需要 Agent 在 `mcpCapabilities`
里声明，否则会被丢弃而不是发出去让 Agent 报错。同一份配置用于 `session/new`、
`session/load` 和 `session/resume`。


### 面板尺寸

原生布局的 `layout.width` 为 `0.05~1` 时按编辑器宽度取比例，`>1` 时为绝对列数。
先应用 `min_width` / `max_width`，再限制为编辑器宽度的 60%；窄屏或窗口空间不足时，
实际宽度可能小于 `min_width`。输入高度受 `min_input_height` / `max_input_height` 约束。
外部布局模式下由布局管理器决定这些尺寸。

两个面板窗口均设置 `statuscolumn = " "`，不覆盖用户全局的行号栏配置。

构建面板时会临时关闭 `'equalalways'`，等两个窗口都创建完、尺寸设置好之后再恢复。
否则第二次 split 会立刻重排，把配置的宽度覆盖掉。

### 会话标题

标题显示在对话记录窗口的标题栏（winbar）里，未生成时回退为会话 ID 短码。

为兼容未推送 `session_info_update` 的 OpenCode 版本，
ade.nvim 在**会话创建后、切换会话后、以及每回合结束后**查询列表，并用
session id 做缓存，因此切换后标题立即更新。

若 Agent 主动推送 `session_info_update`，该路径同样生效，两边不冲突。
历史先重放到暂存对象，成功后提交；失败保留旧会话与队列，不会先清空界面。
同一时间只执行一次历史重放。选择仍在运行的缓存会话时直接查看，不重复加载它的历史；
较早的加载结果也不会抢走后来新建/选择会话的焦点。

### 会话浏览器

`:Ade sessions` 默认使用 **snacks.nvim 的 picker**：自带 fuzzy 搜索、实时预览，
并沿用你已有的 snacks 主题。未安装 snacks 时自动回退到内置窗口，不会报错。

| 按键 | 说明 |
|---|---|
| `<CR>` | 切换到选中会话 |
| `<C-d>` | 删除选中会话（二次确认） |
| 输入 | fuzzy 过滤（fzf 语法） |
| `<Esc>` / `q` | 关闭 |

列表右侧显示更新时间，当前会话行首有箭头标记；右侧预览区显示完整会话 ID、
目录与创建/更新时间。删除后列表原地刷新，可连续删除。

想强制使用内置窗口：

```lua
require("ade").setup({ ui = { session_picker = "internal" } })
```

内置窗口（回退时）支持 `j`/`k` 移动与 `<BS>`/`<C-u>` 编辑过滤。
`q` 关闭、`gg`/`G` 跳转；这些按键对应的字母可用大写 `Q`/`J`/`K` 输入过滤，
`g` 用于过滤（`gg` 仍可跳到首项）。

- 删除非当前会话：当前对话不受影响。
- 删除当前会话：确认后自动新建一个会话。
- Agent 未声明 `sessionCapabilities.delete` 时给出提示，不弹出无法兑现的确认框。

### 窗口保护

ade.nvim 的两个窗口默认锁定到自己的 buffer（`winfixbuf`），因此 `:edit`、`:bnext`、
插件里的「在当前窗口打开」等操作都不会把对话记录或输入框替换成别的文件。

- 关闭窗口、`:q`、隐藏面板都仍然正常。
- 从面板 `:split` / `:vsplit` 会得到一个可用的普通窗口，而不是被锁死的副本。
- 需要临时解除（例如配合某些窗口管理插件）时：

```lua
require("ade").setup({ layout = { lock_buffer = false } })
```

> `winfixbuf` 需要 Neovim 0.10+。更早的版本上插件会跳过锁定并记录一条 debug 日志。

### 消息排队

同一会话同时只运行一个 prompt。生成中提交的消息会本地排队，
当前回合结束后依次发送，工具栏显示 `+N queued`。
队列默认最多 16 条、估算载荷 4 MiB；超过限制时拒绝入队并保留输入草稿。
队列属于会话运行时，不属于当前窗口：切换到 B 不会停止 A 的队列，也不会把 A 的错误
显示到 B。历史替换复用同一个 outbox，待发送消息不会被重放覆盖。

再次 `setup()` 会建立新的运行环境并取消旧任务。存在待发送消息时默认拒绝重新配置，
避免静默丢弃；先等待队列清空，或者**明确同意丢弃后**调用：

```lua
require("ade").setup({ layout = { backend = "native" } }, { discard_queued = true })
```

队列目前只保存在本次 Neovim 进程内，不是持久化 outbox；正常退出或崩溃不会恢复它。

### 思考块

思考进行中会实时展开并显示 `Thinking`，正文随 chunk 更新；思考结束（Agent 转入正文、
工具、计划，或回合结束）后自动折叠并改为 `Thought`。历史会话和重连重放的思考保持折叠。

跟随输出时，超过一屏的内容在自动折叠后仍保持尾部锚定，保留原有尾部空行，后续消息继续追加。
内容不足一屏时从顶部正常显示，不添加顶部留白；鼠标到达末尾后不能再将内容向上推移来扩大底部空白。
上翻阅读历史或手动折叠卡片时不强制跳到最新位置；聊天窗口启用局部 `smoothscroll` 以处理跨屏换行。
鼠标上滚离开末尾会暂停自动跟随，滚回实际末尾后自动恢复，并清除新消息提示；判断依据是视口，
不要求光标也停在最后一行。暂停期间仍正常接收消息并追加到 buffer，只是不抢占阅读位置。

`<Tab>` 手动操作始终优先：流式中折叠后不会被后续 chunk 弹开。需要改变默认值时：

```lua
ui = { thoughts = { expand_while_streaming = false, collapse_on_finish = false } }
```

### 中断与恢复

Agent 崩溃或退出时，正在运行的工具会被标记为失败，并提示 `:Ade reconnect`。
重连会调用 `session/load` 重放 Agent 侧历史，不会自动重发上一条 prompt。
断连会暂停各会话队列、取消旧请求并使旧选择器失效。当前会话恢复成功后继续发送尚未开始
的排队消息；其他会话在选中并恢复后继续。已发出的 prompt 不自动重试，避免重复执行工具。
任务的单次结算保证不等于 Agent 操作的 exactly-once 执行保证。

### 草稿持久化

未发送的输入和附件按「项目 + 会话」保存在
`stdpath("state")/ade/drafts.json`，重启后自动恢复。空草稿会被清除，
最多保留 50 条。
内存中的历史草稿默认最多 20 条（`memory.max_drafts`），当前输入框不受淘汰影响。
磁盘读写有缓存与 150ms 合并窗口，普通保存异步写入，退出时执行最终 flush；
崩溃可能丢失尚未完成持久化的最近修改。
保存始终使用输入框原本的项目/会话身份，不依赖保存时哪个会话可见；消息接受后清理对应
草稿，即使发送过程切换了会话，也不会清空新会话的输入框。仅附件的草稿同样会保留。

### 长会话与性能边界

- 控制器维护 block 变更版本与有限变更日志，渲染只重建变化块及行坐标受影响的后缀；
  稳定前缀保留文本、元数据与 extmark。窗口宽度变化、换主题或变更日志落后时走完整路径。
  当前变化消息仍会物化完整文本；含代码的消息仍重新排版，但会复用语法分析结果，并非逐字符零复制。
- 代码语法缓存与布局宽度分离，已闭合代码不会因后续文字追加而重新解析；缓存最多
  64 项、约 2 MiB。单代码块超过 256 KiB 时降级为纯文本，语法捕获最多 20,000 项。
- 每会话仍保留最多约 2,000 个 block，同时应用字节预算。超大 block 会显示截断标记，
  会话超预算会批量移除最旧记录；这些限制不修改 Agent 侧历史，重新加载仍受本地预算限制。
- 非活动、空闲会话按 LRU 淘汰；当前会话、运行中、有待发送消息或权限请求的会话不会
  被淘汰。因此受保护会话可暂时超过缓存数量/总载荷预算，预算也不包括 Lua 对象、渲染缓存与 Neovim buffer 的全部开销。
- 协议消息按时间预算有序分批处理，超出待分发队列预算时断开连接；单条 JSON 解码或单块排版仍不可抢占。
  普通通知在该批次内直接归约，不再逐条投递第二个无预算队列；权限 UI 单独调度。
- 独立使用 session/view 的代码可保留兼容渲染路径。启用 `session:track_changes()` 后，
  直接修改 block 必须调用 `session:touch(block)`；仅状态/折叠变化可用 `touch(block, false)`。

### 切换模型与模式

有三种方式，任选其一：

1. **直接点击** winbar 上的模型名或模式徽标（不显示下拉箭头）。工具栏只显示模型名，
   例如 `DeepSeek V4.1 Flash` 而不是 `commandcode/DeepSeek V4.1 Flash`；
   选择器里仍保留完整名称，便于区分不同 provider 的同名模型。

   > 鼠标须在当前模式启用。默认 `mouse = "nvi"` 已覆盖普通、可视、插入模式，
   > 不需要改为 `a`；`mouse = ""` 会关闭鼠标支持。终端也须正确转发鼠标事件。
2. 输入时按 `<M-m>` 切换模型、`<M-b>` 切换模式。
3. 普通模式按 `M` / `m`，或执行 `:Ade model` / `:Ade mode`。

`:Ade config` 把 Agent 提供的所有会话选项（模式、模型、思考级别、布尔开关及其它配置）放在
一个选择器里；布尔选项选中即翻转，不再弹第二层选择器。工具栏上模式是左侧徽标，思考级别是
它旁边的小标记。

切换 Agent 用 `:Ade agent`（或 `:Ade agent claude` 直接指定）。每个 Agent 的会话标题与工作
目录分开缓存，切换回来时不会串台。内置 `opencode`、`claude`、`pi` 三个预设，只覆盖你要改的
字段即可。

普通选择器（模型、模式、权限确认）默认走 **`vim.ui.select`**，因此
telescope、fzf-lua、snacks.nvim、dressing 等插件会自动接管，无需额外配置。
选中后立即生效，工具栏同步更新。会话浏览器独立使用 `ui.session_picker`。

想用插件自带的浮动选择器（带模糊过滤，适合上百个模型的场景）：

```lua
require("ade").setup({ ui = { picker = "internal" } })
```

> 不要使用 `<C-m>`：在终端里它与 `<CR>` 是同一个键。

### 登录

Agent 在 `initialize` 里声明登录方式时，`:Ade login` 会使用它：

- 只有一个方式时直接执行；多个时用选择器挑选（显示名称和说明）。
- `terminal` 类型会在新的 `:terminal` 分屏里运行**你自己配置的** Agent 命令，只追加 Agent 给出的
  参数和环境变量（ACP 规定登录方式不能指定命令）。启动前会显示实际执行的命令；命令成功退出后
  会重启 Agent 进程并重试刚才失败的操作。连续失败会停止重试，`:Ade login` 可重新开始。分屏落在
  你最后编辑的窗口下方（面板记录的焦点窗口），不会顶掉聊天区或输入框；空间不足时改用新 tab。
- `agent` 类型（或没有 type）调用 `authenticate(methodId)`，成功后直接重试。
- `session/new`、`session/load`、`session/prompt` 返回 `auth_required`（-32000）时也会进入同一流程。
  超时、断线等本地失败使用不同的错误码，不会误触发登录。
- Agent 完全没有提供登录方式时只提示查看它的文档。
- `:Ade logout` 仅在 Agent 声明 `auth.logout` 时可用。

### 权限请求

Agent 请求权限时弹出选择器，并在旁边打开一个只读详情浮窗：

- `Esc` / `q` 关闭视为拒绝，优先选择 `reject_*` 选项；
  若 Agent 没有提供拒绝项，则返回 `cancelled`。
- 关闭面板不会让权限请求永久挂起。
- 详情浮窗按工具类型显示：`execute` 显示完整命令和工作目录，`edit` 显示 diff，
  其它显示 `content` 或格式化后的 `rawInput`。`permissions.show_details = false` 可关闭。
- 等待回答或批准的 tool card 会显示对应状态，在卡片上按 `<CR>` 可重新打开该请求。
- 可用 `permissions.auto_allow = { "allow_always" }` 显式放开某类请求。
  提问型的权限请求（pi 的 select/confirm、Claude 的 ExitPlanMode）不会被自动回答。

### 提问

Agent 通过 elicitation 提问时（Claude 的 AskUserQuestion、OpenCode 的 question 工具），
ade.nvim 显示表单：

- 只有一个单选字段时直接弹出选择器；多个字段时打开表单，`<CR>` 编辑当前字段，
  `<C-s>` 提交，`q` 取消，`d` 拒绝。
- 选项旁的 `<key>_custom` 字段会成为 "Other"，也可以在选择选项后作为备注一起提交。
- 不支持的结构（嵌套对象等）会回复 `decline` 并提示。
- 需要浏览器时（URL 模式）弹确认后交给 `vim.ui.open`。

## 已知限制

- 未实现客户端侧的文件读写与终端能力（`fs/read_text_file`、`terminal/*`），
  这些功能由 Agent 自行完成。
- 登录方式由 Agent 提供；插件不内置任何 Agent 专属的登录命令或凭据处理。
- 修改审阅（逐块接受 / 拒绝）尚未提供：可以展开工具调用查看完整 diff，但不能在
  插件里应用或回滚某一块改动。
- 会话历史来自 Agent（`session/list`），ade.nvim 不额外保存一份对话库。
- 部分能力（压缩、用量、子会话）依赖 Agent 的扩展，缺失时会自动降级。

### 服务后端（`backend = "service"` / `"auto"`）

- 服务模式下 agent 归 nvim_ade_server 持有，因此 Neovim 退出后 agent 仍在运行。
  但 Lua 侧的托管安装租约（`manager` 的 lease）仍只由本进程持有：Neovim 退出、
  租约释放后，另一个实例执行 `:Ade update` / `:Ade uninstall` 可能删掉这个仍在
  运行的 agent 依赖的 release 目录。S2 把托管安装迁入服务后才解决。在此之前，
  用服务模式时避免在其它 Neovim 里更新/卸载正在被后台 agent 使用的托管 Agent。
- 连接断开（服务崩溃、被 `:Ade service stop`）不会自动重连，界面显示为断开，
  需要手动 `:Ade reconnect`；自动重连与按序号补发在后续阶段实现。
- 同一时刻只保留一个到服务的连接（每个 Neovim 一个），但多个 Neovim 可以同时
  附着到同一实例；agent → 客户端的请求（权限、提问）由最后附着的连接回答。
- 多个 Neovim 附着同一实例时，每个连接都会收到该实例的全部 `session/update`。
  对**不属于自己的会话**的更新，reducer 直接丢弃（`session_update` 找不到会话就
  return，只写一条 debug 日志），既不入队也不缓存，因此不会因为别人的会话而增长。
  唯一会缓冲的是"正在 `session/new`、会话 id 还没拿到"的那一小段，它有上限
  （256 条 / 1 MiB，超出丢最旧的）。此外客户端自己的待派发队列上限 64 MiB，
  与服务端每个连接 64 MiB 的出站队列上限一致；**超出时不丢任何一条消息**，
  而是按连接丢失处理（断开、清空队列、各实例通道上报退出并说明是前台处理不过来），
  重新连接即可——丢一条响应或权限请求只会让对应请求悬挂到超时或让状态悄悄错乱。

## 开发

```bash
# 单元测试
nvim --headless -u tests/minimal_init.lua -l tests/run.lua

# 界面集成测试（含 laststatus=0/2/3）
nvim --headless -u tests/minimal_init.lua -l tests/integration.lua

# edgy 兼容性测试
nvim --headless -u tests/minimal_init.lua -l tests/integration_edgy.lua

# 重连与性能回归
nvim --headless -u tests/minimal_init.lua -l tests/integration_reconnect.lua
nvim --headless -u tests/minimal_init.lua -l tests/perf.lua

# 布局预览
nvim --headless -u tests/minimal_init.lua -l tests/render_preview.lua

# 真实 OpenCode 冒烟测试（需要已登录）
nvim --headless -u tests/minimal_init.lua -l tests/manual_opencode.lua
```

`:checkhealth ade` 会检查 Neovim 版本、Agent 可执行文件、edgy 与日志路径。

可运行配置位于 `examples/minimal/init.lua` 和 `examples/edgy/init.lua`。
后者需要事先把 edgy.nvim 加入 runtimepath；这些示例不会自动安装依赖。
当前代码检查记录与验证边界见 [docs/status.md](docs/status.md)。
运行时所有权、任务生命周期与模块边界见 [docs/architecture.md](docs/architecture.md)。

## 许可证

MIT
