# 安路（Anlogic）器件产品线与 EG4S20 迁移可行性分析

> 调研时间：本次会话。所有数据均来自公开网页（安路官网、官方 FAQ 站、Sipeed Wiki、行业站点）。
> 标注约定：**【官方】** = 安路官方页面/官方 FAQ 原文；**【第三方】** = 非安路官方来源；
> **【推断】** = 本报告的推理，非文档明说；**未查到** = 本次调研未找到可靠来源。
>
> **本次调研的工具限制（影响取证完整性）**：
> 1. 本会话的 PowerShell 被执行沙箱的文件权限故障阻断（`SetNamedSecurityInfoW failed (Win32 5): grantWrite(D:\talk\anlu)`），
>    无法用脚本抓取/解析页面；且本会话为受限子代理，无法申请提权修复。
> 2. `web_fetch` **不支持 PDF**（返回 `unsupported content type "application/pdf"`），
>    因此**所有安路数据手册 PDF 均未能直接读取**，数据手册级参数（LVDS 差分对数量、LVDS33 支持 bank 等）只能依赖官网选型表与 FAQ。
> 3. 安路官网的"工具与资料下载""IP 和参考设计"两个页面的清单是 JS 动态加载，抓取到的只有空壳；
>    且技术文档需注册登录（页面明确提示"对不起，您尚未登录！"），仅 EF2/EF3/EG4 的 FamilyOverview 可免登录下载。

---

## 0. 权威依据修正（**本地 TD 6.2.1 数据，优先级高于本报告中的网页推断**）

后续由项目方从本地 TD 6.2.1 的 `arch/device_resource/device_resource.csv` 给出权威数据，
**以下三条覆盖本报告中任何与之冲突的段落**：

1. **TD 6.2.1 支持的 EG4 家族成员为**：`EG4A15 / EG4X15`（**14720 LUT**）、
   `EG4A20 / EG4X20 / EG4S20 / EG4D20`（**19600 LUT**）。
   → 解释了官网开发板名里的 `EG4A20BG256`：**EG4A20 是真实存在的器件**（A 档），
   与 `EG4X20` 同为 19600 LUT，只是官网**网页选型表漏列了 A 档型号**。
2. **片内 DRAM 的唯一性**：EG4 家族中 **只有 `EG4S20` 带 64Mb SDR SDRAM（= 2M×32）**，
   **只有 `EG4D20` 带 128Mb DDR1（= 8M×16）**，**其余型号（EG4A15/EG4X15/EG4A20/EG4X20）无片内 DRAM**。
   → 第 2.3 节的官方 FAQ 名单（EF2S45、AL3S10、EG4S20、EG4D20）与此完全吻合。
   → **EG4S20BG256 带片内 2M×32 SDRAM 得到确证**，官网选型表把 LFBGA256 行写成
   `EG4S20BG256B` 且标"无"的那一处，判为**官网表格错误或另一个独立 SKU**（见第 4 节不确定项）。
3. **`AL3` 不在 TD 6.2.1 的支持器件列表内** → 第 3.4 节把 AL3S10 从"高风险"**上调为「不可行」**，
   且否决理由不止一条（见下）。**AL3S10 作为"更小且有片内 SDRAM"的候选，彻底出局。**

**由此得到本次调研的最终结论**：在 **TD 6.2.1 可用 + LUT ≤ 19600** 的交集里，安路器件只有 EG4 家族的 6 个型号；
其中**带片内 DRAM 的只有 EG4S20（SDR 2M×32）和 EG4D20（DDR1 8M×16）**。
所以：**"逻辑资源更小"与"保留片内 SDRAM 帧缓存"在安路 TD 6.2.1 生态里无法同时满足** ——
唯一严格更小的 `EG4X15/EG4A15`（14720 LUT）没有片内 DRAM。

---

## 1. 器件资源对照表

数据来源（均为官网产品选型表，**官方**）：

- EG4 / AL3：<https://www.anlogic.com/product/fpga/saleagle/eg4> 、<https://www.anlogic.com/product/fpga/saleagle/salal3>
- EF2：<https://www.anlogic.com/product/fpga/salelf/salelf2>
- EF3：<https://www.anlogic.com/product/fpga/salelf/salelf3>
- SF1：<https://www.anlogic.com/product/fpga/salswift/salswift1>
- PH1A：<https://www.anlogic.com/product/fpga/phoenix/ph1a>
- DR1：<https://www.anlogic.com/product/fpga/saldragon>

### 1.1 SALEAGLE 4（EG4，猎鹰）— 官方选型表共 6 行（5 个不同型号名，EG4S20CG324 重复列了两次）

| 型号 | 系列 | LUT | FF(DFF) | ERAM9K | ERAM32K | ERAM总量 | DSP(M18×18) | PLL | 片内SDRAM | 封装 | 用户IO | ADC | TD支持 | 依据URL |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| EG4X15BG256 | EG4 | 14720 | 14720 | 52 | 8 | 724k | 24 | 4 | 无 | LFBGA256 17×17 | 193 | 1 | 未查到明确列表 | [EG4选型表](https://www.anlogic.com/product/fpga/saleagle/eg4) |
| EG4S20CG324 | EG4 | 19600 | 19600 | 64 | 16 | 1088k | 29 | 4 | **2M×32** | LFBGA324 15×15 | 215 | 1 | 未查到明确列表 | [EG4选型表](https://www.anlogic.com/product/fpga/saleagle/eg4) |
| EG4S20BG256B | EG4 | 19600 | 19600 | 64 | 16 | 1088k | 29 | 4 | **无（表内标 "\"）** | LFBGA256 17×17 | 193 | 1 | 未查到明确列表 | [EG4选型表](https://www.anlogic.com/product/fpga/saleagle/eg4) |
| EG4D20EG176/B | EG4 | 19600 | 19600 | 64 | 16 | 1088k | 29 | 4 | **8M×16（DDR）** | ETQFP176 20×20 | 135 | 1 | 未查到明确列表 | [EG4选型表](https://www.anlogic.com/product/fpga/saleagle/eg4) |
| EG4X20LG144 | EG4 | 19600 | 19600 | 64 | 16 | 1088k | 29 | 4 | 无 | LQFP144 20×20 | 107 | 1 | 未查到明确列表 | [EG4选型表](https://www.anlogic.com/product/fpga/saleagle/eg4) |
| **EG4S20BG256**（本项目器件） | EG4 | 19600 | 19600 | 64 | 16 | 1088k | 29 | 4 | **2M×32** | LFBGA256 17×17 | 193 | 1 | 实测 TD 6.2.1 可用 | [官方FAQ](https://tech.anlogic.com/Cn/Index/index/cate/33/p/1.html?cate=15&tp=1) + [Sipeed Tang Primer](https://wiki.sipeed.com/hardware/zh/tang/Tang-primer/Tang-primer.html) |

**关于 EG4S20BG256 的重要问题（必须向 FAE 确认）**：官网 EG4 选型表在 LFBGA256 封装下写的是
**EG4S20BG256B**，且"片内 SDRAM"栏是 `\`（空/无）；`2M×32` 只标在 EG4S20CG324 上。
但两处证据支持 **EG4S20BG256（不带 B）确实有 2M×32 片内 SDRAM**：
- 【官方】安路 FAQ 原文：「EF2S45，AL3S10，EG4S20，EG4D20 都带有 64M-128M 的大容量存储器」（EG4S20 = 2M×32 = 64Mbit，与"64M"吻合）；
- 【第三方】Sipeed Tang Primer（正是 EG4S20BG256 的板子）参数表写 `EM SDR SDRAM = 2M X 32bits`。

→ **推断**：`EG4S20BG256`（无 B）带片内 SDRAM，`EG4S20BG256B`（带 B）是**不带片内 SDRAM 的引脚兼容版本**。
本报告把这一条列入"不确定项"，因为它直接决定替代器件选择。

### 1.2 SALEAGLE 3（AL3）

| 型号 | 系列 | LUT | FF(DFF) | ERAM9K | ERAM32K | ERAM总量 | DSP(M18×18) | PLL | 片内SDRAM | 封装 | 用户IO | TD支持 | 依据URL |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| AL3S10LG144 | AL3 | **8640** | 8640 | 48 | 2 | 496K | **3** | **2** | **2M×32** | LQFP144 16×16 | 111 | 未查到明确列表 | [AL3选型表](https://www.anlogic.com/product/fpga/saleagle/salal3) |

**AL3S10LG144 是本轮调研最关键的发现**：官方选型表唯一一个「逻辑资源严格小于 EG4S20 且带 2M×32 片内 SDRAM」的器件。
官方 FAQ 的"自带大容量内部存储器"名单里也有它。但它的 DSP 只有 3 个、PLL 只有 2 个（见第 3 节，两项都刚好卡死）。

### 1.3 SALELF 2（EF2，小精灵二代）— 官方选型表 12 行

| 型号 | LUT | FF | ERAM9K | ERAM32K | ERAM-128k | ERAM-256k | ERAM总量 | DSP | PLL | ADC | 用户IO | 封装 | 片内SDRAM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| EF2L15BG256B | 1520 | 1520 | 6 | 3 | 1 | 1 | 534k | 8 | **1** | 2 | 206 | FBGA256 17×17 | 无 |
| EF2L15LG144B | 1520 | 1520 | 6 | 3 | 1 | 1 | 534k | 8 | **1** | 2 | 113 | LQFP144 | 无 |
| EF2L15LG100B | 1520 | 1520 | 6 | 3 | 1 | 1 | 534k | 8 | **1** | 2 | 80 | LQFP100 14×14 | 无 |
| EF2L25AG42P | 2520 | 2520 | 9 | 4 | 1 | 1 | 593k | 12 | **1** | — | 29 | XWFN42 4.2×4.2 | 无 |
| EF2L25BG256B | 2520 | 2520 | 9 | 4 | 1 | 1 | 593k | 12 | **1** | 2 | 206 | FBGA256 17×17 | 无 |
| EF2L45BG256B/H | 4480 | 4480 | 12 | 6 | 1 | 1 | 684k | 15 | **1** | 2 | 206 | FBGA256 17×17 | 无 |
| EF2L45LG144B | 4480 | 4480 | 12 | 6 | 1 | 1 | 684k | 15 | **1** | 2 | 113 | LQFP144 | 无 |
| EF2L45UG132B | 4480 | 4480 | 12 | 6 | 1 | 1 | 684k | 15 | **1** | 2 | 104 | CSFBGA132 8×8 | 无 |
| EF2M45LG48B | 4480 | 4480 | 12 | 6 | 1 | 1 | 684k | 15 | **1** | 2 | 35 | LQFP48 9×9 | 无 |
| EF2M45LG144B | 4480 | 4480 | 12 | 6 | 1 | 1 | 684k | 15 | **1** | 2 | 113 | LQFP144 | 无 |
| EF2M45VG81C | 4480 | 4480 | 12 | 6 | 1 | 1 | 684k | 15 | **1** | 1 | 56 | VFBGA81 4.2×4.2 | 无 |
| EF2S45VG81C | 4480 | 4480 | 12 | 6 | 1 | 1 | 684k | 15 | **1** | — | 56 | BGA81 4.2×4.2 | **有**（官方FAQ列为大容量存储器器件） |

依据URL：[EF2选型表](https://www.anlogic.com/product/fpga/salelf/salelf2) 、[官方FAQ](https://tech.anlogic.com/Cn/Index/index/cate/33/p/1.html?cate=15&tp=1)
备注：EF2 选型表**没有**"片内 SDRAM"列；`EF2S45` 带大容量存储器来自官方 FAQ 文字（"S" 后缀疑似 SIP 含 SDRAM 版本）。EF2 全系 **PLL 只有 1 个**。

### 1.4 SALELF 3（EF3）— 官方选型表 9 行

| 型号 | LUT | FF | ERAM9K | ERAM总量 | DSP(M18×18) | PLL | 用户IO | 用户Flash | 封装 | 片内SDRAM |
|---|---|---|---|---|---|---|---|---|---|---|
| EF3L40CG324B | 4800 | 4800 | 15 | 135K | 8 | 2 | 279 | 8Mb | LFBGA324 15×15 | 无 |
| EF3L40CG332B | 4800 | 4800 | 15 | 135K | 8 | 2 | 279 | 8Mb | LFBGA324 17×17 | 无 |
| EF3L50CG256B | 5304 | 5304 | 31 | 324K | — | 2 | 206 | 8Mb | LFBGA256 14×14 | 无 |
| EF3L70CG256B | 7952 | 7952 | 36 | 324K | — | 2 | 206 | 8Mb | LFBGA256 14×14 | 无 |
| EF3L90CG324B | 9280 | 9280 | 30 | 270K | 16 | 2 | 279 | 8Mb | BGA324 15×15 | 无 |
| EF3L90CG400B | 9280 | 9280 | 30 | 270K | 16 | 2 | 335 | 8Mb | LFBGA400 17×17 | 无 |
| EF3LA0CG484B | **11776** | 11776 | 68 | 612K | **—** | 2 | 383 | 8Mb | LFBGA484 19×19 | 无 |
| EF3LA0CG642B | **11776** | 11776 | 68 | 612K | **—** | 2 | 475 | 8Mb | LFBGA642 23×23 | 无 |

依据URL：[EF3选型表](https://www.anlogic.com/product/fpga/salelf/salelf3)
注意：EF3LA0 逻辑最大但**没有 DSP 硬核**（表内为 `\`）。EF3 全系 **2 个 PLL**，且**均无片内 SDRAM**。

### 1.5 SALSWIFT 1（SF1，雨燕）— FPSoC

| 型号 | LUT | FF | ERAM9K | ERAM总量 | DSP | PLL | RISC-V | MIPI DSI | DSC | **PSRAM** | 用户IO | 封装 | 片内SDRAM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| SF1S60CG121I | 5824 | 5824 | 26 | 234K | 10 | 2 | 1 | 2 | 1 | 内置 64/128Mb | 59 | TFBGA121 9×9 | 无（有PSRAM） |
| SF1N60VG81C | 5824 | 5824 | 26 | 234K | 10 | 2 | 1 | 2 | 1 | 内置 64/128Mb | 31 | VFBGA81 4.5×4.5 | 无（有PSRAM） |
| SF1S60VG81C/E | 5824 | 5824 | 26 | 234K | 10 | 2 | 1 | 2 | 1 | 内置 64/128Mb | 31 | VFBGA81 4.5×4.5 | 无（有PSRAM） |

依据URL：[SF1选型表](https://www.anlogic.com/product/fpga/salswift/salswift1)
官方特色原文：「内置 64Mb/128Mb PSRAM，时钟速率最大支持 200MHz」「2 路 MIPI D-PHY，线速率最大 2.2Gbps」。
**没有 HDMI/TMDS 专用硬核**，定位是 MIPI/DSI 显示。

### 1.6 SALPHOENIX 1A（PH1A，凤凰）

| 型号 | LUT | FF | eRAM-20K | ERAM总量 | DSP | PLL | SerDes | SerDes速率 | DDR速率/位宽 | MIPI-IO | 用户IO | 封装 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| PH1A60GEG324/C | **70848** | 78720 | 158 | 3160K | 120 | 12 | — | — | — | — | 211 | LFBGA324 15×15 |
| PH1A90SEG324 | 115776 | 128640 | 272 | 5440K | 240 | 12 | 8 | 10.3125Gbps | 1066Mbps ×16 | — | 148 | LFBGA324 |
| PH1A90SEG325 | 115776 | 128640 | 272 | 5440K | 240 | 12 | 4 | 10.3125Gbps | 1066Mbps ×40 | 20 | 180 | LFBGA325 |
| PH1A90SBG484 | 115776 | 128640 | 272 | 5440K | 240 | 12 | 4 | 12.5Gbps | 1066Mbps ×40 | 20 | 280 | LFBGA484 |
| PH1A180SFG676 | 210240 | 233600 | 646 | 12920K | 600 | 16 | 8 | 12.5Gbps | 1866Mbps ×72 | 20 | 396 | FCBGA676 |
| PH1A400SFG676 | 417024 | 463360 | 914 | 18280K | 840 | 20 | 8 | 12.5Gbps | 1866Mbps ×72 | — | 400 | FCBGA676 |
| PH1A400SFG900 | 417024 | 463360 | 914 | 18280K | 840 | 20 | 16 | 12.5Gbps | 1866Mbps ×72 | — | 500 | FCBGA900 |

依据URL：[PH1A选型表](https://www.anlogic.com/product/fpga/phoenix/ph1a)
**PH1A 全系 LUT ≥ 70848（3.6× EG4S20）**，不满足"逻辑资源不超过 EG4S20"的筛选条件。

### 1.7 SALDRAGON 1（DR1，飞龙）— FPSoC，无选型表

【官方】<https://www.anlogic.com/product/fpga/saldragon> 描述：软硬件可编程 FPSoC 平台；双核 ARM Cortex-A35 64 位 + 单核 RISC-V 64 位；
集成硬核 NPU 及部署工具链；支持 DDR3/DDR4；**「沿用 SALPHOENIX 系列可编程逻辑」**；集成 MIPI D-PHY。
**未查到**具体型号清单与 LUT 数字。因"沿用 PH1A 逻辑"，其逻辑规模必然 ≫ 19600 LUT。

### 1.8 EF3L15 / EF4 / EF5 / PH1P — 未查到选型表

- sitemap 与官网导航含 `EF3L15` 独立产品页（<https://www.anlogic.com/product/fpga/salelf/elf3l15>），本次未抓取，**规格未查到**。
- "工具与资料下载"页面的技术文档分类里出现了 **EF4、EF5、PH1P** 三个系列（各有数据手册/器件概览等分类），
  但"产品中心"导航下**没有**它们的产品页，**选型表未查到**（可能为未公开发布或仅对客户开放）。

### 1.9 EG4S20 的官方数据手册级特性（**官方**，来源：电子发烧友论坛转述的 EG4S20 数据手册）

来源：<https://bbs.elecfans.com/archiver/?tid-1801320.html>

- 19600 个 LUTs；用户 IO 数量从 71 到 193
- 分布式存储器最大 156 Kbits；嵌入块存储器最大 1 Mbits
- ERAM9K：9 Kbits，真双口，8K×1 ~ 512×18，**带专用 FIFO 控制逻辑**
- ERAM32K：32 Kbits，真双口，2K×16 或 4K×8
- PLB：优化的 LUT4/LUT5 组合设计、双端口分布式存储器、快速进位链
- **16 路全局时钟**、2 路 IOCLK（专为高速 I/O 设计）
- **最多 4 个 PLL**，分频系数 1~128，支持 5 路时钟输出级联、动态相位选择
- 差分标准：LVDS、Bus-LVDS、MLVDS、RSDS、LVPECL；片内 100Ω 差分电阻；支持热插拔
- 单端标准：LVTTL、LVCMOS(3.3/2.5/1.8/1.5/1.2V)、PCI、SSTL3.3/1.8/1.5、HSTL1.8/1.5
- ADC：12-bit SAR，8 个模拟输入，1 MSPS，集成电压监控与环形振荡器
- 配置模式：MSPI / SS / MP / SPI×8 / JTAG；每芯片唯一 64 位 DNA

→ **这条同时解决了 PLL 数量的疑点**：EG4S20 是 4 个 PLL / 16 路全局时钟，与本工程描述一致。
（注：Sipeed Tang Primer 页把 EG4S20BG256 的 PLL 写成 **1**，与官方数据手册冲突，**以官方数据手册为准**；
但"1 个 PLL"这个说法在第三方文档里出现过两次，建议实测 TD 里 PLL 可用数量确认。）

### 1.10 官方 FAQ 中的器件级结论（**官方**）

来源：<https://tech.anlogic.com/Cn/Index/index/cate/33/p/1.html?cate=15&tp=1>

| 问题 | 官方回答 |
|---|---|
| **哪些器件自带大容量内部存储器？** | **「EF2S45，AL3S10，EG4S20，EG4D20 都带有 64M-128M 的大容量存储器」** |
| True LVDS 与 Emulated LVDS 是否均可作 LVDS25 输入，最大输入频率？ | 是；**最大输入频率 400MHz（800Mbps）** |
| 差分对输出电压/摆幅可设？ | 可，通过 ADC 约束设置 VCM 与 VOD |
| 配置管脚可作用户 IO？ | 可以，但不建议作输入（PROGRAMN/INITN/DONE 复用可能导致重加载） |
| 支持哪些 HDL？ | Verilog、VHDL、SystemVerilog，支持混合编译 |
| 哪些器件支持 MIPI？ | EF2 自带 mipi_io；其他器件可用真差分管脚支持 HS 模式 + 普通 IO 支持 LP |

官网 EG4 产品页另称【官方】："部分器件内置 64M bit SDR SDRAM 或者 128M bit DDR SDRAM"、"最大支持 800 Mbps 高速 LVDS 接口"、
"55nm 低功耗工艺，静态功耗低至 5mA"、"等效 23.4K LUTs 逻辑资源"、"强大的**引脚兼容替换性能**"。

---

## 2. 「≤ EG4S20（19600 LUT）的安路器件」清单

### 2.1 完整清单（LUT 升序）

| # | 型号 | 系列 | LUT | FF | ERAM9K | DSP | PLL | 片内SDRAM | 封装 | 有开发板？ |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | EF2L15BG256B / LG144B / LG100B | EF2 | 1520 | 1520 | 6 | 8 | 1 | 无 | FBGA256/LQFP144/LQFP100 | 无（但 EF2L45 板可参考） |
| 2 | EF2L25AG42P / BG256B | EF2 | 2520 | 2520 | 9 | 12 | 1 | 无 | XWFN42/FBGA256 | 无 |
| 3 | EF2L45BG256B/H、EF2L45LG144B、EF2L45UG132B | EF2 | 4480 | 4480 | 12 | 15 | 1 | 无 | FBGA256/LQFP144/CSFBGA132 | **有**（EF2L45BG256B开发板） |
| 4 | EF2M45LG48B / VG81C / LG144B | EF2 | 4480 | 4480 | 12 | 15 | 1 | 无 | LQFP48/VFBGA81/LQFP144 | **有**（EF2M45LG48B开发板） |
| 5 | **EF2S45VG81C** | EF2 | 4480 | 4480 | 12 | 15 | 1 | **有**（官方FAQ） | BGA81 | 未查到 |
| 6 | EF3L40CG324B / CG332B | EF3 | 4800 | 4800 | 15 | 8 | 2 | 无 | LFBGA324 | 无 |
| 7 | EF3L50CG256B | EF3 | 5304 | 5304 | 31 | — | 2 | 无 | LFBGA256 | 无 |
| 8 | SF1S60CG121I / SF1N60VG81C / SF1S60VG81C/E | SF1 | 5824 | 5824 | 26 | 10 | 2 | 无（**内置64/128Mb PSRAM**） | TFBGA121/VFBGA81 | **有**（SF102_V2.0 等） |
| 9 | EF3L70CG256B | EF3 | 7952 | 7952 | 36 | — | 2 | 无 | LFBGA256 | 无 |
| 10 | **AL3S10LG144** | AL3 | **8640** | 8640 | 48 | **3** | **2** | **2M×32** | LQFP144 | **未查到（官网无 AL3 板）** |
| 11 | EF3L90CG324B / CG400B | EF3 | 9280 | 9280 | 30 | 16 | 2 | 无 | BGA324/LFBGA400 | **有**（EF3L90CG400B开发板） |
| 12 | EF3LA0CG484B / CG642B | EF3 | 11776 | 11776 | 68 | **—** | 2 | 无 | LFBGA484/LFBGA642 | **有**（EF3LA0CG484B开发板） |
| 13 | **EG4X15BG256** | EG4 | **14720** | 14720 | 52(+8×32K) | 24 | 4 | 无 | LFBGA256 17×17 | 未查到 |
| 14 | EG4S20CG324 / **EG4S20BG256** / EG4D20EG176 / EG4X20LG144 | EG4 | 19600 | 19600 | 64(+16×32K) | 29 | 4 | 2M×32 / 2M×32 / 8M×16 DDR / 无 | LFBGA324/LFBGA256/ETQFP176/LQFP144 | **有**（EG4S20BG256板、EG4A20BG256板） |

### 2.2 用户问到的三个型号是否存在

| 型号 | 结论 | 依据 |
|---|---|---|
| **EG4S40** | **未查到，官网 EG4 选型表无此型号** | [EG4选型表](https://www.anlogic.com/product/fpga/saleagle/eg4) 只有 5 个不同型号名 |
| **EG4X20** | **真实存在**：EG4X20LG144，19600 LUT / 64 ERAM9K / 16 ERAM32K / 29 DSP / 4 PLL / **无片内 SDRAM** / LQFP144 / 107 IO | 同上 |
| **EG4S10** | **未查到，官网 EG4 选型表无此型号** | 同上 |
| EG4X15 | 真实存在：EG4X15BG256，14720 LUT，**无片内 SDRAM** | 同上 |
| EG4D20 | 真实存在：EG4D20EG176/B，19600 LUT，**8M×16 DDR SDRAM** | 同上 |
| EG4A20 | 只在**开发板**名里出现（EG4A20BG256开发板），**EG4 选型表里没有 EG4A20** | [开发板页](https://www.anlogic.com/product/xaizaiqi/aaa) |

### 2.3 带片内大容量存储器的安路器件（官方 FAQ 权威答案）

> **EF2S45、AL3S10、EG4S20、EG4D20** — 官方 FAQ，<https://tech.anlogic.com/Cn/Index/index/cate/33/p/1.html?cate=15&tp=1>

| 器件 | 片内存储 | 容量 | LUT | 是否 ≤19600 |
|---|---|---|---|---|
| EG4S20（BG256 / CG324） | SDR SDRAM **2M×32** | 64 Mbit = 8 MiB | 19600 | 等于（基线） |
| EG4D20EG176/B | DDR SDRAM **8M×16** | 128 Mbit = 16 MiB | 19600 | 等于（基线） |
| **AL3S10LG144** | SDR SDRAM **2M×32** | 64 Mbit = 8 MiB | **8640** | **是（唯一严格小于）** |
| EF2S45VG81C | 大容量存储器（官方 FAQ 未给容量/类型） | 未查到 | 4480 | 是 |

→ **除 EG4S20 之外，带 2M×32 片内 SDRAM 的安路器件只有 AL3S10LG144**（EG4D20 是 8M×16 DDR，不是 2M×32 SDR）。
**EG4S40 / EG4S10 不存在（未查到）**。

### 2.4 开发板可得性

**官方开发板**（<https://www.anlogic.com/product/xaizaiqi/aaa>、<https://www.anlogic.com/product/xaizaiqi/abc>、
<https://www.anlogic.com/support/tools-downloads>）：

| 板名 | 主芯片 | LUT | 官方列出的板载资源 | 依据URL |
|---|---|---|---|---|
| **EG4S20BG256开发板** | EG4S20BG256 | 19600 | 内嵌ADC、TYPE_C供电、JTAG、16M-bit NOR FLASH、4位拨码、用户扩展接口。**未列 HDMI、未列 SD 卡、未列外部 SDRAM** | [开发板页](https://www.anlogic.com/product/xaizaiqi/aaa) |
| EG4A20BG256开发板 | EG4A20BG256 | 未查到 | 同上（该页标题与面包屑不一致，H1 写的是"EG4S20BG256开发板"） | [开发板页](https://www.anlogic.com/product/xaizaiqi/aaa/eg4a20-kfb) |
| EF2L45BG256B开发板 | EF2L45BG256B | 4480 | TYPE_C、4路ADC、内核SWD、4位拨码、**Micro SD**、扩展口 | [ELF开发板](https://www.anlogic.com/product/xaizaiqi/abc) |
| EF2M45LG48B开发板 | EF2M45LG48B | 4480 | TYPE_C、SWD、JTAG、Micro SD、按键指示灯 | 同上 |
| **EF3L90CG400B开发板** | EF3L90CG400B | 9280 | TYPE_C、JTAG、1路串口、4位拨码、**Micro SD**、扩展口 | 同上 |
| **EF3LA0CG484B开发板** | EF3LA0CG484B | 11776 | 内置8Mb flash、Type-C、**LVDS和单端IO接口**、1路串口、按键指示灯 | 同上 |
| SF102_V2.0 / AP102_V2.0 / AP104_V2.0 / AP106_V1.0 | SF1 / PH1A 系列（**主芯片未逐个确认**） | — | — | [工具与资料下载](https://www.anlogic.com/support/tools-downloads) |
| SALPHOENIX1A系列开发板 / SALDRAGON系列开发板 | PH1A / DR1 | ≥70848 | — | [PH1A板](https://www.anlogic.com/product/xaizaiqi/abcde)、[DR1板](https://www.anlogic.com/product/xaizaiqi/sald) |

**关键观察**：**官方任何一块开发板的特性列表里都没有"板载 SDRAM/DDR"**（EG4S20 板靠的是**片内** SDRAM）。
因此若换到无片内 SDRAM 的器件，外部帧缓存颗粒必须走扩展口自己加，官方板不提供。

**AL3 系列开发板：官网"开发板及下载器"下没有 AL3 分类**（SALEAGLE系列开发板页只有 EG4S20BG256 和 EG4A20BG256 两块）→
**AL3S10 无官方开发板（未查到第三方板）**。

**第三方在售开发板**：

| 板名 | 主芯片 | LUT | 板载资源 | 状态 | 依据URL |
|---|---|---|---|---|---|
| Sipeed **Tang Primer** | **EG4S20BG256** | 19600 | Micro-USB/USB-JTAG、**TF 卡槽**、DVP 摄像头接口、FPC40P（RGB LCD/VGA）、FPC20P、NS2009 触摸控制器；`EM SDR SDRAM = 2M X 32bits` | **已售罄** | [Sipeed Wiki](https://wiki.sipeed.com/hardware/zh/tang/Tang-primer/Tang-primer.html) |
| Sipeed **Tang Nano 4K** | **高云 GW1NSR-LV4C（不是安路！）** | 4608 | HDMI 座、DVP、Type-C | 在售 | [Sipeed Wiki](https://wiki.sipeed.com/hardware/zh/tang/Tang-Nano-4K/Nano-4K.html) |
| Tang Nano 9K / Tang Primer 20K / Mega 系列 | **高云 Gowin**（搜索结果指向 gowinsemi.com） | — | — | 在售 | [Gowin Tang Nano 9K](https://www.gowinsemi.com/en/support/devkits_detail/43/)、[Gowin Tang Nano 4K](https://gowinsemi.com/ja/support/devkits_detail/39) |
| EG4S20-MINI-DEV | EG4S20BG256 | 19600 | 曾用于 2019 年电子发烧友试用活动；有 TF 卡座 | 是否仍在售**未查到** | [elecfans 归档](https://bbs.elecfans.com/archiver/?tid-1801320.html)、[配套指南](https://blog.csdn.net/weixin_34161032/article/details/91706421) |

**⚠️ 重要纠错**：很多资料把 **Tang Nano 4K 当成"安路 EG4S20 的板子"，这是错的** ——
Sipeed 官方 Wiki 明确写 Tang Nano 4K 用的是**高云 GW1NSR-LV4C**。
Sipeed 的 Tang 系列在 Tang Primer 之后基本转向高云；**唯一使用安路 EG4S20 的 Sipeed 板是初代 Tang Primer，且已售罄**。

**未查到**：`EG4X15BG256` 的任何在售开发板；`AL3S10LG144` 的任何在售开发板；`HX4S20C` 板的公开销售渠道
（本工作区记录该板为竞赛用板，型号为 HX4S20C + EG4S20BG256）。

---

## 3. 迁移风险分析

### 3.0 资源门槛的量化：现有设计到底需要多少资源

用户给出的占用：`Slices ≈ 4731/9800`、`RAM9K 23/64`、`DSP 9/29`、`PLL 2/4`。

EG4S20 的 9800 = 19600 LUT ÷ 2（安路 PLB/slice 内含一对 LUT，官方数据手册称"优化的 LUT4/LUT5 组合设计"）。
因此 **LUT 用量 ≈ 4731 × 2 = 9462 LUT（约占 48%）**。以此作为筛选门槛：

| 器件 | LUT | 需求≈9462 <br>LUT 够？ | ERAM9K | 需求 23 <br>够？ | DSP | 需求 9 <br>够？ | PLL | 需求 2 <br>够？ | 片内 SDRAM | 综合判定 |
|---|---|---|---|---|---|---|---|---|---|---|
| **EG4S20**（基线） | 19600 | ✅ 48% | 64(+16×32K) | ✅ | 29 | ✅ | 4 | ✅ | 2M×32 | **基线（零风险）** |
| EG4D20EG176/B | 19600 | ✅ 48% | 64(+16×32K) | ✅ | 29 | ✅ | 4 | ✅ | **8M×16 DDR** | 同族，但片内存储类型变了，控制器要换 → **中风险** |
| EG4X20LG144 | 19600 | ✅ 48% | 64(+16×32K) | ✅ | 29 | ✅ | 4 | ✅ | 无 | 资源够，无 SDRAM → **中高风险** |
| **EG4X15BG256** | **14720** | ✅ 64%（偏紧） | 52(+8×32K) | ✅ | 24 | ✅ | 4 | ✅ | 无 | **同封装同 IO 数，唯一资源可行的"更小"器件 → 中风险** |
| EF3LA0CG484B/CG642B | 11776 | ⚠️ 80%（很紧） | 68 | ✅ | **0** | ❌ | 2 | ✅（零余量） | 无 | **因无 DSP 且 LUT 占用 80%，高风险** |
| EF3L90CG324B/CG400B | 9280 | ❌ 102% | 30 | ✅ | 16 | ✅ | 2 | ✅ | 无 | **LUT 不够 → 不可行** |
| EF3L70CG256B | 7952 | ❌ | 36 | ✅ | 0 | ❌ | 2 | ✅ | 无 | **不可行** |
| EF3L50CG256B | 5304 | ❌ | 31 | ✅ | 0 | ❌ | 2 | ✅ | 无 | **不可行** |
| EF3L40CG324B | 4800 | ❌ | 15 | ❌ | 8 | ❌ | 2 | ✅ | 无 | **不可行** |
| **AL3S10LG144** | **8640** | ❌ **91%…且 9462 > 8640 直接超** | 48 | ✅ | **3** | ❌ **9>3** | **2** | ✅（零余量） | **2M×32** | **LUT 与 DSP 双重不够 → 不可行** |
| SF1S60（全系） | 5824 | ❌ | 26 | ✅ | 10 | ✅ | 2 | ✅ | 无（PSRAM 64/128Mb） | **LUT 不够 + IO 仅 31/59 → 不可行** |
| EF2S45 / EF2L45 等 | ≤4480 | ❌ | ≤12 | ❌ | 15 | ✅ | **1** | ❌ **1<2** | 仅 EF2S45 有 | **PLL 只有 1 个 → 不可行** |
| PH1A（全系） | ≥70848 | ✅（但**超出需求**） | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 无 | 技术可行但**不符合"不超过 EG4S20"的筛选条件** |

> ⚠️ 上表的 LUT 门槛基于用户给的 `Slices 4731/9800` 推算，用户自己也标了问号。
> **这必须用 TD 的 Place&Route 报告实测确认**（`ai/06_REPORTS.md` 有实测流程）。
> 门槛值每变动 10%，上表结论就会移动一到两档。

### 3.1 黑盒 IP 的器件/器件族绑定问题

**能查到的**：

- ❌ **未查到任何官方文档说明 `hdmi_1_4b_transmitter_core_wrapper.enc.v` / `sdr_as_ram.enc.v` / `sdr_init_ref.enc.v` / `sdr_wrrd.enc.v` 的器件适用范围。** 安路官网的"IP 和参考设计"页面需要登录且是 JS 动态加载，抓取不到清单。
- 【官方】HDMI 方案文章（<https://www.anlogic.com/news/company-news/45.html>）原文：
  「该方案已经在 **EG4 等多款安路芯片**上成功实现，**也可以支持安路的其他多款器件**。」
  同文还说「安路 FPGA 芯片的 LVDS，真差分可以支持 1Gbps 以上的速度」、
  「EG4SCG324 器件……器件内具有多对 LVDS；集成了 64Mb SDRAM……分辨率可达 1080P 以上」、
  「HDMI 发送……分辨率基本可以实现 1080P 60Hz RGB 数据」。
- 【第三方】安路有 DNA（64 位唯一 ID）+ AES 位流加密机制（EF2 官方特色："每个芯片拥有唯一的 64 位 DNA，位流支持 AES 加密"）。

**推断（非官方明说）**：

1. **`.enc` 是加密的网表/HDL，不是源码**。它在 TD 综合/实现流程中被解密，内部**极可能直接例化器件专用原语**
   （EG4 的 ERAM9K/ERAM32K、DSP48、PLL、IDDR/ODDR、IOCLK 等）。不同器件族的原语名、端口、时序、可用数量都不同。
2. `EG_PHY_SDRAM_2M_32` 这个原语名带 **`EG`** 前缀，几乎肯定是 **EG4 系列专用器件库原语**。
   因此三个 `sdr_*.enc` 控制器**大概率被锁死在 EG4 系列**，且很可能进一步锁死在**带 2M×32 SDRAM 的具体型号**上
   （EG4S20BG256 / EG4S20CG324），因为原语需要绑定片内 SDRAM 的物理位置。
3. **同族不同型号（EG4X15 / EG4X20 / EG4D20）复用 `.enc` 的可能性**：
   - `hdmi_1_4b_transmitter_core_wrapper.enc.v`：同属 EG4，原语集合相同 → **复用可能性较高**（仍需实测）。
   - 三个 `sdr_*.enc`：EG4X15/EG4X20 **没有片内 SDRAM**，`EG_PHY_SDRAM_2M_32` 原语在综合时就会因器件不具备该硬核而报错 → **不可复用**。
     EG4D20 的片内是 **8M×16 DDR**，与 `2M_32` 不是同一个硬核 → **不可复用**。
4. **跨族（AL3 / EF2 / EF3 / SF1 / PH1A）复用 `.enc`：几乎肯定不可行**，必须向安路 FAE 索取对应器件族的加密 IP
   （这也意味着**竞赛/项目交付路径上多一个外部依赖**，且加密 IP 的发放通常需要 FAE 评估，不是下载即得）。
5. 官方那句"可以在其他多款器件上实现"说的是**安路的方案（源码级参考设计）被移植过**，
   **不等于**本项目手上的**加密黑盒文件**可跨器件复用。这两者必须严格区分。

### 3.2 片内 SDRAM 依赖——这是整个替代方案的死结

现有架构：**8 帧 640×480×24bit 帧缓存 = 640×480×3×8 = 7,372,800 B ≈ 7.4 MB**，全部放在片内 2M×32 SDRAM（8 MiB）里。

官方 FAQ 已经给出权威的候选集合：带 64M~128M bit 片内存储器的只有 **EF2S45、AL3S10、EG4S20、EG4D20**。
其中 LUT ≤ 19600 的是 **AL3S10（8640）** 和 **EG4S20/EG4D20（19600）**；而按 §3.0 的量化门槛，
**AL3S10 的 8640 LUT 装不下 ~9462 LUT 的现有设计，且 DSP 只有 3 个（需 9 个）**。

→ **结论：一旦坚持"片内 SDRAM + 现有设计规模"，安路上没有任何一个"比 EG4S20 更小"的器件能承载。
可选项只剩 EG4S20 自己（同族不同封装）和 EG4D20（同样 19600 LUT，片内换成 DDR）。**

若换到**没有片内 SDRAM** 的器件，7.4 MB 帧缓存的出路：

| 方案 | 做法 | 代价 | 评价 |
|---|---|---|---|
| **A. 外挂 SDR SDRAM** | 板子扩展口上接一颗 64Mbit/256Mbit SDR 颗粒（如 IS42S16400 类），自写 SDR 控制器 | 需改板/加子板；自写控制器 + 刷新逻辑 + 跨时钟域仲裁，约 300–800 LUT + 1 个 PLL（若用 PLL 移相）；**三个 `sdr_*.enc` 全部作废** | 最接近原架构，但仍要重写整个存储子系统 |
| **B. 外挂 DDR3** | 只有 PH1A 有 DDR3/DDR4 硬核控制器（官方：最大 1866Mbps）。EF3/EF2/EG4（除 EG4D20）**没有 DDR 硬核**，软核 DDR 控制器不现实 | PH1A 本身就超出"≤19600 LUT"的条件 → 该路径自动出局 | **不适用** |
| **C. 用 SF1 的内置 PSRAM** | SF1 官方：内置 64Mb/128Mb PSRAM，最大 200MHz | 64Mb = 8 MB，容量刚好；但 SF1 只有 **5824 LUT / 31 或 59 个用户 IO**，LUT 与 IO 都不够；且是 MIPI/DSI 定位，HDMI 核必须换 | **不可行** |
| **D. 用 ERAM 硬塞** | 最大 ERAM 总量是 EF3LA0 的 612Kbit = **76.5 KB** | 差 96 倍 | **不可能** |
| **E. 降规格** | ① 帧数 8→2：1.84 MB；② 色深 24→16bit：600 KB/帧，8 帧 4.8 MB；③ 分辨率降到 320×240 | 仍 > 76.5 KB ERAM 上限，**必须外挂存储**；且 ③ 直接违反赛题"640×480 24-bit BMP"要求 | 只能减少对外存带宽/容量的需求，**不能取消外存** |

**重写量评估**：换到无片内 SDRAM 的器件，至少要重写/新写
① SDRAM/DDR 控制器与初始化，② 帧缓存地址映射与读写仲裁，③ 像素时钟域↔存储时钟域的异步 FIFO 与带宽保证，
④ 顶层例化与引脚约束，⑤ 很可能还要换 HDMI 核并重做 TMDS 时序。
**这不是"改几行约束"，而是显示通路的整体重做。**

### 3.3 640×480@60 HDMI 对器件的硬性要求

| 要求 | 现有设计 | 门槛分析 |
|---|---|---|
| **LVDS 差分对数量** | 1 对时钟 + 3 对数据 = **4 对（TMDS 3 lane + clock）** | 门槛很低。EG4 官方称"最大支持 800Mbps 高速 LVDS"，HDMI 文章称"真差分可支持 1Gbps 以上"。**未查到** EG4S20 的差分对确切数量（数据手册是 PDF，本次工具读不了） |
| **LVDS 速率** | 像素时钟 25MHz，5× 串行时钟 125MHz（DDR → 250 Mbps/lane） | 250 Mbps 远低于 800 Mbps 上限 → **不是瓶颈** |
| **PLL 数量** | **2 个**（`sys_pll` 出 125/100MHz，`video_pll` 出 25/125MHz） | **这是最狠的硬门槛**。EG4S20 有 4 个 → 够；EF3 全系 2 个 → **刚好够，零余量**；AL3S10 2 个 → **刚好够，零余量**；**EF2 全系只有 1 个 → 直接不可行**（无法同时产生两组独立频率的时钟，除非把两组频率绑到同一 VCO，工程上极难） |
| **PLL 频率上限** | 125MHz | 远低于典型上限，无风险 |
| **全局时钟** | 16（EG4S20 官方） | EF3 全系 **未查到** 全局时钟数；AL3S10 未查到 |
| **做 FIFO 的 ERAM** | **RAM9K 23/64** | 门槛：EF2L45 只有 12 个 ERAM9K → 不够；EF3L50 31 个、EF3L40 15 个 → 紧张/不够；**EF3L70/L90 30~36 个、EF3LA0 68 个、EG4X15 52 个、AL3S10 48 个 → 够** |
| **IO 数** | 需 HDMI 4 对差分 + TF 卡 4 线 + 按键 + 等 | EF2M45LG48B 仅 35 IO、SF1 VFBGA81 仅 31 IO → 不够；EF4L45BG256B 206 IO、EF3L90CG400B 335 IO → 够 |

### 3.4 结论：低风险 / 高风险 / 不可行

#### 🟢 低风险（推荐）

| 方案 | 理由 |
|---|---|
| **继续用 HX4S20C（EG4S20BG256）** | 零迁移成本，加密 IP 与片内 SDRAM 全部保留。**这是唯一真正零风险的方案**——注意它本身就已经是"逻辑资源上限"，所谓"替代"其实是"不替代" |
| **EG4S20CG324**（同族同 LUT，LFBGA324） | 同族同规模，`EG_PHY_SDRAM_2M_32` 与片内 2M×32 SDRAM 完全一致，两个 HDMI/SDRAM 加密核**复用概率最高**。代价：**封装不同（324 vs 256），引脚不兼容，必须换板**；需要确认目标板是否有 HDMI 与 TF 卡。**低风险但需要新板** |

#### 🟡 中风险

| 方案 | 理由 |
|---|---|
| **EG4X15BG256**（14720 LUT，LFBGA256 17×17，193 IO） | **唯一一个 LUT 严格小于 EG4S20 且资源账目能装下现有设计的器件**。LUT 14720（需 ~9462，占 64%，偏紧但可行）、ERAM9K 52、DSP 24、PLL 4、IO 193 —— **全部满足**。<br>而且它与 EG4S20BG256 **同为 LFBGA256 / 17×17 / 193 用户 IO**，叠加官方"强大的**引脚兼容替换性能**"的说法，**【推断】可能引脚兼容，可做 drop-in**。<br>**但：无片内 SDRAM** → 帧缓存必须外挂；三个 `sdr_*.enc` 作废；官方 HDMI 核同族复用**可能可以**但需实测。<br>**未查到任何 EG4X15 开发板在售** → 需要自制板或改现有板 |
| **EG4D20EG176/B**（19600 LUT，片内 8M×16 DDR，ETQFP176，135 IO） | 同 LUT、同族，但片内存储从 SDR 变 DDR，`EG_PHY_SDRAM_2M_32` 与 `sdr_*.enc` **不可复用**；ETQFP176 引脚与 BGA256 完全不兼容；IO 只有 135 |
| **EG4X20LG144**（19600 LUT，无片内 SDRAM，LQFP144，107 IO） | 资源够但无 SDRAM、IO 少、封装不同、加密 SDRAM 控制器作废 |

#### 🔴 高风险

| 方案 | 理由 |
|---|---|
| **EF3LA0CG484B / CG642B**（11776 LUT，68 ERAM9K，**无 DSP**，2 PLL） | LUT 占用将达 **80%**（TD 极可能布线失败）；**DSP 硬核为 0，而设计用了 9 个 DSP** → 除非把 DSP 全部改写成 LUT 逻辑（再吃 LUT）；跨族 → HDMI 加密核**必须重新索取**；无片内 SDRAM → 帧缓存要外挂。有官方开发板（含 LVDS 接口）是唯一亮点 |
| **EF3L90CG400B**（9280 LUT，30 ERAM9K，2 PLL） | **LUT 9280 < 需求 ~9462 → 直接不够**（约 102%）。即便压到刚好，80%+ 的占用率加上跨族换核，风险极高。有官方开发板 + Micro SD |
| **AL3S10LG144**（8640 LUT，2M×32 片内 SDRAM） | 表面最诱人（**唯一"更小且有片内 SDRAM"**），但三重否决：<br>① **LUT 8640 < 需求 ~9462**；<br>② **DSP 只有 3 个 < 需求 9 个**；<br>③ 跨族 → HDMI 加密核与 SDRAM 控制器**都不能复用**（且 AL3 的片内 SDRAM 原语名未必是 `EG_PHY_SDRAM_2M_32`）；<br>④ PLL 只有 2 个（零余量）；<br>⑤ **官网无 AL3 开发板**，需自制板。<br>**逻辑上完全走不通** |

#### ⛔ 不可行

| 方案 | 否决理由 |
|---|---|
| **EF2 全系**（EF2L15/L25/L45/M45/S45） | ① **PLL 只有 1 个 < 需求 2 个**（无法同时产生 125/100MHz 与 25/125MHz 两组时钟）——**硬性否决**；<br>② LUT ≤ 4480 < 需求 ~9462；<br>③ ERAM9K ≤ 12 < 需求 23；<br>④ 除 EF2S45 外无片内 SDRAM，且 EF2S45 只有 56 IO |
| **SF1 全系**（SF1S60/SF1N60） | ① LUT 5824 < 需求 ~9462；<br>② 用户 IO 仅 31（VFBGA81）或 59（TFBGA121），装不下 HDMI 4 对差分 + TF 卡 + 按键；<br>③ 官方定位是 MIPI DSI（2 路 D-PHY），**没有 HDMI/TMDS 硬核**，HDMI 加密核必须换族；<br>④ 内置 PSRAM 的帧缓存通路要重写 |
| **PH1A 全系** | LUT 最小 70848，**是 EG4S20 的 3.6 倍**，不满足"逻辑资源不超过 EG4S20"的筛选条件。（技术上完全跑得动 640×480 HDMI，且有 DDR3/DDR4 硬核与 SerDes；**问题在于赛题约束，不是技术约束**） |
| **DR1（飞龙）** | 逻辑"沿用 SALPHOENIX 系列"（≥70848 LUT）；是带 ARM A35 + RISC-V + NPU 的 FPSoC，架构与工具链（可能走 FutureDynasty）都不同 |
| **EG4S20BG256B（带 B）** | 官方选型表把它的"片内 SDRAM"栏标为**无**。若确如其表，则**用它替代会直接丢掉 7.4MB 帧缓存**，现有 `sdr_*.enc` 无硬核可用 → 不可行（**前提是选型表正确，待确认**） |

### 3.5 给项目的一句话建议

**在"逻辑资源不超过 EG4S20"+"保留片内 SDRAM 帧缓存"这两个约束同时成立时，安路没有任何替代器件。**
最接近的可行路径是二选一：

1. **不换器件**（继续 HX4S20C / EG4S20BG256）——零风险，但等于放弃"换更小器件"的目标；
2. **换到 EG4X15BG256**——唯一 LUT 更小（14720）且资源账目够用的型号，且可能引脚兼容；
   代价是**放弃片内 SDRAM，重新设计整个帧缓存通路（外挂 SDR SDRAM + 自写控制器）**，并需实测 HDMI 加密核能否在 EG4X15 上综合通过。

**AL3S10LG144 看起来是"完美的答案"（更小 + 片内 2M×32 SDRAM），实际是陷阱**：LUT 与 DSP 双双不足，跨族加密 IP 全部作废，且无开发板。

---

## 4. 不确定项清单（官网没写 / 只能推测 / 本次工具读不到）

| # | 事项 | 现状 | 建议的验证方式 |
|---|---|---|---|
| 1 | **TD 6.2.1 的官方存在性与器件支持清单** | 官网 sitemap 与"软件工具"分类只列到 **TD_4.6 / TD_5.0 / TD_5.5 / TD_5.6 + TD beta + TD License**，**没有列出任何 6.x 版本**；但该清单是 JS 动态加载且 sitemap 可能滞后。**未查到"TD 版本 ↔ 器件支持"对照表** | 直接问 FAE；或在 TD 安装目录查 device 库目录列表（本工作区已有 TD 6.2.1，可本地核实） |
| 2 | **`.enc` 加密 IP 的器件适用范围** | **未查到任何官方说明**。官网 IP 页需登录且 JS 加载 | 向安路 FAE 书面确认 `hdmi_1_4b_transmitter_core_wrapper.enc.v` 与 `sdr_*.enc.v` 各自允许的器件列表 |
| 3 | **EG4S20BG256（无 B）vs EG4S20BG256B（有 B）** | 官网选型表把 BG256 写成带 B 且标"无片内 SDRAM"；官方 FAQ 与 Sipeed 文档都说 EG4S20 带 2M×32 SDRAM。**两处官方口径冲突** | 问 FAE；或查 EG4S20 数据手册（PDF，需登录）的 Ordering Information / SIP 章节 |
| 4 | **EG4S40 / EG4S10 是否存在** | 官网 EG4 选型表无此型号 → **未查到**（很可能不存在） | 问 FAE 确认是否曾是内部型号 |
| 5 | **AL3S10 的全局时钟数、LVDS 差分对数量与最高速率、是否有开发板** | 官方选型表只给了 LUT/FF/ERAM/DSP/PLL/SDRAM/IO | 见 AL3 数据手册（需登录） |
| 6 | **EG4S20BG256 的 LVDS 差分对确切数量** | **未查到**（数据手册 PDF 无法用本次工具读取；官网文档需登录） | 查 EG4S20 数据手册的 IO 章节；或问 FAE |
| 7 | **LVDS33 标准在 EG4 上的支持范围** | 工程用 `IOSTANDARD=LVDS33` 输出 TMDS，实测可行；但官方 EG4S20 数据手册摘要只列了 `LVDS / Bus-LVDS / MLVDS / RSDS / LVPECL`，**未明确写 LVDS33**，也未说明哪些 bank 支持 | 查 TD 的 IO Standard 列表（本地 TD 6.2.1 可直接查） |
| 8 | **EG4X15BG256 与 EG4S20BG256 是否引脚兼容** | 同封装（LFBGA256）、同尺寸（17×17）、同用户 IO 数（193），官方又强调"强大的引脚兼容替换性能" → **强烈推断兼容，但官方未明说这两个型号之间的关系** | 比对两份封装/引脚文档（需登录），或问 FAE |
| 9 | **EG4X15BG256 是否有在售开发板** | **未查到** | 问代理（世强/中电港/芯查查上的安路代理） |
| 10 | **官方开发板的具体主芯片（SF102_V2.0 / AP102 / AP104 / AP106）** | 工具下载页只给板名，未逐个确认主芯片 | 查各板的原理图（需登录） |
| 11 | **EF3L15 / EF4 / EF5 / PH1P 的选型表** | 官网有 EF3L15 产品页与 EF4/EF5/PH1P 的文档分类，但本次未取到规格；EF4/EF5/PH1P **没有产品页** | 抓 EF3L15 页面；EF4/EF5/PH1P 问 FAE 是否已公开发布 |
| 12 | **SF1 的 PSRAM 容量（64Mb 还是 128Mb，按型号如何分布）与能否当通用帧缓存** | 官方只说"内置 64Mb/128Mb PSRAM"，选型表 PSRAM 栏只写"2"（含义不明） | 查 SF1 数据手册 |
| 13 | **Sipeed 写 EG4S20BG256 的 PLL = 1，官方数据手册写最多 4 个** | 官方 FAQ 与 EG4S20 数据手册摘要都支持 4 个 PLL / 16 全局时钟，与工程描述一致 → **以官方为准，Sipeed 文档疑有误** | 本地 TD 6.2.1 里对 EG4S20BG256 实例化第 3、第 4 个 PLL 看能否通过 |
| 14 | **现有设计 LUT 用量的确切数字** | 由用户给的 `Slices 4731/9800` 推算为 **~9462 LUT（48%）**，用户自己标了问号。§3.0 的整张筛选表都建立在这个推算上 | 读 `ai/06_REPORTS.md` 或重跑 TD 综合/布局布线报告，拿 LUT/ERAM/DSP/PLL 的实测绝对值 |
| 15 | **安路技术文档与 IP 的下载权限** | 【官方】官网提示："我们提供了 EF2\EF3\EG4 等系列器件的 **FamilyOverview** 文档，可免注册登录下载。如需开通资料权限，请将具体需求及会员注册手机号发送到如下邮箱 web@anlogic.com"；IP 与参考设计页显示"您的会员等级不足" | 注册会员并邮件申请权限；或通过 FAE |

---

## 5. 官方链接汇总（可点击）

**产品选型表**
- EG4（SALEAGLE 4）：<https://www.anlogic.com/product/fpga/saleagle/eg4>
- AL3（SALEAGLE 3）：<https://www.anlogic.com/product/fpga/saleagle/salal3>
- EF2（SALELF 2）：<https://www.anlogic.com/product/fpga/salelf/salelf2>
- EF3（SALELF 3）：<https://www.anlogic.com/product/fpga/salelf/salelf3>
- EF3L15：<https://www.anlogic.com/product/fpga/salelf/elf3l15>
- SF1（SALSWIFT 1）：<https://www.anlogic.com/product/fpga/salswift/salswift1>
- PH1A（SALPHOENIX 1A）：<https://www.anlogic.com/product/fpga/phoenix/ph1a>
- DR1（SALDRAGON 1）：<https://www.anlogic.com/product/fpga/saldragon>
- 器件总览：<https://www.anlogic.com/product/fpga>

**开发软件 / 工具链**
- TangDynasty (TD) 产品页：<https://www.anlogic.com/product/software/1.html>
- FutureDynasty 产品页：<https://www.anlogic.com/product/software/5.html>
- **工具与资料下载（TD 安装包 / TD License / 数据手册 / 开发板资料）**：<https://www.anlogic.com/support/tools-downloads>
- IP 和参考设计：<https://www.anlogic.com/support/ip>

**开发板**
- 开发板及下载器总入口：<https://www.anlogic.com/product/xaizaiqi>
- SALEAGLE 系列开发板（EG4S20BG256 板、EG4A20BG256 板）：<https://www.anlogic.com/product/xaizaiqi/aaa>
- EG4A20BG256 开发板详情：<https://www.anlogic.com/product/xaizaiqi/aaa/eg4a20-kfb>
- SALELF 系列开发板（EF2L45/EF2M45/EF3L90CG400B/EF3LA0CG484B）：<https://www.anlogic.com/product/xaizaiqi/abc>
- SALSWIFT1 系列开发板：<https://www.anlogic.com/product/xaizaiqi/sf11>
- SALPHOENIX1A 系列开发板：<https://www.anlogic.com/product/xaizaiqi/abcde>
- SALDRAGON 系列开发板：<https://www.anlogic.com/product/xaizaiqi/sald>
- 大学计划 / 学生竞赛 / 芯片及教育板卡申请：<https://www.anlogic.com/support/university/apply> 、<https://www.anlogic.com/support/university/competitions> 、<https://www.anlogic.com/support/university/development-board>

**官方 FAQ（器件与软件）**
- 应用类 FAQ（含"哪些器件自带大容量内部存储器""LVDS 最大输入频率"）：<https://tech.anlogic.com/Cn/Index/index/cate/33/p/1.html?cate=15&tp=1>
- 软件类 FAQ（含 TD License 获取方式）：<https://tech.anlogic.com/Cn/Index/index/cate/32/p/1/tp/1.html>
- FAQ 首页：<http://tech.anlogic.com/>

**官方技术文章**
- 技术分享｜安路 FPGA 实现 HDMI 的编解码的视频显示方案（**HDMI 方案与器件适用性的唯一官方口径来源**）：<https://www.anlogic.com/news/company-news/45.html>
- 方案｜简化存储器操作时序，快捷实现 FPGA ERAM 容量扩展：<https://www.anlogic.com/news/company-news/90.html>

**站点地图**：<https://www.anlogic.com/sitemap.html> ｜ 英文站：<https://www.anlogic.com/en/>

**第三方（非官方，仅作交叉验证）**
- Sipeed Tang Primer（EG4S20BG256，含 `EM SDR SDRAM 2M X 32bits` 参数）：<https://wiki.sipeed.com/hardware/zh/tang/Tang-primer/Tang-primer.html>
- Sipeed Tang Nano 4K（**高云 GW1NSR-LV4C，不是安路**）：<https://wiki.sipeed.com/hardware/zh/tang/Tang-Nano-4K/Nano-4K.html>
- 电子发烧友 EG4S20BG256 数据手册特性摘录 + EG4S20-MINI-DEV 板：<https://bbs.elecfans.com/archiver/?tid-1801320.html>
- 芯查查原厂 FAQ 镜像（"TD 自带 6 个月免费 License"）：<https://www.xcc.com/faq/1985982540638142465>
- TD 使用手册（第三方整理）：<https://zeeklog.com/guo-chan-fpgahan-jia-an-lu-kai-fa-gong-ju-tdshi-yong-shou-ce-xiang-xi-ban-11>
