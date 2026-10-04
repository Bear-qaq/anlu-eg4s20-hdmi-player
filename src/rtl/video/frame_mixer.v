//=============================================================================
// 模块：frame_mixer
// 功能：双读端口混合器。用帧仓的两个独立读端口同时取两帧，按像素混合输出。
//
// ★ 这是例程**结构上做不到**的一件事，也是本设计坚持要 8 槽帧仓的原因：
//   淡入淡出/滑动切换都要求「同一时刻两帧都可读」。例程是 BUF0/BUF1 乒乓 +
//   单读端口（rfifo 只有一条），内存里虽然有两块，但读通道只有一条，
//   要在同一像素时钟里取两个像素根本不可能。
//
// 四种模式（mode）：
//   0 MODE_A    ：只出 A（直通）
//   1 MODE_B    ：只出 B（直通，用于对比/调试）
//   2 MODE_FADE ：淡入淡出，alpha 0->255 表示 A->B
//                 out = A + (((B - A) * alpha) >> 8)
//                 用「加上差值」而不是「两路加权求和」，好处是 alpha=0 时**逐位等于 A**，
//                 不会有加权求和的 ±1 舍入误差导致静止画面出现噪点。
//   3 MODE_SLIDE：滑动切换，A 在左、B 在右，交界处 16 像素线性过渡（软边）
//
// 端口：
//   en        通路使能
//   mode      0..3
//   alpha     MODE_FADE 用，0=全 A，255=全 B
//   slide_pos MODE_SLIDE 用，交界中心列号
//   pix_a/b   两路 24 bit RGB888
//   pix_out   混合结果
//
// 时序说明：本模块是**纯组合 + 输出寄存**，一拍延迟。调用方必须保证 pix_a/pix_b
//           与 x 同拍对齐（本例由 top 统一延迟 de/x/y 实现）。
//=============================================================================
`timescale 1ns / 1ps

module frame_mixer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire [1:0]  mode,
    input  wire [7:0]  alpha,
    input  wire [11:0] slide_pos,
    input  wire [11:0] x,
    input  wire [23:0] pix_a,
    input  wire [23:0] pix_b,
    output reg  [23:0] pix_out
);

    localparam [1:0] MODE_A     = 2'd0;
    localparam [1:0] MODE_B     = 2'd1;
    localparam [1:0] MODE_FADE  = 2'd2;
    localparam [1:0] MODE_SLIDE = 2'd3;

    // ---------------------------------------------------------------- 淡入淡出
    // 逐通道：out = a + (((b - a) * alpha) >>> 8)，**两端点做精确特判**。
    //
    // 为什么必须特判：alpha 只有 8 bit，最大 255，而 255/256 != 1。
    // 不做特判的话 alpha=255 会输出 a + (b-a)*255/256，比 b 少 1 个 LSB
    // （实测 R 通道 0xAA 变成 0xA9）。后果是：过渡结束、切回直通模式的瞬间
    // 整幅画面会跳 1 个灰阶，肉眼在纯色区域能看出来。
    // 特判之后 alpha=0 逐位等于 A、alpha=255 逐位等于 B，过渡首尾无跳变。
    function [7:0] fade_ch;
        input [7:0] a;
        input [7:0] b;
        input [7:0] al;
        reg signed [8:0]  d;
        reg signed [17:0] p;
        reg signed [9:0]  s;
        begin
            if (al == 8'd0)
                fade_ch = a;
            else if (al == 8'd255)
                fade_ch = b;
            else begin
                d = {1'b0, b} - {1'b0, a};          // -255..255
                p = d * $signed({1'b0, al});        // -65025..65025
                s = {1'b0, a} + (p >>> 8);          // 加回 A
                if (s[9])          fade_ch = 8'd0;  // 下溢钳位
                else if (s > 10'sd255) fade_ch = 8'd255;
                else               fade_ch = s[7:0];
            end
        end
    endfunction

    wire [23:0] fade_rgb = {fade_ch(pix_a[23:16], pix_b[23:16], alpha),
                            fade_ch(pix_a[15:8],  pix_b[15:8],  alpha),
                            fade_ch(pix_a[7:0],   pix_b[7:0],   alpha)};

    // ---------------------------------------------------------------- 滑动切换
    // 交界处 16 像素线性过渡，避免硬边割裂感。
    // 注意：这里刻意不用有符号减法 —— 负数的位运算在 Verilog 里容易写错，
    // 改成「先饱和减法再比较」的纯无符号形式。
    wire [11:0] xp = x + 12'd8;                              // 把交界左移 8 像素
    wire [11:0] d1 = (xp > slide_pos) ? (xp - slide_pos) : 12'd0;
    wire [7:0]  a_slide = (d1 >= 12'd16) ? 8'd255 : {d1[3:0], 4'b0000};

    wire [23:0] slide_rgb = {fade_ch(pix_a[23:16], pix_b[23:16], a_slide),
                             fade_ch(pix_a[15:8],  pix_b[15:8],  a_slide),
                             fade_ch(pix_a[7:0],   pix_b[7:0],   a_slide)};

    // ---------------------------------------------------------------- 输出
    reg [23:0] mix_rgb;
    always @(*) begin
        case (mode)
            MODE_A:     mix_rgb = pix_a;
            MODE_B:     mix_rgb = pix_b;
            MODE_FADE:  mix_rgb = fade_rgb;
            MODE_SLIDE: mix_rgb = slide_rgb;
            default:    mix_rgb = pix_a;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pix_out <= 24'h00_00_00;
        else
            pix_out <= en ? mix_rgb : 24'h00_00_00;
    end

endmodule
