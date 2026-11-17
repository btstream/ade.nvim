# W0 技术架构草案：团队面板、看板与流程（待审）

状态：**草案，等待审核**。功能和界面以 `docs/w0-team-dashboard-draft.md` 为准，本文只讲怎么实现：
模块怎么分、数据存在哪里、协议怎么改、数据怎么流动、按什么顺序做。

## 1. 总览

```
┌──────────────────────────── Neovim（前端，Lua）────────────────────────────┐
│ config.lua      teams.workflows / templates.models / dashboard 配置校验        │
│ app/team.lua    团队状态缓存：team.list、inbox、board、workflows、watch        │
│ ui/team/        统一面板：成员 / 收件箱 / 看板 / 详情 / 观察窗口                │
│ ui/workflows.lua  :Ade workflows                                            │
│ ui/chat.lua     （复用）观察窗口 = 只读 Chat 实例；leader = 它自己的 Chat      │
└──────────────┬───────────────────────────────────────────────────────────┘
               │ JSON-RPC over unix socket（PROTOCOL.md；api_version 5 → 6）
┌──────────────▼──────────── nvim_ade_server（Rust）─────────────────────────┐
│ hub/teams.rs     请求分发：team.* / bus.*，通知 team.changed / board_changed │
│ team/mod.rs      团队、参与者、投递、收件箱（已有）                            │
│ team/board.rs    看板模型、校验、合并写入、卡片摘要         ← 新                │
│ team/workflow.rs 命名流程：模型、校验、解析顺序              ← 新                │
│ team/activity.rs “最近动态”提取与限速                       ← 新                │
│ team/brief.rs    leader 基础说明、组队通知、角色卡拼装       ← 新                │
│ team/mcp.rs      MCP server：initialize.instructions、按角色列工具（扩展）     │
│ store.rs         SQLite：新增 boards / card_history / workflows 三张表         │
└──────────────┬───────────────────────────────────────────────────────────┘
               │ ACP（stdio 管道）                │ MCP stdio（nvim_ade_server mcp）
        ┌──────▼──────┐                    ┌──────▼──────┐
        │ leader agent │ ── tools/call ──▶ │ ade-team MCP │ ── bus.* ──▶ 服务
        │ worker agents│                   └─────────────┘
        └─────────────┘
```

原则保持不变：服务拥有全部状态和 agent 进程；Neovim 只渲染、只发起人的操作；
服务里没有流程状态机，只做校验、保存、转发和提取。

## 2. 服务端

### 2.1 模块划分

`team/mod.rs` 已有 4246 行，新功能放进独立子模块，`mod.rs` 只增加挂接点。

| 模块 | 内容 | 对外接口（示意） |
|---|---|---|
| `team/board.rs` | `Board`、`Card`、`Column`；`board_update`/`card_update` 的校验和应用；权限（leader 管结构，owner 写 `body`/`fields`/`archive`）；大小上限；worker 写入的 10 秒合并；`bus_status` 用的结构摘要；卡片消息摘要行 | `Board::apply_leader(ops) -> Result<Rev>`、`Board::apply_owner(name, op)`、`Board::outline()`、`Board::summary_line(id)` |
| `team/workflow.rs` | `Workflow`（`summary/text/leader?/team/columns/scope`）；校验（`team` 不含 `leader`/`human`、模板存在、模型在 `models` 内）；三个来源合并（配置 > 项目 > 用户 > 内置 `default`）；内置默认流程文本 | `Workflows::resolve(project, name)`、`Workflows::list(project)`、`save`/`delete` |
| `team/activity.rs` | 从 worker 的 `session/update` 提取一行动态（`tool_call` 标题、`plan` 进行中条目、发出的总线消息、回合末正文首行）；每个参与者 2 秒限速；`state_since` | `Activity::observe(update) -> Option<Changed>` |
| `team/brief.rs` | leader 基础说明（MCP `instructions` 和组队通知共用一份）；组队通知正文（流程全文 + 成员 + 任务）；worker 角色卡拼装（模板 `role` + spawn 的 `role` + 卡片约定 + pi 代理调用说明） | `leader_instructions()`、`start_notice(workflow, task)`、`role_card(template, role, agent)` |

挂接点（已有代码里要改的地方）：

- `team/mod.rs`：`Team` 增加 `board: Board`；`TeamConfig` 增加 `workflows`、`default_workflow`，`Template` 增加 `models`；
  `SpawnRequest` 增加 `model`、`role`；inbox 的 `spawn` 项增加 `group`（同一 leader 回合内发出的申请共用一个 id）。
- `hub/teams.rs`：
  - 新的 `bus.*` 和 `team.*` 分发（见 2.3）；
  - `note_worker_chunk` 扩展为 `note_worker_update`：把每个 worker 的 `session/update` 交给 `activity`，
    把 `bus_send`/`bus_ask_human` 工具调用也作为动态来源；leader 只取总线相关的动态；
  - 启动 worker 后的模型校验：`session/new` 的 `configOptions` 里没有请求的模型时，停掉 worker，
    给 leader 发 `notice`（列出可用模型）。现在是悄悄忽略。
- `team/mcp.rs`：`initialize` 结果加 `instructions`（只给 leader 的 token）；按角色列工具；新增工具的 schema。

### 2.2 存储

现在团队整体以 JSON 存在 `teams.state_json`，由快照写入器整块重写。看板和历史变化频繁、体积较大，
**单独建表**，不塞进团队快照：

```sql
CREATE TABLE boards (
  team_id   TEXT PRIMARY KEY,
  rev       INTEGER NOT NULL,
  json      TEXT NOT NULL            -- 整块看板（≤ 256 KiB）
);
CREATE TABLE card_history (
  team_id   TEXT NOT NULL,
  card_id   TEXT NOT NULL,
  rev       INTEGER NOT NULL,        -- 写入前的看板 rev
  json      TEXT NOT NULL,           -- 卡片旧版本
  ts_ms     INTEGER NOT NULL,
  PRIMARY KEY (team_id, card_id, rev)
);
CREATE TABLE workflows (
  scope     TEXT NOT NULL,           -- 'project' | 'user'
  project   TEXT NOT NULL,           -- scope=project 时为项目键；user 时为 ''
  name      TEXT NOT NULL,
  json      TEXT NOT NULL,
  updated_ms INTEGER NOT NULL,
  PRIMARY KEY (scope, project, name)
);
```

- **写入时机**：leader 写入立即落盘；worker 写入在内存里立即生效，落盘和 `team.board_changed` 合并到至少间隔 10 秒。
  服务退出时冲刷未落盘的写入。
- **历史**：每次落盘前，把被改动卡片的旧版本写进 `card_history`，每张卡片只留最新 20 条（同一事务内删旧的）。
  归档时删除这张卡片的全部历史。
- **删除**：团队被删除（`team.close` 或挂起超过 7 天被清理）时，`boards` 和 `card_history` 一并删除；`workflows` 不受影响。
- **项目键**：团队 cwd 所在 git 仓库的公共目录（`git rev-parse --git-common-dir` 的规范路径），
  这样同一个仓库的各个 worktree 共用项目级流程；不在 git 仓库里时用 cwd 本身。
- **配置里的流程**（`teams.workflows`）不入库，随 `team.configure` 交给服务，只在内存里，只读。
- **恢复**：服务重启后，挂起的团队连同看板一起恢复（沿用 18.15 的流程，加载时多读一张表）。
- 建表沿用 `create_schema` 的 `CREATE TABLE IF NOT EXISTS`，旧库升级不需要迁移步骤。

### 2.3 协议改动（PROTOCOL.md 新增第 19 节，api_version 6，服务 0.7.0）

**MCP 工具（`bus.*`）**

| 工具 | 谁 | 方法 | 说明 |
|---|---|---|---|
| `team_spawn` | leader | `bus.spawn` | 增加 `model?`、`role?` |
| `board_update` | leader | `bus.board_update` | `workflow_name?`、`workflow?`、`columns?`、`upsert?`、`archive?`、`remove?` → `{rev}` |
| `card_update` | worker | `bus.card_update` | `card`、`body?`、`fields?`、`archive?` → `{rev}` |
| `workflow_save` / `workflow_get` / `workflow_delete` | leader | `bus.workflow_*` | 2.4 节 |
| `bus_status` | all | `bus.status` | leader 结果增加 `board`（结构摘要）、`workflows`（名字 + 一行说明）、模板的 `agent`/`models` |

**前端方法和通知**

| 方法 / 通知 | 说明 |
|---|---|
| `team.configure` | `config` 增加 `workflows`、`default_workflow`，模板增加 `models`；删除 `definitions` 相关字段 |
| `team.start {team, workflow, task?}` | 新：服务按流程逐个 spawn（以 `human` 身份，不需确认，已有的名字跳过），再给 leader 发组队通知。`:Ade team start` 和 `teams.enabled` 自动组队都走它，前端不再自己循环 `team.spawn` |
| `team.board {team}` | → `{board}` |
| `team.card_history {team, card}` | → `{versions}` |
| `team.workflows {cwd}` / `team.workflow_delete {cwd, name}` | 列出 / 删除命名流程 |
| `team.send` | 增加 `card?`：服务在正文前加卡片摘要行 |
| `team.answer_group {group, allow}` | 新：一组 spawn 申请一起批准或拒绝 |
| `team.list` | 团队条目增加 `board_rev`、`workflow_name`、`stage_progress`；参与者增加 `activity`、`state_since` |
| 通知 `team.board_changed {team, rev}` | 只发给前端连接 |

错误码沿用 18.10（`-32060` 参数无效，`-32061` 不允许，`-32064` 未知），不新增。

### 2.4 关键流程

**`:Ade team start review_by_pi`**

```
前端                          服务                                   leader / workers
 │ 确保 leader 会话（必要时新建）   │                                        │
 │ team.start{team,"review_by_pi",task}                                     │
 │ ─────────────────────────────▶ resolve(workflow)                        │
 │                               for m in workflow.team: spawn(m)  ──▶ w1, w2, reviewer 启动
 │                               notice → leader：基础说明+流程全文+成员+任务 ─▶ leader 回合
 │ ◀──── team.changed ×N          │                                        │ board_update(...)
 │ ◀──── team.board_changed       │ ◀──────────── bus.board_update ────────│
 │ 打开面板                        │                                        │ bus_send(task → w1 …)
```

**worker 更新卡片**：`card_update` → `board.rs` 校验 owner → 内存生效 → 合并计时器到期 →
写历史 + 落盘 → `team.board_changed` → 前端 `team.board` 拉取并重绘。**不进任何 agent 的信箱。**

**卡片消息**：面板 `m` → `team.send {to=leader, kind=notice, task=T3, card=T3, body}` →
服务拼上摘要行 → 排队 → leader 空闲时和其他排队消息合成一个回合。

**最近动态**：worker 的 `session/update` → `hub` 转发给观察者的同时交给 `activity` →
有变化且距上次超过 2 秒 → `team.changed`。

**一键批准**：leader 一个回合里调用多次 `team_spawn` → 这些 spawn 项带同一个 `group` →
前端在收件箱里合并显示 → `A` → `team.answer_group`。

## 3. 前端

### 3.1 模块划分

| 模块 | 内容 |
|---|---|
| `config.lua` | `teams` 配置：`enabled`、`default`（流程名）、`workflows`、`templates.models`、`dashboard.wide`；遇到 `definitions` 或 `workflow` 直接报错并给出新写法 |
| `app/team.lua` | 已有的团队状态。增加：每个团队的看板缓存（收到 `board_changed` 后拉取，同一时刻只有一个请求在途）、流程列表、`start()`、`answer_group()`、`card_history()`；删除 `start_defined_workers`（改由服务的 `team.start` 完成） |
| `ui/team/init.lua` | 面板控制器：按宽度选择 tabpage 布局或浮窗布局；分发按键到光标下的对象；`team.changed`/`board_changed` 后的重绘调度 |
| `ui/team/layout_tab.lua` | 宽屏 tabpage：成员、收件箱、看板、详情四个窗口，以及右侧观察窗口；窗口尺寸随 `VimResized` 调整 |
| `ui/team/layout_float.lua` | 窄屏居中浮窗（现有面板改造） |
| `ui/team/members.lua`、`inbox.lua`、`board.lua`、`detail.lua` | 各区域的行生成和高亮；`board.lua` 按显示宽度（`strdisplaywidth`）排版看板列，支持横向滚动 |
| `ui/team/watch.lua` | 观察窗口（见 3.2） |
| `ui/team/history.lua` | 卡片历史版本和逐版对比 |
| `ui/workflows.lua` | `:Ade workflows` 列表、全文、删除 |
| `plugin/ade.lua` | 子命令：`:Ade team [start [流程]\|close]`、`:Ade workflows`，以及补全 |

现有的 `ui/team.lua`（792 行）拆进 `ui/team/` 后删除。

### 3.2 观察窗口

- **worker**：沿用 `app/team.lua` 里已有的观察逻辑（`team.watch` + 重放 + `session/reducer`，已经得到完整的会话状态），
  只换掉渲染：新建一个**只读 `Chat` 实例**（`ui/chat.lua`，`Chat:set_session(watch_session)`），
  放进右侧 vsplit。工具展开、diff、plan、思考折叠、跟随滚动都直接复用。不创建输入区。
- **按回合分组**：用已有的 `_ade/turn_started`/`turn_finished`（`origin: "bus"` 和 `prompt`）在会话里插入回合标题块；
  `<bus>` prompt 和 `bus_*` 工具调用由一个小的展示层改写成消息样式（只影响显示，不改 reducer 的数据）。
- **leader**：不新建 Chat，把 leader 现有的聊天缓冲区和输入区挂到这个 vsplit 上。
  `Chat` 目前只记一个 `win`，需要改成“当前显示它的窗口”，切换时把聊天窗口移过来，而不是同时开两个。
- **切换**：在成员上按 `<CR>` 切换观察对象：worker 之间先 `team.unwatch` 再 `team.watch`；切到 leader 时不需要 watch。

### 3.3 启动流程（前端部分）

`:Ade team start [流程]`：

1. 没有流程名时，用 `team.workflows` 的结果弹出选择器。
2. 确保 leader 会话：没有就打开聊天、新建会话（流程的 `leader.agent` 优先）；
   agent 不一致、已有团队在跑等情况按 `w0-team-dashboard-draft.md` 2.7 提示。
3. 输入任务（可留空）。
4. 调用 `team.start`，打开面板。

`teams.enabled = true`：`team.bind_leader` 成功、且团队还没有 worker 时，自动调用 `team.start {workflow = teams.default}`，不弹输入框。

## 4. token 预算（leader）

| 来源 | 开销 | 频率 |
|---|---|---|
| MCP `instructions`（claude、opencode） | ~300 token，进系统提示，可缓存 | 每回合（缓存命中） |
| 新增工具定义（`board_update`、`workflow_*` 等） | 每个约 100～200 token | 每回合（缓存命中） |
| 组队通知（基础说明 + 流程全文） | 300 + 流程长度（≤ 4 KiB） | 每次组队一次 |
| `board_update` 调用 | 结构操作几十 token，返回 `{rev}` | 派活、挪列时 |
| 卡片消息摘要 | 几十 token | 每条卡片消息 |
| 看板变化、动态、worker 写卡片 | 0（不进信箱） | — |

## 5. 实施顺序

先写协议，再前后端并行。每一步都能单独合并、单独测试。

| 步骤 | 内容 | 依赖 |
|---|---|---|
| **W0a 协议** | PROTOCOL.md 第 19 节定稿（本文 2.3 展开成规范） | — |
| **W0b 服务：看板** | `board.rs`、三张表中的 `boards`/`card_history`、`board_update`/`card_update`、`team.board`/`card_history`/`board_changed`、合并写入、`bus_status.board`、卡片消息摘要 | W0a |
| **W0c 服务：流程与组队** | `workflow.rs`、`workflows` 表、`workflow_*` 工具、`team.start`、`team_spawn` 的 `model`/`role` 与模型校验、`brief.rs`、MCP `instructions`、spawn 分组和 `team.answer_group` | W0a |
| **W0d 服务：动态** | `activity.rs`、`state_since`、`team.list` 新字段 | W0a |
| **W0e 前端：配置与状态** | `config.lua` 新配置和报错、`app/team.lua` 的看板/流程/启动、`:Ade team start`、`:Ade workflows` | W0b–W0d 的协议（可以先对着规范写，用模拟服务测试） |
| **W0f 前端：统一面板** | `ui/team/` 各模块、宽窄两种布局、按键、看板排版、收件箱分组、卡片历史 | W0e |
| **W0g 前端：观察窗口** | 只读 Chat 复用、回合分组、消息样式、leader 聊天挂载 | W0e |
| **W0h 文档** | `doc/ade.txt` 第 23b 节重写（新配置、命令、面板）、README | 全部 |

W0b、W0c、W0d 互不依赖，可以交给不同的 worker 并行；W0f 和 W0g 也可以并行。

## 6. 测试

- **服务（Rust 单元 / 集成测试）**：看板权限矩阵（leader/owner/其他 worker × 各字段）、大小上限、合并写入计时、
  历史保留 20 条与归档清空、流程校验（含 `team` 里出现 `leader`）、解析顺序、`team.start` 的幂等（已有名字跳过）、
  模型不可用时停 worker 并通知、spawn 分组、服务重启后看板和历史恢复。
  沿用现有的模拟 agent（假 ACP 进程）跑端到端。
- **前端（现有的 Lua 测试框架）**：配置报错（旧键）、看板排版（中英文混排宽度、横向滚动）、按键分发、
  `board_changed` 风暴下只有一个拉取请求在途、观察窗口切换时的 watch/unwatch 配对。
- **手动验收**：用 claude、opencode、pi 各当一次 leader 走完默认流程的一个阶段；pi 当 worker 时确认它能通过 `mcp` 代理调用 `card_update`。

## 7. 风险

| 风险 | 应对 |
|---|---|
| leader 的聊天窗口挂到观察 vsplit：`Chat` 现在只认一个窗口 | W0g 先做一个小重构，让 `Chat` 支持换窗口；不行就退一步，选中 leader 时直接跳到它原来的聊天窗口 |
| 看板中文排版宽度 | 统一用 `vim.fn.strdisplaywidth` 截断和补齐，测试覆盖 |
| pi 的工具走 `mcp` 代理，worker 可能调用失败 | 角色卡写明调用方式；手动验收覆盖 |
| agent 不遵守流程约定（不写卡片、不归档） | 服务不强制；面板上能看出来（卡片很久没更新），由你在对话里纠正 |
| 改动 `team.configure` 的配置结构 | 前后端同版本发布；版本不一致时沿用现有的版本检查和重启逻辑 |
