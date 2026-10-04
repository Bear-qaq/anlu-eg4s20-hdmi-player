//=============================================================================
// 模块：rgb_to_axis
// 功能：把「像素坐标 + DE + RGB888」转成 HDMI 1.4b 发送核需要的 AXI-Stream 从接口。
//
// 与例程的差异：例程用 I_vs 的跳变沿去"武装"一帧（S_frame_arm 机制），再靠内部
// x 计数器判行尾。本模块直接利用时序发生器给出的 x/y 坐标，条件更直接、更不易错。
//
// 时序说明：SOF(user) 在 (x=0, y=0) 的有效像素处拉高；每行最后一个有效像素处
//           拉高 EOF(last)。核按 HTOTAL/HACTIVE 等参数重建同步，因此 last 指的是
//           **有效像素行的最后一个**，不是整行的最后一个。
//
// 端口：
//   en        数据通路使能（0 时整帧输出黑，用于"无信号"状态）
//   x,y      来自 video_timing 的像素坐标
//   de        数据有效
//   rgb       24 bit RGB888
//   axis_user 帧首标志
//   axis_valid 数据有效
//   axis_last 行尾标志
//   axis_data 像素数据
//=============================================================================
`timescale 1ns / 1ps

module rgb_to_axis #(
    parameter H_ACTIVE = 640
)(
    input  wire        pixel_clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de,
    input  wire [23:0] rgb,
    output reg         axis_user,
    output reg         axis_valid,
    output reg         axis_last,
    output reg  [23:0] axis_data
);

    localparam [11:0] X_LAST = H_ACTIVE[11:0] - 12'd1;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            axis_user  <= 1'b0;
            axis_valid <= 1'b0;
            axis_last  <= 1'b0;
            axis_data  <= 24'h00_00_00;
        end else begin
            axis_valid <= de;
            axis_user  <= de && (x == 12'd0) && (y == 12'd0);
            axis_last  <= de && (x == X_LAST);
            axis_data  <= en ? rgb : 24'h00_00_00;
        end
    end

endmodule
