# 团队交接说明

更新日期：2026-10-04

## 一、项目当前状态

项目名称：基于安路 EG4S20BG256 的 HDMI 多媒体播放系统。

实际硬件已经从旧板 HX4S20C 迁移到硬木课堂「大拇指」EG4S20：

- 核心板：DMZ_Anlogic
- 底板：M0
- 工具链：Tang Dynasty 6.2.1，版本号 `6.2.168116`
- 当前约束：`constr/pin_damuzhi.adc`
- 当前顶层：`src/rtl/top.v`

当前已经完成：

1. 新板引脚约束迁移。
2. HDMI DDC 用户端口移除。
3. 4 位数码管适配，段选高有效、位选低有效。
4. key1 使用独立按键 E3。
5. key2 使用 4x4 矩阵键盘任意键。
6. TD 6.2.1 综合、布局布线和位流生成。
7. 厂家 M0 HDMI、PWM、SD 官方对照位流已提取，用于上板排障。

当前没有完成：

1. 真实上板验证。
2. HDMI、音频、SD、按键的实物验收记录。
3. ModelSim 回归测试。当前机器没有原交接说明中的
   `D:\modeltech64_10.6e`，需要安装或设置 `MODELTECH` 后再运行。

## 二、当前构建结果

最终本工程位流：

`build/hdmi_player/td_project/hdmi_player_Runs/phy_1/hdmi_player.bit`

结果：

| 项目 | 数值 |
|---|---:|
| Setup WNS | +521 ps |
| Hold WNS | +14 ps |
| Setup/Hold 违例端点 | 0 |
| Slices | 4513 / 9800 = 46.05% |
| RAM | 21 / 64 |
| DSP | 9 / 29 |
| PLL | 2 / 4 |
| 位流大小 | 629,624 B |
| SHA256 | `AB18256666E50BF16EE660493BDD92237A99FA06700E99B890FF4F316D050650` |

## 三、上板前必须先确认

`rst_n` 使用 A9，也就是拨码 SW0，低有效。厂家 PWM 和 SD 示例都把该脚配置为
`PULLDOWN`。因此：

**上板前必须把 SW0 拨到高电平，否则 FPGA 会一直处于复位状态。**

HDMI 使用：

| 信号 | 引脚 |
|---|---|
| HDMI_CLK_P | P1 |
| HDMI_D0_P | N1 |
| HDMI_D1_P | P4 |
| HDMI_D2_P | J3 |

M0 底板没有 DDC/EDID。厂家官方 M0 HDMI 例程也只约束这四根 TMDS 线，
没有 DDC 端口。

## 四、第一轮上板顺序

1. 接好 JTAG-USB，不要接成 UART-USB。
2. 把 SW0 拨到高电平。
3. 先下载厂家 HDMI 对照位流：
   `vendor_bringup/m0_vendor_hdmi_tx_display.bit`
4. 确认显示器能稳定出图。
5. 再下载本项目位流：
   `hdmi_player.bit`
6. 记录 HDMI 画面、音频、数码管和按键现象。

判断方法：

- 厂家 HDMI 位流和本项目位流都能出图：硬件通路正常。
- 厂家 HDMI 位流能出图，本项目位流不能：优先检查本项目设计。
- 厂家 HDMI 位流也不能出图：优先检查线缆、显示器输入源、供电和 JTAG 下载。

厂家对照位流说明见 `vendor_bringup/README.md`。

## 五、公开 GitHub 仓库内容边界

本仓库用于团队同步和公开分享。

应该提交：

- `src/rtl/` 中我们自己编写的 RTL。
- `constr/` 中自己的引脚和时序约束。
- `sim/` 中自己的 testbench 和仿真脚本。
- `prj/`、`tools/` 中的构建脚本与工程清单。
- `docs/`、`AGENTS.md`、`PROGRESS.md`、`HANDOFF_TEAM.md` 等文档。

不要提交：

- `raw/`：厂家手册、PDF、官方例程原件。
- `ai/`：由资料生成的本地索引。
- `build/`、`dist/`：构建产物和压缩包。
- `vendor_bringup/`：厂家官方位流。
- `src/vendor/`：厂家加密黑盒和厂商包装文件。

`src/vendor/` 中的文件是构建所必需的，但不适合直接放到公开仓库。
从 GitHub 克隆后，需要从合法取得的厂家资料包中恢复这些文件。

## 六、常用命令

构建前先检查：

```powershell
node tools/td_build.mjs --dry
```

完整构建：

```powershell
node tools/td_build.mjs
```

只做综合：

```powershell
node tools/td_build.mjs --step syn
```

仿真：

```powershell
node sim/run.mjs
```

## 七、下一阶段工作

1. 完成第一轮厂家 HDMI 对照位流上板验证。
2. 完成本项目位流上板验证。
3. 记录并修复 HDMI、音频、数码管和按键问题。
4. 根据赛题要求补齐“下一张图片”和“轮播启停”的按键语义。
5. 完成 SD 介质读写和图片加载验证。
6. 形成测试报告、演示视频和最终答辩材料。

## 八、团队协作规则

1. 每次开始工作前先读 `PROGRESS.md` 和本文件。
2. 每次结束工作前更新 `PROGRESS.md` 的变更记录和待办。
3. 一次提交只做一件事，提交信息写清楚完成了什么。
4. 不把官方资料、加密黑盒、位流和构建目录提交到公开仓库。
5. 修改端口或引脚时，同步更新约束、文档和例化处。
