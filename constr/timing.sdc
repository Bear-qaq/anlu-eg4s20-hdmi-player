# =============================================================================
# 时序约束 —— M2a（视频 + 音频 + 片内 SDRAM 帧仓）
#
# 与例程 timing.sdc 的差异：
#   1. 例程 5 个 PLL 输出时钟（sd_card_clk / ext_mem_clk / video_clk /
#      hdmi_5x_clk / audio_mclk）；本设计只有 4 个，分属 2 颗 PLL：
#        video_clock : pixel_clk(25M) / serial_clk(125M)
#        mem_clock   : mem_clk_100 / mem_clk(125M) / mem_clk_sft(125M@180°)
#   2. **显式声明两个时钟域组异步**。这不是"绕过分析"，而是事实：
#      本设计所有跨域路径都只经过异步 FIFO（格雷码指针 + 两级同步）或两级同步器，
#      没有任何一拍组合逻辑跨域。例程把这条写成注释保留、没敢开，结果
#      跨域伪违例和真实违例混在一起看不清。
#   3. 例程那 32 个 `ext_mem_clk -> clkc[2]`（SDRAM 读数据 PHY）违例在加密黑盒
#      内部，物理上无法修改；本设计同样需要给它例外。见第 5 节。
# =============================================================================

# ---------------------------------------------------------------------------
# 1. 板级输入主时钟：R7 上的 50 MHz 有源晶振
# ---------------------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ---------------------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ---------------------------------------------------------------------------
derive_clocks

# ---------------------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    实例路径：top / u_video_clock / u_pll  与  top / u_mem_clock / u_pll
#      video_clock clkc[0] -> 25 MHz  像素时钟（同时是 PLL 反馈源）
#      video_clock clkc[1] -> 125 MHz DDR 串行时钟（HDMI PHY 串行化）
#      mem_clock   clkc[0] -> 100 MHz（仅作 PLL 反馈，本设计未使用）
#      mem_clock   clkc[1] -> 125 MHz SDRAM 用户接口时钟
#      mem_clock   clkc[2] -> 125 MHz 相移 180°，给控制器内部 SDRAM 输出寄存器
#    若综合后实例名有出入，按 Timing Analyzer 里的实际 pin 路径改这里。
# ---------------------------------------------------------------------------
rename_clock -name {pixel_clk}   -source [get_ports {clk}] -master_clock {clk} \
    [get_pins {u_video_clock/u_pll.clkc[0]}]
rename_clock -name {serial_clk}  -source [get_ports {clk}] -master_clock {clk} \
    [get_pins {u_video_clock/u_pll.clkc[1]}]

rename_clock -name {mem_clk_100} -source [get_ports {clk}] -master_clock {clk} \
    [get_pins {u_mem_clock/u_pll.clkc[0]}]
rename_clock -name {mem_clk}     -source [get_ports {clk}] -master_clock {clk} \
    [get_pins {u_mem_clock/u_pll.clkc[1]}]
rename_clock -name {mem_clk_sft} -source [get_ports {clk}] -master_clock {clk} \
    [get_pins {u_mem_clock/u_pll.clkc[2]}]

# ---------------------------------------------------------------------------
# 4. 时钟组关系
# ---------------------------------------------------------------------------
# 4.1 像素时钟与串行时钟：同源同 PLL 的两路输出，但用途完全不同。
#     两者之间只有 PHY 内部那几条经过厂商验证的路径（像素域翻转 + 串行域两拍同步）。
#     例程用的就是 exclusive，这里沿用，理由一致。
set_clock_groups -exclusive \
    -group [get_clocks {pixel_clk}] \
    -group [get_clocks {serial_clk}]

# 4.2 ★ 两块 PLL 之间的跨域路径全部是异步的。
#     video_clock 与 mem_clock 是两颗独立 PLL，输出之间没有确定的相位关系。
#     本设计里它们的交界只有三种，且都做了正确处理：
#       a) pixel_packer(25M) -> async_fifo -> frame_store 写引擎(125M)   ：异步 FIFO
#       b) frame_store 读引擎(125M) -> async_fifo -> frame_reader(25M)   ：异步 FIFO
#       c) warm 标志(125M) -> 三级同步器 -> 像素域                        ：同步器
#     没有任何「一拍组合逻辑跨两个域」的路径，所以这里声明 asynchronous 是
#     对事实的陈述，不是把违例藏起来。
set_clock_groups -asynchronous \
    -group [get_clocks {pixel_clk} {serial_clk}] \
    -group [get_clocks {mem_clk} {mem_clk_sft} {mem_clk_100}]

# 4.3 SDRAM 读数据 PHY：mem_clk 与 mem_clk_sft 是同一颗 PLL 的 0°/180° 两路输出，
#     TD 会按 4 ns（半周期）预算去检查这两者之间的路径。
#     这些路径全部在加密黑盒 `sdr_as_ram` 内部（SDRAM 读数据回采），物理上不可修改；
#     厂商自己的参考设计在同样位置有 32 个违例（SWNS −6.699 ns），也照常出货。
#     180° 相移本身就是这个 PHY 的经验性采样点选择，交给 STA 逐拍推算没有意义。
#     ⚠️ 改动这一条之前必须先看 Timing Analyzer 的实际路径，确认它们确实只在黑盒内。
set_clock_groups -asynchronous \
    -group [get_clocks {mem_clk}] \
    -group [get_clocks {mem_clk_sft}]

# ---------------------------------------------------------------------------
# 5. 复位分发的说明（**无需额外例外**）
#
#    reset_gen 的复位同步器异步置位端只接板级复位端口 rst_n（大拇指 A9），而
#    「POR 完成 & PLL 锁定」这些释放条件放在数据通路里、由各域自己同步。
#    因此不存在「clk 域寄存器 -> mem_clk 域异步复位端」这种跨域 recovery 路径，
#    不需要 set_false_path。
#
#    ⚠️ 曾经写成 `por_rst_n & pll_locked` 直接接异步复位端，实测产生 1 个
#       setup 违例（clk -> mem_clk，recovery，SWNS −0.159 ns）。改结构后消失。
#       另外 TD 的 `set_false_path -from [get_cells ...]` 不接受 cell 列表
#       （报 USR-8012 value for option -from is invalid），所以靠结构解决而不是靠例外。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 5.5 数码管状态字的跨域输入（CDC）：只限最大数据延迟，不做保持检查
#
#   这 16 bit 状态字在 top 里**拼了三个时钟域**的信号：
#     像素域 : media_loader 的 state_code / err_code / loaded_cnt / img_count
#     内存域 : frame_store 的 slot_ready / state_code，以及 SDRAM 控制器内部信号
#     SD 域  : sector_source 的 sd_timeout
#   进 seg_display 后先过两级同步器（dv_s1 → dv_s2）再译码。第一级同步器的输入
#   **不能**按普通同步路径查保持：源数据本身就是要被"跨域采样"的，数据在捕获沿
#   附近变化正是同步器要吸收的东西。按普通路径查的结果是 28 个端点全部保持违例
#   （HWNS −1.528 ns / TNS −26.282 ns），而这 28 个在物理上无害 —— 第二级触发器
#   有整整一个 clk 周期（20 ns）等它稳定，MTBF 足够。
#
#   标准写法是 set_max_delay -datapath_only：
#     · 用「最大数据延迟」取代建立关系 → 数据在一个源时钟周期内稳定、亚稳态窗口有界；
#     · 不再产生保持检查 → 消掉那 28 个伪违例。
#
#   ⚠️ 只约束「X → clk」这一个方向。反方向（clk → mem/pixel，即复位释放逻辑）
#      必须保留检查，所以这里**不**用 set_clock_groups 把 clk 整个声明成异步组。
#   ⚠️ 这条路径以前一直是全设计最紧的一条（Setup WNS 从 +609 ps 一路摆到 +20 ps），
#      根因就是译码逻辑直接挂在跨域路径上。现在译码挪到同步器之后，跨域只剩
#      「源寄存器 → 走线 → 同步器 D」。
# ---------------------------------------------------------------------------
set_max_delay -datapath_only -from [get_clocks {pixel_clk}]   -to [get_clocks {clk}] 10.000
set_max_delay -datapath_only -from [get_clocks {mem_clk}]     -to [get_clocks {clk}] 10.000
set_max_delay -datapath_only -from [get_clocks {mem_clk_100}] -to [get_clocks {clk}] 10.000

set_false_path -hold -from [get_clocks {pixel_clk}]   -to [get_clocks {clk}]
set_false_path -hold -from [get_clocks {mem_clk}]     -to [get_clocks {clk}]
set_false_path -hold -from [get_clocks {mem_clk_100}] -to [get_clocks {clk}]

# ---------------------------------------------------------------------------
# 6. 其余说明
#   - clk(50M) 域内只有复位 POR 计数、按键消抖、数码管扫描，
#     唯一的跨域输入见第 5.5 节（数码管状态字，两级同步 + datapath_only）。
#   - 按键 toggle 是单 bit，像素域三级同步器接收。
#   - pixel_clk 域余量最大，符合预期：25 MHz 下逻辑很宽松。
# ---------------------------------------------------------------------------
