# 新开发板：硬木课堂「大拇指」EG4S20（DMZ_Anlogic 核心板）

> **2026-09-29 起取代康芯 HX4S20C 作为开发平台。2026-10-04 已完成板级迁移。**
> 器件完全相同（EG4S20BG256），媒体层 RTL / 加密黑盒 / 仿真主体保持不变；
> 已完成引脚约束、数码管、矩阵按键和 HDMI DDC 端口适配，并重新生成位流。
> 当前构建结果：Setup WNS **+521 ps**、Hold WNS **+14 ps**、0 违例端点。
>
> 本文件是这块板卡的**权威引脚参考**。引脚全部来自厂家原文，无一条臆造。
> 相关的换板可行性调研见 `docs/BOARD_SWAP.md`。

---

## 1. 板卡构成

「大拇指」是**核心板 + 底板**两层结构，厂家把两块分开卖、引脚也分两份文档：

| 层 | 型号 | 内容 |
|---|---|---|
| **核心板** | DMZ_Anlogic | FPGA + 时钟 + LED + 数码管 + 矩阵键盘 + 拨码 + 蜂鸣器 + UART + USB-JTAG + 137 个扩展 IO |
| **底板** | M0 底板 | HDMI 输出 + SD 卡槽 + RGB565 屏 + VGA + 音频功放 + 麦克风 + CMSIS-DAP 调试器 |

> ✅ **2026-09-29 已确认：手上是「核心板 + M0 底板」。**
> 因此本文件的 HDMI / SD / 音频引脚**全部适用**，`constr/pin_damuzhi.adc` 可直接用。
>
> （注：硬木还有一块**综合实验底板**，引脚不同 —— 音频脚 F3 vs E1 之类。
> 如果将来换了底板，HDMI 和 SD 的引脚要重新核对。）

---

## 2. 器件资源（EG4S20BG256）

| 项 | 值 |
|---|---|
| 系列 | EG4「EAGLE 猎鹰」，55 nm 低功耗工艺 |
| 封装 / IO | BG256，256 管脚，**193 个可用 IO** |
| LUT | **19600** |
| 分布式 RAM | 156 Kbit |
| 块 RAM | **64 × 9 Kbit**（真双口，8K×1 ~ 512×18）+ **16 × 32 Kbit**（2K×16 或 4K×8）+ 专用 FIFO 控制逻辑 |
| **内置 SDRAM** | **2M × 32 bit SDR SDRAM**，最高 200 MHz —— 用 3D 合封技术与 EG4X20 封在一起 |
| 时钟 | 2 路 IOCLK + **16 路全局时钟** + **4 个 PLL**（分频 1~128）+ 5 路时钟输出 |
| 硬核 IP | **8 通道 12 位 1 MSPS SAR ADC**、电压监控、环形振荡器 |
| 唯一 ID | 每颗芯片有唯一 **64 位 DNA** |
| 配置模式 | MSPI / SS / MP / SP / **JTAG (IEEE-1532)** |
| IO 标准 | LVTTL、LVCMOS(3.3/2.5/1.8/1.5/1.2)、PCI、**LVDS**/Bus-LVDS/MLVDS/RSDS/LVPECL；片内 100 Ω 差分电阻 |

静态功耗低至 5 mA。

---

## 3. 核心板引脚表（厂家表 1.1 ~ 1.9）

### 3.1 时钟（表 1.6）

| 信号 | 引脚 | 说明 |
|---|---|---|
| **CLK** | **R7** | **50 MHz** 晶振 —— 与 HX4S20C **相同**，PLL 不用重生成 |
| Clock_3Hz | F5 | 3 Hz 秒脉冲，调试方便 |

### 3.2 按键（表 1.1）

| 信号 | 引脚 | 方向 |
|---|---|---|
| Key_Col[0] | **E11** | 输出（扫描） |
| Key_Col[1] | **D11** | 输出 |
| Key_Col[2] | **C11** | 输出 |
| Key_Col[3] | **F10** | 输出 |
| Key_Row[0] | **E10** | 输入（读回，需上拉） |
| Key_Row[1] | **C10** | 输入 |
| Key_Row[2] | **F9** | 输入 |
| Key_Row[3] | **D9** | 输入 |
| **独立按键** | **E3** | 输入 —— **可直接当 key1，不必扫描** |

> ⚠️ **索引方向容易看错**：厂家表格是按 `[3] [2] [1] [0]` **降序**列出的，
> 照抄成升序会把整个键盘镜像。本表已转成标准的 `[0] → [3]` 升序。
>
> **矩阵键盘驱动**：一次把一列拉低、其余拉高，读 4 行；某行为低 = 该行该列被按下。
> 行输入需上拉。

### 3.3 拨动开关（表 1.2）SW7~SW0

| 信号 | 引脚 | 网络标号 |
|---|---|---|
| SW_In[0] | A9 | SW0 |
| SW_In[1] | A10 | SW1 |
| SW_In[2] | B10 | SW2 |
| SW_In[3] | A11 | SW3 |
| SW_In[4] | A12 | SW4 |
| SW_In[5] | B12 | SW5 |
| SW_In[6] | A13 | SW6 |
| SW_In[7] | A14 | SW7 |

拨向板边 = 低电平，拨向 UP = 高电平。

### 3.4 LED（表 1.3）—— **高电平点亮**，共 12 个

| 信号 | 引脚 | 网络标号 |
|---|---|---|
| LED_Out[0] | B14 | LED0 |
| LED_Out[1] | B15 | LED1 |
| LED_Out[2] | B16 | LED2 |
| LED_Out[3] | C15 | LED3 |
| LED_Out[4] | C16 | LED4 |
| LED_Out[5] | E13 | LED5 |
| LED_Out[6] | E16 | LED6 |
| LED_Out[7] | F16 | LED7 |
| LED_Out[8] | D3 | LED11 |
| LED_Out[9] | E4 | LED12 |
| LED_Out[10] | C1 | LED13 |
| LED_Out[11] | C2 | LED14 |

> ⚠️ **B14 在这块板上是 LED0**，而在 HX4S20C 上是 `sd_miso`。旧约束文件不可混用。

### 3.5 数码管（表 1.4）—— **4 位，段选高有效（共阴），位选低有效**

| 信号 | 引脚 | 说明 |
|---|---|---|
| Digitron_Out[0] | A4 | 字码段 A |
| Digitron_Out[1] | A6 | 字码段 B |
| Digitron_Out[2] | B8 | 字码段 C |
| Digitron_Out[3] | E8 | 字码段 D |
| Digitron_Out[4] | A7 | 字码段 E |
| Digitron_Out[5] | B5 | 字码段 F |
| Digitron_Out[6] | A8 | 字码段 G |
| Digitron_Out[7] | C8 | 小数点 DOT |
| DigitronCS_Out[0] | C9 | COM4（**最右位**） |
| DigitronCS_Out[1] | B6 | COM3 |
| DigitronCS_Out[2] | A5 | COM2 |
| DigitronCS_Out[3] | A3 | COM1（最左位） |

> ⚠️ 与 HX4S20C 的**两处不同**：① 只有 **4 位**（我们是 6 位）；② **段选极性相反**（我们是低有效）。
> `seg_display` 已改为 4 位、段选高有效，并保留 `SEG_ACTIVE_LOW` 参数；
> 位选低有效两边一致，扫描顺序不用换（两边第 0 位都是最右位）。

### 3.6 蜂鸣器（表 1.5）与 UART（表 1.9）

| 信号 | 引脚 | 说明 |
|---|---|---|
| Buzzer_Out | H11 | 无源蜂鸣器（经功放） |
| **RXD** | **F12** | **FPGA 接收**外部数据 |
| **TXD** | **D12** | **FPGA 向外部发送**数据 |

> ⚠️ UART 方向容易接反：这里是「RXD = FPGA 收」，与某些芯片的命名习惯相反。

### 3.7 R-2R DAC（表 1.8）—— **复用 LED0~LED7 引脚**

| 信号 | 引脚 |
|---|---|
| DA_Data[0..7] | B14 B15 B16 C15 C16 E13 E16 F16 |

输出电压 `DAC_VOUT = 3.3V × DA_Data/256`。**与 LED0~7 冲突，不能同时用。**

### 3.8 扩展排针的 LVDS 差分对（来自核心板原理图，**独立验证过**）

上下排针各有 6 对 LVDS，共 12 对。原理图里网络名和引脚是写在一起的，所以配对确定：

| 网络名 | 正端 (P) | 负端 (N) |
|---|---|---|
| LVDS_01 | P16 | P15 |
| LVDS_02 | L12 | M11 |
| LVDS_03 | N14 | N16 |
| LVDS_04 | L16 | M16 |
| LVDS_05 | J12 | K12 |
| **LVDS_06** | **P1** | R1 |
| LVDS_07 | R2 | P2 |
| **LVDS_08** | **P4** | N4 |
| **LVDS_09** | **N1** | M1 |
| **LVDS_10** | **J3** | J4 |
| LVDS_11 | L13 | M13 |
| LVDS_12 | N3 | M4 |

> 🔴 **这解释了 M0 底板的 HDMI 是怎么走的**：底板用的 `HDMI_CLK_P`=P1 / `HDMI_D0_P`=N1 /
> `HDMI_D1_P`=P4 / `HDMI_D2_P`=J3，**正好是 LVDS_06_P / LVDS_09_P / LVDS_08_P / LVDS_10_P**。
> 即底板 HDMI 是 FPGA 经扩展排针的 LVDS 差分对**直出 TMDS**，中间没有转换芯片。
> 负端（R1/M1/N4/J4）由 TD 的 `LVDS33` 自动配对，不用单独约束。
>
> 这条结论原先是从底板引脚表**推断**的，现在从核心板原理图**独立验证**了。

### 3.9 配置 / 启动网络（原理图新增信息）

`SPI_CSN`（配置 Flash 片选）、`FPGA_CCLK`、`FPGA_D0`、`FPGA_MOSI`、`FPGA_GCLK1`、
`INIT_B`、`PROGRAM_B`、`DONE`、`MSEL0`、`MSEL1`、`BOOT`
→ 证明核心板走 **MSPI（主模式串行 SPI）配置**，与"掉电配置 QSPI Flash"一致。

另有 `OSC_OUT` 和 **`CLOCK_24M`** —— 24 MHz 那条文档里没提过（文档只有 50 MHz@R7 和 3 Hz@F5），
用途待确认，可能是 USB-JTAG 芯片的时钟。

> 完整的网络清单见 `raw/06_开发板_硬木课堂/09_核心板原理图_信号清单.md`。

---

## 4. M0 底板引脚表（厂家 §4.1 ~ §4.7）

### 4.1 HDMI 输出（§4.3）—— **关键**

| 引脚 | 功能 |
|---|---|
| **P1** | HDMI_CLK_P |
| **N1** | HDMI_D0_P |
| **P4** | HDMI_D1_P |
| **J3** | HDMI_D2_P |

**结论：底板 HDMI 就是 FPGA 直出 TMDS 差分对（LVDS33），中间没有任何 HDMI 发送芯片。**
与 HX4S20C 是同一套做法 → `hdmi_1_4b_transmitter_core_wrapper.enc.v` 与 `hdmi_phy_warpper.v`
**可原样复用，只改这 4 个引脚号**。

> 🔴 **引脚表里只有 4 对 TMDS，没有 DDC 的 SCL/SDA。**
> 没有接到 FPGA。顶层已删除 `HDMI_DDC_SCL` / `HDMI_DDC_SDA` 两个用户端口，
> 加密核的 `O_ddc_scl` / `IO_ddc_sda` 接到内部未使用网络。
> 剩余工作是**上板实测无 EDID 时能否正常出图**，这是换板后的第一验证点。

### 4.2 SD 卡（§4.6）—— **SPI 模式**

| 引脚 | SDIO | 四线 SPI |
|---|---|---|
| **F13** | SD_D3 | **SPI_CS** |
| **F14** | SD_CMD | **SPI_MOSI** |
| **F15** | SD_CLK | **SPI_SCK** |
| **D14** | SD_D0 | **SPI_MISO** |
| G14 / D16 / E15 | SD_D2 / SD_D1 / — | 未用 |

底板是 **SPI 模式** SD 卡槽 → 与 HX4S20C 同样走 `spi_master` 四线协议，**驱动零改动**。

### 4.3 音频（§4.4 / §4.5）

| 引脚 | 功能 |
|---|---|
| J6 | ADC_CS |
| K5 | ADC_MISO |
| H3 | ADC_SCK |
| G6 | ADC_RSTN |
| **F3** | **Audio_PWM**（PWM 低通 + 功放 → 3.5 mm） |

> ✅ **2026-09-29 已澄清**：厂家《板卡和引脚说明》PDF 原文写的是
> *"将麦克风信号放大、调理后送给**板载的 ADC 芯片**采样"* ——
> 即**外部 SPI ADC 芯片**，不是 FPGA 内部 XADC。
> （语雀 M0 页面写成"送给 FPGA 内部 XADC 的第 14 通道"，是那份文档的笔误。）
>
> **与我们无关** —— HDMI 音频完全走核内部，不占任何板级引脚。

### 4.4 其他底板资源

- **RGB565 液晶屏 / VGA**（复用同一组引脚）：`lcd_rgb[15:0]` = H15 G16 H16 H13 H14 J14 J16 K15 K16 J11 G11 L14 K12 J12 K14 J13；`LCD_CLK`=L13、`VGA_HS`=M14、`VGA_VS`=P14、`LCD_DE`=L16、`LCD_BL`=M16
- **并口屏**：`LCD_DATA[15:0]` = K1 J1 H1 H2 G1 F1 F2 E1 E2 D1 M5 M3 M2 L4 L3 P2；
  控制信号 `LCD_CS`=N3、`LCD_RS`=M4、`LCD_WR`=L5、`LCD_RD`=L1、`LCD_RST`=K2、`LCD_BL_CTR`=R2
  （后面这 6 个是厂家 PDF 有、语雀页面漏掉的）
- **SPI 串口屏**：`LCD_SCL`=D1、`LCD_SDA`=E1、`LCD_RES`=F1、`DC`=H2、`LCD_CS`=J1、`LCD_BLK`=K2
- **CMSIS-DAP 调试器**：`SWDIO`=K6、`SWCLK`=K3

---

## 5. 与 HX4S20C 的差异 → 迁移落地状态

**无需改器件级主体**：器件、50 MHz@R7、HDMI 直出 TMDS、SD 走 SPI、板载 USB 下载器、
TD 6.2.1、加密黑盒、片内 SDRAM 数据通路、7 个 testbench。

**迁移改动与落地状态**：

| # | 项 | HX4S20C | 大拇指 + M0 | 当前实现 |
|---|---|---|---|---|
| 1 | 引脚约束 | `constr/pin.adc` | `constr/pin_damuzhi.adc` | 已改 `prj/prj.json`，TD 构建全程使用新板约束 |
| 2 | HDMI DDC | P2 / R2 | **未引出** | 已删两个顶层端口，内部网络保持未使用；无 EDID 出图待实测 |
| 3 | 数码管 | 6 位，段选低有效 | **4 位，段选高有效** | `seg_display` 已改为 4 位；`seg_sel[3:0]`，段选高有效、位选低有效 |
| 4 | 按键 | 4 个独立按键 | **1 个独立按键 E3** + 4×4 矩阵 | key1 用 E3；key2 为矩阵任意键：四列全拉低、四行相与，再复用 `key_debounce` |
| 5 | 复位 | 专用复位键，A2 | **无专用复位键** | 当前用 SW0（A9）作为板级复位输入；厂家 PWM/SD 例程均在此脚配 `PULLDOWN`，上板时 SW0 必须拨高释放复位 |

> ⚠️ A9 同时是 `SW_In[0]`。当前先用厂家示例的 A9 方案完成上板；
> 若实测与拨码功能冲突，可改为只依赖内部 POR，不占外部复位脚。

**存疑（不影响主链路）**：

| 项 | 说明 |
|---|---|
| 片内 ADC 引出脚 | 厂家实验 13 给出 CH1=M10、CH2=L10、CH3=P11、CH4=M12；其余通道在左侧 40 针排针上，需原理图定脚 |
| SPI Flash 容量 | 核心板**有**板载 SPI Flash（厂家例程 11 `spi_flash` 就是读写它），容量待确认 |
| 赛题合规 | 「器件相同、板卡不同」是否被接受需出题方书面确认（2026-09-29 已获**临时许可**） |

---

## 6. 可直接对照移植的厂家例程

| 例程 | 用途 |
|---|---|
| `SDRAM_as_BRAM` / `SDRAM_FIFO` | 把片内 SDRAM 当 64 Mb 虚拟 BRAM，接口同 BRAM —— 与本工程 `sdr_as_ram` 用法完全一致 |
| `SD_Card_SPI` | 四线 SPI 读写 SD 卡（需 16G/32G HC 卡） |
| `VGA_hdmi_tx_display_MB` | **在底板 HDMI 口输出彩条** —— 证明底板 HDMI 就是 FPGA 直出 TMDS |
| `spi_flash`（实验 11） | 读写板载 SPI Flash |
| 内部 AD 多通道采样（实验 13） | 片内 ADC，给出 CH1~CH4 引脚 |

---

## 7. 上电与下载（来自厂家《编译和下载》）

1. **license**：把 license 文件放进 TD 安装目录的 `license/` 文件夹
2. **编译**：TD 里点 Run 或双击 Generate Bitstream → 产出 `.bit`
3. **接线**：JTAG-USB 口接电脑（**下方那个是 UART-USB，别插错**）
4. **驱动**：首次使用需装 USB-JTAG 驱动 —— 设备管理器里找到 `USB-JTAG-Cable`，
   更新驱动指向 **TD 安装目录下的 `drivers` 文件夹**，勾选"包括子文件夹"
   - ⚠️ 若 `Anlogic USB Cable` 上有黄色叹号：先在 **BIOS 里禁用 Secure Boot**，
     再**禁用 Windows 驱动数字签名强制**
5. **下载**：双击 Download → 确认找到硬件、选 JTAG 速度 → 添加 `.bit` → Run
   - **成功标志：LED0~LED7 依次右移点亮**
6. **固化**：选 Program Flash 模式 → Add `.bit` → Run 烧进外部 Flash；
   拔掉 USB 再上电，程序自动运行

---

## 8. 来源

| 内容 | 链接 |
|---|---|
| 核心板总体介绍与全部引脚表（2024 版） | https://www.yuque.com/yingmuketang/01/sz9qkx4rnuw6yctz |
| M0 底板引脚（HDMI §4.3 / SD §4.6 / 音频 §4.4-4.5） | https://www.yuque.com/yingmuketang/01/ybuzk6rfe3lk923i |
| 编译和下载（license / 驱动 / 下载 / 固化） | https://www.yuque.com/yingmuketang/01/garumc3ftmcfbcog |
| 板卡资源下载页 | https://www.yuque.com/yingmuketang/01/lwghr4 |
| **厂家《板卡和引脚说明》PDF**（14 页，M0 底板权威引脚表） | 本地：`raw/06_开发板_硬木课堂/08_板卡和引脚说明.pdf`，已提取文字为同名 `.md` |
| **核心板原理图 PDF**（EG4S20BG256-20211231） | https://www.yuque.com/attachments/yuque/0/2021/pdf/23019172/1640922948674-a27b4c6d-4e22-4a24-b3a9-88ced41b7c62.pdf |
| **配套资源百度网盘**（提取码 `o1at`） | https://pan.baidu.com/s/1crkRpJx0xDSasG4jWGynmQ?pwd=o1at |
| 综合实验底板（另一块底板，引脚不同） | https://www.yuque.com/yingmuketang/01/qfczf3f4plkdkohv |
| 常见问题 FAQ | https://www.yuque.com/yingmuketang/01/rma2p4 |
| 核心板旧版引脚（2021，口袋实验 KB） | http://kb.koudaishiyan.com/7001.html |
| 硬木官网 / 淘宝 | https://www.emooc.cc/ ／ shop280814574.taobao.com |
| 联系 | frank@emooc.cc ／ 13764149990 |

> **抓取技巧**：语雀公开文档在 URL 后加 `/markdown?plain=true&linebreak=false&anchor=false`
> 就能拿到完整 markdown 正文（页面本身是前端渲染的，直接抓只有标题）。
