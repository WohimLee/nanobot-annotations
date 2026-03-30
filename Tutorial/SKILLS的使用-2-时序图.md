## SKILLS 的使用（时序图）

“单次请求 + Skill 按需加载”的时序图（ASCII），对应当前实现。

**图 1：普通用户消息的主链路（含 prompt 拼接）**

```text
[CLI / Telegram / WhatsApp / ...]
            |
            v
      AgentLoop._process_message()
            |
            |-- 取会话历史 SessionManager.get_or_create()
            |
            |-- ContextBuilder.build_messages()
            |        |
            |        |-- build_system_prompt()
            |        |      1) Identity / Platform / Workspace Guidelines
            |        |      2) AGENTS.md / SOUL.md / USER.md / TOOLS.md
            |        |      3) Memory (仅 MEMORY.md 长期记忆)
            |        |      4) Active Skills (always=true 的完整内容，含 memory skill)
            |        |      5) Skills Summary (所有技能摘要 XML)
            |        |
            |        |-- 拼 messages[]
            |            [system] + [history] + [user(runtime metadata + current user)]
            |
            v
      AgentLoop._run_agent_loop(...)
            |
            |-- Provider.chat(messages, tools, ...)
            |
            |-- 如果返回 tool_calls:
            |      1) append assistant(tool_calls)
            |      2) 执行工具 ToolRegistry.execute()
            |      3) append tool result
            |      4) 再次 Provider.chat(...) 继续循环
            |
            |-- 如果无 tool_calls:
            |      得到最终文本回复
            |
            v
      保存会话历史（history 窗口由 memory_window 控制）
            |
            |-- 若会话过长：异步触发自动归档
            |   -> MEMORY.md + HISTORY.md
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
      Skills Summary(XML)
  },
  ...history (最多 memory_window 条，默认 50；可包含部分工具相关字段),
  {
    role: "user",
    content:
      Runtime Context(Current Time, 可选 Channel/Chat ID) +
      当前消息（有图片时会变成多模态数组）
  }
]
```

关键代码：
- `ContextBuilder.build_system_prompt()`
- `ContextBuilder._build_runtime_context()`
- `ContextBuilder.build_messages()`
- `MemoryStore.get_memory_context()`

**图 3：SKILL 怎么“发挥作用”（按需加载）**

```text
ContextBuilder.build_system_prompt()
  |
  |-- SkillsLoader.get_always_skills()
  |    -> always=true 且依赖满足的 skill，完整注入 system prompt
  |
  |-- SkillsLoader.build_skills_summary()
       -> 把所有 skill 的 name/description/location/available 放进 XML 摘要

LLM 看到摘要后（例如识别用户要 GitHub/tmux/weather）
  |
  |-- 调用 read_file(path=<SKILL.md 路径>)
  |
  |-- read_file 返回完整 SKILL.md 内容（tool result）
  |
  |-- 该内容作为 [tool] 消息追加到当前轮 messages
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
            |   - 小 HISTORY 可 read_file 后在上下文内搜索
            |   - 大 HISTORY 更适合用 exec 做定向搜索

对话变长
  |
  |-- AgentLoop 触发 consolidate()
       -> LLM 归档旧消息
       -> 更新 MEMORY.md
       -> 追加 HISTORY.md
       -> 连续失败时会降级为 raw archive
```

**再补几个容易踩坑的点**

- `skill_names` 参数目前在主流程里基本没被用来“指定注入某个 skill”；当前主要还是 `always + summary + read_file 按需` 模式
- `subagent` 不走主 agent 的 `ContextBuilder`，不会自动继承 bootstrap files / memory / active skills；但它现在会生成自己的 skills summary，可继续按需读取 `SKILL.md`
- 文件工具会把相对路径按 `workspace` 解析，skill 里的相对路径更可靠
