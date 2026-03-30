
设计 prompt 系统和记忆系统时，核心目标是 4 件事：`稳定性`、`可扩展性`、`低 token 成本`、`可审计性`。  
这个项目里用的是“`分层 prompt + 渐进式技能加载 + 双层记忆`”的方案。

**1. Prompt 系统怎么设计**
1. 把 prompt 拆成“固定规则层”和“动态上下文层”，避免把所有信息混在一个 system prompt 里。
2. 在这个项目里，`ContextBuilder` 统一负责组装，入口是 `build_system_prompt()` 和 `build_messages()`。
3. `Tutorial/prompt的拼接.md` 里总结得很清楚，system prompt 的顺序是：
   1. 身份/运行环境（平台、Python、workspace、行为规则）
   2. Bootstrap 文件（`AGENTS.md`、`SOUL.md`、`USER.md`、`TOOLS.md`）
   3. Memory（长期记忆）
   4. Active Skills（always=true 的技能全文）
   5. Skills Summary（所有技能摘要）
4. 这样做的好处是职责清晰：
   - `workspace/AGENTS.md` 放行为规范
   - `workspace/USER.md` 放用户偏好/画像
   - `workspace/TOOLS.md` 放工具契约和边界
   - 记忆和技能单独管理，不污染主规则
5. `messages[]` 也不是只拼 system，而是 `system + 历史窗口 + 当前用户消息`。其中当前时间、`Channel`、`Chat ID` 这类 runtime metadata 会并入当前 `user` 消息，而不是塞进 system prompt。这保证了多轮对话的一致性，也兼容一些不接受连续同角色消息的 provider。

**2. 为什么要做“渐进式技能加载”**
1. 不会把所有技能全文都塞进 prompt，这会浪费 token，也会增加干扰。
2. 项目里采用的是 `摘要常驻 + 按需读取 + 少量 always 预加载`，`Tutorial/SKILLS的使用-1-原理.md` 和 `Tutorial/SKILLS的使用-2-时序图.md` 都强调了这一点。
3. 实现上：
   - 所有技能先生成摘要（XML summary），由 `SkillsLoader.build_skills_summary()` 负责
   - `always=true` 的技能直接注入全文，由 `SkillsLoader.get_always_skills()` 和 `load_skills_for_context()` 负责
   - 需要时模型再用 `read_file` 去读具体 `SKILL.md`
4. 这本质上是“prompt 的分层检索化”，能兼顾能力范围和上下文长度。

**3. 记忆系统怎么设计**
1. 把记忆分成三层：
   - `短期记忆`：当前会话历史窗口（session history）
   - `长期记忆`：稳定事实（`memory/MEMORY.md`）
   - `历史日志`：事件流（`memory/HISTORY.md`）
2. 这个项目的 `MemoryStore` 就是双层记忆核心。
3. 关键策略是：
   - `MEMORY.md` 进 prompt（高价值、低体积）
   - `HISTORY.md` 不进 prompt（避免 token 爆炸）
   - `memory` skill 会引导模型按文件大小选择搜索方式：小文件直接读，大文件再做定向搜索
4. 这点在 `nanobot/skills/memory/SKILL.md` 和 `Tutorial/prompt的拼接.md` 里都有明确说明。

**4. 记忆如何写入与更新（避免“越记越乱”）**
1. 会话原始消息先 append-only 保存，`SessionManager` 保留历史和工具字段，见 `nanobot/session/manager.py:45`。
2. 当会话变长时，会触发自动归档（consolidation）。
3. 归档时会让模型调用 `save_memory` 工具，输出两份内容：
   - 一条 grep 友好的 `history_entry`（写入 `HISTORY.md`）
   - 一份完整更新后的 `memory_update`（覆盖 `MEMORY.md`）
4. 如果归档阶段连续失败多次，系统会降级为 raw archive，把原始消息直接写进 `HISTORY.md`，避免彻底丢失历史。
5. 这样设计比“直接摘要覆盖全部上下文”更稳，因为保留了：
   - 原始会话（可审计）
   - 历史日志（可检索）
   - 长期事实（可直接注入）

**5. 认为这个方案的工程价值**
1. 可维护：prompt 的每一层都有独立文件和职责，不需要频繁改代码。
2. 可扩展：新增能力主要通过 `SKILL.md`，不必改主 prompt。
3. 成本可控：常驻的是规则/摘要，重内容按需加载。
4. 可解释：出了问题可以定位是规则层、技能层、记忆层还是 session 历史层。

**6. 面试加分项（你可以主动补一句）**
如果继续优化，会做三件事：
1. 给记忆增加“类型/置信度/更新时间”，减少过期信息污染。
2. 给 `HISTORY.md` 增加结构化索引（关键词或向量检索），但保留 grep 作为兜底。
3. 建 prompt/memory 的评测集（例如工具选择准确率、记忆召回率、token 成本）做回归测试。

**一句话总结**
这个项目的设计不是“把所有信息塞进 prompt”，而是把 prompt 当成一个分层上下文系统：`规则常驻、技能摘要常驻、能力按需加载、记忆分层注入与检索`。这正是这个项目在 `Tutorial/prompt的拼接.md` 和 `Tutorial/SKILLS的使用-*` 里体现的思路。

如果你要，可以再给你一版 `90秒口语版`（更像现场面试表达）。
