//=============================================================================
// 模块：video_clock
// 功能：像素时钟生成。50 MHz 参考时钟 -> 25 MHz 像素时钟 + 125 MHz DDR 串行时钟。
//
// 说明：例程直接使用 IP Generator 生成的 video_pll.v，但该文件的 extlock 被接成
//       open，顶层无法感知 PLL 是否锁定。本模块用同一组 EG_PHY_PLL 参数，但把
//       extlock 引出来，供复位逻辑使用（锁定后才释放视频域复位）。
//
// 端口：
//   refclk      50 MHz 板上晶振（R7）
//   rst_n_async 低有效异步复位（POR 之后）
//   pll_locked  PLL 锁定指示，高有效
//   pixel_clk   25.000 MHz  像素时钟
//   serial_clk  125.000 MHz 串行时钟（5 x 像素时钟，配 ODDR 双沿 = 10 bit/像素）
//
// 时序说明：EG_PHY_PLL 的 reset 为高有效；本模块内部取反。锁定后约需数十个
//           参考时钟周期，调用方应在 pll_locked 有效后再释放像素域复位。
//=============================================================================
`timescale 1ns / 100fs

module video_clock (
    input  wire refclk,
    input  wire rst_n_async,
    output wire pll_locked,
    output wire pixel_clk,
    output wire serial_clk
);

    wire clk0_buf;

    // 反馈时钟必须经 BUFG 回到 pll_inst.fbclk，否则 PLL 无法锁定
    EG_LOGIC_BUFG u_bufg_feedback (
        .i (clk0_buf),
        .o (pixel_clk)
    );

    EG_PHY_PLL #(
        .DPHASE_SOURCE  ("DISABLE"),
        .DYNCFG         ("DISABLE"),
        .FIN            ("50.000000"),
        .FEEDBK_MODE    ("NORMAL"),
        .FEEDBK_PATH    ("CLKC0_EXT"),
        .STDBY_ENABLE   ("DISABLE"),
        .PLLRST_ENA     ("ENABLE"),
        .SYNC_ENABLE    ("DISABLE"),
        .GMC_GAIN       (2),
        .ICP_CURRENT    (9),
        .KVCO           (2),
        .LPF_CAPACITOR  (1),
        .LPF_RESISTOR   (8),
        .REFCLK_DIV     (2),
        .FBCLK_DIV      (1),
        .CLKC0_ENABLE   ("ENABLE"),
        .CLKC0_DIV      (40),
        .CLKC0_CPHASE   (39),
        .CLKC0_FPHASE   (0),
        .CLKC1_ENABLE   ("ENABLE"),
        .CLKC1_DIV      (8),
        .CLKC1_CPHASE   (7),
        .CLKC1_FPHASE   (0)
    ) u_pll (
        .refclk    (refclk),
        .reset     (~rst_n_async),
        .stdby     (1'b0),
        .extlock   (pll_locked),
        .load_reg  (1'b0),
        .psclk     (1'b0),
        .psdown    (1'b0),
        .psstep    (1'b0),
        .psclksel  (3'b000),
        .psdone    (),
        .dclk      (1'b0),
        .dcs       (1'b0),
        .dwe       (1'b0),
        .di        (8'h00),
        .daddr     (6'b000000),
        .do        ({open, open, open, open, open, open, open, open}),
        .fbclk     (pixel_clk),
        .clkc      ({open, open, open, serial_clk, clk0_buf})
    );

endmodule
