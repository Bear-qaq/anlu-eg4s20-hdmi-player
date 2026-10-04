# constr/ —— 你自己的约束文件

- `pin.adc` —— 引脚约束（安路 TD 语法）
- `timing.sdc` —— 时钟与时序约束

## 引脚约束模板（HX4S20C，已从官方 `pin.adc` 核对）

```
set_pin_assignment { clk }           { LOCATION = R7;  IOSTANDARD = LVCMOS33; }
set_pin_assignment { rst_n }         { LOCATION = A2;  IOSTANDARD = LVCMOS33; }
set_pin_assignment { key1 }          { LOCATION = B2;  IOSTANDARD = LVCMOS33; }
set_pin_assignment { key2 }          { LOCATION = C1;  IOSTANDARD = LVCMOS33; }

# HDMI TMDS —— 注意是 LVDS33，不是 LVCMOS33
set_pin_assignment { HDMI_CLK_P }    { LOCATION = C3;  IOSTANDARD = LVDS33; PULLTYPE = NONE; }
set_pin_assignment { HDMI_D0_P }     { LOCATION = G5;  IOSTANDARD = LVDS33; PULLTYPE = NONE; }
set_pin_assignment { HDMI_D1_P }     { LOCATION = F1;  IOSTANDARD = LVDS33; PULLTYPE = NONE; }
set_pin_assignment { HDMI_D2_P }     { LOCATION = E1;  IOSTANDARD = LVDS33; PULLTYPE = NONE; }

# DDC (I2C，用于读显示器 EDID)
set_pin_assignment { HDMI_DDC_SCL }  { LOCATION = P2;  IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = PULLUP; }
set_pin_assignment { HDMI_DDC_SDA }  { LOCATION = R2;  IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = PULLUP; }

# TF 卡 (SPI 模式)
set_pin_assignment { sd_ncs }        { LOCATION = A12; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; }
set_pin_assignment { sd_dclk }       { LOCATION = A14; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; }
set_pin_assignment { sd_mosi }       { LOCATION = A13; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; }
set_pin_assignment { sd_miso }       { LOCATION = B14; IOSTANDARD = LVCMOS33; }
```

完整引脚表（含数码管 `seg_data[7:0]` / `seg_sel[5:0]`）见 `ai/04_CONSTRAINTS.md`。

> ⚠️ 官方 `pin.adc` 里 `#` 开头的那批（`I_sys_clk`、`O_tmds_*`、`I_i2s_*`、`vga_*`）是**废弃的旧命名**，
> 别照抄。

## 时钟约束参考

例程用的是 50 MHz 系统时钟（周期 20 ns）：

```
create_clock -name clk -period 20.000 [get_ports {clk}]
```

PLL 产生的 `pixel_clk` / `serial_clk` 由 TD 自动推导，参考设计里手动补了 13.5 ns / 2.7 ns。
