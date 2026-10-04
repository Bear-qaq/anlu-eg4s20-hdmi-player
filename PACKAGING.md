# 怎么把 FPGA 资料喂给 AI

## 核心结论

**不要"打包文件"，要"打包信息"。**

把一堆官方例程和手册原封不动丢给 AI 有三个致命问题：

1. **工程垃圾占大头。** Vivado/TD/Quartus 工程里 80–95% 是构建产物
   （`.cache/ runs/ .Xil/ *.jou *.log *.dcp *.bit`），对理解设计零价值，却要烧掉大量上下文。
2. **没有地图。** AI 面对 300 个文件，每轮对话都要重新摸索"顶层在哪、引脚在哪、板卡是什么型号"，
   这些重复劳动会挤掉真正用于设计的注意力。
3. **接口和实现混在一起。** 改一个模块的端口，AI 却不得不读完全部源码才能确认影响范围。

所以本工具包把资料整理成**三层**：

| 层 | 产物 | 作用 | 什么时候读 |
|---|---|---|---|
| 地图层 | `00_START_HERE.md` `01_INDEX.md` `03_HIERARCHY.md` | 一次读完就知道整个项目长什么样 | 每轮开头 |
| 接口层 | `02_MODULE_MAP.md` `04_CONSTRAINTS.md` | 所有模块端口 + 时钟 + 引脚，**不读源码** | 要改代码前 |
| 原文层 | `files/` `packs/` | 清理过的真实源码，按需分卷 | 确定要动哪个文件时 |

实测：一个有 20 个官方例程的竞赛资料，全量丢给 AI 轻松超过 50 万 token；
走本方案，地图层 + 接口层通常在 **5k–30k token** 以内，且信息密度更高。

---

## 使用流程

### 第一步：把资料丢进 `raw/`

```
raw/
  examples/        官方例程（整个工程目录直接拷进来，不用手动清理）
  docs/            数据手册、用户指南、板卡原理图（PDF 原样放）
  board/           引脚表、原理图截图
```

**不用手动删构建产物** —— 脚本会自动剔除。

### 第二步：填好 `AI_GUIDE.md`

这是**唯一需要你手写的文件**，也是 ROI 最高的投入。
板卡型号、工具版本、引脚、编码规范、协作规则，写清楚。
AI 少问一句，你就少一轮来回。

### 第三步：生成

```powershell
node tools/pack.mjs
```

或者一键 + 打包成 zip：

```powershell
node tools/bundle.mjs agent
```

先干跑看看会产出什么、有没有误删：

```powershell
node tools/pack.mjs --dry
```

### 第四步：让 AI 先读 `ai/00_START_HERE.md`

对话开头就说：

> 读 `ai/00_START_HERE.md`，然后我们讨论 XXX。

需要改模块时再说：

> 读 `ai/02_MODULE_MAP.md`，我要给 uart_rx 加一个 FIFO 溢出标志。

---

## 产物说明

| 文件 | 内容 | 典型 token |
|---|---|---|
| `00_START_HERE.md` | 入口：统计 + 目录树 + `AI_GUIDE.md` 全文 + 阅读顺序 | 小 |
| `01_INDEX.md` | 每个文件一行：路径 / 类别 / 行数 / 大小 / 文件头注释摘要 | 中 |
| `02_MODULE_MAP.md` | **所有** Verilog/VHDL 模块的端口、参数、例化列表 | 中 |
| `03_HIERARCHY.md` | 顶层候选、例化树、厂商原语/IP 引用清单 | 小 |
| `04_CONSTRAINTS.md` | 时钟表、引脚表 + 约束文件原文 | 小 |
| `05_DOCS.md` | PDF/Office 清单 + 摘要填写槽位 | 小 |
| `06_REPORTS.md` | 综合/布局布线报告的头尾（报错、资源占用、Fmax） | 小 |
| `files/` | 清理后的原始文件树，保留目录结构 | — |
| `packs/*.md` | 按例程/目录分卷，一次只喂一个 | 按需 |
| `MANIFEST.json` | 机器可读的全量元数据（供进一步脚本处理） | — |

`02_MODULE_MAP.md` 是最有价值的一个：它让 AI 在**不读任何源码**的情况下，
就能写出正确的例化、testbench 和端口连接。

---

## PDF 手册怎么办

AI 读不了 PDF。按优先级处理：

1. **最好的办法：找官方在线文档 URL。**
   写进 `05_DOCS.md` 对应条目，AI 可以直接抓网页。很多厂商（Xilinx/AMD、Intel）文档都在线。
2. **次好：只抄关键表。**
   数据手册里你真正需要的通常只有三样——引脚表、寄存器映射、时序参数。
   手抄成 `docs_md/pinout.md`、`docs_md/regmap.md`、`docs_md/timing.md`，
   比整本 400 页手册有用得多，而且 AI 一定读得准。
3. **整本转换：** 用 `marker`、`MinerU`、`markitdown` 之类工具转 markdown，丢进 `docs_md/`。
4. **截图/原理图：** 保留在 `raw/`，需要时单独把图片附给 AI（别一次附 50 张）。

转换完成后，把路径填回 `05_DOCS.md` 的「已转 markdown」一栏。

---

## 工具链一览

> 全部是 Node 脚本，**不依赖 PowerShell** —— 早期版本用过 `.ps1`，
> 但 PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按 GBK 解析，中文注释一多就语法报错，
> 任何编辑器保存一次都可能踩到。改用 Node 后这个坑彻底消失。

| 文件 | 作用 |
|---|---|
| `tools/pack.mjs` | 主脚本：扫描分类 → 剔除构建产物 → 提取模块接口 → 生成索引与分卷 |
| `tools/bundle.mjs` | 生成三档交接包（zip），交给其他 AI / agent |
| `tools/unzip.mjs` | 选择性解压：从几百 MB 的包里只取出需要的条目 |
| `tools/docx2md.mjs` | docx → markdown（官方手册大多是 docx，这一步很关键） |
| `tools/lib/zip.mjs` | 自带的 ZIP 读写实现（支持 GBK 文件名，无需第三方库） |
| `tools/config.json` | 白/黑名单、各项阈值（改这里就能调整行为） |
| `tools/lib/core.mjs` | 编码识别、目录遍历、文件分类、token 估算 |
| `tools/lib/hdl.mjs` | Verilog/SystemVerilog/VHDL 接口与例化关系提取 |

## 给 DSH 的三层上下文

工作区同时是一套 DSH 原生配置，三层各司其职：

| 层 | 文件 | 加载方式 | 预算 |
|---|---|---|---|
| 硬规则 | `AGENTS.md` | 每次任务自动注入 | 5.2 KB / 64 KB |
| 深度知识 | `.dsh/skills/*/SKILL.md` | 任务匹配时按需加载 | 仅摘要常驻 |
| 资料索引 | `ai/*.md`、`ai/packs/*.md` | 按需读取 | 单个 2–18k token |

- `AGENTS.md` 由 `dsh-agent-instructions` 从项目根到工作目录逐级加载，整条链共享 64 KB。
- `.dsh/skills` 是 `dsh-skill-filesystem` 的**项目级根目录（优先级 100，最高）**，
  格式 `<技能名>/SKILL.md`，frontmatter 必填 `name`（kebab-case）与 `description`。
- 工作区里有一个**空的 `.git` 目录**作为项目根标记，这样在任意子目录启动 dsh
  都能正确解析 `AGENTS.md` 与 skills（DSH 找不到标记时退化为 cwd）。

由于 `ai/02_MODULE_MAP.md` 单独就有 64 KB —— 和整个指令预算一样大 ——
它**绝不能**放进 `AGENTS.md`，只能在需要时读取。这就是分层的原因。

### 从压缩包里挑资料

官方资料常常是「一个 600MB 的 zip，里面 78% 是演示视频」。先干跑看清单再解压：

```powershell
# 先看看会取出什么
node tools/unzip.mjs "D:\path\big.zip" "raw\01_例程" `
  --include="lab_ex4_tf/src/user_source/**,lab_ex4_tf/*.md" `
  --exclude="**/*.mp4,**/*.mif,**/*.enc.v" `
  --max-mb=5 --dry

# 确认无误后去掉 --dry 真正解压
```

`--include` / `--exclude` 用逗号分隔多个 glob；`**` 跨目录，`*` 不跨目录；
`--max-mb` 是单文件体积上限（防止误抓大文件）。

### 把 docx 手册转成 AI 能读的 markdown

```powershell
node tools/docx2md.mjs "raw\00_赛题指南\选题指南.docx"      # 输出同名 .md
node tools/docx2md.mjs "raw\docs\"*.docx                     # 批量
```

支持标题层级、列表、表格、图片占位。转换后 PDF/Office 原件仍保留在 `raw/`，
但 AI 读的是 `.md`。

---

## 调整配置

改 `tools/config.json`：

| 键 | 作用 |
|---|---|
| `inputs` | 扫描哪些目录（默认 `["raw"]`，可加 `"src"` `"constr"` 把自己的设计也纳进来） |
| `dropDirNames` / `dropDirGlobs` | 要剔除的目录名 |
| `dropExtensions` | 要剔除的扩展名 |
| `listOnlyExtensions` | 只登记不读内容的（PDF、Office） |
| `maxFileLines` | 单个源文件最多取多少行（默认 1500） |
| `packMaxTokens` | 每个分卷的 token 上限（默认 45000） |
| `packMaxFiles` | 分卷超过多少文件就继续下钻分组 |
| `guidanceFiles` | 哪些手写文件要被嵌进 `00_START_HERE.md` |

---

## 常见问题

**Q：脚本会不会误删我的文件？**
不会。它只**读取** `raw/`，所有输出写在 `ai/`。剔除只是"不纳入 AI 资料包"，原文件不动。

**Q：为什么剔除列表里有 `.log`，但报告又保留了？**
`.log` 在 `runs/` `.Xil/` 这类目录里的会被整目录剔除（那是噪声）；
工程根目录上手动的报告（`.rpt` `.log`）会保留，且只取头尾——报错和资源占用都在那里。

**Q：中文注释乱码？**
脚本会检测非 UTF-8 文件并告警（老工具链可能输出 GBK）。
这些文件仍会复制，但不提取内容。用 VSCode 转成 UTF-8 后重跑即可。

**Q：例程太多，分卷还是很碎？**
调小 `packMaxFiles` 会分得更细，调大则更粗。
也可以直接只用 `02_MODULE_MAP.md` —— 大多数任务看接口就够了。

**Q：AI 还是读不懂我的板卡？**
那是 `AI_GUIDE.md` 没填够。把引脚表和板卡原理图的关键部分抄进去，效果立竿见影。

**Q：多久重新生成一次？**
资料有变动就重跑。生成很快，且是幂等的。
建议把 `raw/` 纳入 git，`ai/` 加入 `.gitignore`（它是派生产物）。

---

## 环境要求

- Node.js ≥ 18（当前机器上是 v24；`zlib.crc32` 需要 Node ≥ 20.15 才能用自带实现，
  低版本会退回到内置查表实现，功能不受影响）
- 无第三方依赖，不需要联网
