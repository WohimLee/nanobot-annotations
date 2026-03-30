## SKILLS 的使用（原理）

核心不是“自动把所有 skill 塞进 prompt”，而是：

`摘要常驻 + 按需读取 + 少量 always 预加载`

### 一、SKILL 的来源与优先级

`SkillsLoader.list_skills()` 会同时扫描：

- 工作区自定义技能：`<workspace>/skills/<name>/SKILL.md`（优先级高）
- 内置技能：`nanobot/skills/<name>/SKILL.md`
- 同名时工作区覆盖内置（内置会跳过同名项）

相关实现：
- `SkillsLoader.list_skills()`
- `SkillsLoader.load_skill()`

### 二、SKILL 的格式

每个 skill 是一个目录，核心文件是 `SKILL.md`：

- frontmatter（如 `name` / `description` / `metadata` / `always`）
- markdown 正文（工作流、命令、注意事项）

补充：
- 当前 frontmatter 解析是“简单按行切 `key: value`”，不是完整 YAML 解析器
- 复杂的 skill 元数据通常放在 `metadata` 字段里，再由代码把其中的 JSON 解析成 `nanobot` / `openclaw` 配置

例子：
- `nanobot/skills/github/SKILL.md:1`
- `nanobot/skills/tmux/SKILL.md:1`
- `nanobot/skills/cron/SKILL.md:1`
- `nanobot/skills/memory/SKILL.md:1`

### 三、SKILL 在 prompt 中如何出现（progressive loading）

入口在 `ContextBuilder.build_system_prompt()`。

分两层：

1. `always` 技能（完整注入）
- `ContextBuilder` 会先取 `SkillsLoader.get_always_skills()`
- 再调用 `SkillsLoader.load_skills_for_context()`，把这些 skill 的完整正文（去 frontmatter）放进 `# Active Skills`

当前版本新增了内置 `memory` skill，且 `always: true`，所以通常会稳定进入 system prompt：
- `nanobot/skills/memory/SKILL.md:4`

2. 所有技能摘要（仅摘要常驻）
- `ContextBuilder` 会把所有 skill 生成为 XML 摘要（名称、描述、路径、`available`）
- 如果依赖没满足，还会额外带上 `<requires>...`
- 模型看到摘要后，如果判断需要某个 skill，再用 `read_file` 按路径读取完整 `SKILL.md`

相关实现：
- `SkillsLoader.build_skills_summary()`
- `SkillsLoader._get_missing_requirements()`

### 四、SKILL 实际如何“发挥作用”

实际运行时通常是这样：

1. 模型先从 skills summary 里识别可用技能（如 `github` / `tmux` / `weather`）
2. 调用 `read_file(path=...)` 读取对应 `SKILL.md`
3. `read_file` 返回 skill 正文（作为 tool result）
4. 下一轮 LLM 推理拿着这份 skill 指南继续执行命令/操作

`read_file` 工具名就是 `read_file`，定义在 `nanobot/agent/tools/filesystem.py`。

### 五、`available=true/false` 是怎么计算的

`SkillsLoader` 会检查 frontmatter 的 metadata 里声明的依赖（当前主要检查）：

- `requires.bins`：命令是否在 PATH
- `requires.env`：环境变量是否存在

相关实现：
- `SkillsLoader._check_requirements()`

skills summary 会显示：
- `<skill available="true|false">`
- 缺失依赖（`<requires>...`）

相关实现：
- `SkillsLoader.build_skills_summary()`

补充：
- metadata 解析兼容 `nanobot` 和 `openclaw` 两种 key，便于复用 OpenClaw 风格 skill
- 对应实现：`SkillsLoader._parse_nanobot_metadata()`

### 六、和 Memory 的关系（当前版本新增重点）

现在 `SKILL` 和 `Memory` 的关系更紧了，尤其是内置了 `memory` skill：

- `memory/MEMORY.md`（长期记忆）会直接进入 prompt：`MemoryStore.get_memory_context()`
- `memory/HISTORY.md`（事件日志）不会直接进入 prompt
- `memory` skill（always）会告诉模型如何回忆历史：
  - 小文件可先 `read_file` 再在上下文内搜索
  - 大文件更适合用 `exec` 做定向搜索（如 `grep` / `findstr` / Python 单行脚本）
- 长对话会自动归档到 `MEMORY.md + HISTORY.md`：`MemoryStore.consolidate()`
- 如果 `save_memory` 连续失败 3 次，会降级成原始消息直接写入 `HISTORY.md`

### 七、几个容易误解的点

- `skill_names` 参数目前仍然更像“预留接口”
  - `build_system_prompt(..., skill_names=...)` 和 `build_messages(..., skill_names=...)` 都有参数
  - 但主流程主要依赖 `always + summary + read_file 按需`，没有看到显式指定 skill 注入的实际使用路径

- `workspace/AGENTS.md`（仓库里的示例/模板）不等于运行时一定加载它
  - 运行时加载的是“当前配置 workspace 根目录”下的 `AGENTS.md / SOUL.md / USER.md / TOOLS.md`
  - 不是仓库里随便某个同名文件都会自动生效

- `tmux` skill frontmatter 里虽然有 `os` 信息，但当前 `_check_requirements()` 仍只检查 `bins/env`，不检查 `os`
  - `nanobot/skills/tmux/SKILL.md`
  - `SkillsLoader._check_requirements()`

- `subagent` 不走主 agent 的 `ContextBuilder`
  - 它不会自动继承主 agent 的 bootstrap files、Memory、Active Skills
  - 但它现在会构建自己的简化 prompt，并主动附带一份 skills summary，仍然可以按需 `read_file` 读取 `SKILL.md`

- 文件工具现在会把相对路径按 `workspace` 解析，这让 skill 文档里的相对路径更好用
  - 对应实现：`nanobot/agent/tools/filesystem.py` 里的 `_resolve_path()`
