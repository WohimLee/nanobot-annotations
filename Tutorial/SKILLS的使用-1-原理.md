## SKILLS 的使用（原理）

核心不是“自动把所有 skill 塞进 prompt”，而是：

`摘要常驻 + 按需读取 + 少量 always 预加载`

### 一、SKILL 的来源与优先级

`SkillsLoader.list_skills()` 会同时扫描：

- 工作区自定义技能：`<workspace>/skills/<name>/SKILL.md`（优先级高）
- 内置技能：`nanobot/skills/<name>/SKILL.md`
- 同名时工作区覆盖内置（内置会跳过同名项）

相关代码：
- `nanobot/agent/skills.py:38-53`
- `nanobot/agent/skills.py:51`

### 二、SKILL 的格式

每个 skill 是一个目录，核心文件是 `SKILL.md`：

- frontmatter（如 `name` / `description` / `metadata` / `always`）
- markdown 正文（工作流、命令、注意事项）

例子：
- `nanobot/skills/github/SKILL.md:1`
- `nanobot/skills/tmux/SKILL.md:1`
- `nanobot/skills/cron/SKILL.md:1`
- `nanobot/skills/memory/SKILL.md:1`

### 三、SKILL 在 prompt 中如何出现（progressive loading）

入口在 `ContextBuilder.build_system_prompt()`：`nanobot/agent/context.py:28`

分两层：

1. `always` 技能（完整注入）
- `ContextBuilder` 会先取 `get_always_skills()`：`nanobot/agent/context.py:55`
- 再把这些 skill 的完整正文（去 frontmatter）放进 `# Active Skills`：`nanobot/agent/context.py:57-60`

相关代码：
- `nanobot/agent/skills.py:82`
- `nanobot/agent/skills.py:193`

当前版本新增了内置 `memory` skill，且 `always: true`，所以通常会稳定进入 system prompt：
- `nanobot/skills/memory/SKILL.md:4`

2. 所有技能摘要（仅摘要常驻）
- `ContextBuilder` 会把所有 skill 生成 XML 摘要（名称、描述、路径、available）：`nanobot/agent/context.py:62-69`
- 模型看到摘要后，如果判断需要某个 skill，再用 `read_file` 按路径读取完整 `SKILL.md`

相关代码：
- `nanobot/agent/skills.py:101-140`

### 四、SKILL 实际如何“发挥作用”

实际运行时通常是这样：

1. 模型先从 skills summary 里识别可用技能（如 `github` / `tmux` / `weather`）
2. 调用 `read_file(path=...)` 读取对应 `SKILL.md`
3. `read_file` 返回 skill 正文（作为 tool result）
4. 下一轮 LLM 推理拿着这份 skill 指南继续执行命令/操作

`read_file` 工具名是 `read_file`：
- `nanobot/agent/tools/filesystem.py:24`
- `nanobot/agent/tools/filesystem.py:32-33`

### 五、`available=true/false` 是怎么计算的

`SkillsLoader` 会检查 frontmatter 的 metadata 里声明的依赖（当前主要检查）：

- `requires.bins`：命令是否在 PATH
- `requires.env`：环境变量是否存在

相关代码：
- `nanobot/agent/skills.py:177-186`

skills summary 会显示：
- `<skill available="true|false">`
- 缺失依赖（`<requires>...`）

相关代码：
- `nanobot/agent/skills.py:123-136`

补充：
- metadata 解析现在兼容 `nanobot` 和 `openclaw` 两种 key（便于复用 OpenClaw 风格 skill）
- 代码：`nanobot/agent/skills.py:169-175`

### 六、和 Memory 的关系（当前版本新增重点）

现在 `SKILL` 和 `Memory` 的关系更紧了，尤其是新增了 `memory` skill：

- `memory/MEMORY.md`（长期记忆）会直接进入 prompt：`nanobot/agent/memory.py:65-68`
- `memory/HISTORY.md`（事件日志）不会直接进入 prompt，需要 grep 检索：`nanobot/agent/memory.py:51`、`nanobot/skills/memory/SKILL.md:11-21`
- `memory` skill（always）会告诉模型如何用 `grep` 在 `HISTORY.md` 里回忆历史事件：`nanobot/skills/memory/SKILL.md:7-21`
- 长对话会自动归档到 `MEMORY.md + HISTORY.md`：`nanobot/agent/memory.py:69-143`

### 七、几个容易误解的点

- `skill_names` 参数目前仍然更像“预留接口”
  - `build_messages(..., skill_names=...)` 有参数：`nanobot/agent/context.py:124`
  - 但主流程主要依赖 `always + summary + read_file 按需`，没有看到显式指定 skill 注入的实际使用路径：`nanobot/agent/context.py:55`

- `workspace/AGENTS.md`（仓库里的示例/模板）不等于运行时一定加载它
  - 运行时加载的是“配置指定 workspace 根目录”下的 `AGENTS.md` 等：`nanobot/agent/context.py:112-117`
  - 默认 workspace 在 `~/.nanobot/workspace`：`nanobot/config/schema.py:122`、`nanobot/config/schema.py:194-197`

- `tmux` skill frontmatter 里虽然有 `os` 信息，但当前 `_check_requirements()` 仍只检查 `bins/env`，不检查 `os`
  - `nanobot/skills/tmux/SKILL.md:4`
  - `nanobot/agent/skills.py:177-186`

- `subagent` 不走 `ContextBuilder`，不会自动带主 agent 的 skills summary / memory
  - 它有自己的简化 system prompt：`nanobot/agent/subagent.py:211`
  - 但新版本会明确提示到 `workspace/skills/` 按需读取 `SKILL.md`：`nanobot/agent/subagent.py:249-252`

- 文件工具现在会把相对路径按 `workspace` 解析，这让 skill 文档里的相对路径更好用
  - `nanobot/agent/tools/filesystem.py:10-21`
  - `nanobot/agent/tools/filesystem.py:52-55`
