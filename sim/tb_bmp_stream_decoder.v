//=============================================================================
// testbench：bmp_stream_decoder
//
// 用**小尺寸图**（6x3）而不是 640x480：解码逻辑与尺寸无关，但 6x3 的
// 一行是 18 字节、4 字节对齐后要填 2 个字节 —— 正好把「行末填充」这条
// 最容易写错的路径覆盖到（640x3=1920 恰好整除，反而测不出填充 bug）。
// 填充字节刻意填成 8'hEE：如果解码器没正确跳过，像素流会整体错位，比对必然失败。
//
// 验证目标：
//   1. 头部字段按小端正确解析
//   2. BGR -> RGB 字节序正确
//   3. 行末 4 字节对齐填充被正确跳过
//   4. biHeight 为正 -> vflip=1；为负 -> vflip=0
//   5. bfOffBits > 54 时能正确跳过附加头
//   6. 各类非法头都能给出**正确的错误码**而不是静默通过
//   7. 字节流连续灌入（中间不留空拍）也不丢字节
//=============================================================================
`timescale 1ns / 1ps

module tb_bmp_stream_decoder;

    localparam W = 6;
    localparam H = 3;

    reg clk = 1'b0;
    always #20 clk = ~clk;          // 25 MHz

    reg        rst_n = 1'b0;
    reg        start;
    reg        byte_en;
    reg  [7:0] byte_in;

    wire        hdr_done, hdr_ok, vflip, pix_en, row_end, frame_end;
    wire [3:0]  err_code;
    wire [23:0] pix;
    wire [8:0]  src_row;

    bmp_stream_decoder #(.IMG_W(W), .IMG_H(H)) u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .byte_en   (byte_en),
        .byte_in   (byte_in),
        .hdr_done  (hdr_done),
        .hdr_ok    (hdr_ok),
        .err_code  (err_code),
        .vflip     (vflip),
        .pix_en    (pix_en),
        .pix       (pix),
        .src_row   (src_row),
        .row_end   (row_end),
        .frame_end (frame_end)
    );

    // 文件缓冲：54 字节头 + 3 行 x 20 字节（18 像素 + 2 填充）
    reg [7:0] fbuf [0:255];
    integer   flen;

    integer errors, checks, got, i;
    integer exp_r, exp_c;
    reg [23:0] exp_pix;

    // 期望像素：R=10+r*8+c, G=40+r*8+c, B=70+r*8+c
    // ⚠️ 三个分量**必须先各自截成 8 bit 再拼接**。
    //    写成 { (10+r*8+c), (40+r*8+c), (70+r*8+c) } 是错的：未指定宽度的表达式
    //    按 32 bit 处理，拼成 96 bit 再赋给 24 bit 返回值时只留下最低 24 位，
    //    也就是只剩最后一个分量 —— 实测返回 0x000046 而不是 0x0A2846。
    function [23:0] mk_pix;
        input integer r;
        input integer c;
        reg [7:0] rr, gg, bb;
        begin
            rr = 10 + r*8 + c;
            gg = 40 + r*8 + c;
            bb = 70 + r*8 + c;
            mk_pix = {rr, gg, bb};
        end
    endfunction

    // 头部结果与 frame_end 都是单拍脉冲，feed() 返回后再查就没了，必须就地锁存
    reg        cap_hdr_done, cap_hdr_ok, cap_vflip, cap_frame_end;
    reg [3:0]  cap_err;
    always @(posedge clk) begin
        if (hdr_done) begin
            cap_hdr_done <= 1'b1;
            cap_hdr_ok   <= hdr_ok;
            cap_vflip    <= vflip;
            cap_err      <= err_code;
        end
        if (frame_end) cap_frame_end <= 1'b1;
    end

    task wr32;
        input integer off;
        input [31:0] v;
        begin
            fbuf[off]   = v[7:0];
            fbuf[off+1] = v[15:8];
            fbuf[off+2] = v[23:16];
            fbuf[off+3] = v[31:24];
        end
    endtask

    task wr16;
        input integer off;
        input [15:0] v;
        begin
            fbuf[off]   = v[7:0];
            fbuf[off+1] = v[15:8];
        end
    endtask

    // 构造 BMP：h_off = 像素数据偏移，bh = biHeight（有符号）
    task build_bmp;
        input integer h_off;
        input integer bh;
        integer r, c, base, p;
        begin
            for (i = 0; i < 256; i = i + 1) fbuf[i] = 8'h00;
            fbuf[0] = 8'h42; fbuf[1] = 8'h4D;              // 'BM'
            wr32(10, h_off);                                // bfOffBits
            wr32(14, 40);                                   // biSize
            wr32(18, W);                                    // biWidth
            wr32(22, bh);                                   // biHeight
            wr16(26, 1);                                    // biPlanes
            wr16(28, 24);                                   // biBitCount
            wr32(30, 0);                                    // biCompression
            // 像素数据
            for (r = 0; r < H; r = r + 1) begin
                base = h_off + r * 20;
                for (c = 0; c < W; c = c + 1) begin
                    p = base + c * 3;
                    fbuf[p]   = 8'd70 + r*8 + c;   // B
                    fbuf[p+1] = 8'd40 + r*8 + c;   // G
                    fbuf[p+2] = 8'd10 + r*8 + c;   // R
                end
                fbuf[base + 18] = 8'hEE;           // 行末填充，必须被跳过
                fbuf[base + 19] = 8'hEE;
            end
            flen = h_off + H * 20;
            // bfSize
            wr32(2, flen);
        end
    endtask

    // 连续灌入一个文件（不留空拍），并收集像素
    task feed;
        input integer len;
        begin
            got = 0;
            for (i = 0; i < len; i = i + 1) begin
                @(negedge clk);
                byte_en = 1'b1;
                byte_in = fbuf[i];
                @(posedge clk);
                #1;
                if (pix_en) begin
                    exp_r   = got / W;
                    exp_c   = got % W;
                    exp_pix = mk_pix(exp_r, exp_c);
                    checks  = checks + 1;
                    if (pix !== exp_pix) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("  FAIL pixel %0d (row %0d col %0d): expect %06h got %06h",
                                     got, exp_r, exp_c, exp_pix, pix);
                    end
                    if (src_row !== exp_r[8:0]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("  FAIL pixel %0d: src_row expect %0d got %0d",
                                     got, exp_r, src_row);
                    end
                    got = got + 1;
                end
            end
            @(negedge clk);
            byte_en = 1'b0;
            repeat (6) @(posedge clk);
        end
    endtask

    task do_start;
        begin
            cap_hdr_done = 1'b0;
            cap_hdr_ok   = 1'b0;
            cap_vflip    = 1'b0;
            cap_frame_end= 1'b0;
            cap_err      = 4'd0;
            @(negedge clk); start = 1'b1;
            @(posedge clk);
            @(negedge clk); start = 1'b0;
        end
    endtask

    initial begin
        errors = 0; checks = 0; got = 0;
        start = 0; byte_en = 0; byte_in = 0;

        #101 rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ============ 用例 1：标准 24bit 自下而上（biHeight 正） ============
        build_bmp(54, H);
        do_start();
        fork
            feed(flen);
        join
        checks = checks + 1;
        if (!(cap_hdr_ok === 1'b1)) begin errors = errors + 1; $display("  FAIL 用例1 hdr_ok 应为 1"); end
        checks = checks + 1;
        if (!(cap_vflip === 1'b1))  begin errors = errors + 1; $display("  FAIL 用例1 vflip 应为 1"); end
        checks = checks + 1;
        if (!(cap_frame_end === 1'b1)) begin errors = errors + 1; $display("  FAIL 用例1 frame_end 未拉高"); end
        checks = checks + 1;
        if (got != W*H) begin errors = errors + 1; $display("  FAIL 用例1 像素数 %0d 应为 %0d", got, W*H); end

        // ============ 用例 2：自上而下（biHeight 负） ============
        build_bmp(54, -H);
        do_start();
        feed(flen);
        checks = checks + 1;
        if (!(cap_hdr_ok === 1'b1)) begin errors = errors + 1; $display("  FAIL 用例2 hdr_ok 应为 1"); end
        checks = checks + 1;
        if (cap_vflip !== 1'b0)     begin errors = errors + 1; $display("  FAIL 用例2 vflip 应为 0"); end

        // ============ 用例 3：bfOffBits=70（多 16 字节附加头） ============
        build_bmp(70, H);
        do_start();
        feed(flen);
        checks = checks + 1;
        if (!(cap_hdr_ok === 1'b1)) begin errors = errors + 1; $display("  FAIL 用例3 hdr_ok 应为 1"); end
        checks = checks + 1;
        if (got != W*H) begin errors = errors + 1; $display("  FAIL 用例3 像素数 %0d 应为 %0d", got, W*H); end

        // ============ 用例 4：biBitCount=8 -> 错误码 5 ============
        build_bmp(54, H);
        wr16(28, 8);
        do_start();
        feed(flen);
        checks = checks + 1;
        if (cap_hdr_ok !== 1'b0)   begin errors = errors + 1; $display("  FAIL 用例4 hdr_ok 应为 0"); end
        checks = checks + 1;
        if (cap_err !== 4'd5)      begin errors = errors + 1; $display("  FAIL 用例4 err_code 应为 5，实得 %0d", cap_err); end

        // ============ 用例 5：魔数错 -> 错误码 1 ============
        build_bmp(54, H);
        fbuf[1] = 8'h58;                     // 'X'
        do_start();
        feed(flen);
        checks = checks + 1;
        if (cap_err !== 4'd1)      begin errors = errors + 1; $display("  FAIL 用例5 err_code 应为 1，实得 %0d", cap_err); end

        // ============ 用例 6：压缩方式非 0 -> 错误码 6 ============
        build_bmp(54, H);
        wr32(30, 1);
        do_start();
        feed(flen);
        checks = checks + 1;
        if (cap_err !== 4'd6)      begin errors = errors + 1; $display("  FAIL 用例6 err_code 应为 6，实得 %0d", cap_err); end

        // ============ 用例 7：width 不符 -> 错误码 3 ============
        build_bmp(54, H);
        wr32(18, 8);
        do_start();
        feed(flen);
        checks = checks + 1;
        if (cap_err !== 4'd3)      begin errors = errors + 1; $display("  FAIL 用例7 err_code 应为 3，实得 %0d", cap_err); end

        repeat (10) @(posedge clk);
        $display("---------------------------------------------");
        $display("checks : %0d", checks);
        $display("errors : %0d", errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT");
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
