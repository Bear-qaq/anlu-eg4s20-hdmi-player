//=============================================================================
// 模块：effect_ctrl
// 功能：切换特效控制。产生 frame_mixer 需要的 alpha / slide_pos 扫描值，
//       并管理特效模式与一次切换的进程。
//
// 设计意图：
//   「切换特效」在别的实现里往往需要一个专门的过渡状态机去协调帧仓换槽。
//   本设计不需要 —— 因为帧仓是 8 槽的，两帧本来就同时可读（读端口 A 取当前帧、
//   读端口 B 取上一帧），所以特效退化成**纯粹的输出级扫描**：
//   只要把 alpha 从 0 扫到 255，画面自然就是淡入淡出。
//   这也是为什么帧仓槽数和双读端口值得做。
//
// 端口：
//   start      一次切换开始（上升沿触发扫描）
//   mode       0=直通(只出A) 1=只出B 2=淡入淡出 3=滑动
//   busy       扫描进行中
//   alpha      0..255，扫完后停在 255
//   slide_pos  0..640，扫完后停在 640
//
// 时序说明：扫描步长 STEP_DIV 个像素时钟加一格。25 MHz 下 STEP_DIV=32768
//           ≈ 1.3 ms/格 x 256 格 ≈ 0.34 s，肉眼舒适的过渡时长。
//=============================================================================
`timescale 1ns / 1ps

module effect_ctrl #(
    parameter STEP_DIV = 16'd32768,
    parameter H_ACTIVE = 640
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [1:0]  mode,
    output reg         busy,
    output reg  [7:0]  alpha,
    output reg  [11:0] slide_pos
);

    reg [15:0] div_cnt;
    reg        start_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt   <= 16'd0;
            start_d   <= 1'b0;
            busy      <= 1'b0;
            alpha     <= 8'd255;
            slide_pos <= H_ACTIVE[11:0];
        end else begin
            start_d <= start;

            if (start && !start_d) begin
                // 一次新的切换：把扫描值复位到起点
                busy      <= 1'b1;
                alpha     <= 8'd0;
                slide_pos <= 12'd0;
                div_cnt   <= 16'd0;
            end else if (busy) begin
                if (div_cnt >= STEP_DIV) begin
                    div_cnt <= 16'd0;
                    if (alpha != 8'd255)     alpha     <= alpha + 8'd1;
                    if (slide_pos < H_ACTIVE[11:0]) slide_pos <= slide_pos + 12'd1;
                    if (alpha == 8'd255 && slide_pos >= H_ACTIVE[11:0])
                        busy <= 1'b0;
                end else begin
                    div_cnt <= div_cnt + 16'd1;
                end
            end
        end
    end

endmodule
