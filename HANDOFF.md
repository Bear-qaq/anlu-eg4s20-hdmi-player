# 用 DSH 开发这个项目

## 起步

```powershell
cd <当前项目目录>
dsh
```

**第一句只需要说你要做什么。** 项目背景、板卡、引脚、五个坑、编码规范、资料在哪 ——
这些由 `AGENTS.md` 自动注入，不用重复。

### 常用开场白

**① 直接干活（最常用）**
```
读 PROGRESS.md，然后：给 bmp_read 加一个缩略图降采样输出
```

**② 需要先建立全局认识**
```
读 ai/00_START_HERE.md 和 PROGRESS.md，我们讨论切换特效怎么做
```

**③ 排查问题**
```
读 PROGRESS.md 和 ai/06_REPORTS.md。综合报 timing violation，帮我定位
```

**④ 不确定该读什么**
```
读 ai/00_START_HERE.md，我要做 <你的需求>
```

**⑤ 接着上次继续**
```
读 PROGRESS.md，接着「<待办里的某一条>」继续
```

### 为什么一句话就够

新会话开局时**已经知道**（`AGENTS.md` 自动注入）：项目是什么、器件是 EG4S20BG256、
TD 6.2.1 锁定、生效引脚表、加密 HDL 是黑盒、`pin.adc` 的 `#` 行已废弃、
编码规范、以及"读源码是最后手段"的阅读顺序。

新会话**不知道**的只有两件：**你要做什么**，和**你做到哪了**。
前者你说，后者靠 `PROGRESS.md`。

### 保持 `PROGRESS.md` 更新

`AGENTS.md` 里已经写了规则：开工前读、收工前把**决策和理由**追加进去。

这条规则是跨会话工作的关键。**没写下来的决策，下个会话会重新推一遍，而且很可能推出不同的结论。**
比如"为什么选双缓冲而不是三缓冲"—— 理由不记，下次就会有人（包括 AI）提议改掉它。


## 三层上下文机制

这套资料按"什么时候必须知道"分成三层，各自用不同的加载方式：

| 层 | 载体 | 加载时机 | 体积 |
|---|---|---|---|
| **硬规则** | `AGENTS.md` | 每次任务**自动注入** | 5.2 KB / 64 KB 预算 |
| **深度知识** | `.dsh/skills/*/SKILL.md` | 任务匹配时**按需加载** | 只有 name+description 常驻 |
| **资料索引** | `ai/*.md`、`ai/packs/*.md` | 我让你读时**按需读取** | 单个 2–18k token |
| **源码** | `ai/files/`（`raw/` 的干净镜像） | 确认要改哪个文件时才读 | — |

设计依据（读 DSH 源码确认的，不是猜的）：

- `dsh-agent-instructions` 从**项目根到工作目录**逐级加载 `AGENTS.md` / `CLAUDE.md`，
  整条链共享 **64 KB** 预算，超出时先丢宽泛的文件、最后截断最具体的文件。
  所以 `AGENTS.md` 只放"不知道就会出错"的内容。
- `dsh-skill-filesystem` 扫描 `<projectRoot>/.dsh/skills`（优先级 100，最高），
  格式是 `<技能名>/SKILL.md`（YAML frontmatter 必填 `name` 与 `description`）。
  只有摘要常驻上下文，正文按需加载。
- `ai/02_MODULE_MAP.md` 单独就 **64 KB** —— 和整个指令预算一样大，所以它**绝不能**进 `AGENTS.md`。

## 项目根标记

我在工作区里建了一个**空的 `.git` 目录**。

原因是 DSH 用 `.git` 作为项目根标记，找不到时退化为当前工作目录。有了这个标记，
**你在任何子目录里启动 dsh 都能正确找到 `AGENTS.md` 和 `.dsh/skills/`**：

```powershell
cd D:\talk\anlu\src
dsh          # 依然会加载 D:\talk\anlu\AGENTS.md
```

没有这个标记的话，上面这条命令就会丢失全部项目规则。

> 这个 `.git` 是空目录，只为标记用途。将来真要 `git init`，直接执行即可，
> 不会冲突。不想要了就删掉，代价是必须在工作区根目录启动 dsh。

## 验证配置生效

会话开头应该能看到 `Instructions from: AGENTS.md`。技能目录里应该列出
`anlogic-td` 和 `fpga-workspace`。两者都在，说明三层机制都正常。

## 日常循环

```powershell
# 1. 写代码 —— 在 src/ / constr/ / sim/ 下
# 2. 可选：重建索引，让模块地图跟上你的新代码
node tools/pack.mjs
# 3. 换任务就开新会话，避免上下文被上一个任务污染
```

**新任务开新会话**是这个工作流最重要的一条。`AGENTS.md` 是自动的，
`ai/` 是按需的，所以新会话的启动成本很低，没必要在一个会话里硬撑。

## 什么时候该加载技能

| 你说的事 | 我会加载 |
|---|---|
| "给 bmp_read 加个缩略图降采样" | 都不用，直接查 `ai/02_MODULE_MAP.md` |
| "TD 报了个 timing violation 怎么查" | `anlogic-td` |
| "把新下载的例程加进资料包" | `fpga-workspace` |
| "引脚约束该怎么写" | `anlogic-td` |

你也可以直接点名：*"用 anlogic-td 技能看看这个问题"*。

## 加新资料时

丢进 `raw/`，然后 `node tools/pack.mjs`。细节（从 zip 里挑文件、docx 转 markdown、
调剔除规则）都在 `fpga-workspace` 技能里，需要时让我加载就行。

> ⚠️ 自己手动跑 `pack.mjs` 时，**不要用 `... | Select-Object -First N`** 截断输出。
> PowerShell 拿到 N 行就关管道，node 收到 EPIPE 会中途退出。
> 虽然现在"渲染完才动磁盘"的顺序保证不会毁掉旧索引，但这次更新会不完整。

---

## 附录：需要给别人时

如果哪天要把资料给网页版 AI 或另一台机器：

```powershell
node tools/bundle.mjs context   # 0.2 MB，37 个 md 索引 —— 上传给网页版 AI
node tools/bundle.mjs agent     # 0.5 MB，索引 + 源码镜像 + 工程骨架
node tools/bundle.mjs full      # 120 MB，全部含 raw/ 原件
```

打出来的 zip 用 .NET 的 `ZipFile` 验证过可正常解压，中文路径完好。

**Codex 用的是同一套 `AGENTS.md` 约定**，所以如果把工作区拷到另一台装了 Codex 的机器上，
不需要改任何东西 —— 在同一目录启动 `codex` 即可。
