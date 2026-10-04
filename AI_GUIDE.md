# AI_GUIDE.md — 项目总说明

> **这是给 AI 看的第一份材料，也是效率的决定因素。**
> 由 `tools/pack.mjs` 自动嵌进 `ai/00_START_HERE.md`。改动后重跑 `node tools/pack.mjs` 即可。

---

## 1. 项目背景

| 项目 | 内容 |
|---|---|
| 竞赛 | 全国大学生嵌入式芯片与系统设计竞赛 2026 · FPGA 创新设计赛道 |
| 出题方 | 杭州康芯电子有限公司 |
| 赛题 | **选题一：基于安路 HX4S20C 板的 HDMI 多媒体播放系统** |
| 实际开发平台 | **硬木课堂「大拇指」EG4S20：DMZ_Anlogic 核心板 + M0 底板** |
| 当前阶段 | **板级迁移完成，位流已生成；待上板实测 HDMI / SD / 数码管 / 按键** |

### 赛题要求（官方原文摘要，完整版见 `ai/packs/pack_00_赛题指南.md`）

**基础要求：**
1. 从 TF 卡或 SPI Flash 读取媒体资源，至少支持 **4 幅 640×480、24-bit** 图片的自动扫描、识别与装载
2. 在 FPGA 端完成图像缓存，并通过 HDMI 稳定输出（画面连续清晰、无黑屏卡死/斑点/花屏/撕裂）
3. 至少 2 个按键：一个切下一张，一个启停自动轮播；**轮播周期可配置**
4. 显示图像的同时通过 HDMI 输出可识别音频，链路稳定、终端能正常枚举出声

**扩展要求：** 淡入淡出/滑动切换/缩略图/多窗口；音视频联动；用片上 ADC + 用户 IO + UART 扩展配置；启动速度/资源/功耗/鲁棒性优化；自主创意

> ⚠️ **硬性红线**：官方明确要求 *"提交作品中的整体实现架构、音频和图片处理方法不能和参考实例相同"*。
> 所以例程只能用来**理解接口和时序**，不能照搬架构。给建议时请主动提出与例程不同的实现路径。

**自备设备：** 带 HDMI 输入的显示器（建议支持 1280×720@60Hz），HDMI 1.4+ 纯铜线，长度 ≤ 5 米。

---

## 2. 硬件平台：硬木课堂「大拇指」EG4S20 + M0 底板

| 项目 | 值 |
|---|---|
| 器件 | **安路 EG4S20BG256**（EG4 系列，BG256 封装 17×17mm） |
| 逻辑资源 | 19,600 LUT / 19,600 FF |
| PLL | 4 个 |
| 全局时钟 | 16 路 |
| 用户 IO | 最多 193 |
| 片内 SDRAM | **2M × 32 bit**（片内集成，不是外挂！） |
| 片上 RAM | 64 块 9Kb (ERAM9K) + 16 块 32Kb |
| 系统时钟 | **50 MHz 有源晶振，接引脚 R7** |
| 配置 Flash | 核心板板载 SPI Flash，容量待确认 |
| 存储 | M0 底板 TF 卡槽，SPI 模式 |
| 视频 | M0 底板 1 路 HDMI 输出，FPGA 直出 TMDS |
| 通信 | USB 转 UART，蜂鸣器 |
| 人机交互 | 1 个独立按键、4×4 矩阵键盘、8 路拨码、4 位数码管、12 个 LED |
| 下载 | 板载 USB-JTAG，不需要另配下载器 |
| 扩展 | 核心板上下两排扩展 IO，含 12 对 LVDS |

### 生效引脚分配（来自 `constr/pin_damuzhi.adc`，完整表见 `docs/BOARD_DAMUZHI.md`）

| 信号 | 引脚 | 电平 | 说明 |
|---|---|---|---|
| `clk` | **R7** | LVCMOS33 | 50 MHz 系统时钟 |
| `rst_n` | **A9** | LVCMOS33 | 低有效复位，复用拨码 SW0；厂家例程配 `PULLDOWN`，上板时 SW0 需拨高 |
| `key1` | **E3** | LVCMOS33 | 独立按键 |
| `key_col[3:0]` | E11 D11 C11 F10 | LVCMOS33 | 4×4 矩阵键盘列扫描输出，当前全拉低 |
| `key_row[3:0]` | E10 C10 F9 D9 | LVCMOS33 | 4×4 矩阵键盘行输入，当前任意键作为 `key2` |
| `HDMI_CLK_P` | P1 | **LVDS33** | TMDS 时钟差分对 |
| `HDMI_D0_P` | N1 | LVDS33 | TMDS 数据 0 |
| `HDMI_D1_P` | P4 | LVDS33 | TMDS 数据 1 |
| `HDMI_D2_P` | J3 | LVDS33 | TMDS 数据 2 |
| `sd_ncs` / `sd_mosi` / `sd_dclk` / `sd_miso` | F13 / F14 / F15 / D14 | LVCMOS33 | TF 卡 SPI 模式 |
| `seg_data[7:0]` | A4 A6 B8 E8 A7 B5 A8 C8 | LVCMOS33 | 数码管段选，高有效 |
| `seg_sel[3:0]` | C9 B6 A5 A3 | LVCMOS33 | 数码管位选，低有效 |
| I2S 音频（**已废弃，未生效**） | BCLK=J13, LRCK=F13, DOUT=L14 | — | `pin.adc:8-10` 三行是 `#` 注释；例程顶层没有这些端口 |

> HDMI DDC/EDID 没有引出到 M0 底板，顶层已删除对应用户端口。首次上板必须验证
> 加密 HDMI 核在没有 EDID 时能否正常输出画面。

> **更正（2026-09-26）**：原来说"I2S 是输入方向、音频从 HDMI 接收侧进 FPGA"是**错的**。
> 实测例程 `top` 的 16 个端口里没有任何音频引脚，生效的音频约束是 **0 条**；
> lab_ex5_i2s 的音频 100% 由 FPGA 内部产生：
> `PLL_HDMI_AUDIO(12.288M)` → `hdmi_audio_tone_i2s_64fs`（方波 DDS）→
> **`I2S_receiver`（把刚造出来的 I2S 又解回来，片内自环）** → `audio_arc_calculate` → 加密核。
> 加密核的音频接口本来就是**并行 PCM**（`I_audio_valid` + `I_audio_left/right_data[23:0]`
> + `I_acr_valid/cts/n`），那圈 I2S 纯属自找的中间环节。
> "外部 I2S 进 FPGA"的说法出自厂商 APUG092 参考设计，被误当成了例程行为。

---

## 3. 工具链

| 项目 | 值 |
|---|---|
| 综合/布局布线 | **Tang Dynasty (TD) 6.2.1** —— 实测工程版本号 `6.2.168116` |
| 工程文件 | `*.al`（XML 格式，含源文件清单与器件设置） |
| 管脚约束 | `*.adc`（`set_pin_assignment { 端口 } { LOCATION = xx; IOSTANDARD = xx; }`） |
| 时序约束 | `*.sdc` |
| DDC/EDID 约束 | `*.cwc` |
| 语言 | Verilog 为主（少量 VHDL IP 包装） |
| 仿真 | ModelSim（参考设计带 `sim_do/` 脚本） |

> ⚠️ **必须用 TD 6.2.1，不要用更高版本。**
> 官方《重要提醒》原文：评审环境统一为 6.2.1；高版本工程文件**无法向下兼容**，
> 在 6.2.1 中打不开，会直接影响作品提交和评审。
> 因此：**不要给需要 6.2.1 以上版本才能打开的工程格式或 IP 配置建议。**

---

## 4. 目录约定

```
raw/                            原始资料（只读，不改）
  00_赛题指南/                  官方赛题 PDF/DOCX 及其转出的 md
  01_例程/                      官方两个 lab（lab_ex4_tf / lab_ex5_i2s）
  02_原理图/                    开发板原理图 PDF
  03_芯片手册/                  EG4S20 手册、IP 参考设计、外设芯片手册
  04_板卡手册/                  HX4S20 开发板手册、教学实验平台手册
  05_工具流程/                  TD 使用流程、安装教程、ModelSim 安装

src/                            我自己的设计源码        ← 只改这里
constr/                         我自己的约束文件
sim/                            我的 testbench
docs_md/                        手册转出来的 markdown
ai/                             pack.mjs 生成的 AI 资料包（自动生成，勿手改）
tools/                          打包工具链
```

---

## 5. 参考例程结构（重要）

两个 lab 的目录布局完全一致，都是安路官方标准结构：

```
lab_exX/
  src/
    user_source/
      hdl_source/         ← 可读的 Verilog 源码（顶层 + SD + IP 包装 + include）
      constraints_source/ ← pin.adc（引脚）+ timing.sdc（时钟）+ edid_debug.cwc
      ip_source/          ← PLL 等 IP（.ipc 配置 + .v/.vhd 生成代码）
    td_project/
      *.al                ← TD 工程文件
      al_ip/              ← IP 生成产物
  doc/                    ← 说明文档、图片转换脚本
  代码说明.md
  设计参考例程文档.md      ← 主要教程（已是 Markdown，AI 可直接读）
```

### 两个 lab 的关系

| | lab_ex4_tf | lab_ex5_i2s |
|---|---|---|
| 功能 | TF 卡 BMP 读取 → SDRAM → HDMI 显示 | 在 ex4 基础上增加 **HDMI 音频（I2S）** |
| 顶层 | `top_tf_hdmi_audio.v`（12 个例化） | `top_tf_hdmi_audio.v`（15 个例化） |
| 独有 | — | `I2S_receiver.v`、`audio_arc_calculate.v`、`hdmi_audio_tone_i2s_64fs.v` |

### 顶层设计要点（从例程提取）

```verilog
module top(
    input clk, rst_n,
    input key1,      // 手动下一张
    input key2,      // 自动播放 开/关
    output [5:0] seg_sel, output [7:0] seg_data,
    output HDMI_CLK_P, HDMI_D2_P, HDMI_D1_P, HDMI_D0_P,
    output HDMI_DDC_SCL, inout HDMI_DDC_SDA,
    output sd_ncs, sd_dclk, sd_mosi, input sd_miso
);
parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS; // ← 双缓冲，乒乓切换
```

主要子模块链路：
`top` → `sys_pll`/`video_pll`（时钟）→ `sd_card_bmp`（含 `bmp_read` + `sd_card_top`→`sd_card_cmd`/`spi_master`/`sd_card_sec_read_write`）→ `frame_read_write`（含 `wfifo`/`rfifo` 异步 FIFO）→ `sdram`（片内 SDRAM 控制器）→ `video_timing_data`/`video_delay`/`video_rgb_to_axis_640x480` → `hdmi_phy_warpper` → HDMI 输出；另有 `seg_scan`/`seg_decoder` 数码管、`startup_pulse` 上电脉冲。

---

## 6. 已知陷阱（请务必注意，避免给出错误建议）

1. **加密 HDL，不可读也不可改**
   - `hdl_source/hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v`（约 321KB）
   - `hdl_source/include/sdr_as_ram.enc.v`、`sdr_init_ref.enc.v`、`sdr_wrrd.enc.v`
   - 这些是二进制密文，工具链已自动剔除。**HDMI 收发核心和 SDRAM 控制器是黑盒**，
     只能按包装层（`hdmi_phy_warpper.v`）暴露的接口使用。不要建议"进 core 里改"。

2. **`pin.adc` 里被 `#` 注释掉的引脚是旧版命名，已失效**
   - 失效：`I_sys_clk`、`O_tmds_ch0_p/ch1_p/ch2_p`、`O_tmds_clk_p`、`I_i2s_*`、`I_key_in`、`vga_data[*]`、`vga_out_hs/vs`
   - 生效：`clk`、`key1`、`key2`、`rst_n`、`HDMI_*`、`sd_*`、`seg_*`
   - 注意 `I_key_in` 和 `rst_n` 指向同一个引脚 A2，前者是废弃写法。

3. **工程文件名错位**：`lab_ex4_tf/src/td_project/` 下的工程文件叫 **`lab_ex5_i2s_v1.0.al`**。
   不要因为文件名就以为 lab_ex4 里装的是 lab_ex5 的代码。

4. **片内 SDRAM 不是外挂颗粒**：EG4S20 把 2M×32bit SDRAM 集成在封装内，
   通过 `EG_PHY_SDRAM_2M_32` 原语访问，不是通用 IO 驱动的外部 SDRAM。

5. **`Runs` 目录是构建产物**：TD 生成 `<工程名>_Runs/`，里面是 `.db`/`.log` 等，已全部剔除。

---

## 7. 编码规范（AI 生成代码必须遵守）

- 命名：模块/信号 `snake_case`；参数常量 `UPPER_SNAKE`；低有效信号加 `_n` 后缀
- 时钟：一律 `posedge clk` 同步设计；**禁止门控时钟和用计数器分频产生时钟**，要用 PLL
- 复位：**异步复位、低有效**，与例程保持一致；所有寄存器必须复位
- 跨时钟域：必须两级同步器或异步 FIFO（例程里 `afifo_*` 就是干这个的）
- 组合逻辑：`always @(*)` + 完整 `else`，禁止产生 latch
- 位宽：赋值两侧位宽必须一致，显式写明，禁止隐式截断
- 注释：中文；每个模块头部写功能 / 端口含义 / 时序说明
- 禁止：`initial` 块（testbench 除外）、`#delay`（testbench 除外）、浮点运算

---

## 8. AI 协作规则 ← 最重要的一节

**你应该这样帮我：**

1. **先读 `ai/00_START_HERE.md`**；要改模块先读 `ai/02_MODULE_MAP.md` 拿接口，
   涉及引脚/时钟读 `ai/04_CONSTRAINTS.md`。**不要通读 `ai/files/` 下的源码**——那是最后手段。
2. 只修改 `src/` `constr/` `sim/`。**永远不要改 `raw/`**——那是官方原件。
3. 遵守第 7 节编码规范，并保持与例程一致的复位/时钟风格。
4. 改端口前先在 `ai/02_MODULE_MAP.md` 确认现有接口，并列出所有需要同步修改的例化处。
5. **不要臆造引脚号**，一律以 `ai/04_CONSTRAINTS.md` 的引脚表为准。
6. 时刻记住第 6 节的陷阱：加密 core 是黑盒、注释引脚已失效、片内 SDRAM 是原语。
7. **红线段**：方案不能照搬例程架构。如果你发现我的思路和例程一样，请直接指出。
8. 时序不收敛/资源超限时，读 `ai/06_REPORTS.md` 再下结论。
9. 不确定就直接问我，不要猜。输出代码给完整可编译的文件，不要用 `// ... 省略` 占位。

**不要做：**

- 不要为了"更规范"重构我没让你动的模块
- 不要引入我没装的 IP 核或第三方库
- 不要改时钟频率、引脚分配、约束文件（除非我明确要求）
- 不要建议需要 TD > 6.2.1 的方案
- 不要说"应该可以工作"——要么给出可验证的仿真/约束检查方法，要么明说不确定
