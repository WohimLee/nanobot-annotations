
## SILLS 的使用
“单次请求 + Skill 按需加载”的时序图（ASCII），直接对应当前实现。

**图 1：普通用户消息的主链路（含 prompt 拼接）**
```text
[CLI / Telegram / WhatsApp / ...]
            |
            v
      AgentLoop._process_message()
      (nanobot/agent/loop.py:144)
            |
            |-- 取会话历史 SessionManager.get_or_create()
            |   (nanobot/session/manager.py:78)
            |
            |-- ContextBuilder.build_messages()
            |   (nanobot/agent/context.py:121)
            |        |
            |        |-- build_system_prompt()
            |        |   (nanobot/agent/context.py:28)
            |        |      1) Identity/Runtime/Workspace
            |        |      2) AGENTS.md / SOUL.md / USER.md / TOOLS.md / IDENTITY.md
            |        |      3) Memory (MEMORY.md + 今日笔记)
            |        |      4) Active Skills (always=true 的完整内容)
            |        |      5) Skills Summary (所有技能摘要 XML)
            |        |
            |        |-- 拼 messages[]
            |            [system] + [history] + [current user]
            |
            v
      Provider.chat(messages, tools)
      (nanobot/agent/loop.py:195)
            |
            |-- 如果返回 tool_calls:
            |      1) append assistant(tool_calls)
            |         (nanobot/agent/context.py:206)
            |      2) 执行工具 ToolRegistry.execute()
            |         (nanobot/agent/tools/registry.py:33)
            |      3) append tool result
            |         (nanobot/agent/context.py:179)
            |      4) 再次 Provider.chat(...) 继续循环
            |
            |-- 如果无 tool_calls:
            |      得到最终文本回复
            |
            v
      保存会话历史（只存 user/assistant）
      (nanobot/agent/loop.py:240, nanobot/session/manager.py:136)
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
      Memory +
      Active Skills(always) +
      Skills Summary(XML) +
      Current Session(Channel/Chat ID)
  },
  ...history (最多 50 条 user/assistant),
  {
    role: "user",
    content: 当前消息（有图片时会变成多模态数组）
  }
]
```

关键代码：
- `nanobot/agent/context.py:28`
- `nanobot/agent/context.py:121`
- `nanobot/agent/memory.py:90`
- `nanobot/session/manager.py:39`

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
  |   (nanobot/agent/context.py:179)
  |
  |-- 下一次 LLM 推理时就“拿着这份 skill 指南”继续执行
```

**再补两点你最容易踩坑的地方**
- `skill_names` 参数目前在主流程里基本没被用来“指定注入某个 skill”；当前主要是 `always + summary + read_file 按需` 模式：`nanobot/agent/context.py:28`
- `subagent` 不走 `ContextBuilder`，它用的是自己的简化 system prompt，所以默认不自动带 skills summary/memory：`nanobot/agent/subagent.py:113`、`nanobot/agent/subagent.py:211`

如果你要，我可以再画一张“当模型决定读取某个 `SKILL.md` 时，单轮 messages 如何增长”的展开图（把 assistant/tool/assistant 三段消息具体示例化）。