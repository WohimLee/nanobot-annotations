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
- 核心执行循环在 `AgentLoop`：`nanobot/agent/loop.py:25`
- prompt 构建在 `ContextBuilder`：`nanobot/agent/context.py:13`
- skill 管理在 `SkillsLoader`：`nanobot/agent/skills.py:13`

### 二、Prompt 拼接模式（重点）
>先区分两层

1. `system prompt` 字符串内部如何拼
2. 整个 `messages[]`（发给 LLM 的消息数组）如何拼

#### 2.1  `system prompt` 的拼接顺序

- `ContextBuilder.build_system_prompt`
- 位置：`nanobot/agent/context.py:28`

按顺序拼成 `parts`，最后用 `\n\n---\n\n` 连接：`nanobot/agent/context.py:71`

>顺序如下
- 身份与运行环境（动态时间、平台、workspace 路径、行为规则）：
    - `nanobot/agent/context.py:40`
    - `nanobot/agent/context.py:73`
- Bootstrap 文件（工作区根目录下的 `AGENTS.md / SOUL.md / USER.md / TOOLS.md / IDENTITY.md`）：
    - `nanobot/agent/context.py:21`
    - `nanobot/agent/context.py:43`
    - `nanobot/agent/context.py:109`
- Memory（长期记忆 + 今日笔记）：
    - `nanobot/agent/context.py:48`
    - `nanobot/agent/memory.py:90`
- Skills（分两段，见下节）：`nanobot/agent/context.py:53`

#### 2.2 `messages[]` 的拼接顺序
- `ContextBuilder.build_messages`
- 位置：`nanobot/agent/context.py:121`

>顺序如下
- `system`：上面的完整 system prompt：`nanobot/agent/context.py:146`
- （可选）附加当前会话信息 `Channel/Chat ID` 到 system prompt 尾部：`nanobot/agent/context.py:148`
- 历史对话（来自 session，最多 50 条，仅 role/content）：
    - `nanobot/agent/context.py:152`
    - `nanobot/session/manager.py:39`
- 当前用户消息（若有图片，会编码成多模态 content）：
    - `nanobot/agent/context.py:155`
    - `nanobot/agent/context.py:161`

### 三、Prompt 增长
工具调用时 prompt 如何继续增长（单轮内）
在 `AgentLoop` 内，LLM 一旦返回 tool calls，会继续把以下内容 append 到 `messages` 后再请求下一轮：
- assistant 消息（带 tool_calls）：
    - `nanobot/agent/loop.py:202`
    - `nanobot/agent/context.py:206`
- tool 结果消息：
    - `nanobot/agent/loop.py:221`
    - `nanobot/agent/context.py:179`

这意味着：
- 单轮中 prompt 是“滚动增长”的
- 跨轮（下一次用户发言）只保留 `user/assistant` 文本历史，不保留上轮工具调用明细（session 保存时没有存 tool 消息）：
    - `nanobot/agent/loop.py:240`
    - `nanobot/session/manager.py:52`


**你可以把当前项目理解成**
- `AgentLoop` 是执行引擎
- `ContextBuilder` 是 prompt 装配器
- `SkillsLoader` 是 skill 目录索引 + 摘要生成器
- `MemoryStore` 和 `SessionManager` 分别负责“长期/当天记忆”和“对话历史”
- `ToolRegistry + tools` 提供可调用能力（文件、shell、web、消息、spawn、cron）
