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
- 核心执行循环在 `AgentLoop`：`nanobot/agent/loop.py:34`
- prompt 构建在 `ContextBuilder`：`nanobot/agent/context.py:13`
- skill 管理在 `SkillsLoader`：`nanobot/agent/skills.py:13`
- 记忆系统（长期记忆 + 历史归档）在 `MemoryStore`：`nanobot/agent/memory.py:45`

### 二、Prompt 拼接模式（重点）
先区分两层：

1. `system prompt` 字符串内部如何拼
2. 整个 `messages[]`（发给 LLM 的消息数组）如何拼

#### 2.1 `system prompt` 的拼接顺序

- `ContextBuilder.build_system_prompt`
- 位置：`nanobot/agent/context.py:28`

按顺序拼成 `parts`，最后用 `\n\n---\n\n` 连接：`nanobot/agent/context.py:71`

顺序如下：
- 身份与运行环境（动态时间、时区、平台、workspace 路径、行为规则）：
  - `nanobot/agent/context.py:40`
  - `nanobot/agent/context.py:73`
- Bootstrap 文件（工作区根目录下的 `AGENTS.md / SOUL.md / USER.md / TOOLS.md / IDENTITY.md`）：
  - `nanobot/agent/context.py:21`
  - `nanobot/agent/context.py:43`
  - `nanobot/agent/context.py:108`
- Memory（当前版本默认只注入长期记忆 `memory/MEMORY.md`）：
  - `nanobot/agent/context.py:48`
  - `nanobot/agent/memory.py:65`
- Active Skills（`always: true` 的技能完整注入，当前内置 `memory` skill 会在这里出现）：
  - `nanobot/agent/context.py:54`
  - `nanobot/agent/skills.py:193`
  - `nanobot/skills/memory/SKILL.md:4`
- Skills 摘要（所有技能的 XML summary，供按需加载）：`nanobot/agent/context.py:61`

补充（Identity 段最近新增的提示）：
- 会显示时区：`nanobot/agent/context.py:76-89`
- 明确要求“调用工具前先用用户语言说一句要做什么（简短）”：`nanobot/agent/context.py:103-105`
- 明确提示通过 `grep` 检索 `memory/HISTORY.md`：`nanobot/agent/context.py:95-106`

#### 2.2 `messages[]` 的拼接顺序

- `ContextBuilder.build_messages`
- 位置：`nanobot/agent/context.py:120`

顺序如下：
- `system`：上面的完整 system prompt：`nanobot/agent/context.py:146`
- （可选）追加当前会话信息 `Channel / Chat ID` 到 system prompt 尾部：`nanobot/agent/context.py:147-149`
- 历史对话（来自 session，条数由 `memory_window` 控制，默认 50）：
  - `nanobot/agent/loop.py:55`
  - `nanobot/agent/loop.py:303-306`
  - `nanobot/agent/loop.py:378-383`
- 历史消息会尽量保留工具相关字段（如 `tool_calls / tool_call_id / name`），不再是“仅 role/content”：
  - `nanobot/session/manager.py:45-54`
- 当前用户消息（若有图片，会编码成多模态 content）：
  - `nanobot/agent/context.py:155`
  - `nanobot/agent/context.py:160`

### 三、Prompt 在单轮中的增长（工具调用）

在 `AgentLoop._run_agent_loop()` 中，LLM 一旦返回 `tool_calls`，会继续把内容 append 到 `messages` 后再请求下一轮：

- assistant 消息（带 `tool_calls`）：
  - `nanobot/agent/loop.py:202-216`
  - `nanobot/agent/context.py:205`
- tool 结果消息：
  - `nanobot/agent/loop.py:218-225`
  - `nanobot/agent/context.py:178`

这意味着：
- 单轮中 prompt 是“滚动增长”的
- 跨轮会带最近历史窗口（默认 `memory_window=50`）
- 会话过长时会自动触发记忆归档，把旧消息总结进 `memory/MEMORY.md + memory/HISTORY.md`：
  - `nanobot/agent/loop.py:355-372`
  - `nanobot/agent/loop.py:416-421`
  - `nanobot/agent/memory.py:69-143`

### 四、当前版本需要特别注意的变化

- 旧版本文档里常见的“今日笔记（`YYYY-MM-DD.md`）自动进 prompt”描述，当前实现已不成立；现在 `get_memory_context()` 默认只返回长期记忆 `MEMORY.md`：`nanobot/agent/memory.py:65-68`
- `memory/HISTORY.md` 默认不进 prompt，需要通过 `exec + grep` 检索（同时有 `memory` skill 指导怎么用）：`nanobot/skills/memory/SKILL.md:11-21`
- `Session` 现在会记录 `last_consolidated`，供自动归档使用：`nanobot/session/manager.py:32`

### 五、一句话总结

- `AgentLoop` 是执行引擎
- `ContextBuilder` 是 prompt 装配器
- `SkillsLoader` 负责 skills 摘要/always 技能注入
- `MemoryStore` 负责两层记忆（`MEMORY.md` + `HISTORY.md`）及自动归档
- `SessionManager` 负责会话历史窗口与持久化
