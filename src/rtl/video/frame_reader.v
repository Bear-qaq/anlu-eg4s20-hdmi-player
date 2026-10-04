//=============================================================================
// 模块：frame_reader
// 功能：帧仓读侧的像素域解包器。从 FWFT 异步 FIFO 弹出 96 bit 条目，按像素时钟
//       **连续**吐出 24 bit 像素（严格 1 像素/时钟，不允许有气泡）。
//
// 为什么不能"弹一条 -> 等一拍 -> 出 4 个像素"：
//   那样每个条目要 5 拍（4 拍输出 + 1 拍等待），像素率只有 4/5 = 80%，
//   640 像素的行会被拉长成 800 拍，时序全乱。所以必须提前预取：
//   在条目第 0 个像素那一拍就发起下一条的弹出，第 1 拍数据回来存进 nxt，
//   第 3 拍（末像素）结束时把 nxt 顶成 cur —— 正好 4 拍 4 像素，零气泡。
//
// 端口：
//   en           通路使能（0 时清状态、输出黑）
//   stall        冻结输出推进（行消隐期间用）。**预取不受 stall 影响** ——
//                消隐期正好用来把下一个条目提前拿到手，这样行首第一个有效像素
//                就能立刻出图，不会因为弹出延迟而整体错位。
//   rd_empty     FIFO 空
//   rd_data      96 bit 队首
//   rd_en        弹出脉冲
//   pixel_valid  像素有效
//   pixel        24 bit RGB888
//   underrun     要求出像素却无数据可出时置位并保持（诊断用）
//
// 为什么行消隐一定落在条目边界：一行有效像素 640 个 = 160 个条目 = 4 的整数倍，
// 所以 de 拉低时 idx 必然刚回到 0。这个前提不成立的话 stall 会截断条目。
//=============================================================================
`timescale 1ns / 1ps

module frame_reader (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire        stall,
    input  wire        rd_empty,
    input  wire [95:0] rd_data,
    output reg         rd_en,
    output reg         pixel_valid,
    output reg  [23:0] pixel,
    output reg         underrun
);

    reg [95:0] cur;         // 正在展开的条目
    reg [95:0] nxt;         // 预取到的下一条
    reg        cur_valid;
    reg        nxt_valid;
    reg [1:0]  idx;         // 0..3
    reg        popping;     // 上一拍发起了弹出，本拍 rd_data 是新条目

    wire advance = en && !stall;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur         <= 96'd0;
            nxt         <= 96'd0;
            cur_valid   <= 1'b0;
            nxt_valid   <= 1'b0;
            idx         <= 2'd0;
            popping     <= 1'b0;
            rd_en       <= 1'b0;
            pixel       <= 24'd0;
            pixel_valid <= 1'b0;
            underrun    <= 1'b0;
        end else begin
            rd_en       <= 1'b0;
            pixel_valid <= 1'b0;

            if (!en) begin
                cur_valid <= 1'b0;
                nxt_valid <= 1'b0;
                idx       <= 2'd0;
                popping   <= 1'b0;
                pixel     <= 24'd0;
            end else begin
                // ---- 1. 弹出返回，存进预取缓冲（与 stall 无关）----
                if (popping) begin
                    nxt       <= rd_data;
                    nxt_valid <= 1'b1;
                    popping   <= 1'b0;
                end

                // ---- 2. 输出推进（受 stall 冻结）----
                if (advance) begin
                    if (cur_valid) begin
                        case (idx)
                            2'd0:    pixel <= cur[23:0];
                            2'd1:    pixel <= cur[47:24];
                            2'd2:    pixel <= cur[71:48];
                            default: pixel <= cur[95:72];
                        endcase
                        pixel_valid <= 1'b1;

                        if (idx == 2'd3) begin
                            cur       <= nxt;
                            cur_valid <= nxt_valid;
                            nxt_valid <= 1'b0;
                            idx       <= 2'd0;
                        end else begin
                            idx <= idx + 2'd1;
                        end
                    end else if (nxt_valid) begin
                        cur       <= nxt;
                        cur_valid <= 1'b1;
                        nxt_valid <= 1'b0;
                        idx       <= 2'd0;
                    end
                end

                // ---- 3. 预取：条目第 0 个像素那一拍发起下一次弹出（不受 stall 影响）----
                if (!popping && !nxt_valid && !rd_empty &&
                    (cur_valid ? (idx == 2'd0) : 1'b1)) begin
                    rd_en   <= 1'b1;
                    popping <= 1'b1;
                end

                // ---- 4. 欠载诊断：只在「要求出像素」时才算 ----
                if (advance && !cur_valid && !nxt_valid && rd_empty)
                    underrun <= 1'b1;
            end
        end
    end

endmodule
