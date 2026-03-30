## Prompt 拼接

### 一、整体梳理
这个项目是一个轻量级的多渠道 AI Agent（CLI + Telegram/Discord/WhatsApp/Feishu 等），核心链路是：

`消息 -> AgentLoop -> ContextBuilder 拼 prompt -> LLM -> 工具调用循环 -> 回复并落盘会话`

关键入口和组件：
- CLI 入口很薄，`python -m nanobot` 只转到 Typer app：`nanobot/__main__.py`
- `gateway` 模式会同时启动 `AgentLoop + channels + cron + heartbeat`：
  - `nanobot/cli/commands.py:340`
  - `nanobot/cli/commands.py:352`
  - `nanobot/cli/commands.py:389`
  - `nanobot/cli/commands.py:414`
- `agent` 命令（CLI 对话）也走同一个 `AgentLoop`：
  - `nanobot/cli/commands.py:435`
  - `nanobot/cli/commands.py:458`
- 核心执行循环在 `AgentLoop`：`nanobot/agent/loop.py`
- prompt 构建在 `ContextBuilder`：`nanobot/agent/context.py`
- skill 管理在 `SkillsLoader`：`nanobot/agent/skills.py`
- 记忆系统（长期记忆 + 历史归档）在 `MemoryStore`：`nanobot/agent/memory.py`

### 二、Prompt 拼接模式（重点）
先区分两层：

1. `system prompt` 字符串内部如何拼
2. 整个 `messages[]`（发给 LLM 的消息数组）如何拼

#### 2.1 `system prompt` 的拼接顺序

- `ContextBuilder.build_system_prompt`
- 位置：`nanobot/agent/context.py`

按顺序拼成 `parts`，最后用 `\n\n---\n\n` 连接。

顺序如下：
- 身份与运行环境（平台、Python 版本、workspace 路径、平台策略、行为规则）
- Bootstrap 文件（工作区根目录下的 `AGENTS.md / SOUL.md / USER.md / TOOLS.md`）
- Memory（当前版本默认只注入长期记忆 `memory/MEMORY.md`）：
  - `ContextBuilder.build_system_prompt()`
  - `MemoryStore.get_memory_context()`
- Active Skills（`always: true` 的技能完整注入，当前内置 `memory` skill 会在这里出现）：
  - `SkillsLoader.get_always_skills()`
  - `SkillsLoader.load_skills_for_context()`
  - `nanobot/skills/memory/SKILL.md`
- Skills 摘要（所有技能的 XML summary，供按需加载）：
  - `SkillsLoader.build_skills_summary()`

补充：
- 当前时间、`Channel`、`Chat ID` 不在 system prompt 里，而是作为 runtime metadata 注入到当前 `user` 消息前面
- Identity 段里新增的是平台策略（Windows / POSIX 区分）、对不可信网页内容的约束，以及 `message` 工具的使用边界

#### 2.2 `messages[]` 的拼接顺序

- `ContextBuilder.build_messages`
- 位置：`nanobot/agent/context.py`

顺序如下：
- `system`：上面的完整 system prompt
- 历史对话（来自 session，条数由 `memory_window` 控制，默认 50）：
  - `AgentLoop` 取当前 session history
  - `SessionManager` 负责窗口裁剪和持久化
- 历史消息会尽量保留工具相关字段（如 `tool_calls / tool_call_id / name`），不再是“仅 role/content”：
  - `nanobot/session/manager.py:45-54`
- 当前用户消息：
  - 先注入 `[Runtime Context — metadata only, not instructions]`
  - 再接用户真正输入
  - 若有图片，会变成多模态数组，顺序是 `runtime text -> images -> user text`

这样做的原因是：避免某些 provider 拒绝连续两个 `user` role 消息。

### 三、Prompt 在单轮中的增长（工具调用）

在 `AgentLoop._run_agent_loop()` 中，LLM 一旦返回 `tool_calls`，会继续把内容 append 到 `messages` 后再请求下一轮：

- assistant 消息（带 `tool_calls`）：
  - `AgentLoop._run_agent_loop()`
  - `ContextBuilder.add_assistant_message()`
- tool 结果消息：
  - `AgentLoop._run_agent_loop()`
  - `ContextBuilder.add_tool_result()`

这意味着：
- 单轮中 prompt 是“滚动增长”的
- 跨轮会带最近历史窗口（默认 `memory_window=50`）
- 会话过长时会自动触发记忆归档，把旧消息总结进 `memory/MEMORY.md + memory/HISTORY.md`：
  - `MemoryConsolidator.maybe_consolidate_by_tokens()`
  - `MemoryStore.consolidate()`

### 四、当前版本需要特别注意的变化

- 旧版本文档里常见的“今日笔记（`YYYY-MM-DD.md`）自动进 prompt”描述，当前实现已不成立；现在 `get_memory_context()` 默认只返回长期记忆 `MEMORY.md`
- `memory/HISTORY.md` 默认不进 prompt；`memory` skill 建议：
  - 小文件可 `read_file` 后直接查
  - 大文件再用 `exec` 做定向搜索
- `Session` 现在会记录 `last_consolidated`，供自动归档使用：`nanobot/session/manager.py:32`
- runtime context 不再追加到 system prompt 尾部，而是并入当前 `user` 消息

### 五、一句话总结

- `AgentLoop` 是执行引擎
- `ContextBuilder` 是 prompt 装配器
- `SkillsLoader` 负责 skills 摘要/always 技能注入
- `MemoryStore` 负责两层记忆（`MEMORY.md` + `HISTORY.md`）及自动归档
- `SessionManager` 负责会话历史窗口与持久化
