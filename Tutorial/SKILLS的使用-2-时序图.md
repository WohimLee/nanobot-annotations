## SKILLS 的使用（时序图）

“单次请求 + Skill 按需加载”的时序图（ASCII），对应当前实现。

**图 1：普通用户消息的主链路（含 prompt 拼接）**

```text
[CLI / Telegram / WhatsApp / ...]
            |
            v
      AgentLoop._process_message()
      (nanobot/agent/loop.py:288)
            |
            |-- 取会话历史 SessionManager.get_or_create()
            |   (nanobot/session/manager.py:86)
            |
            |-- ContextBuilder.build_messages()
            |   (nanobot/agent/context.py:120)
            |        |
            |        |-- build_system_prompt()
            |        |   (nanobot/agent/context.py:28)
            |        |      1) Identity/Runtime/Workspace
            |        |      2) AGENTS.md / SOUL.md / USER.md / TOOLS.md / IDENTITY.md
            |        |      3) Memory (仅 MEMORY.md 长期记忆)
            |        |      4) Active Skills (always=true 的完整内容，含 memory skill)
            |        |      5) Skills Summary (所有技能摘要 XML)
            |        |
            |        |-- 拼 messages[]
            |            [system] + [history] + [current user]
            |
            v
      AgentLoop._run_agent_loop(...)
      (nanobot/agent/loop.py:172)
            |
            |-- Provider.chat(messages, tools, ...)
            |   (nanobot/agent/loop.py:186-192)
            |
            |-- 如果返回 tool_calls:
            |      1) append assistant(tool_calls)
            |         (nanobot/agent/loop.py:202-216)
            |         (nanobot/agent/context.py:205)
            |      2) 执行工具 ToolRegistry.execute()
            |         (nanobot/agent/tools/registry.py:33)
            |      3) append tool result
            |         (nanobot/agent/loop.py:218-225)
            |         (nanobot/agent/context.py:178)
            |      4) 再次 Provider.chat(...) 继续循环
            |
            |-- 如果无 tool_calls:
            |      得到最终文本回复
            |
            v
      保存会话历史（history 窗口由 memory_window 控制）
      (nanobot/agent/loop.py:402-405, nanobot/session/manager.py:45-54)
            |
            |-- 若会话过长：异步触发自动归档
            |   -> MEMORY.md + HISTORY.md
            |   (nanobot/agent/loop.py:355-372, nanobot/agent/memory.py:69-143)
            |
            v
        OutboundMessage -> 回给用户
```

**图 2：Prompt（messages）实际长什么样**

```text
messages = [
  {
    role: "system",
    content:
      Identity +
      Bootstrap Files +
      Memory(MEMORY.md) +
      Active Skills(always) +
      Skills Summary(XML) +
      Current Session(Channel/Chat ID)
  },
  ...history (最多 memory_window 条，默认 50；可包含部分工具相关字段),
  {
    role: "user",
    content: 当前消息（有图片时会变成多模态数组）
  }
]
```

关键代码：
- `nanobot/agent/context.py:28`
- `nanobot/agent/context.py:120`
- `nanobot/agent/memory.py:65`
- `nanobot/session/manager.py:45`
- `nanobot/agent/loop.py:55`

**图 3：SKILL 怎么“发挥作用”（按需加载）**

```text
ContextBuilder.build_system_prompt()
  |
  |-- SkillsLoader.get_always_skills()
  |    -> always=true 且依赖满足的 skill，完整注入 system prompt
  |    (nanobot/agent/skills.py:193)
  |
  |-- SkillsLoader.build_skills_summary()
       -> 把所有 skill 的 name/description/location/available 放进 XML 摘要
       (nanobot/agent/skills.py:101)

LLM 看到摘要后（例如识别用户要 GitHub/tmux/weather）
  |
  |-- 调用 read_file(path=<SKILL.md 路径>)
  |   (tool 名在 nanobot/agent/tools/filesystem.py:24)
  |
  |-- read_file 返回完整 SKILL.md 内容（tool result）
  |
  |-- 该内容作为 [tool] 消息追加到当前轮 messages
  |   (nanobot/agent/context.py:178)
  |
  |-- 下一次 LLM 推理时就“拿着这份 skill 指南”继续执行
```

**图 4：memory skill + 两层记忆（当前版本新增重点）**

```text
系统启动 / 每轮构建 prompt
  |
  |-- MemoryStore.get_memory_context()
  |    -> 只注入 memory/MEMORY.md
  |
  |-- SkillsLoader.get_always_skills()
       -> 注入 memory skill（always: true）
            |
            |-- 提醒模型：
            |   - MEMORY.md 存长期事实
            |   - HISTORY.md 不进上下文
            |   - 用 exec + grep 检索 HISTORY.md

对话变长
  |
  |-- AgentLoop 触发 consolidate()
       -> LLM 归档旧消息
       -> 更新 MEMORY.md
       -> 追加 HISTORY.md
```

**再补几个容易踩坑的点**

- `skill_names` 参数目前在主流程里基本没被用来“指定注入某个 skill”；当前主要是 `always + summary + read_file 按需` 模式：`nanobot/agent/context.py:28`
- `subagent` 不走 `ContextBuilder`，所以默认不自动带主 agent 的 skills summary/memory；但新版本会提示它到 `workspace/skills/` 按需读 `SKILL.md`：`nanobot/agent/subagent.py:249-252`
- 文件工具现在会把相对路径按 `workspace` 解析，skill 里的相对路径更可靠：`nanobot/agent/tools/filesystem.py:10-21`
