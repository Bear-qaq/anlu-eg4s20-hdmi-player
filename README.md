# 安路 EG4S20 HDMI 多媒体播放器

面向全国大学生嵌入式芯片与系统设计竞赛 2026 FPGA 创新设计赛道选题一。

当前实际开发平台：

- 器件：安路 `EG4S20BG256`
- 核心板：DMZ_Anlogic
- 底板：硬木课堂 M0
- 工具链：Tang Dynasty 6.2.1
- 当前约束：`constr/pin_damuzhi.adc`

## 当前状态

工程已经完成新板迁移并成功生成位流：

- Setup WNS：`+521 ps`
- Hold WNS：`+14 ps`
- Setup/Hold 违例端点：`0`
- Slices：`4513 / 9800`
- 位流大小：`629,624 B`

当前尚未完成真实上板验收。详细进度见 `PROGRESS.md` 和 `HANDOFF_TEAM.md`。

## 数据通路

```text
microSD -> SPI SD 驱动 -> FAT32 索引 -> BMP 流式解码
        -> 8 槽帧仓 -> 片内 SDRAM -> 行预取与混合器
        -> HDMI 1.4b 输出
```

音频在像素时钟域直接合成 48 kHz PCM，并送入 HDMI 发送核。

## 构建

先准备厂家提供且未存放在公开仓库中的 `src/vendor/` 文件，然后：

```powershell
node tools/td_build.mjs --dry
node tools/td_build.mjs
```

只做综合：

```powershell
node tools/td_build.mjs --step syn
```

## 仿真

安装 ModelSim 10.6e 并设置 `MODELTECH`：

```powershell
$env:MODELTECH = "D:\modeltech64_10.6e"
node sim/run.mjs
```

## 仓库边界

公开仓库不包含：

- 厂家 PDF、手册和官方例程原件
- 厂家加密 HDL
- 厂家官方位流
- 本工程的构建产物和本地索引

`src/vendor/README.md` 说明了构建前需要恢复的厂家文件。

## 上板提示

`rst_n` 接 A9，也就是拨码 SW0，低有效，并且按厂家 M0 示例配置为下拉。
上板前必须把 SW0 拨到高电平，否则 FPGA 会一直保持复位。

M0 底板没有 DDC/EDID，HDMI 只使用 `P1/N1/P4/J3` 四根 TMDS 线。

## 许可证

本仓库中我们自己编写的代码和文档使用 MIT License。
厂家文件不包含在本仓库中，仍适用其原始授权条件。
