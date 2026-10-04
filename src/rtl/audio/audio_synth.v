//=============================================================================
// 模块：audio_synth
// 功能：三声部波表合成器 + 每张图片独立曲目表。
//
// ★ 与例程的音频差异（三条同时成立）：
//   1. 波形：例程是方波 DDS（相位累加器只取最高位）；本模块查正弦表。
//   2. 内容：例程是写死的 8 音符 do-re-mi 循环，与图片无关；本模块有 8 条曲目，
//      由 track_sel 选择 —— 上层把 track_sel 绑到当前图片序号，就实现了赛题
//      扩展要求(2)的「音视频联动：图片切换时音频同步切换」。
//   3. 声部：例程单声部单声道（左右复用同一样本）；本模块三声部（原音 + 低八度
//      + 低两个八度）叠加，立体声左右同相输出。
//
// 曲目编码：每条曲目 64 bit = 16 步 x 4 bit。
//           4 bit 音符码：0 = 休止，1..15 = 半音序号（1 = C5，13 = C6，15 = D6）。
//           ⚠️ 早期版本音高表只写到 13，而 TRACK_2 / TRACK_5 里出现了 E(14)、F(15)，
//              这两个码当时落进 default -> lead_inc=0，而 note_on 仍为 1
//              （相位被清零）—— 听感是"这两个曲目有几步莫名其妙没声音"。
//              现已把音高表补到 15，并在 sim/tb_audio.v 里加了
//              「所有曲目的所有非零步都必须出音 + 相邻音高比必须是 2^(1/12)」的检查。
//
// 端口：
//   sample_tick  48 kHz 采样节拍
//   track_sel    曲目选择（0..7），顶层接「当前显示图片序号 + 按键偏移」
//   vol          主音量 0..8（8 = 单位增益）
//   audio_valid  样本有效，配合 48 kHz 节拍
//   audio_l/r    24 bit 有符号 PCM，直接送 HDMI 发送核
//=============================================================================
`timescale 1ns / 1ps

module audio_synth #(
    parameter SAMPLE_RATE  = 48_000,
    parameter NOTE_TICKS   = 12_000,   // 每步 0.25 s @48 kHz
    parameter TRACK_STEPS  = 16        // 每条曲目 16 步
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire        [2:0]  track_sel,
    input  wire        [3:0]  vol,
    output reg                audio_valid,
    output reg  signed [23:0] audio_l,
    output reg  signed [23:0] audio_r
);

    // ---------------------------------------------------------------- 曲目表
    // 每条 16 步 x 4 bit（低位是第 0 步）。0 = 休止。
    localparam [63:0] TRACK_0 = 64'h1234_5678_9ABC_D123;
    localparam [63:0] TRACK_1 = 64'h1358_5312_468A_8642;
    localparam [63:0] TRACK_2 = 64'h1A2B_3C4D_5E6F_7A8B;
    localparam [63:0] TRACK_3 = 64'h8642_1975_3121_2345;
    localparam [63:0] TRACK_4 = 64'h1113_1518_1A18_1513;
    localparam [63:0] TRACK_5 = 64'hABCD_EF01_2345_6789;
    localparam [63:0] TRACK_6 = 64'h159D_159D_26AE_26AE;
    localparam [63:0] TRACK_7 = 64'h1C1B_1A19_1817_1615;

    reg [63:0] track_bits;
    always @(*) begin
        case (track_sel)
            3'd0:    track_bits = TRACK_0;
            3'd1:    track_bits = TRACK_1;
            3'd2:    track_bits = TRACK_2;
            3'd3:    track_bits = TRACK_3;
            3'd4:    track_bits = TRACK_4;
            3'd5:    track_bits = TRACK_5;
            3'd6:    track_bits = TRACK_6;
            default: track_bits = TRACK_7;
        endcase
    end

    // ---------------------------------------------------------------- 步进
    // ★ 宽度必须装得下 NOTE_TICKS。早期写成 14 bit（`NOTE_TICKS[13:0]`），
    //   默认 12000 没事，但一旦把 NOTE_TICKS 调到 16383 以上（例如 24000 = 0.5 s），
    //   24000 会被**静默截断成 7616** —— 症状是节拍莫名其妙变快、包络形状被截掉一半。
    //   现在用 16 bit（NOTE_TICKS ≤ 65535，即每步最长 1.36 s）。
    //   这个 bug 是 sim/tb_audio.v 把 NOTE_TICKS 放大到 24000 提测量分辨率时抓出来的。
    localparam [15:0] NOTE_TICKS_C  = NOTE_TICKS;      // 不做位选，直接按宽度截断
    localparam [3:0]  TRACK_STEPS_M1 = TRACK_STEPS - 1;

    reg [15:0] tick_cnt;    // 0..NOTE_TICKS-1
    reg [3:0]  step_idx;    // 0..TRACK_STEPS-1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= 16'd0;
            step_idx <= 4'd0;
        end else if (sample_tick) begin
            if (tick_cnt == NOTE_TICKS_C - 16'd1) begin
                tick_cnt <= 16'd0;
                step_idx <= (step_idx == TRACK_STEPS_M1) ? 4'd0 : (step_idx + 4'd1);
            end else begin
                tick_cnt <= tick_cnt + 16'd1;
            end
        end
    end

    // 当前步的音符码（变址部分选择）
    wire [3:0] note_code = track_bits[{step_idx, 2'b00} +: 4];
    wire       note_on   = (note_code != 4'd0);

    // ---------------------------------------------------------------- 音高表
    // 相位增量 inc = f * 2^32 / 48000，基准八度 C5 = 523.251 Hz。
    // 每一条都是按该公式独立取整算出来的（不是逐级乘出来的），
    // 所以任意相邻两条的比值恒为 2^(1/12)（TB 里按 1e-6 相对误差卡）。
    reg [31:0] lead_inc;
    always @(*) begin
        case (note_code)
            4'd1:    lead_inc = 32'd46819719;   // C  523.251 Hz
            4'd2:    lead_inc = 32'd49603764;   // C# 554.365 Hz
            4'd3:    lead_inc = 32'd52553357;   // D  587.330 Hz
            4'd4:    lead_inc = 32'd55678342;   // D# 622.254 Hz
            4'd5:    lead_inc = 32'd58989149;   // E  659.255 Hz
            4'd6:    lead_inc = 32'd62496826;   // F  698.456 Hz
            4'd7:    lead_inc = 32'd66213081;   // F# 739.989 Hz
            4'd8:    lead_inc = 32'd70150316;   // G  783.991 Hz
            4'd9:    lead_inc = 32'd74321671;   // G# 830.609 Hz
            4'd10:   lead_inc = 32'd78741067;   // A  880.000 Hz
            4'd11:   lead_inc = 32'd83423255;   // A# 932.328 Hz
            4'd12:   lead_inc = 32'd88383837;   // B  987.766 Hz
            4'd13:   lead_inc = 32'd93639414;   // C6 1046.502 Hz
            4'd14:   lead_inc = 32'd99207503;   // C#6 1108.730 Hz
            4'd15:   lead_inc = 32'd105106688;  // D6 1174.659 Hz
            default: lead_inc = 32'd0;          // 0 = 休止
        endcase
    end

    // ---------------------------------------------------------------- 包络
    // 起音 2048 个样本（≈43 ms），收音 2048 个样本，中间保持满值
    wire [15:0] tail_cnt = NOTE_TICKS_C - tick_cnt;
    wire [7:0]  env_up   = tick_cnt[10:3];   // tick_cnt 0..2047 -> 0..255
    wire [7:0]  env_dn   = tail_cnt[10:3];   // tail_cnt 0..2047 -> 0..255
    wire [7:0]  env      = (tick_cnt  < 16'd2048) ? env_up :
                           (tail_cnt  < 16'd2048) ? env_dn : 8'd255;

    // ---------------------------------------------------------------- 三声部
    wire signed [23:0] s_lead;
    wire signed [23:0] s_sub1;
    wire signed [23:0] s_sub2;

    wavetable_osc u_osc_lead (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .note_on     (note_on),
        .phase_inc   (lead_inc),
        .env         (env),
        .sample      (s_lead)
    );

    wavetable_osc u_osc_sub1 (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .note_on     (note_on),
        .phase_inc   ({1'b0, lead_inc[31:1]}),   // 低八度
        .env         (env),
        .sample      (s_sub1)
    );

    wavetable_osc u_osc_sub2 (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .note_on     (note_on),
        .phase_inc   ({2'b00, lead_inc[31:2]}),  // 低两个八度
        .env         (env),
        .sample      (s_sub2)
    );

    // ---------------------------------------------------------------- 混音
    // 增益：主声部 1/1，两个低八度各 1/2。
    // 峰值上界 = 8.39M + 4.19M + 4.19M = 16.8M，需 26 bit 有符号；
    // 右移 1 位压到 24 bit 范围内，再乘主音量（0..8，8 为单位增益）。
    // 注意：必须用算术右移 >>>，不能用 sum[24:1] —— 那会把符号位一起切掉。
    wire signed [23:0] g_sub1 = s_sub1 >>> 1;
    wire signed [23:0] g_sub2 = s_sub2 >>> 1;
    wire signed [25:0] sum    = s_lead + g_sub1 + g_sub2;   // |sum| <= 16,777,213
    wire signed [23:0] mix    = sum >>> 1;                  // |mix| <= 8,388,606
    wire signed [27:0] vol_mul = mix * $signed({1'b0, vol}); // *8 <= 67,108,848
    wire signed [23:0] out_s   = vol_mul >>> 3;             // /8，回到 24 bit 范围内

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            audio_valid <= 1'b0;
            audio_l     <= 24'sd0;
            audio_r     <= 24'sd0;
        end else begin
            audio_valid <= sample_tick;
            audio_l     <= out_s;
            audio_r     <= out_s;   // 单声道复制到左右
        end
    end

endmodule
