//=============================================================================
// 模块：video_timing
// 功能：640x480@60 显示时序发生器，输出数据有效标志与像素坐标。
//
// 与例程的差异：例程用 color_bar.v 兼职当时序发生器（video_timing_data.v 只
// 例化 color_bar，RGB 输出悬空），而且额外产生 hs/vs 送给后面的流水线。本模块
// 把坐标 x/y 直接暴露出来 —— 这是后续「按坐标混合两帧」「缩略图带」「滑动切换」
// 的前提，例程的整帧 FIFO 直通结构拿不到坐标。
//
// 注意：加密的 HDMI 1.4b 发送核会根据 HTOTAL/HSA/HFP/HBP 与 VTOTAL/VSA/VFP/VBP
//       参数自己重建 H/V 同步，只从 AXIS 取像素。因此本模块的时序参数必须与
//       核的例化参数严格一致，否则画面会错位。
//
// 行内布局（h_cnt 0..799）：  [0,95] 同步  [96,143] 后肩  [144,783] 有效  [784,799] 前肩
// 场内布局（v_cnt 0..524）：  [0,1] 同步   [2,34] 后肩    [35,514] 有效   [515,524] 前肩
//
// 端口：
//   pixel_clk    像素时钟 25 MHz
//   rst_n        像素域低有效复位
//   x,y          当前像素的有效区坐标（de 无效时保持末值，仅供调试观察）
//   de           数据有效
//   hs_n,vs_n    行/场同步，低有效
//   frame_start  每帧第一个有效像素处拉高 1 拍
//=============================================================================
`timescale 1ns / 1ps

module video_timing #(
    parameter H_ACTIVE = 640,
    parameter H_FP     = 16,
    parameter H_SYNC   = 96,
    parameter H_BP     = 48,
    parameter V_ACTIVE = 480,
    parameter V_FP     = 10,
    parameter V_SYNC   = 2,
    parameter V_BP     = 33
)(
    input  wire        pixel_clk,
    input  wire        rst_n,
    output reg  [11:0] x,
    output reg  [11:0] y,
    output reg         de,
    output reg         hs_n,
    output reg         vs_n,
    output reg         frame_start
);

    localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;              // 800
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;              // 525
    localparam H_ACT_BEG = H_SYNC + H_BP;                              // 144
    localparam H_ACT_END = H_SYNC + H_BP + H_ACTIVE;                   // 784
    localparam V_ACT_BEG = V_SYNC + V_BP;                              // 35
    localparam V_ACT_END = V_SYNC + V_BP + V_ACTIVE;                   // 515

    reg [11:0] h_cnt;
    reg [11:0] v_cnt;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 12'd0;
            v_cnt <= 12'd0;
        end else if (h_cnt == H_TOTAL[11:0] - 12'd1) begin
            h_cnt <= 12'd0;
            if (v_cnt == V_TOTAL[11:0] - 12'd1)
                v_cnt <= 12'd0;
            else
                v_cnt <= v_cnt + 12'd1;
        end else begin
            h_cnt <= h_cnt + 12'd1;
        end
    end

    // 组合译码，全部寄存器输出
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            x           <= 12'd0;
            y           <= 12'd0;
            de          <= 1'b0;
            hs_n        <= 1'b1;
            vs_n        <= 1'b1;
            frame_start <= 1'b0;
        end else begin
            de   <= (h_cnt >= H_ACT_BEG[11:0]) && (h_cnt < H_ACT_END[11:0]) &&
                    (v_cnt >= V_ACT_BEG[11:0]) && (v_cnt < V_ACT_END[11:0]);
            hs_n <= ~(h_cnt < H_SYNC[11:0]);
            vs_n <= ~(v_cnt < V_SYNC[11:0]);

            if (de) begin
                x <= h_cnt - H_ACT_BEG[11:0];
                y <= v_cnt - V_ACT_BEG[11:0];
            end else begin
                x <= 12'd0;
                y <= 12'd0;
            end

            frame_start <= de && (h_cnt == H_ACT_BEG[11:0]) && (v_cnt == V_ACT_BEG[11:0]);
        end
    end

endmodule
