//=============================================================================
// 模块：sdram_ctrl
// 功能：片内 SDRAM 控制器包装层。
//
// 为什么要自己写一层而不是直接用例程的 SD/sdram.v：
//   例程那个文件里有一句 `include "../user_source/hdl_source/include/global_def.v"`，
//   该路径是按「工程目录」解析的，一旦工程目录变了就找不到文件（本工程实测踩过）。
//   本包装层把端口位宽直接写成常量（21/32/4 由 global_def.v 的宏值确认），
//   不依赖任何 include，构建位置可以随便挪。
//
// 端口说明：
//   clk        125 MHz 用户接口时钟
//   clk_sft    125 MHz 相移 180°，给控制器内部的 SDRAM 输出寄存器用
//   rst        高有效异步复位（沿用黑盒原有约定）
//   App_*      用户读写接口；读数据在 Sdr_rd_en 有效那一拍出现在 Sdr_rd_dout
//   Sdr_init_done / Sdr_init_ref_vld / Sdr_busy  控制器状态
//
// 器件侧的 SDRAM 是封装内的 EG_PHY_SDRAM_2M_32，不是外部颗粒。
//=============================================================================
`timescale 1ns / 1ps

module sdram_ctrl (
    input  wire        clk,
    input  wire        clk_sft,
    input  wire        rst,

    output wire        sdr_init_done,
    output wire        sdr_init_ref_vld,
    output wire        sdr_busy,

    input  wire        app_wr_en,
    input  wire [20:0] app_wr_addr,
    input  wire [3:0]  app_wr_dm,
    input  wire [31:0] app_wr_din,

    input  wire        app_rd_en,
    input  wire [20:0] app_rd_addr,
    output wire        sdr_rd_en,
    output wire [31:0] sdr_rd_dout
);

    wire        sdram_clk;
    wire        sdr_ras;
    wire        sdr_cas;
    wire        sdr_we;
    wire [1:0]  sdr_ba;
    wire [10:0] sdr_addr;
    wire [31:0] sdr_dq;
    wire [3:0]  sdr_dm;

    // 加密黑盒：初始化 + 自刷新 + 读写调度
    sdr_as_ram #(
        .self_refresh_open (1'b1)
    ) u_ram (
        .Sdr_clk           (clk),
        .Sdr_clk_sft       (clk_sft),
        .Rst               (rst),

        .Sdr_init_done     (sdr_init_done),
        .Sdr_init_ref_vld  (sdr_init_ref_vld),
        .Sdr_busy          (sdr_busy),

        .App_ref_req       (1'b0),

        .App_wr_en         (app_wr_en),
        .App_wr_addr       (app_wr_addr),
        .App_wr_dm         (app_wr_dm),
        .App_wr_din        (app_wr_din),

        .App_rd_en         (app_rd_en),
        .App_rd_addr       (app_rd_addr),
        .Sdr_rd_en         (sdr_rd_en),
        .Sdr_rd_dout       (sdr_rd_dout),

        .SDRAM_CLK         (sdram_clk),
        .SDR_RAS           (sdr_ras),
        .SDR_CAS           (sdr_cas),
        .SDR_WE            (sdr_we),
        .SDR_BA            (sdr_ba),
        .SDR_ADDR          (sdr_addr),
        .SDR_DM            (sdr_dm),
        .SDR_DQ            (sdr_dq)
    );

    // 封装内 SDRAM 原语
    EG_PHY_SDRAM_2M_32 u_sdram (
        .clk   (sdram_clk),
        .ras_n (sdr_ras),
        .cas_n (sdr_cas),
        .we_n  (sdr_we),
        .addr  (sdr_addr[10:0]),
        .ba    (sdr_ba),
        .dq    (sdr_dq),
        .cs_n  (1'b0),
        .dm0   (sdr_dm[0]),
        .dm1   (sdr_dm[1]),
        .dm2   (sdr_dm[2]),
        .dm3   (sdr_dm[3]),
        .cke   (1'b1)
    );

endmodule
