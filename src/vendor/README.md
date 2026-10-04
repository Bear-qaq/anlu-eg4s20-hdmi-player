# 厂家文件占位目录

本目录中的厂商文件没有提交到公开 GitHub 仓库，包括：

- HDMI 加密发送核及包装文件
- SDRAM 加密控制器
- PLL 包装文件
- SD 卡 SPI 驱动
- LVDS/PHY 包装文件

这些文件属于厂家提供的资料，公开仓库只保留本目录说明和恢复路径。

从合法取得的官方资料包恢复后，本目录应至少包含：

```text
src/vendor/
  hdmi/
    hdmi_1_4b_transmitter_core_wrapper.enc.v
    hdmi_phy_warpper.v
    lane_lvds_10_1.v
  mem/
    sdr_as_ram.enc.v
    sdr_init_ref.enc.v
    sdr_wrrd.enc.v
  pll/
    sys_pll.v
    video_pll.v
  sd/
    sd_card_cmd.v
    sd_card_sec_read_write.v
    sd_card_top.v
    spi_master.v
```

恢复完成后运行：

```powershell
node tools/td_build.mjs --dry
```

确认源文件路径完整后，再执行完整构建。
