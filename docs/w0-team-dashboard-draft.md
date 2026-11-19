# W0 草案：团队面板与任务看板（待审）

状态：**草案，等待审核**。审核通过之前不写任何实现代码。

## 1. 原则

- **默认流程 + 对话定制**：有一套默认流程；你也可以在对话里让 leader 换一套流程、换团队组成
  （用哪些 agent、什么模型、谁写代码谁审查），见 2。流程由 leader 按约定执行，
  服务和界面里没有状态机，也不会根据事件自动推进卡片。
- **结构归 leader，进度归 worker**：
  - leader 管看板结构：定义列、建卡、删卡、挪列、指定负责人。
  - worker 只能写**自己负责的卡片**的正文（`body`）和键值（`fields`）。
  - 这样分工是为了省 leader 的 token：给你看的进度、分支、测试结果由 worker 写进卡片（worker 模型便宜），
    leader 不用为了维护看板去写长文本。
- **卡片是给人看的，不是 agent 之间的信息通道**：leader 需要的细节由 worker 在汇报里给，
  或者由 leader 自己决定怎么拿（`bus_read`、看分支的 diff、跑测试等）。agent 没有读取卡片内容的工具。
- **看板变化不叫醒任何 agent**：看板变化只通知 Neovim，不进 leader 或 worker 的信箱，
  不会触发任何回合。
- **服务只负责保存和转发**：服务不解释列名或字段的含义。看板随团队持久化，服务重启后保留。
- **Neovim 只负责展示**：用户可以针对某张卡片给 leader 发消息，但不能直接改看板。
- 不开团队、或 leader 从没写过看板时，看不到任何变化。

## 2. 工作流：默认流程 + 对话定制

工作流是 **leader 遵循的约定**，写在 leader 的提示词和看板上，不是服务里的状态机：
服务只管安全边界（只能用配置过的模板、worker 上限、spawn 确认），不判断“现在该走哪一步”。

### 2.1 默认流程

不说明流程时，leader 按默认流程工作。默认流程是一段内置提示词，可以用 `teams.workflows.default` 整体替换（2.5）：

1. 你提出需求；leader 做设计，把工作分成若干**阶段**，每个阶段拆成任务，在看板上建卡（卡片的 `stage` 写阶段名）。
   默认列：`待开发` / `进行中` / `审查中` / `等你决定`。`等你决定` 只放需要你拍板的问题，不放“等提交”的卡片。
2. leader 按需 `team_spawn` worker，每张卡片指定负责人，发 `task` 消息。worker 在自己的 worktree 里开发，进度写在卡片上。
3. worker 做完后 `report`；leader 审查改动、跑测试。不通过就发 `review` 打回，卡片回到 `进行中`。
4. **单张卡片通过后不问你**：leader 把这个 worker 的分支合并到本阶段的集成分支
   （例如 `ade/<team>/<stage>`，在单独的 worktree 里合并，不改动主工作区的 HEAD），然后给 worker 发完成确认；
   worker 归档卡片（3.1）。如果 worker 已经退出，由 leader 归档。
5. **阶段完成后一次性问你**：本阶段的卡片都归档后，leader 在对话里汇总这一阶段做了什么
   （每张卡片的标题和结论、集成分支上的测试结果、需要你注意的地方），请你确认提交。
6. 你确认后，leader 把集成分支合并进主分支、清理本阶段的 worktree 和 worker 分支；
   你不同意时，按你的意见在下一轮里修改，或者放弃整个集成分支。
7. 你也可以事先授权“阶段完成后直接提交”，那第 5 步只汇报、不等确认。

### 2.2 通过对话建立别的流程

你可以在对话里描述流程和团队组成，例如：

> 做 xxx 工作，你来做主要设计和任务分解，生成两个 opencode 的 worker 写代码，
> opencode 的 worker 使用的模型是 xxx，然后用一个 pi 的 reviewer 来审核代码，reviewer 使用 gpt6.1sol 模型。

leader 的做法（写在默认提示词里）：

1. **先复述计划，等你确认**：团队组成、每个人用什么 agent 和模型、看板列、每一步谁做什么。
   这一步只是一次对话回复，花不了多少 token，但能避免它理解错了再返工。
2. **把流程写到看板上**：`board_update {workflow: "..."}`，面板标题下面显示一行“流程：……”，可以展开看全文。
   之后 leader 在恢复上下文时也以它为准。
3. **按计划组队**：上面的例子会变成三次调用

   ```
   team_spawn {template="opencode", name="w1", model="xxx", role="按 leader 分配的卡片写代码……"}
   team_spawn {template="opencode", name="w2", model="xxx", role="按 leader 分配的卡片写代码……"}
   team_spawn {template="pi", name="reviewer", model="gpt6.1sol", role="审查 w1/w2 的分支，结论用 report 发给 leader……"}
   ```

   默认每次都需要你在收件箱确认；确认项里能看到模板、agent、模型和角色说明。
4. **按约定走流程**：例如编码 worker 做完后，leader（或按约定由编码 worker 直接）把分支名发给 reviewer；
   reviewer 审完向 leader 汇报；之后按默认流程第 4～6 步收尾。worker 之间本来就可以互发消息（18.11）。
   reviewer 通过卡片上的 `branch` 字段找到要审的分支（各 worktree 共用同一个仓库）。

流程中途也可以改：你在对话里说“以后测试也交给 reviewer 跑”，leader 更新看板上的 `workflow` 并照做。

### 2.3 为此需要的改动

- **模板改为按 agent 配置**：模板描述“用哪个 agent、怎么启动”，比如 `opencode`、`pi`；
  具体角色（写代码、审查）和模型由 leader 在 `team_spawn` 时给出。原来写好角色的模板继续可用。

  ```lua
  teams = {
    templates = {
      opencode = { agent = "opencode", worktree = true, models = { "opencode-go/deepseek-v4.1-flash", "xxx" } },
      pi       = { agent = "pi", worktree = true },   -- 不写 models：允许 agent 自己列出的任何模型
    },
  }
  ```

- **`team_spawn` 增加 `model?` 和 `role?`**：
  - `role` 接在模板的 `role` 后面组成角色卡（合计 16 KiB 以内）。
  - `model` 不在模板的 `models` 列表里时直接报错（`-32060`）。worker 启动后，如果 agent 的
    `configOptions` 里没有这个模型，服务停掉这个 worker，给 leader 发 `notice`，正文列出 agent 实际提供的模型，
    由 leader 换一个再试或者来问你。现在的行为是悄悄忽略，要改掉。
  - 模板在 `spawn_confirm.auto` 里时照样自动放行；带了 `model` / `role` 也一样。
- **`bus_status` 给 leader 的模板列表带上 `agent` 和 `models`**，leader 才能把“opencode 的 worker”“pi 的 reviewer”
  对上模板名。
- **看板增加 `workflow` 字段**（leader 写，最多 4 KiB），见 3。
- **默认流程的提示词**：内置一段，`teams.workflows.default` 可以替换；它只在 leader 的角色说明里出现一次，不会每回合重复发送。

### 2.4 命名流程

对话里定好的流程可以保存下来，以后直接点名使用。

**内容**：一个命名流程就是一份“流程 + 团队组成”的说明，leader 保存时整理成：

```
workflow = {
  name,          -- [a-z0-9][a-z0-9_-]{0,31}，如 "review_by_pi"
  summary,       -- 一行说明，最多 120 字符
  text,          -- 流程全文（各步骤谁做什么），最多 4 KiB，就是看板 `workflow` 字段的内容
  leader?,       -- {agent?, model?, role?}：只有你明确要求时才有，见 2.6
  team?,         -- [{name, template, model?, role?, task?}]：只有 worker，不含 leader；组队时逐个 team_spawn
  columns?,      -- 看板列
  scope,         -- "project"（只在这个仓库可用，默认）或 "user"（所有项目可用）
  updated_at,
}
```

**来源**：

| 来源 | 谁写 | 存在哪里 |
|---|---|---|
| 内置的 `default` | 插件 | 内置，`teams.workflows.default` 可以替换（2.5） |
| 配置里的 `teams.workflows = { name = {...} }` | 你在 setup 里写 | Neovim 配置；只读，leader 不能改 |
| 对话里保存的 | leader 按你的要求保存 | 服务的数据库，随服务持久化，不随团队删除 |

同名时：配置 > 对话保存的项目级 > 对话保存的用户级。

**用法**：

- **保存**：你说“把这个流程存成 review_by_pi”，leader 调 `workflow_save`。
  同名的已经存在时，工具返回错误，leader 问你是否覆盖，你同意后带 `replace: true` 再存。
  不需要额外的确认弹窗：保存的只是文字和组队计划，真正启动 worker 时仍然走 spawn 确认。
- **使用**：你说“用 review_by_pi 流程做 xxx”，leader 调 `workflow_get` 读出全文，复述计划（团队、模型、阶段），
  你确认后按 `team` 组队、按 `columns` 建看板，把 `text` 写进看板的 `workflow`，并在看板上记下流程名。
  中途改了流程，可以让 leader 另存或覆盖。
- **查看和删除**：`:Ade workflows` 列出所有命名流程（名字、范围、一行说明、来源），
  `<CR>` 看全文，`d` 删除对话保存的流程（配置里的只能改配置）。也可以在对话里让 leader 删除。
- **省 token**：leader 平时只在 `bus_status` 里看到名字和一行说明；全文只有在用到时才用 `workflow_get` 读取。

**新增的工具和协议**：

| 工具 | 谁 | `bus.*` 方法 | 输入 | 返回 |
|---|---|---|---|---|
| `workflow_save` | leader | `bus.workflow_save` | `workflow`（上面的字段，不含 `updated_at`）、`replace?` | `{name}` |
| `workflow_get` | leader | `bus.workflow_get` | `name` | `{workflow}` |
| `workflow_delete` | leader | `bus.workflow_delete` | `name` | `{}` |

- `team` 里引用的模板必须存在，模型必须在模板的 `models` 列表内（有列表时），否则保存就报错（`-32060`）。
- `bus_status` 给 leader 的结果增加 `workflows: [{name, summary, scope, source}]`。
- 前端：`team.workflows {cwd}` 列出、`team.workflow_delete {cwd, name}` 删除；`team.configure` 把配置里的
  `teams.workflows` 一起交给服务（只读）。
- 看板增加 `workflow_name?`，面板标题下面显示成“流程：review_by_pi”，没有名字时显示“流程：自定义”。

### 2.5 `teams.definitions` 并入 `teams.workflows`（不保留旧写法）

S4c 的预定义团队（`teams.definitions` + `teams.default`）和命名流程的 `team` 是同一件事，合并成一个：

```lua
teams = {
  enabled = true,              -- true：leader 建团队时自动按默认流程组队（同 S4c 的行为）
  default = "dev",             -- 默认流程名；不写就用内置的 default
  workflows = {
    dev = {
      summary = "两个 opencode 写代码，leader 审查",
      text = "……",             -- 不写 text 时沿用内置默认流程的步骤
      team = {                 -- 只列 worker，不含 leader
        { name = "w1", template = "opencode", model = "opencode-go/deepseek-v4.1-flash", role = "写代码", task = "T1" },
        { name = "w2", template = "opencode", model = "opencode-go/deepseek-v4.1-flash", role = "写代码" },
      },
      columns = { "待开发", "进行中", "审查中", "等你决定" },
    },
    default = { text = "……" }, -- 同名覆盖内置的 default 流程
  },
}
```

- **删除** `teams.definitions` 和 `teams.workflow`（2.1 里替换默认流程的那个字符串）：
  替换内置默认流程改为写 `teams.workflows.default`。
- `teams.default` 的含义改为“默认流程名”，必须是 `teams.workflows` 里的名字或内置的 `default`。
- **不兼容旧写法**：配置里还有 `definitions` 或 `workflow` 时，setup 直接报错，提示改成 `teams.workflows`
  （报错信息里给出对应的新写法）。不做自动迁移。
- `teams.enabled = true` 的行为不变：leader 建团队、且团队还没有 worker 时，前端调用 `team.start`，
  由服务按默认流程的 `team` 启动成员（已在 `team.list` 里的跳过），并给 leader 发组队通知（流程全文），
  leader 据此建看板。`team` 条目在原来的 `{name, template, task?}` 之外增加 `model?`、`role?`。
- `teams.enabled = false` 时什么也不自动启动，你在对话里点名流程，由 leader 组队。

### 2.6 流程里的 leader

- **`team` 只列 worker，永远不含 leader**。`team` 里出现名字 `leader`（或 `human`）时，setup 和 `workflow_save` 都报错。
- leader 默认就是**你正在对话的那个 agent 会话**，用它当时的 agent 和模型；流程不改变它。
- 只有你**明确要求**时，流程里才写 `leader` 配置，例如“这个流程的 leader 用 claude 的 opus 模型”：

  ```lua
  workflows = {
    big_refactor = {
      leader = { agent = "claude", model = "opus", role = "只做设计和审查，不亲自改代码" },
      team = { ... },          -- 仍然只有 worker
    },
  }
  ```

  - `role`：追加在 leader 的团队说明后面（和默认流程的提示词一起，只出现一次）。
  - `model`：当前 leader 会话的 agent 提供这个模型时，前端用 `session/set_config_option` 切过去，并告诉你切换了；
    不提供时只提示，不切换。
  - `agent`：和当前 leader 会话的 agent 不同时，不会自动换 leader（换 leader 要先结束团队，18.11）。
    前端提示“流程要求 leader 使用 claude，当前是 opencode”，由你决定是另开一个 claude 会话作为 leader，
    还是忽略这项继续。
- leader 用 `workflow_save` 保存流程时，只有你在对话里明确提到 leader 的 agent、模型或角色，才写 `leader`；
  默认提示词里写明这一点。

### 2.7 启动团队：命令和对话

#### 现状（S4c）

- 服务模式下，只要配置了模板，每个新开的聊天会话都会被注入 `ade-team` MCP server；
  绑定时服务为这个 cwd 建一个只有 leader 的团队。同一个 cwd 只有一个 leader 会话。
- leader 只能从工具描述（每个工具一句话）知道自己能组队，没有任何说明书。
- 启动 worker 有三种方式：leader 调 `team_spawn`、面板里按 `s`、`teams.enabled = true` 时自动按定义启动。

#### 设计

**1. 谁是 leader**：不变。MCP server 只能在 `session/new`/`load`/`resume` 时给出，所以注入照旧；
但**没有 worker、也没有看板的团队不显示**（面板显示空状态，见下），单 agent 使用时感觉不到团队的存在。

**2. leader 的说明书分两层**：

| 内容 | 什么时候给 | 怎么给 |
|---|---|---|
| 基础说明：你能组队；只有用户要求，或者你先提议并得到同意，才组队；看板和归档的约定 | 会话开始时 | MCP `initialize` 结果的 `instructions` 字段（支持它的 agent 会放进系统提示，约 300 token） |
| 流程全文（默认流程或命名流程）、团队组成、阶段约定 | **组队开始时一次** | 一条 `notice`；不支持 `instructions` 的 agent，基础说明也一起放在这条 `notice` 里 |

不组队就不会收到流程全文，单 agent 使用不多花 token。

各 agent 对 MCP `instructions` 的支持（2026-11-17 按本机安装的版本查源码/二进制确认）：

| agent | 版本 | 支持 | 方式 |
|---|---|---|---|
| claude | claude-agent-acp 0.107.0（Claude Agent SDK / Claude Code 2.1.x） | **是** | 系统提示里的 `# MCP Server Instructions` 段；会话中途新增的 server 以增量说明补上 |
| opencode | 2.3.0 | **是** | `McpInstructions` 指导块（`core/mcp-guidance`）放进上下文，说明变化时会发更新 |
| pi | @geohar/pi-acp 0.4.0 → pi-mcp-adapter 7.0.0 | **否（只能按需读取）** | 适配器缓存了 `instructions`，但不放进提示；模型要自己调 `mcp({ instructions: "ade-team" })` 才看得到 |

据此：

- **基础说明两处都给**：`instructions` 照常提供；组队开始时的 `notice` 里**总是**再带一份基础说明（约 300 token，只一次），
  不按 agent 区分，逻辑简单。对 claude/opencode 是重复的一小段，可以接受。
- **pi 当 leader 时**，组队前它不知道自己能组队，只有你明确要求（或用 `:Ade team start`）时才会组队。可以接受，不另做处理。
- **pi 的工具走代理**：pi-mcp-adapter 默认不把 MCP 工具直接放进工具列表，而是通过一个 `mcp` 代理工具调用
  （`mcp({ tool: "bus_send", args: {...} })`）。pi worker 的角色卡要写明这种调用方式，否则它可能找不到 `bus_send`。

**3. 三种启动方式**

| 方式 | 适合 | 谁启动 worker | 要不要逐个确认 spawn |
|---|---|---|---|
| **对话**：在聊天里说 | 临时决定、要 leader 帮你设计团队 | leader（`team_spawn`） | 要，但可以一键全部批准（见 5） |
| **命令**：`:Ade team start [流程]` | 已有命名流程，直接开工 | 前端（`team.spawn`，你发起的，不用确认） | 不要 |
| **自动**：`teams.enabled = true` | 每次打开项目都用同一个团队 | 前端，按 `teams.default` 流程 | 不要 |

**4. 命令**

| 命令 | 作用 |
|---|---|
| `:Ade team` | 打开统一面板。还没组队时显示空状态：可用的流程列表（名字、一行说明、团队组成），光标所在流程按 `S` 启动，按 `<CR>` 看全文 |
| `:Ade team start [流程名]` | 按流程启动团队；不给名字时弹出流程选择器（含 `default`），补全列出所有流程名 |
| `:Ade team close` | 结束团队（同面板里的 `x`，要确认） |
| `:Ade workflows` | 列出、查看、删除命名流程（2.4） |

`:Ade team start <流程>` 的步骤：

1. **确定 leader 会话**：
   - 当前项目没有聊天会话时，打开聊天并新建会话；流程配置了 `leader.agent` 时用那个 agent，否则用默认 agent。
   - 已有 leader 会话、但流程的 `leader.agent` 和它不同：提示你选择“另开 <agent> 会话作为 leader（需要先结束现有团队）”或“忽略，用当前 leader”。
   - 流程有 `leader.model` 时按 2.6 切换模型。
2. **已有在跑的团队**（有 worker）：提示“已有团队 w1、w2 在运行”，选择“结束后重新开始”“追加流程里缺的成员”或“取消”。
3. **输入任务**：弹出输入框“这次要做什么？（可以留空，稍后在聊天里说）”。
4. **启动**：前端调用 `team.start`，服务按流程的 `team` 逐个启动（已存在的名字跳过），再给 leader 发一条 `notice`（`from=human`）：
   流程名、流程全文、团队成员、你输入的任务。leader 收到后建看板（列、阶段、卡片），分派任务。
5. 自动打开面板（宽屏是 tabpage），你可以看着团队开工。

**5. 对话**

leader 的行为写在基础说明和流程里，下面是三种典型对话。

*a. 点名流程*

```
你：     用 review_by_pi 流程，把配置解析拆成独立模块。
leader： （workflow_get review_by_pi）
         按 review_by_pi 流程：w1、w2 用 opencode（deepseek-v4.1-flash）写代码，reviewer 用 pi（gpt6.1sol）审查。
         我计划分两个阶段：S1 抽出解析器（3 张卡），S2 迁移调用方并删除旧代码（2 张卡）。
         可以开始吗？
你：     可以。
leader： （team_spawn ×3 → 收件箱出现 3 个 spawn 申请，面板里按 A 一次全部批准）
         （board_update：流程、列、S1/S2 的 5 张卡）
         已组队，S1 开工：T1 给 w1，T2 给 w2，T3 等 T1 完成后再派。
```

*b. 临时描述流程，顺便保存*

```
你：     做 xxx，你来设计和拆任务，两个 opencode worker 写代码，模型用 xxx，再用一个 pi 的 reviewer 审核，模型 gpt6.1sol。
leader： 复述：团队、模型、每一步谁做什么、阶段划分。可以开始吗？要把这个流程存成命名流程吗？
你：     开始，存成 review_by_pi，只在这个项目用。
leader： （workflow_save {name="review_by_pi", scope="project", ...}）
         （team_spawn ×3，board_update ...）
```

*c. 没提团队*

```
你：     把这个函数改成异步的。
leader： （直接自己改，不组队）
```

任务明显很大时，leader 可以先提议：“这件事拆成 4 个独立任务比较快，要不要按 default 流程组一个 2 人团队？”
你同意后才组队。

**一键批准**：同一个 leader 在短时间内发出的多个 spawn 申请，在收件箱里合成一组显示：
`+ i21–i23  leader 申请启动 3 个 worker：w1 opencode/xxx、w2 opencode/xxx、reviewer pi/gpt6.1sol`。
`A` 全部批准，`a` 逐个处理。你已经在对话里同意了计划，这里只是最后的把关。

## 3. 数据模型

每个团队有一块看板：

```
board  = { workflow_name?, workflow?, columns: [column], cards: [card], updated_at, rev }   -- workflow：当前流程的文字说明，leader 写，最多 4 KiB
column = { id, title }                       -- 顺序即显示顺序
card   = {
  id,            -- leader 自定，如 "T3"；建议与总线 task 标签一致，便于关联
  title,         -- leader 写
  column,        -- column.id，leader 写
  owner?,        -- 参与者名（w1 …），leader 写；界面据此显示该 worker 的实时状态
  body?,         -- 多行 markdown：进度、测试结果、待决问题…（leader 或 owner 写）
  stage?,        -- 阶段名，leader 写；面板按阶段分组显示已归档卡片，见 2.1
  fields?,       -- 少量短的键值，如 {branch="ade/w1", tests="✓ 42"}，在卡片上显示成一行（leader 或 owner 写）
  updated_by,    -- 最后写入者（leader 或 worker 名），界面显示
  updated_at,
  archived?,     -- true：已归档（任务完成或提交后归档，owner 或 leader 写），见 3.1
}
```

限制（防止写爆）：最多 16 列、200 张卡片，`body` 每张最多 8 KiB，`fields` 每张最多 12 项、
每个值最多 120 字符，整块看板最多 256 KiB。超出时返回错误，交给调用方自行处理。归档的卡片不计入 200 张。

### 3.1 历史版本（有限保留）

- 按**卡片**保留历史：卡片每次被写入（合并写入之后算一次），服务把写入前的版本存下来，
  每张卡片最多保留 **20** 个版本，超出时丢掉最旧的。列结构的变化不保留历史。
- **已完成或已提交的任务不保留历史**。卡片一归档，服务就删除它的全部历史，只留最终版本。
  归档有两种情况：

  | 情况 | 谁归档 | 怎么归档 |
  |---|---|---|
  | leader 确认任务已完成（审查通过，在给 worker 的消息里明确说“完成”） | **负责的 worker** | `card_update {card, archive: true}` |
  | 用户确认提交了一个阶段 | **leader** | `board_update {archive: [这个阶段还没归档的卡片]}`（通常已经全部由 worker 归档，这一步只是收尾） |

  leader 也可以归档任何卡片（例如负责的 worker 已经退出）。服务不检查“是否真的确认过”，
  靠两边的默认提示词约定：worker 只在收到 leader 的完成确认后归档，leader 只在用户确认提交后归档。
- 归档卡片不出现在看板列里，只在看板末尾显示一行“已归档 N 张（按 <CR> 展开）”；
  归档之后不能再修改，只有 leader 能 `remove`。
- 历史只给人看：agent 的工具里没有读取历史的入口，不会因此花 token。
- 历史随团队持久化；团队被删除时一起删除。

## 4. MCP 工具

| 工具 | 谁 | `bus.*` 方法 | 输入 | 返回 |
|---|---|---|---|---|
| `board_update` | leader | `bus.board_update` | `workflow?`（当前流程说明）、`columns?`（整体替换列表）、`upsert?: [card]`（按 id 合并，只改给出的字段）、`archive?: [card id]`（归档并删除历史，见 3.1）、`remove?: [card id]` | `{rev}` |
| `card_update` | worker | `bus.card_update` | `card`（id）、`body?`、`fields?`（按键合并，值为 `null` 表示删除该键）、`archive?`（`true` 归档并删除历史，见 3.1） | `{rev}` |

- worker 的 `tools/list` 里看不到 leader 的工具，反过来也一样。
- **没有读取看板的工具**：工具定义本身每回合都会随请求发送，少一个工具就少一份固定开销。
  - leader 只需要知道看板的**结构**（有哪些卡片、在哪一列、谁负责、属于哪个阶段），以便继续更新；
    这些放进 `bus_status` 的 leader 结果里：`board: {workflow_name, columns, cards: [{id, title, column, owner, stage, archived}]}`，
    不含 `body` 和 `fields`。leader 恢复上下文（会话重新加载、团队从挂起恢复）时调一次 `bus_status` 就够了。
  - worker 从 `task` 消息里知道自己的卡片 id（`task` 标签就是卡片 id）；写错了 id，`card_update` 返回错误。
- 一次调用就是一次原子更新，`rev` 加 1。返回值只有 `{rev}`，不回传整块看板，免得塞进上下文。
- leader 的约束：卡片引用了不存在的列时报错；删除某一列时，如果这列里还有卡片，也报错。
- worker 的约束：
  - 只能改 `owner` 等于自己的卡片，否则返回 `-32061`（not allowed，`message` 为 "not your card"），沿用 18.10 已有错误码。
  - 不能改 `title`、`column`、`owner`，也不能建卡、删卡；可以归档自己的卡片，不能取消归档。
  - leader 把卡片改派给别人以后，原 worker 就不能再写这张卡片。
- **合并写入（限速）**：同一张卡片的 worker 写入，服务端立即应用到内存，
  但 `team.board_changed` 通知和落盘至少间隔 10 秒，期间的多次写入合并成一次。
  leader 的写入不限速。
- **默认提示词**：团队配置里增加两段默认提示词，可以覆盖。
  - leader：看板是给用户看的；派活时建卡并指定负责人；收到汇报、和用户谈完之后挪列；
    卡片正文由 worker 维护，不要自己重写正文，也不要指望从卡片里读细节，细节让 worker 在汇报里给；
    用户关于卡片的话会带着卡片引用到达；确认 worker 的任务完成时，在消息里明确写“完成”，worker 会自己归档卡片；
    **只有在用户明确确认提交之后**才自己归档卡片。
  - worker：开工、遇到阻塞、测试跑完、提交之后，用 `card_update` 更新自己的卡片；
    卡片写给用户看；给 leader 的汇报要包含 leader 做决定需要的细节（改了什么、测试结果、遗留问题），不要写“见卡片”；
    收到 leader 对任务的完成确认后，用 `card_update {archive: true}` 归档自己的卡片。

## 5. 前端协议

- `team.list` 的每个团队条目增加 `board_rev`。
- `team.board {team}` → `{board}`。
- `team.card_history {team, card}` → `{versions: [card]}`（新到旧，最多 20 个；归档卡片返回空）。
- 通知 `team.board_changed {team, rev}`（只发给前端连接，不进任何 agent 的信箱），
  前端收到后重新拉取看板，不做增量更新，保持简单。

## 6. 界面：统一面板 `:Ade team`

看板不单独开命令。现有的 `:Ade team` 浮窗升级为**统一面板（dashboard）**，
一屏同时看到：成员（每个 worker 在干什么）、收件箱（等你处理的事）、看板卡片，以及光标所在项的详情。

### 6.1 宽屏布局（≥ 160 列）

在独立的 tabpage 里打开（已定），分四个窗口：左上**成员**、左下**收件箱**、右边**看板**、底部**详情**。
在成员上按 `<CR>` 后，右侧再弹出观察窗口（vsplit，见 6.6），看板和详情窗口相应变窄。
每个窗口各自滚动，`<Tab>` / `<S-Tab>` 在窗口之间切换；`q` 关闭整个 tabpage，回到原来的位置。

```
 ade.nvim · team t1 · ~/src/proj        active · workers 3/3 · turns 41/200 · board rev 17              g? help
╭─ 成员 ─────────────────────────────────────╮╭─ 看板 ───────────────────────────────────────────────────────────╮
│ leader ● 工作中 0:42                         ││ 待开发 1          进行中 2             等你决定 1          完成 3    │
│   ↳ 和你对话                                 ││ ┌─────────────┐  ┌────────────────┐  ┌────────────────┐  T1 重命名模块 │
│                                             ││ │ T6 清理日志   │  │ T4 补齐 auth 测试│  │ T3 修复重连竞态  │  T5 补文档    │
│ w1     ● 工作中 3:10   T4 · 回合 5/30         ││ │             │  │ w1 ● 3:10      │  │ w2 ○           │  T7 CI 矩阵  │
│   ↳ 执行 cargo test -p service               ││ └─────────────┘  │ tests 38/42    │  │ tests ✓ 42     │             │
│   wt ade/t1-1117/w1                          ││                  └────────────────┘  │ +84 -12        │             │
│                                             ││                  ┌────────────────┐  └────────────────┘             │
│ w2     ○ 空闲 12 分钟  T3 · 回合 8/30          ││                  │ T2 拆分 config  │                                 │
│   ↳ 已汇报：重连竞态已修复，等你决定是否合并       ││                  │ w3 ? 等你回答    │                                 │
│   wt ade/t1-1117/w2                          ││                  └────────────────┘                                 │
│                                             ││                                                                    │
│ w3     ? 等你回答 2:05  T2 · 队列 1            ││                                                                    │
│   ↳ 提问：要不要保留旧的 config 格式？           ││                                                                    │
├─ 收件箱 2 ──────────────────────────────────┤│                                                                    │
│ ? i12  w3  要不要保留旧的 config 格式？ [是/否]  ││                                                                    │
│ ⚑ i13  w1  权限：执行 git push                 ││                                                                    │
╰─────────────────────────────────────────────╯╰────────────────────────────────────────────────────────────────────╯
╭─ 详情 · T3 修复重连竞态 ──────────────────────────────────────────────────────────────────────────────────────────╮
│ 等你决定 · 负责 w2 ○ 空闲 · w2 更新于 3 分钟前 · branch ade/t1-1117/w2 · tests ✓ 42 · +84 -12                         │
│ 已修复：重连时同一 session 被绑定两次。改动集中在 hub/relay.rs，新增 2 个回归测试。                                     │
│ 待决：是否顺带把旧的 reconnect 计时器删掉（会影响 0.5 的客户端）。                                                     │
╰─────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
```

（中文字符宽度在草案里没有严格对齐，实际渲染按显示宽度计算。）

- **成员**：每人三行。
  - 第一行：名字、实时状态（`●` 工作中 / `○` 空闲 / `?` 等你回答 / `⏸` 暂停 / `✕` 退出）、
    当前状态持续时间、当前任务和回合数、排队消息数（非 0 才显示）。
  - 第二行 `↳`：**最近动态**，见 6.4。
  - 第三行：worktree 分支（有才显示）。
- **收件箱**：只列 open 的项，图标区分 `?` 提问、`⚑` 权限、`+` spawn 申请、`✉` 消息、`⏱` 回合上限。
- **看板**：列和卡片来自 leader；卡片上显示负责人和实时状态，以及最多 2 个 `fields`。
  列太多放不下时，看板窗口横向滚动（`zh` / `zl`），标题行固定。
- **详情**：跟随光标。光标在卡片上显示卡片全文；在成员上显示这个人负责的卡片列表和最近 5 条动态（完整工作过程在观察窗口里看，见 6.6）；
  在收件箱项上显示完整内容和可选答案。
- **联动高亮**：光标停在某个 worker 上时，看板里它负责的卡片高亮；停在卡片上时，成员里的负责人高亮。

### 6.2 窄屏布局（< 160 列）

保持现在的居中浮窗，单列从上到下：成员、收件箱、看板（按列分组的列表）。成员上按 `<CR>` 同样在右侧打开观察 vsplit；卡片和收件箱项上按 `<CR>` 另开浮窗显示详情。

```
╭──────────────────────── Team t1 ─────────────────────────╮
│ active · workers 3/3 · turns 41/200            g? help    │
│                                                          │
│ 成员                                                      │
│  leader ● 工作中 0:42   ↳ 和你对话                          │
│  w1     ● 工作中 3:10   T4  ↳ 执行 cargo test -p service    │
│  w2     ○ 空闲 12 分钟  T3  ↳ 已汇报：重连竞态已修复          │
│  w3     ? 等你回答      T2  ↳ 提问：要不要保留旧格式？        │
│                                                          │
│ 收件箱 2                                                   │
│  ? i12 w3  要不要保留旧的 config 格式？ [是/否]               │
│  ⚑ i13 w1  权限：执行 git push                              │
│                                                          │
│ 看板 · rev 17                                              │
│  待开发    T6 清理日志                                       │
│  进行中    T4 补齐 auth 测试      w1 ●  tests 38/42          │
│           T2 拆分 config 解析    w3 ?                       │
│  等你决定  T3 修复重连竞态        w2 ○  tests ✓ 42           │
│  完成 3    T1 T5 T7（按 <CR> 展开）                          │
╰──────────────────────────────────────────────────────────╯
```

### 6.3 按键

按键作用于**光标下的对象**；同一个键在不同对象上含义一致，不冲突。

| 键 | 成员 | 卡片 | 收件箱项 |
|---|---|---|---|
| `<CR>` | 打开（或切换到）这个人的观察窗口，见 6.6 | 在详情窗口显示全文 | 在详情窗口显示全文 |
| `m` | 给这个人发消息 | 就这张卡片给 leader 发消息（见 6.7） | — |
| `H` | — | 在详情窗口查看这张卡片的历史版本（逐版对比） | — |
| `a` | — | — | 回答 |
| `A` | — | — | 同一组 spawn 申请全部批准（2.7） |
| `w` | 同 `<CR>` | 打开负责人的观察窗口 | 打开提问者的观察窗口 |
| `p` / `r` / `c` | 暂停 / 恢复 / 取消当前回合 | 对负责人生效 | — |
| `D` | 删除已退出 worker 的 worktree | — | — |

全局键：`L` 跳到 leader 聊天窗口，`s` 按模板启动 worker，`R` 重置回合上限，`x` 结束团队，
`<Tab>` / `<S-Tab>` 切换窗口（宽屏），`zh` / `zl` 横向滚动看板，`g?` 帮助，`q` 关闭。

（原面板里 `c` 是取消，草案保留这个含义；跳到 leader 聊天改用 `L`。）

### 6.4 “最近动态”从哪里来

成员第二行的 `↳` 是界面最有用的一行，但不能靠 agent 自己写（会花 token），也不能每次都 `bus_read`
（太重）。由**服务**从它已经在转发的会话更新里提取，不经过任何 agent：

| 来源 | 显示 |
|---|---|
| 最近一次 `tool_call` / `tool_call_update` 的 `title` 和状态 | `执行 cargo test -p service`、`编辑 hub/relay.rs` |
| 最近一次 `plan` 里 in_progress 的条目 | `计划：补 reconnect 的回归测试` |
| 最近一条发出的总线消息 | `已汇报：…`、`提问：…`、`→ w2 发消息：…` |
| 回合结束时都没有以上内容 | 回复文本的第一行 |

协议上，`team.list` 的参与者条目增加：

```
activity? = { text, at }     -- 最多 120 字符，服务提取
state_since                  -- 当前 state 开始的时间（毫秒），界面算持续时间
```

`activity` 变化也走 `team.changed`，但同一参与者最多 2 秒发一次，避免刷屏。
leader 的 `activity` 只取总线相关的内容（它和你的对话本来就在聊天窗口里）。

### 6.5 其他

- 团队断线时标题栏标出 stale；团队挂起时标题栏显示“挂起 · 等待 leader 会话恢复”，看板照常显示最后的内容。
- leader 还没写过看板时，看板窗口显示“leader 还没有创建看板”和“按 L 去和 leader 聊”。
- 标题栏下面一行显示看板上的 `workflow`（“流程：……”，超长截断），光标移上去按 `<CR>` 在详情窗口看全文；
  leader 没写时显示“流程：默认”。同一行右侧显示当前阶段的进度，例如“阶段 S2 · 5/8 已完成”。
- 已归档的卡片按阶段分组折叠：`S1 · 已提交 · 6 张`、`S2 · 5 张已完成，待提交`。
- 多个团队时，标题栏显示 `[1/2]`，`]t` / `[t` 切换团队。
- 宽窄阈值做成配置项 `teams.dashboard.wide = 160`。

### 6.6 观察窗口：查看成员的完整工作过程

**现状**：`:Ade team` 里按 `w` 会在右侧 vsplit 打开一个只读窗口（`team.watch`，先重放历史再接实时），
但只把会话压成纯文本：工具调用只剩“状态 + 标题”一行，看不到参数、输出、diff、plan 和思考过程。

**改为**：

- **打开方式**：在成员列表里**选中**一个成员（`<CR>`）后，才在面板右侧弹出 vsplit 观察窗口。
  只移动光标不会打开或切换；观察窗口已打开时，在另一个成员上按 `<CR>` 切换到那个人
  （前端 `team.unwatch` 旧的、`team.watch` 新的）。`q` 或 `<CR>` 再按一次当前成员关闭观察窗口。
- **完整的消息回放**：从这个成员会话的第一条消息开始完整重放，再接实时更新，内容和聊天窗口一致，
  用同一套 reducer 和渲染器（`session/reducer`、`ui/transcript`、`ui/blocks`、`ui/diff`）：
  - 收到的每条总线消息完整显示，标出来源和类型（`leader → task T4`、`human → answer`）；worker 第一条的角色卡默认折叠；
  - agent 的回复正文完整显示，不截断；
  - 工具调用可展开参数和输出，编辑类显示 diff，`gd` 用审查界面并排查看；
  - 它发出的 `bus_send` / `bus_ask_human` 显示成消息（`→ leader report T4：……`），而不是普通工具调用；
  - plan 原样显示；思考过程默认折叠。
- **按回合分组**：每个回合一行标题（由什么消息触发、用时、工具数），`za` 折叠，`[[` / `]]` 跳回合；
  默认全部展开，与聊天窗口一致。
- **跟随**：停在底部时自动滚动；往上翻暂停跟随，`G` 回到底部并恢复。

**leader 和 worker 的区别**：

| | leader | worker |
|---|---|---|
| 观察窗口里的内容 | leader 的聊天会话本身（你和 leader 的对话 + 总线回合） | worker 的会话 |
| 输入框 | **有**：就是 leader 聊天的输入区，发出去的是你给 leader 的 prompt（18.4：你的 prompt 优先于总线消息） | **没有**：窗口只读，不显示输入区 |
| 权限请求、提问 | 同聊天窗口 | 在窗口内弹出，可以直接回答（18.7 watcher 应答） |

- 选中 leader 时，如果 leader 的聊天窗口已经在别的地方打开，观察窗口直接复用那个聊天会话
  （同一个 Chat 对象挂到这个 vsplit 上），不会出现两份输入状态。
- 对 worker 说话仍然只能在成员列表里按 `m`，走 `team.send`；观察窗口里没有对话入口。

**回放的上限**：服务端的模拟 `session/load` 只能重放不超过 32 MiB 的会话日志（第 12 节）；
超过时 `team.watch` 返回 `replayed: false`。这种情况下窗口顶部提示“会话过长，只显示观察开始之后的内容”，
再按 `team.read` 补上最近的消息和最后 3 个回合的正文。不做分段重放（已确认）。

协议不需要改；主要工作在前端：观察窗口接上聊天的 reducer 和渲染器、按回合分组、
把 `<bus>` prompt 和 `bus_*` 工具调用渲染成消息，以及 leader 的聊天会话挂到观察窗口。

### 6.7 卡片消息（`m`）的形式

为了省 leader 的 token，卡片消息这样发：

- **走总线排队，不直接打断 leader**：用 `team.send {to=leader, kind="notice", task=<card.id>, body}`。
  如果改成往 leader 聊天输入框里发 prompt，按 18.4 会取消 leader 正在跑的总线回合，
  那个回合已经花掉的 token 白费，被取消回合里的消息也不会重投。排队则在 leader 空闲时投递，
  几条卡片消息还会合并进同一个回合。
- **服务附上卡片摘要**：投递时服务在正文前加一行摘要，只含 `id`、`title`、列名、负责人和 `fields`
  （不含 `body`），例如 `[card T3 · 修复重连竞态 · 等你决定 · w2 · tests=✓ 42]`，约几十个 token。
  leader 由此知道你说的是哪张卡片、它现在的状态，不需要另外查看板。
- **不新增 `kind`**：类型名本身的 token 差别可以忽略；新增 kind 要改协议的枚举和角色卡说明，收益不大。
  用 `from="human"` 加 `task` 标签已经足够让 leader 知道这是你就某张卡片说的话。

## 7. 待定与已定

已定：

- 卡片消息用 `notice` 加 `task` 标签，服务附卡片摘要，排队投递，见 6.7。
- 历史版本按卡片有限保留（每张 20 个）；leader 确认完成后由 worker 归档、阶段提交后由 leader 收尾归档，归档即删除历史；提交确认按阶段一次性问，不按卡片问，见 3.1。
- “最近动态”的提取规则按 6.4，不对具体 agent 做特殊处理。
- 观察窗口不做分段重放。
- 宽屏用 tabpage（窄屏保留居中浮窗）。
- 对话里定好的流程可以保存成命名流程，见 2.4。
- `teams.definitions` 并入 `teams.workflows`，不保留旧写法，见 2.5。
- 流程的 `team` 只含 worker；leader 只有明确配置 `leader` 时才受流程影响，见 2.6。
- 启动团队有对话、`:Ade team start`、自动三种方式；leader 的说明书分基础说明（MCP `instructions`）和组队时一次性的流程全文，见 2.7。

待定：无。
