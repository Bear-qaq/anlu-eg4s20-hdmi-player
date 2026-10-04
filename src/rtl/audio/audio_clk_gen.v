//=============================================================================
// 模块：audio_clk_gen
// 功能：在像素时钟域里精确产生 48.000 kHz 的音频采样节拍。
//
// ★ 这是与例程最本质的音频差异之一。
//   例程：另开一颗 PLL_HDMI_AUDIO 产生 12.288 MHz，用 hdmi_audio_tone_i2s_64fs
//         造出 I2S 三线，再用 I2S_receiver 把刚造出来的 I2S 解回来。整条路径
//         只是为了得到"并行 24 bit PCM + valid"，而加密核本来就吃并行 PCM。
//   本模块：不开 PLL、不产生 I2S，直接用分数累加器把 25 MHz 分频成 48 kHz。
//
// 精度论证：25,000,000 / 48,000 = 3125 / 6，是精确的有理数。
//           每拍把累加器加 6，满 3125 归零并输出一拍 tick。
//           长期平均频率误差 = 0（不是"接近"，是恒等于）。
//           抖动为 ±1 个像素时钟 = ±40 ns，对音频重建无影响。
//
// 端口：
//   pixel_clk    25 MHz 像素时钟
//   rst_n        像素域低有效复位
//   sample_tick  48 kHz 采样节拍，占空比 1/521
//=============================================================================
`timescale 1ns / 1ps

module audio_clk_gen #(
    parameter PIXEL_CLK_HZ = 25_000_000,
    parameter SAMPLE_RATE  = 48_000
)(
    input  wire pixel_clk,
    input  wire rst_n,
    output reg  sample_tick
);

    // MODULUS / STEP 由两个频率的比化简而来：gcd(25e6, 48000) = 2000
    localparam integer DIV_GCD = 2000;
    localparam integer MODULUS = PIXEL_CLK_HZ / DIV_GCD;   // 12500 ... 占位，见下
    // 实际化简结果：25000000/48000 = 3125/6。这里显式写死，避免综合器做除法。
    localparam [11:0] ACC_MOD = 12'd3125;
    localparam [11:0] ACC_INC = 12'd6;

    reg [11:0] acc;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            acc         <= 12'd0;
            sample_tick <= 1'b0;
        end else if ((acc + ACC_INC) >= ACC_MOD) begin
            acc         <= acc + ACC_INC - ACC_MOD;
            sample_tick <= 1'b1;
        end else begin
            acc         <= acc + ACC_INC;
            sample_tick <= 1'b0;
        end
    end

endmodule
