//=============================================================================
// testbench：media_loader（媒体层端到端）
//
// 把整条媒体链跑通：FAT32 镜像 --> 目录索引 --> 按簇链读文件 --> BMP 解码 --> 像素流。
// 镜像里放一张**真的小 BMP**（6x3、24bit、自下而上、带行末填充），
// 所以这个 tb 同时覆盖了 FAT32 定位、簇链跟随、文件字节流、BMP 头解析、
// BGR->RGB、行末填充跳过、行序翻转标志。
//
// 镜像布局（在 tb_fat32_index 的构造方式上扩展）：
//   扇区 0      : BPB（512/1簇/保留32/1个FAT/根目录项0/FATSz32=8/根簇2）
//   扇区 32..39 : FAT
//   扇区 40     : 根目录（簇 2）—— 1 个 BMP 目录项 + 0x00 终止
//   扇区 48     : 文件数据（簇 10）—— 114 字节的 6x3 BMP
//   FAT[2]=EOC, FAT[10]=EOC
//=============================================================================
`timescale 1ns / 1ps

module tb_media_loader;

    localparam NSEC = 64;
    localparam W = 6;
    localparam H = 3;

    reg clk = 1'b0;
    always #20 clk = ~clk;              // 25 MHz

    reg rst_n = 1'b0;
    initial begin #101 rst_n = 1'b1; end

    reg  start;
    wire sec_req;
    wire [31:0] sec_addr;
    wire src_ack;
    wire src_byte_en;
    wire [7:0] src_byte;
    wire src_last;

    wire        pix_en;
    wire [23:0] pix;
    wire        pix_vflip;
    wire        pix_row_end;
    wire        img_done;
    wire [2:0]  load_slot;
    wire [4:0]  img_count;
    wire [7:0]  img_loaded;
    wire [3:0]  err_code;
    wire [3:0]  state_code;

    media_loader #(.N_MAX(16), .IMG_W(W), .IMG_H(H)) u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .sec_req     (sec_req),
        .sec_addr    (sec_addr),
        .src_ack     (src_ack),
        .src_byte_en (src_byte_en),
        .src_byte    (src_byte),
        .src_last    (src_last),
        .pix_en      (pix_en),
        .pix         (pix),
        .pix_vflip   (pix_vflip),
        .pix_row_end (pix_row_end),
        .img_done    (img_done),
        .load_slot   (load_slot),
        .img_count   (img_count),
        .img_loaded  (img_loaded),
        .err_code    (err_code),
        .state_code  (state_code)
    );

    // ---------------------------------------------------------------- 镜像
    reg [7:0] img [0:NSEC*512-1];

    // 扇区源行为模型（与 tb_fat32_index 同一套协议：ack 之后一拍才吐字节）
    reg [1:0]  st;
    reg        streaming, src_ack_r;
    reg [31:0] latched;
    reg [9:0]  bcnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 2'd0; streaming <= 1'b0; src_ack_r <= 1'b0; latched <= 32'd0; bcnt <= 10'd0;
        end else begin
            src_ack_r <= 1'b0;
            case (st)
                2'd0: begin
                    streaming <= 1'b0;
                    if (sec_req) begin
                        st <= 2'd1; src_ack_r <= 1'b1; latched <= sec_addr;
                    end
                end
                2'd1: begin
                    st <= 2'd2; streaming <= 1'b1; bcnt <= 10'd0;
                end
                default: begin
                    if (bcnt == 10'd511) begin st <= 2'd0; streaming <= 1'b0; end
                    else                 bcnt <= bcnt + 10'd1;
                end
            endcase
        end
    end

    assign src_ack     = src_ack_r;
    assign src_byte_en = streaming;
    assign src_byte    = img[{latched[5:0], 9'd0} + bcnt];
    assign src_last    = streaming && (bcnt == 10'd511);

    // ---------------------------------------------------------------- 镜像构造
    task wr8;  input integer o; input [7:0]  v; begin img[o] = v; end endtask
    task wr16; input integer o; input [15:0] v; begin img[o]=v[7:0]; img[o+1]=v[15:8]; end endtask
    task wr32; input integer o; input [31:0] v;
        begin img[o]=v[7:0]; img[o+1]=v[15:8]; img[o+2]=v[23:16]; img[o+3]=v[31:24]; end
    endtask

    task build_bpb;
        integer i;
        begin
            for (i = 0; i < NSEC*512; i = i + 1) img[i] = 8'h00;
            wr16(11, 16'd512);
            wr8 (13, 8'd1);
            wr16(14, 16'd32);
            wr8 (16, 8'd1);
            wr16(17, 16'd0);
            wr32(36, 32'd8);
            wr32(44, 32'd2);
        end
    endtask

    task set_entry;
        input integer sec, ent;
        input [8*8-1:0] nm;
        input [8*3-1:0] ex;
        input [7:0] attr;
        input [15:0] ch, cl;
        input [31:0] size;
        integer b, base;
        begin
            base = sec*512 + ent*32;
            for (b = 0; b < 8; b = b + 1) img[base + b]     = nm[(7-b)*8 +: 8];
            for (b = 0; b < 3; b = b + 1) img[base + 8 + b] = ex[(2-b)*8 +: 8];
            img[base + 11] = attr;
            img[base + 20] = ch[7:0];  img[base + 21] = ch[15:8];
            img[base + 26] = cl[7:0];  img[base + 27] = cl[15:8];
            wr32(base + 28, size);
        end
    endtask

    task fat_set; input [31:0] c; input [31:0] v; begin wr32(512*32 + c*4, v); end endtask

    // 在扇区 sec 的偏移 off 处放一张 WxH 的 24bit 自下而上 BMP，返回文件长度
    integer fbuf_base;
    integer flen;
    task build_bmp_at;
        input integer sec;
        input integer off;
        integer r, c, p;
        begin
            fbuf_base = sec*512 + off;
            img[fbuf_base + 0] = 8'h42;   // 'B'
            img[fbuf_base + 1] = 8'h4D;   // 'M'
            wr32(fbuf_base + 2,  32'd114);        // bfSize
            wr32(fbuf_base + 10, 32'd54);         // bfOffBits
            wr32(fbuf_base + 14, 32'd40);         // biSize
            wr32(fbuf_base + 18, W);              // biWidth
            wr32(fbuf_base + 22, H);              // biHeight 正 -> 自下而上
            wr16(fbuf_base + 26, 16'd1);          // biPlanes
            wr16(fbuf_base + 28, 16'd24);         // biBitCount
            wr32(fbuf_base + 30, 32'd0);          // biCompression
            for (r = 0; r < H; r = r + 1) begin
                for (c = 0; c < W; c = c + 1) begin
                    p = fbuf_base + 54 + r*20 + c*3;
                    img[p]   = 8'd70 + r*8 + c;   // B
                    img[p+1] = 8'd40 + r*8 + c;   // G
                    img[p+2] = 8'd10 + r*8 + c;   // R
                end
                img[fbuf_base + 54 + r*20 + 18] = 8'hEE;   // 行末填充
                img[fbuf_base + 54 + r*20 + 19] = 8'hEE;
            end
            flen = 114;
        end
    endtask

    // ---------------------------------------------------------------- 统计
    integer errors, checks, got, i;
    integer exp_r, exp_c;
    reg [23:0] exp_pix;
    reg        saw_vflip_high, saw_img_done;

    function [23:0] mk_pix;
        input integer r, c;
        reg [7:0] rr, gg, bb;
        begin
            rr = 10 + r*8 + c;
            gg = 40 + r*8 + c;
            bb = 70 + r*8 + c;
            mk_pix = {rr, gg, bb};
        end
    endfunction

    task chk; input cond; input [8*60-1:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                if (errors <= 12) $display("  FAIL %0s", msg);
            end
        end
    endtask

    // 采集像素 + 锁存脉冲
    always @(posedge clk) begin
        if (rst_n) begin
            if (pix_en) begin
                exp_r = got / W;
                exp_c = got % W;
                exp_pix = mk_pix(exp_r, exp_c);
                checks = checks + 1;
                if (pix !== exp_pix) begin
                    errors = errors + 1;
                    if (errors <= 12)
                        $display("  FAIL pixel %0d (row %0d col %0d): expect %06h got %06h",
                                 got, exp_r, exp_c, exp_pix, pix);
                end
                got = got + 1;
            end
            if (pix_vflip) saw_vflip_high = 1'b1;
            if (img_done)  saw_img_done   = 1'b1;
        end
    end

    initial begin
        errors = 0; checks = 0; got = 0;
        start = 0;
        saw_vflip_high = 1'b0;
        saw_img_done   = 1'b0;

        #101 rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ---- 构造镜像 ----
        build_bpb();
        fat_set(32'd2,  32'h0FFFFFFF);       // 根目录单簇
        fat_set(32'd10, 32'h0FFFFFFF);       // 文件单簇
        build_bmp_at(48, 0);                 // 文件在簇 10 -> 扇区 40+(10-2)=48
        set_entry(40, 0, "IMG1    ", "BMP", 8'h20, 16'd0, 16'd10, 32'd114);
        img[40*512 + 32] = 8'h00;            // 目录终止

        // ---- 启动 ----
        @(negedge clk); start = 1'b1;
        @(posedge clk);
        @(negedge clk); start = 1'b0;

        // ---- 等结束 ----
        i = 0;
        while (!(state_code == 4'd7 || state_code == 4'd8) && i < 400000) begin
            @(posedge clk); i = i + 1;
        end
        repeat (20) @(posedge clk);

        $display("  [diag] state=%0d err=%0d img_count=%0d loaded=%0d pixels=%0d",
                 state_code, err_code, img_count, img_loaded, got);

        chk(err_code === 4'd0,    "err_code 应为 0");
        chk(img_count === 5'd1,   "应找到 1 张 BMP");
        chk(got == W*H,           "应输出 18 个像素");
        chk(saw_vflip_high,       "自下而上 BMP 的 vflip 应为 1");
        chk(saw_img_done,         "img_done 应拉高过");
        chk(img_loaded == 8'd1,   "loaded 应为 1");

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
        #40_000_000;
        $display("TIMEOUT (tb) state=%0d err=%0d", state_code, err_code);
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
