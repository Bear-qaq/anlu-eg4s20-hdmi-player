# sim/ —— testbench 与仿真

## 仿真环境

- ModelSim（参考设计里带 `sim_do/` 脚本，见 `raw/03_芯片手册/IP参考设计/APUG011_*/sim_do/`）
- 也可用 TD 内建仿真

## 注意

例程**没有提供 testbench** —— 官方两个 lab 都是直接上板验证的。
所以仿真环境需要你自己搭，建议优先给这些模块写 tb：

| 优先 | 模块 | 为什么 |
|---|---|---|
| 高 | `sd_card_cmd` / `spi_master` | 状态机时序，上板调试成本最高 |
| 高 | 你自己写的帧缓存 / 切图逻辑 | 评分考察点，必须能独立验证 |
| 中 | `bmp_read` | BMP 头解析，边界情况多 |
| 低 | `seg_scan` / `ax_debounce` | 逻辑简单，上板一眼能看出来 |

## 黑盒模块无法仿真

这些是加密的，没有行为模型，tb 里只能当空壳或跳过：
`hdmi_1_4b_transmitter_core_wrapper.enc.v`、`sdr_as_ram.enc.v`、`sdr_init_ref.enc.v`、`sdr_wrrd.enc.v`。

好在安路提供了 SDRAM **仿真模型**可供参考：
`raw/03_芯片手册/IP参考设计/APUG011_*/source_code/model/IS42s32200.v`
