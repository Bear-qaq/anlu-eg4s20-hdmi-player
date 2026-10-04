---
name: fpga-workspace
description: "本 FPGA 竞赛工作区的资料管理与工具链操作：读取顺序、重建 AI 资料包、从压缩包提取资料、docx 转 markdown、生成交接包，以及调整 pack 配置。"
whenToUse: "需要定位资料文件、往 raw/ 加入新的官方资料、重建或调整 ai/ 索引、从 zip 里挑文件、把 docx 手册转成 markdown 时。不涉及具体 HDL 设计决策时用它。"
---

# 本工作区的资料管理

## 目录职责

```
raw/          官方原件（只读）。例程、手册、原理图、赛题
ai/           派生产物（可随时重建，勿手改）
  ├─ 00_START_HERE.md   入口
  ├─ 01..06_*.md        索引层：文件索引 / 模块地图 / 层次 / 约束 / 文档 / 报告
  ├─ packs/*.md         按目录分卷，一次只喂一个
  ├─ files/raw/…        raw/ 的干净镜像（已剔除构建产物与加密 HDL）
  └─ MANIFEST.json      机器可读的全量元数据
tools/        工具链（纯 Node，无依赖）
src/          你自己的设计源码  ← 在这里写代码
constr/       你的约束（README 里有现成的 HX4S20C 引脚模板）
sim/          你的 testbench
```

## 什么时候重跑 `ai/` 索引

**资料有变动就重跑**，很快且幂等：

```powershell
node tools/pack.mjs            # 重建全部索引
node tools/pack.mjs --dry      # 只分析不写盘，先看会剔除什么
```

会触发重建的情况：往 `raw/` 加了新资料、改了 `AI_GUIDE.md`、调整了 `tools/config.json`。
**改了 `src/` 下的代码也建议重跑** —— 这样 `02_MODULE_MAP.md` 里会有你新模块的接口。

> ⚠️ 不要用 `... | Select-Object -First N` 去截断 `pack.mjs` 的输出。
> PowerShell 会在拿到 N 行后关闭管道，node 收到 EPIPE 中途退出。
> 虽然现在「渲染完才动磁盘」的顺序保证不会毁掉旧索引，但这次更新会不完整。
> 要看开头就用 `Select-Object -Last`，或者先 `Out-String` 存进变量。

## 加入新资料

1. 丢进 `raw/` 对应子目录（**不用手动清理构建产物**，脚本会剔除）
2. `node tools/pack.mjs`
3. 如果是 PDF/Office，它只会被登记进 `05_DOCS.md` 而不提取内容 —— 见下节转换

## 从压缩包里挑资料

官方资料常是「一个大 zip，里面大半是演示视频」。**先干跑看清单再解压**：

```powershell
node tools/unzip.mjs "D:\path\big.zip" "raw\01_例程" `
  --include="lab_ex4_tf/src/user_source/**,lab_ex4_tf/*.md" `
  --exclude="**/*.mp4,**/*.mif,**/*.enc.v" `
  --max-mb=5 --dry
```

- `--include` / `--exclude` 逗号分隔多个 glob；`**` 跨目录，`*` 不跨目录
- `--max-mb` 单文件体积上限，防止误抓大文件
- 去掉 `--dry` 才真正写入
- 中文文件名是 GBK 编码的 zip 也能正确处理

## docx → markdown

AI 读不了 docx。官方手册大多是 docx，这一步很关键：

```powershell
node tools/docx2md.mjs "raw\00_赛题指南\选题指南.docx"   # 输出同名 .md
```

支持标题层级、列表、表格、图片占位。转换后原件仍保留，但 AI 读的是 `.md`。

## PDF → markdown

**文字型 PDF 可以直接提取**（扫描件不行）：

```powershell
node tools/pdftext.mjs "raw\06_开发板_硬木课堂\08_板卡和引脚说明.pdf"   # 输出同名 .md
node tools/pdftext.mjs "xxx.pdf" --probe        # 只看结构：页数、每页字体
node tools/pdftext.mjs "xxx.pdf" --pages=1-3    # 只提取前 3 页
```

纯 Node 实现，无第三方依赖。经字体的 ToUnicode 表映射，中文正常。

判定能不能提取：**提取后中文字数为 0 且字符数 > 200 → 是扫描件**，工具会直接告警。
扫描件只能人工看图，别浪费时间。

> 厂家的《板卡和引脚说明》就是这么提出来的 —— 14 页、8 张引脚表全部拿到。
> **遇到 PDF 先试这个，不要默认"AI 读不了 PDF"。**

`tools/pdf_probe.mjs` 是老一点的**探测脚本**：只把流解出来看原始字符串，
不做字体映射。`pdftext.mjs` 提不出中文时（字体没有 ToUnicode 表），
可以用它看流里到底是 ASCII 还是 CID 码位，判断值不值得再折腾。

> ⚠️ **不是所有 PDF 都能提**。实测 `raw/02_原理图/*.pdf` 的网络名是**矢量轮廓**
> （文字被转成了曲线），`raw/04_板卡手册/*.pdf` 的流是**图片** —— 这两类都提不出来。
> 判定方法：`pdftext.mjs` 跑完中文字数为 0 就是提不出来。
**PDF 转不了** —— 要么找官方在线 URL，要么只手抄关键表（引脚/寄存器/时序）进 `docs_md/`。

## 调整剔除规则

改 `tools/config.json`，不用动代码：

| 键 | 作用 |
|---|---|
| `inputs` | 扫描哪些目录（默认 `["raw"]`；想把自己的设计也纳入可加 `"src"`） |
| `dropDirNames` / `dropDirGlobs` | 要剔除的目录名/模式 |
| `dropExtensions` | 要剔除的扩展名 |
| `dropFileGlobs` | 按文件名剔除（如加密 HDL `*.enc.v`） |
| `copyBinaryDocs` | PDF/Office 是否复制进 `ai/files/`（默认 false，只登记） |
| `maxFileLines` / `bigFileBytes` | 单文件内容上限与大文件保护 |
| `packMaxFiles` / `packMaxTokens` | 分卷粒度与预算 |

## 生成交接包（仅在需要给别人时）

```powershell
node tools/bundle.mjs context   # 0.2 MB，37 个 md 索引 —— 贴给网页版 AI
node tools/bundle.mjs agent     # 0.5 MB，含源码镜像与工程骨架 —— 给另一台机器
node tools/bundle.mjs full      # 120 MB，含 raw/ 原件
```

**本机用 DSH 不需要这个** —— agent 直接在这个目录里工作即可。
