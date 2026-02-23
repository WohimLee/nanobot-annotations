## SKILLS 的使用

核心不是“自动把所有 skill 塞进 prompt”，而是 `摘要常驻 + 按需读取 + 少量 always 预加载`

### 一、SKILL 的来源与优先级
`SkillsLoader.list_skills()` 会同时扫：
- 工作区自定义技能：`<workspace>/skills/<name>/SKILL.md`（优先级高）
- 内置技能：`nanobot/skills/<name>/SKILL.md`: `nanobot/agent/skills.py:38-53`
- 同名时工作区覆盖内置（内置会跳过同名项）：`nanobot/agent/skills.py:51`

### 二、SKILL 的格式
每个 skill 是一个目录，里面一个 `SKILL.md`，前面有 frontmatter（`name/description/metadata`），后面是操作说明。
例子：
- `nanobot/skills/github/SKILL.md:1`
- `nanobot/skills/tmux/SKILL.md:1`
- `nanobot/skills/cron/SKILL.md:1`

### 三、SKILL 在 prompt 中如何出现（progressive loading）
位置：`nanobot/agent/context.py:53`

分两层：
- `always` 技能：把完整内容（去 frontmatter 后）直接注入 system prompt 的 `# Active Skills`：
  - `nanobot/agent/context.py:54`
  - `nanobot/agent/skills.py:82`
  - `nanobot/agent/skills.py:193`
- 所有技能摘要：只注入 XML 摘要（名字、描述、路径、available），告诉模型“需要时用 `read_file` 读 `SKILL.md`”：
- `nanobot/agent/context.py:61-69`
- `nanobot/agent/skills.py:101`

这就是你问的“SKILL 怎么发挥作用”：
- 平时不占太多 token（只放摘要）
- 模型识别任务匹配后，用 `read_file` 工具读取对应 `SKILL.md`
- 再按 skill 里的步骤/命令执行

`read_file` 工具名确实就是 `read_file`：
- `nanobot/agent/tools/filesystem.py:17`
- `nanobot/agent/tools/filesystem.py:24`

### 四、`available=true/false` 怎么算
`SkillsLoader` 会检查 frontmatter 里 `metadata.nanobot.requires` 的：
- `bins`（命令是否在 PATH）
- `env`（环境变量是否存在）
逻辑：`nanobot/agent/skills.py:177`

摘要里会显示 `available` 和缺失依赖：`nanobot/agent/skills.py:123-136`

**几个实现层面的关键细节（容易误解）**
- `skill_names` 参数目前是“预留接口”，主流程没真正用来强制注入指定 skill。
  - `build_messages(..., skill_names=...)` 有参数：`nanobot/agent/context.py:125`
  - 但 `build_system_prompt()` 里实际只处理 `always_skills`，没有用传入的 `skill_names`：`nanobot/agent/context.py:55`
- `workspace/AGENTS.md`（仓库里的模板文件）不等于运行时自动加载文件。
  - 运行时加载的是“配置指定 workspace 根目录”下的 `AGENTS.md` 等：`nanobot/agent/context.py:113`
  - 默认 workspace 配置是 `~/.nanobot/workspace`：`nanobot/config/schema.py:122`、`nanobot/config/schema.py:194`
  - `onboard` 会在该 workspace 根目录生成模板：`nanobot/cli/commands.py:226`
- `tmux` skill frontmatter 里有 `os` 信息，但当前 `SkillsLoader._check_requirements()` 只检查 `bins/env`，没有检查 `os`：`nanobot/skills/tmux/SKILL.md:4`、`nanobot/agent/skills.py:177`
- `spawn` 出来的 subagent 不走 `ContextBuilder`，因此默认不会自动带上 memory/skills 摘要。
  - 它有自己的简化 system prompt：`nanobot/agent/subagent.py:113`、`nanobot/agent/subagent.py:211`