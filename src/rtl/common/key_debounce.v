//=============================================================================
// 模块：key_debounce
// 功能：按键消抖 + 短按/长按区分。低有效按键输入。
//
// 与例程的差异：例程 sd_card_bmp.v 里的 key_press_debounce 只输出一个
// press_pulse，两个按键各只能干一件事（下一张 / 轮播开关）。本模块额外给出
// long_pulse，于是同样两个按键可以承载「切换特效」「切换轮播周期」等第二组功能
// —— 这是在**不新增引脚**的前提下满足赛题扩展要求(3)的关键。
//
// 端口：
//   key_n        低有效按键输入（异步）
//   press_pulse  短按：释放时若未达长按阈值，输出 1 拍
//   long_pulse   长按：按住达到阈值时输出 1 拍（之后不再重复，直到释放）
//
// 时序说明：输入先过两级同步器；稳定电平需连续保持 DEBOUNCE_CYCLES 拍才被承认。
//           长按阈值 LONG_CYCLES 从「按下被确认」开始计。
//=============================================================================
`timescale 1ns / 1ps

module key_debounce #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter DEBOUNCE_MS = 20,
    parameter LONG_MS     = 1000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,
    output reg  press_pulse,
    output reg  long_pulse
);

    localparam [19:0] DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    localparam [26:0] LONG_CYCLES     = (CLK_FREQ_HZ / 1000) * LONG_MS;

    // 两级同步器
    reg [2:0] key_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            key_sync <= 3'b111;
        else
            key_sync <= {key_sync[1:0], key_n};
    end

    // 消抖计数
    reg [19:0] db_cnt;
    reg        key_stable;    // 消抖后的稳定电平，1 = 松开

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            db_cnt     <= 20'd0;
            key_stable <= 1'b1;
        end else if (key_sync[2] == key_stable) begin
            db_cnt <= 20'd0;
        end else if (db_cnt == DEBOUNCE_CYCLES) begin
            db_cnt     <= 20'd0;
            key_stable <= key_sync[2];
        end else begin
            db_cnt <= db_cnt + 20'd1;
        end
    end

    // 长按计时与脉冲输出
    reg [26:0] hold_cnt;
    reg        long_fired;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_cnt    <= 27'd0;
            long_fired  <= 1'b0;
            press_pulse <= 1'b0;
            long_pulse  <= 1'b0;
        end else if (!key_stable) begin
            // 按住中
            press_pulse <= 1'b0;
            if (!long_fired) begin
                if (hold_cnt == LONG_CYCLES) begin
                    hold_cnt   <= hold_cnt;      // 到顶停住
                    long_fired <= 1'b1;
                    long_pulse <= 1'b1;
                end else begin
                    hold_cnt   <= hold_cnt + 27'd1;
                    long_pulse <= 1'b0;
                end
            end else begin
                long_pulse <= 1'b0;
            end
        end else begin
            // 已松开
            hold_cnt   <= 27'd0;
            long_pulse <= 1'b0;
            if (long_fired) begin
                long_fired  <= 1'b0;
                press_pulse <= 1'b0;    // 长按已经触发过，释放时不再给短按
            end else if (hold_cnt != 27'd0) begin
                press_pulse <= 1'b1;
            end else begin
                press_pulse <= 1'b0;
            end
        end
    end

endmodule
