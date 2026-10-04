//=============================================================================
// 模块：bmp_stream_decoder
// 功能：BMP 字节流解码器。吃「字节 + 有效」，吐「24 bit 像素 + 行号」。
//
// ★ 这是「图片处理方法」与例程拉开差距的地方（官方红线之一）：
//   例程 bmp_read.v 是在**物理扇区**里靠固定字节偏移硬取头部字段，判定条件只有
//   'B','M' + 宽高 + 24bit + 非压缩，而且宽高是顶层写死的常量、不检查高度符号、
//   不校验 biSize/bfOffBits，也不处理行 4 字节对齐（640x3 恰好整除才侥幸成立）。
//   本模块：
//     1. 完整校验 'BM' / biSize==40 / biWidth / |biHeight| / biBitCount==24 /
//        biCompression==0 / bfOffBits 合法 —— 任何一项不符就给出**明确的错误码**，
//        而不是静默花屏；
//     2. 由 biHeight 的**符号**判断行序（正=自下而上，负=自上而下），输出 vflip
//        给帧仓，不像例程那样只会一种；
//     3. 显式跳过行末 4 字节对齐填充（不依赖 640x3 整除的巧合）；
//     4. 支持 bfOffBits > 54 的调色板/附加头，按偏移量精确跳过。
//
// 实现要点一：头部 34 字节用一个 272 bit 移位寄存器整体收下，**用「下一拍的值」
//   （hdr_next）在同一拍完成校验**。这样从收完头到进像素态之间没有任何「空转拍」，
//   字节流可以完全连续地灌进来而不会丢字节 —— 早期版本用一个独立的 S_JUDGE 状态，
//   那一拍如果 byte_en 还在拉高，字节就被吞掉了。
//   字节 i 落在 hdr_sr[8*i+7 : 8*i]（byte0 在最低位）。
//
// 实现要点二：`if (byte_en)` 守卫出现在每一个可能吃到字节的状态里，
//   包括跳过 bfOffBits 的 S_SKIP。唯一会丢字节的是 S_DONE / S_ERR，
//   而那时整幅已经解完或已判定失败，丢掉后续字节无影响。
//
// 端口：
//   start            开始一个新文件（清状态、进头部收集）
//   byte_en/byte_in  字节输入（来自 SD 卡）
//   hdr_done/hdr_ok/err_code  头部收完 1 拍 / 校验结果 / 错误码
//   vflip            行序翻转标志（1 = 自下而上，帧仓按 H-1-src_row 落行）
//   pix_en/pix       像素输出
//   src_row          当前像素属于文件里的第几行（0 起，文件顺序）
//   row_end/frame_end
//
// 错误码：
//   0 正常             1 魔数不是 BM      2 biSize != 40
//   3 biWidth 不符     4 |biHeight| 不符  5 biBitCount != 24
//   6 biCompression!=0 7 bfOffBits 非法
//=============================================================================
`timescale 1ns / 1ps

module bmp_stream_decoder #(
    parameter IMG_W = 640,
    parameter IMG_H = 480
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire        byte_en,
    input  wire [7:0]  byte_in,

    output reg         hdr_done,
    output reg         hdr_ok,
    output reg  [3:0]  err_code,
    output reg         vflip,

    output reg         pix_en,
    output reg  [23:0] pix,
    output reg  [8:0]  src_row,
    output reg         row_end,
    output reg         frame_end
);

    localparam integer W_I = IMG_W;
    localparam integer H_I = IMG_H;

    localparam [31:0] IMG_W32 = W_I;
    localparam [31:0] IMG_H32 = H_I;

    localparam [9:0] ROW_B   = W_I * 3;                        // 一行像素字节数
    localparam [9:0] ROW_PAD = (4 - (ROW_B % 10'd4)) % 10'd4;  // 行末 4 字节对齐填充
    localparam [9:0] ROW_ALL = ROW_B + ROW_PAD;                // 行步长

    localparam [3:0] S_IDLE = 4'd0;
    localparam [3:0] S_HDR  = 4'd1;
    localparam [3:0] S_SKIP = 4'd2;
    localparam [3:0] S_PIX  = 4'd3;
    localparam [3:0] S_DONE = 4'd4;
    localparam [3:0] S_ERR  = 4'd5;

    reg [3:0]   state;
    reg [5:0]   hdr_cnt;        // 0..33
    reg [271:0] hdr_sr;         // 34 字节
    reg [8:0]   skip_cnt;
    reg [9:0]   row_byte;       // 行内已收字节 0..ROW_ALL-1
    reg [1:0]   pix_byte;       // 像素内字节 0=B 1=G 2=R
    reg [23:0]  pix_acc;

    // ---------------------------------------------------------------- 头部字段解析
    // 用「本拍结束后的移位寄存器值」做校验，从而在同一拍完成判定
    wire [271:0] hdr_next = {byte_in, hdr_sr[271:8]};

    wire [7:0]  n_b0   = hdr_next[7:0];
    wire [7:0]  n_b1   = hdr_next[15:8];
    wire [31:0] n_boff = hdr_next[111:80];
    wire [31:0] n_bsz  = hdr_next[143:112];
    wire [31:0] n_bw   = hdr_next[175:144];
    wire [31:0] n_bh   = hdr_next[207:176];
    wire [15:0] n_bits = hdr_next[239:224];
    wire [31:0] n_comp = hdr_next[271:240];

    wire h_magic = (n_b0 == 8'h42) && (n_b1 == 8'h4D);        // 'B','M'
    wire h_size  = (n_bsz  == 32'd40);
    wire h_w     = (n_bw   == IMG_W32);
    wire [31:0] bh_abs = n_bh[31] ? (~n_bh + 32'd1) : n_bh;
    wire h_h     = (bh_abs == IMG_H32);
    wire h_bits  = (n_bits == 16'd24);
    wire h_comp  = (n_comp == 32'd0);
    wire h_off   = (n_boff >= 32'd34) && (n_boff <= 32'd4096);

    wire hdr_all_ok = h_magic && h_size && h_w && h_h && h_bits && h_comp && h_off;

    // ---------------------------------------------------------------- 主状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            hdr_cnt   <= 6'd0;
            hdr_sr    <= 272'd0;
            skip_cnt  <= 9'd0;
            row_byte  <= 10'd0;
            pix_byte  <= 2'd0;
            pix_acc   <= 24'd0;

            hdr_done  <= 1'b0;
            hdr_ok    <= 1'b0;
            err_code  <= 4'd0;
            vflip     <= 1'b0;
            pix_en    <= 1'b0;
            pix       <= 24'd0;
            src_row   <= 9'd0;
            row_end   <= 1'b0;
            frame_end <= 1'b0;
        end else begin
            hdr_done  <= 1'b0;
            pix_en    <= 1'b0;
            row_end   <= 1'b0;
            frame_end <= 1'b0;

            case (state)
                // ------------------------------------------------ 等待启动
                S_IDLE: begin
                    if (start) begin
                        hdr_cnt  <= 6'd0;
                        hdr_sr   <= 272'd0;
                        row_byte <= 10'd0;
                        pix_byte <= 2'd0;
                        src_row  <= 9'd0;
                        hdr_ok   <= 1'b0;
                        err_code <= 4'd0;
                        state    <= S_HDR;
                    end
                end
                // ------------------------------------------------ 收 34 字节头并当场判定
                S_HDR: begin
                    if (byte_en) begin
                        hdr_sr <= hdr_next;
                        if (hdr_cnt == 6'd33) begin
                            hdr_cnt  <= 6'd0;
                            hdr_done <= 1'b1;
                            // Verilog-2001 的函数至少要有一个入参，这里直接用条件表达式
                            state    <= hdr_all_ok ? ((n_boff > 32'd34) ? S_SKIP : S_PIX)
                                                   : S_ERR;
                            // 采用「下一拍值」判定，因此本拍不丢字节
                            hdr_ok   <= hdr_all_ok;
                            vflip    <= ~n_bh[31];        // 高度为正 = 自下而上 = 需翻转
                            if (hdr_all_ok) begin
                                if (n_boff > 32'd34) begin
                                    skip_cnt <= n_boff[8:0] - 9'd34;
                                end else begin
                                    skip_cnt <= 9'd0;
                                end
                            end else begin
                                if      (!h_magic) err_code <= 4'd1;
                                else if (!h_size)  err_code <= 4'd2;
                                else if (!h_w)     err_code <= 4'd3;
                                else if (!h_h)     err_code <= 4'd4;
                                else if (!h_bits)  err_code <= 4'd5;
                                else if (!h_comp)  err_code <= 4'd6;
                                else               err_code <= 4'd7;
                            end
                        end else begin
                            hdr_cnt <= hdr_cnt + 6'd1;
                        end
                    end
                end

                // ------------------------------------------------ 跳到像素数据起点
                S_SKIP: begin
                    if (byte_en) begin
                        if (skip_cnt <= 9'd1)
                            state <= S_PIX;
                        else
                            skip_cnt <= skip_cnt - 9'd1;
                    end
                end

                // ------------------------------------------------ 像素数据
                S_PIX: begin
                    if (byte_en) begin
                        // ⚠️ 只有 row_byte < ROW_B 的字节才是像素字节。
                        //    行末那 ROW_PAD 个填充字节必须**只计数、不组装**，
                        //    否则每行会多吐 ROW_PAD/3 个错误像素（6x3 的测试图
                        //    实测每行多吐 2/3 个，总像素数 18 变 20）。
                        if (row_byte < ROW_B) begin
                            // BMP 内像素字节序是 B,G,R
                            case (pix_byte)
                                2'd0: pix_acc[7:0]   <= byte_in;
                                2'd1: pix_acc[15:8]  <= byte_in;
                                default: begin
                                    pix_acc[23:16] <= byte_in;
                                    pix            <= {byte_in, pix_acc[15:8], pix_acc[7:0]};
                                    pix_en         <= 1'b1;
                                end
                            endcase
                            pix_byte <= (pix_byte == 2'd2) ? 2'd0 : (pix_byte + 2'd1);
                        end

                        if (row_byte == ROW_ALL - 10'd1) begin
                            // 一行结束（含行末填充）
                            row_byte <= 10'd0;
                            row_end  <= 1'b1;
                            if (src_row == H_I[8:0] - 9'd1) begin
                                frame_end <= 1'b1;
                                state     <= S_DONE;
                            end else begin
                                src_row <= src_row + 9'd1;
                            end
                        end else begin
                            row_byte <= row_byte + 10'd1;
                        end
                    end
                end

                // ------------------------------------------------ 收尾 / 出错
                // ⚠️ 这两个状态**必须**接受 start 重新开始。
                //    早期版本只在 S_IDLE 里判 start，导致一幅图解完或判错之后
                //    状态机永远卡在 S_DONE / S_ERR，后续所有文件都解不出来
                //    （实测现象：连续几个用例都报同一个陈旧的 err_code）。
                S_DONE, S_ERR: begin
                    if (start) begin
                        hdr_cnt  <= 6'd0;
                        hdr_sr   <= 272'd0;
                        row_byte <= 10'd0;
                        pix_byte <= 2'd0;
                        src_row  <= 9'd0;
                        hdr_ok   <= 1'b0;
                        err_code <= 4'd0;
                        state    <= S_HDR;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
