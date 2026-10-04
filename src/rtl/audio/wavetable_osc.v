//=============================================================================
// 模块：wavetable_osc
// 功能：波表振荡器。32 点四分之一正弦查表 + 象限折叠，输出 24 bit 有符号样本。
//
// ★ 与例程的音频差异：例程 hdmi_audio_tone_i2s_64fs 是"方波 DDS"——32 bit 相位
//   累加器只取最高位定符号，没有波形表，谐波极丰富、音色刺耳。本模块查正弦表，
//   并且把相位与包络分开，便于多声部混音。
//
// 相位格式：32 bit，高 8 位当"整周角度"（0..255 = 0..360°）。
//           每象限 64 个角度单位 -> 表索引 = pos[5:1]（0..31）。
//   quad[1:0] = angle[7:6]：
//     0: 0..90°    取表 idx，正号
//     1: 90..180°  取表 31-idx，正号（sin(90+x) = sin(90-x)）
//     2: 180..270° 取表 idx，负号
//     3: 270..360° 取表 31-idx，负号
//
// 端口：
//   sample_tick  48 kHz 采样节拍，只有该拍才推进相位、更新输出
//   note_on      0 = 休止：相位清零、输出 0（从零交叉起音，无爆音）
//   phase_inc    相位增量，决定音高（inc = f * 2^32 / 48000）
//   env          包络 0..255
//   sample       24 bit 有符号输出，满幅 ±8388607
//=============================================================================
`timescale 1ns / 1ps

module wavetable_osc (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               note_on,
    input  wire        [31:0] phase_inc,
    input  wire        [7:0]  env,
    output reg  signed [23:0] sample
);

    reg [31:0] phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 32'd0;
        end else if (sample_tick) begin
            if (note_on)
                phase <= phase + phase_inc;
            else
                phase <= 32'd0;
        end
    end

    wire [7:0] angle = note_on ? phase[31:24] : 8'h00;
    wire [1:0] quad  = angle[7:6];
    wire [5:0] pos   = angle[5:0];

    // 折到四分之一周期
    wire [4:0] lut_addr = quad[0] ? (5'd31 - pos[5:1]) : pos[5:1];

    // 32 点四分之一正弦，幅度 2^23-1 = 8388607
    reg [22:0] lut;
    always @(*) begin
        case (lut_addr)
            5'd0:  lut = 23'd0;
            5'd1:  lut = 23'd411609;
            5'd2:  lut = 23'd822227;
            5'd3:  lut = 23'd1230864;
            5'd4:  lut = 23'd1636536;
            5'd5:  lut = 23'd2038265;
            5'd6:  lut = 23'd2435084;
            5'd7:  lut = 23'd2826037;
            5'd8:  lut = 23'd3210181;
            5'd9:  lut = 23'd3586592;
            5'd10: lut = 23'd3954362;
            5'd11: lut = 23'd4312606;
            5'd12: lut = 23'd4660460;
            5'd13: lut = 23'd4997087;
            5'd14: lut = 23'd5321676;
            5'd15: lut = 23'd5633444;
            5'd16: lut = 23'd5931641;
            5'd17: lut = 23'd6215548;
            5'd18: lut = 23'd6484481;
            5'd19: lut = 23'd6737792;
            5'd20: lut = 23'd6974872;
            5'd21: lut = 23'd7195148;
            5'd22: lut = 23'd7398091;
            5'd23: lut = 23'd7583211;
            5'd24: lut = 23'd7750062;
            5'd25: lut = 23'd7898243;
            5'd26: lut = 23'd8027396;
            5'd27: lut = 23'd8137211;
            5'd28: lut = 23'd8227422;
            5'd29: lut = 23'd8297813;
            5'd30: lut = 23'd8348214;
            default: lut = 23'd8378503;
        endcase
    end

    // 象限 1、2 为负半周
    wire signed [23:0] lut_s = quad[1] ? -$signed({1'b0, lut}) : $signed({1'b0, lut});

    // 包络：env 取高 5 位当增益（0..31），除以 32
    wire        [4:0]  env5  = env[7:3];
    wire signed [28:0] prod  = lut_s * $signed({1'b0, env5});
    wire signed [23:0] scaled = (prod >>> 5);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sample <= 24'sd0;
        else if (sample_tick)
            sample <= note_on ? scaled : 24'sd0;
    end

endmodule
