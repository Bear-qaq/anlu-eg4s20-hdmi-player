---
name: anlogic-td
description: "安路科技 Tang Dynasty (TD) 工具链细节：.al 工程文件结构、.adc/.sdc/.cwc 约束语法、.ipc IP 配置、_Runs 构建产物、器件原语命名、报告与报错定位。"
whenToUse: "涉及 TD 工程结构、约束文件写法、IP 核配置、综合/布局布线报错、引脚与时序约束、器件原语例化时。纯粹写 RTL 逻辑时不需要。"
---

# 安路 TD (Tang Dynasty) 工具链

## 版本锁定

**TD 6.2.1，工程实测版本号 `6.2.168116`。** 官方要求评审环境统一此版本；
高版本创建保存的工程无法向下兼容，在 6.2.1 中打不开。
**不要提出任何需要 TD > 6.2.1 的方案、工程格式或 IP 配置。**

## 工程文件 `.al`（XML）

```xml
<Project Version="3" Minor="2" Path="...">
  <TD_Version>6.2.168116</TD_Version>
  <Name>HDMI1.4b_Transmitter_v1.0</Name>
  <HardWare>
    <Family>EG4</Family>
    <Device>EG4S20BG256</Device>
  </HardWare>
  <Source_Files>
    <Verilog>
      <File Path="../user_source/hdl_source/top.v">
        <FileInfo>
          <Attr Name="UsedInSyn"      Val="true"/>
          <Attr Name="UsedInP&amp;R"  Val="true"/>
          <Attr Name="BelongTo"       Val="design_1"/>
          <Attr Name="CompileOrder"   Val="1"/>
        </FileInfo>
      </File>
```

要点：
- `File Path` 是**相对 `.al` 所在目录**的路径
- `UsedInSyn` / `UsedInP&R` 决定该文件是否参与综合 / 布局布线
- `CompileOrder` 是编译顺序 —— 排查"模块找不到"时先看这里
- 提取好的清单见 `ai/04_CONSTRAINTS.md` 的「工程文件」一节，不用自己解析 XML

## 约束文件

| 扩展名 | 用途 | 语法要点 |
|---|---|---|
| `.adc` | 引脚约束 | `set_pin_assignment { 端口 } { LOCATION = R7; IOSTANDARD = LVCMOS33; }` |
| `.sdc` | 时序约束 | Tcl：`create_clock -name clk -period 20.000 [get_ports {clk}]` |
| `.cwc` | DDC/EDID 相关 | HDMI 读显示器 EDID 用 |

`.adc` 的属性键：`LOCATION`（引脚号）、`IOSTANDARD`（`LVCMOS33` / `LVDS33` …）、
`DRIVESTRENGTH`（如 8）、`PULLTYPE`（`NONE` / `PULLUP` / `PULLDOWN`）。

> ⚠️ **`#` 开头的行是被注释掉的废弃约束。** 官方例程的 `pin.adc` 里保留了一批旧命名
> （`I_sys_clk`、`O_tmds_*`、`I_i2s_*`、`vga_*`），它们**不生效**。
> 判断引脚时只看非 `#` 行，或者直接读 `ai/04_CONSTRAINTS.md`（已过滤）。

## IP 配置 `.ipc`（XML）

一个安路 IP 会生成一组文件：

| 文件 | 内容 |
|---|---|
| `xxx.ipc` | IP 配置（XML），IP 生成器读写的就是它 |
| `xxx.v` / `xxx.vhd` | 生成出的包装代码 |
| `xxx.tcl` | 生成脚本 |

PLL 的 `.ipc` 结构示例：

```xml
<PLLConfig version="1.0">
  <GeneralConfig>
    <Device>...</Device>
    <Type>PLL</Type>
    <create_VHDL>true</create_VHDL>
  </GeneralConfig>
  <Page1>
    <input_frequency>50.0000000000000000MHz</input_frequency>
    <clk_num>CLKC0</clk_num>
    <feedback_mode>Normal</feedback_mode>
    <pll_lock>ENABLE</pll_lock>
  </Page1>
</PLLConfig>
```

> ⚠️ **`.ipc` 里的 `<Device>` 字段不可信。** 实测官方例程的 `pll.ipc` 写的是
> `PH1A90SBG484`，而实际器件是 `EG4S20BG256` —— 是模板残留。
> 判断目标器件请看 `.al` 文件的 `<HardWare>` 节或 `ai/04_CONSTRAINTS.md`。

## 构建产物目录 `<工程名>_Runs/`

**注意是 `<名字>_Runs`（下划线），不是 `*.runs`。** 编写剔除规则时这是常见错误。

```
<工程名>_Runs/
  .logs/phy_1/td_YYYYMMDD_HHMMSS.log   带时间戳的运行日志，单个可达 80 KB
  syn_1/                                综合阶段
  phy_1/                                布局布线阶段
  phy_1/<工程名>_pr.db                  布局布线数据库（MB 级）
  phy_1/<工程名>_place.db
  phy_1/run.log
  phy_1/<工程名>.timing                时序结果
```

同类产物扩展名：`.db` `.logw` `.qor` `.status` `.area` `.ts` `.bid` `.cwc` `.dmp` `.timing`
`.bit`（比特流）。这些对理解设计没有价值，`tools/config.json` 里已全部列入剔除名单。

## 器件原语命名

被例化但没有源码定义的名字，基本都是器件原语。按系列分前缀：

| 前缀 | 系列 |
|---|---|
| `EG_` | EG4 系列（本项目用的就是这个） |
| `EF2_` / `EF3_` / `EF4_` | Eagle 各代 |
| `PH1_` / `PH1P_` | PH1 系列 |
| `SF1_` | SF1 系列（Tang Mega） |
| `DR1_` | DR1 系列 |
| `AL_` | 通用逻辑原语（`AL_DFF_X`、`AL_MUX`、`AL_MAP_ADDER`）—— 通常出现在**综合后网表**里，不是手写的 |

本项目实际用到的关键原语：

| 原语 | 作用 |
|---|---|
| `EG_PHY_SDRAM_2M_32` | **片内集成 SDRAM** 控制器（2M×32bit 封装在芯片内，不是外挂颗粒） |
| `EG_PHY_PLL` | 锁相环 |
| `EG_PHY_CONFIG` | 配置相关 |
| `EG_PHY_BRAM` / `EG_LOGIC_RAMFIFO` | 块 RAM / 硬 FIFO |
| `EG_LOGIC_BUFG` / `EG_PHY_GCLK` | 全局时钟缓冲 |
| `EG_LOGIC_ODDR` | 输出双沿寄存器（LVDS 发送常用） |

## 报错与资源定位

综合/布局布线的问题**不要在源码里瞎找**，直接看：

- `ai/06_REPORTS.md` —— 已提取的报告头尾（报错、资源占用、Fmax）
- `raw/.../<工程名>_Runs/.logs/*/td_*.log` —— 完整运行日志
- `phy_1/*.timing` —— 时序收敛详情

资源对标：EG4S20BG256 有 19600 LUT / 19600 FF / 4 PLL / 64 块 9Kb ERAM + 16 块 32Kb。

## 本项目的加密黑盒

这些是二进制密文，**不可读也不可改**，只能通过包装层例化：

- `hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v`
- `include/sdr_as_ram.enc.v`、`sdr_init_ref.enc.v`、`sdr_wrrd.enc.v`

即 **HDMI 收发核心与 SDRAM 控制器是黑盒**。需要了解接口时读包装层
（如 `hdmi_phy_warpper.v`）或查 `ai/02_MODULE_MAP.md`。
