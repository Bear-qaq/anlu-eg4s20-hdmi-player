//=============================================================================
// 模块：pixel_packer
// 功能：把 4 个 24 bit 像素打包成 1 个 96 bit「条目」，供帧仓按 4 像素/3 字存储。
//
// 打包格式（这是与例程最直接的存储差异）：
//   例程：1 像素占 1 个完整 32 bit 字，低 8 位恒 0 丢弃 —— 容量与带宽各浪费 25%。
//   本设计：一行 640 像素 = 1920 字节 = 480 个 32 bit 字，4 像素恰好 12 字节 = 3 字。
//           字节流按小端装字：word[w] = 字节 4w..4w+3，字节 4w 在 bit[7:0]。
//           条目 entry[e] = {word[3e+2], word[3e+1], word[3e]}，覆盖像素 4e..4e+3。
//           像素 4e+k 在条目里的位置：data[24k+7:24k]=R, [24k+15:24k+8]=G, [24k+23:24k+16]=B
//
// 因为 640*3 = 1920 能被 4 整除，**每行边界天然字对齐**，不需要行末补零。
//
// 端口：
//   clk, rst_n     源时钟域（本例为像素域 25 MHz）
//   pix_en         像素有效
//   pix            24 bit RGB888
//   entry_en       打包满 4 个像素时拉高 1 拍，此时 entry 有效
//   entry          96 bit 条目
//   flush          强制把不足 4 个像素的余数补零后输出（换图时用）
//=============================================================================
`timescale 1ns / 1ps

module pixel_packer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        pix_en,
    input  wire [23:0] pix,
    input  wire        flush,
    output reg         entry_en,
    output reg  [95:0] entry
);

    reg [1:0]  pix_idx;    // 0..3
    reg [95:0] acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_idx  <= 2'd0;
            acc      <= 96'd0;
            entry    <= 96'd0;
            entry_en <= 1'b0;
        end else if (pix_en) begin
            // 把 24 bit 像素放到它在条目里的位置
            case (pix_idx)
                2'd0:    acc[23:0]   <= pix;
                2'd1:    acc[47:24]  <= pix;
                2'd2:    acc[71:48]  <= pix;
                default: acc[95:72]  <= pix;
            endcase

            if (pix_idx == 2'd3) begin
                // 第 4 个像素：连同本拍数据一起输出
                entry[23:0]   <= acc[23:0];
                entry[47:24]  <= acc[47:24];
                entry[71:48]  <= acc[71:48];
                entry[95:72]  <= pix;
                entry_en      <= 1'b1;
                pix_idx       <= 2'd0;
            end else begin
                entry_en <= 1'b0;
                pix_idx  <= pix_idx + 2'd1;
            end
        end else if (flush) begin
            entry    <= acc;
            entry_en <= 1'b1;
            pix_idx  <= 2'd0;
        end else begin
            entry_en <= 1'b0;
        end
    end

endmodule
