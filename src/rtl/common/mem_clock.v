//=============================================================================
// 模块：mem_clock
// 功能：SDRAM 域的时钟生成。输出 125 MHz 与 125 MHz 相移 180°。
//
// 参数与官方例程 IP Generator 生成的 sys_pll.v **完全一致**（已逐项核对），
// 唯一区别是把 extlock 引出来给复位逻辑用 —— 例程里 sys_pll 的 extlock 是
// 接 open 的，顶层根本不知道 PLL 有没有锁（ex5 相对 ex4 的一个可靠性回退）。
//
// 端口：
//   refclk        50 MHz 板上晶振（R7）
//   rst_n_async   低有效异步复位
//   pll_locked    锁定指示，高有效
//   clk_100       100 MHz（C0，同时是 PLL 反馈源；本设计未使用，但必须保留反馈通路）
//   clk_125       125 MHz（C1）—— SDRAM 控制器用户接口时钟
//   clk_125_sft   125 MHz 相移 180°（C2）—— 控制器内部 SDRAM 输出寄存器用
//
// 说明：C0 必须经 BUFG 回到 fbclk，否则 PLL 不锁（FEEDBK_PATH="CLKC0_EXT"）。
//=============================================================================
`timescale 1ns / 100fs

module mem_clock (
    input  wire refclk,
    input  wire rst_n_async,
    output wire pll_locked,
    output wire clk_100,
    output wire clk_125,
    output wire clk_125_sft
);

    wire clk0_buf;

    EG_LOGIC_BUFG u_bufg_feedback (
        .i (clk0_buf),
        .o (clk_100)
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
        .GMC_GAIN       (4),
        .ICP_CURRENT    (29),
        .KVCO           (4),
        .LPF_CAPACITOR  (1),
        .LPF_RESISTOR   (2),
        .REFCLK_DIV     (1),
        .FBCLK_DIV      (2),
        .CLKC0_ENABLE   ("ENABLE"),
        .CLKC0_DIV      (10),
        .CLKC0_CPHASE   (9),
        .CLKC0_FPHASE   (0),
        .CLKC1_ENABLE   ("ENABLE"),
        .CLKC1_DIV      (8),
        .CLKC1_CPHASE   (7),
        .CLKC1_FPHASE   (0),
        .CLKC2_ENABLE   ("ENABLE"),
        .CLKC2_DIV      (8),
        .CLKC2_CPHASE   (3),
        .CLKC2_FPHASE   (0)
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
        .fbclk     (clk_100),
        // ⚠️ clkc 的拼接顺序是 [4:0] —— **最低位在最后**。
        //    FEEDBK_PATH="CLKC0_EXT" 要求 clkc[0] 必须是反馈用的 C0，
        //    写反了会让 C0 悬空、反馈取自 C2，PLL 根本不锁（而且工具不会报错，
        //    只会表现为内存域一直复位、画面全黑 —— 极难查）。
        .clkc      ({open, open, clk_125_sft, clk_125, clk0_buf})
    );

endmodule
