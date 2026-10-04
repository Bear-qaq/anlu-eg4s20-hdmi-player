//=============================================================================
// 模块：acr_gen
// 功能：产生 HDMI 音频时钟重建（ACR）包所需的 N / CTS 参数。
//
// ★ 与例程的差异：
//   例程 audio_arc_calculate.v 的做法是「N 固定 6144 + 每 48 个样本用像素时钟
//   数一个 1 ms 窗口」，即 CTS 是**实时测出来的**，量化误差约 ±1/25000 = ±40 ppm。
//   本模块的 CTS 是**按公式静态算出**的常量，误差为 0，并且不占计数器资源。
//
// 公式：CTS = f_pixel * N / (128 * fs)
//            = 25e6 * 6144 / (128 * 48000)
//            = 25000
//       等价换算（避免 32 bit 溢出）：CTS = f_pixel[kHz] * N / (128 * 48)
//            = 25000 * 6144 / 6144 = 25000
//
// 说明：ACR 包需要周期性发送，接收端才能持续锁定。这里沿用例程的 1 ms 周期
//       （25 MHz 下 25000 拍），但发送的是同一个静态值。
//
// 端口：
//   pixel_clk   25 MHz
//   rst_n       像素域低有效复位
//   acr_valid   高 1 拍，通知核读取 CTS/N 并发一个 ACR 包
//   acr_cts     20 bit
//   acr_n       20 bit
//=============================================================================
`timescale 1ns / 1ps

module acr_gen #(
    parameter PIXEL_CLK_KHZ = 25_000,   // 像素时钟，单位 kHz
    parameter SAMPLE_RATE   = 48_000,
    parameter ACR_N         = 6144
)(
    input  wire        pixel_clk,
    input  wire        rst_n,
    output reg         acr_valid,
    output reg  [19:0] acr_cts,
    output reg  [19:0] acr_n
);

    // 静态 CTS。用 kHz 为单位做乘除，最大值 25000*6144 = 1.536e8 < 2^31，不会溢出。
    localparam [19:0] ACR_CTS_VAL = (PIXEL_CLK_KHZ * ACR_N) / (128 * (SAMPLE_RATE / 1000));
    // 发送周期 1 ms
    localparam [19:0] PULSE_DIV   = PIXEL_CLK_KHZ;

    reg [19:0] div_cnt;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt   <= 20'd0;
            acr_valid <= 1'b0;
            acr_cts   <= 20'd0;
            acr_n     <= 20'd0;
        end else if (div_cnt == PULSE_DIV - 20'd1) begin
            div_cnt   <= 20'd0;
            acr_valid <= 1'b1;
            acr_cts   <= ACR_CTS_VAL;
            acr_n     <= ACR_N[19:0];
        end else begin
            div_cnt   <= div_cnt + 20'd1;
            acr_valid <= 1'b0;
            // valid 之外保持上次的值，避免核读到 0
        end
    end

endmodule
