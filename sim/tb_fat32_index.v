//=============================================================================
// testbench：fat32_index
//
// 用一个**手工构造的 FAT32 镜像**验证目录索引逻辑。镜像放在 TB 内部的字节数组里，
// 由一个符合扇区源接口的行为模型吐出来 —— 不需要真 SD 卡、不需要加密黑盒，
// 纯逻辑可以完整仿真。
//
// 镜像布局：
//   扇区 0        : BPB（BytsPerSec=512, SecPerClus=1, Rsvd=32, NumFATs=1,
//                        RootEntCnt=0, FATSz32=8, RootClus=2）
//   扇区 32..39   : FAT（8 个扇区）
//   数据区起点    : 32 + 1*8 + 0 = 40
//   簇 2 -> 扇区 40, 簇 3 -> 41, 簇 5 -> 43, 簇 9 -> 47
//
// 用例 1（单簇根目录）：FAT[2]=EOC，根目录在扇区 40。
//   期望：2 张 BMP（要跳过 LFN 项、子目录项、TXT 项），遇到 0x00 终止。
// 用例 2（跨簇根目录链）：FAT[2]=5, FAT[5]=EOC。
//   根目录第 15 项不是终止符 -> 必须跟到簇 5（扇区 43）继续找，那里有第 2 张图。
//   这条专门验证 **FAT 链跟随**，例程完全没有这个能力。
// 用例 3（坏 BPB）：BytsPerSec=1024 -> 错误码 1。
//=============================================================================
`timescale 1ns / 1ps

module tb_fat32_index;

    localparam NSEC = 64;
    localparam NMAX = 16;

    reg clk = 1'b0;
    always #20 clk = ~clk;          // 25 MHz

    reg rst_n = 1'b0;
    initial begin #101 rst_n = 1'b1; end

    reg        start;
    wire       sec_req;
    wire [31:0] sec_addr;
    wire       src_ack;
    wire       src_byte_en;
    wire [7:0] src_byte;
    wire       src_last;

    wire [4:0]  img_count;
    wire        done;
    wire [3:0]  err_code;
    wire [3:0]  state_code;
    wire [31:0] rd_clus, rd_size;
    wire        rd_ok;
    reg  [3:0]  rd_idx;
    // 几何参数输出（本 tb 不用，但必须接上，否则 ModelSim 会报端口未连接告警）
    wire [31:0] g_data_start, g_rsvd, g_fatsz;
    wire [7:0]  g_spc;
    wire [3:0]  g_log2;

    fat32_index #(.N_MAX(NMAX)) u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .sec_req     (sec_req),
        .sec_addr    (sec_addr),
        .src_ack     (src_ack),
        .src_byte_en (src_byte_en),
        .src_byte    (src_byte),
        .src_last    (src_last),
        .img_count   (img_count),
        .done        (done),
        .err_code    (err_code),
        .state_code  (state_code),
        .rd_idx      (rd_idx),
        .rd_clus     (rd_clus),
        .rd_size     (rd_size),
        .rd_ok       (rd_ok),
        .o_data_start(g_data_start),
        .o_rsvd      (g_rsvd),
        .o_fatsz     (g_fatsz),
        .o_spc       (g_spc),
        .o_spc_log2  (g_log2)
    );

    // ---------------------------------------------------------------- 镜像
    reg [7:0] img [0:NSEC*512-1];

    // 扇区源行为模型：三段式 —— 空闲 -> 接受(打一拍 ack) -> 吐 512 字节。
    //
    // ⚠️ ack 与第一个字节之间**必须隔一拍**。DUT 在收到 ack 的那一拍把 wait_ack
    //    清掉，而清掉的生效时刻是下一拍；如果源在 ack 的同一拍就开始吐字节，
    //    第一个字节会被 DUT 丢掉，整个 BPB 往后错一位（实测现象：BytsPerSec 校验
    //    失败、错误码 1）。协议定义为「ack 之后一拍起才有字节」。
    reg [1:0]  st;              // 0=idle 1=acked 2=streaming
    reg        streaming;
    reg        src_ack_r;
    reg [31:0] latched;
    reg [9:0]  bcnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= 2'd0;
            streaming <= 1'b0;
            src_ack_r <= 1'b0;
            latched   <= 32'd0;
            bcnt      <= 10'd0;
        end else begin
            src_ack_r <= 1'b0;
            case (st)
                2'd0: begin
                    streaming <= 1'b0;
                    if (sec_req) begin
                        st        <= 2'd1;
                        src_ack_r <= 1'b1;
                        latched   <= sec_addr;
                    end
                end
                2'd1: begin
                    st        <= 2'd2;
                    streaming <= 1'b1;
                    bcnt      <= 10'd0;
                end
                default: begin
                    if (bcnt == 10'd511) begin
                        st        <= 2'd0;
                        streaming <= 1'b0;
                    end else begin
                        bcnt <= bcnt + 10'd1;
                    end
                end
            endcase
        end
    end

    assign src_ack     = src_ack_r;
    assign src_byte_en = streaming;
    assign src_byte    = img[{latched[5:0], 9'd0} + bcnt];
    assign src_last    = streaming && (bcnt == 10'd511);

    // ---------------------------------------------------------------- 镜像构造
    task wr8;
        input integer off;
        input [7:0] v;
        begin img[off] = v; end
    endtask

    task wr16;
        input integer off;
        input [15:0] v;
        begin img[off] = v[7:0]; img[off+1] = v[15:8]; end
    endtask

    task wr32;
        input integer off;
        input [31:0] v;
        begin
            img[off]   = v[7:0];
            img[off+1] = v[15:8];
            img[off+2] = v[23:16];
            img[off+3] = v[31:24];
        end
    endtask

    task build_bpb;
        input [15:0] byts;
        input [7:0]  spc;
        input [15:0] rsvd;
        input [7:0]  nfat;
        input [15:0] rootent;
        input [31:0] fatsz;
        input [31:0] rootc;
        integer i;
        begin
            for (i = 0; i < NSEC*512; i = i + 1) img[i] = 8'h00;
            wr16(11, byts);
            wr8 (13, spc);
            wr16(14, rsvd);
            wr8 (16, nfat);
            wr16(17, rootent);
            wr32(36, fatsz);
            wr32(44, rootc);
        end
    endtask

    // 写一个目录项：name 8 字符、ext 3 字符
    task set_entry;
        input integer sec;
        input integer ent;
        input [8*8-1:0] nm;
        input [8*3-1:0] ex;
        input [7:0]  attr;
        input [15:0] ch;
        input [15:0] cl;
        input [31:0] size;
        integer b;
        integer base;
        begin
            base = sec*512 + ent*32;
            for (b = 0; b < 8; b = b + 1) img[base + b]     = nm[(7-b)*8 +: 8];
            for (b = 0; b < 3; b = b + 1) img[base + 8 + b] = ex[(2-b)*8 +: 8];
            img[base + 11] = attr;
            img[base + 20] = ch[7:0];   img[base + 21] = ch[15:8];
            img[base + 26] = cl[7:0];   img[base + 27] = cl[15:8];
            wr32(base + 28, size);
        end
    endtask

    task fat_set;
        input [31:0] clus;
        input [31:0] val;
        integer off;
        begin
            off = 512*32 + clus*4;      // FAT 从扇区 32 开始
            wr32(off, val);
        end
    endtask

    // ---------------------------------------------------------------- 统计
    // 直接探 tb 内部表（只用于诊断打印）
    function [31:0] tbl_clus_dbg;
        input integer k;
        begin tbl_clus_dbg = u_dut.tbl_clus[k]; end
    endfunction
    function [31:0] tbl_size_dbg;
        input integer k;
        begin tbl_size_dbg = u_dut.tbl_size[k]; end
    endfunction

    integer errors, checks;
    integer i;

    task do_start;
        begin
            @(negedge clk); start = 1'b1;
            @(posedge clk);
            @(negedge clk); start = 1'b0;
        end
    endtask

    task wait_done;
        begin
            // ⚠️ 必须先等 done 落下去。done 在 S_DONE/S_ERR 里是**电平**而不是脉冲，
            //    上一轮结束时会一直保持高，直接等它拉高会立刻返回、读到陈旧结果。
            i = 0;
            while (done && i < 50000) begin @(posedge clk); i = i + 1; end
            i = 0;
            while (!done && i < 200000) begin @(posedge clk); i = i + 1; end
            if (!done) begin
                errors = errors + 1;
                $display("  FAIL 超时：状态机没有结束（state=%0d）", state_code);
            end
            @(posedge clk);
        end
    endtask

    task chk;
        input cond;
        input [8*60-1:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                if (errors <= 15) $display("  FAIL %0s", msg);
            end
        end
    endtask

    initial begin
        errors = 0; checks = 0;
        start = 0; rd_idx = 0;

        #101 rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ================= 用例 1：单簇根目录 =================
        build_bpb(16'd512, 8'd1, 16'd32, 8'd1, 16'd0, 32'd8, 32'd2);
        fat_set(32'd2, 32'h0FFFFFFF);
        set_entry(40, 0, "IMG1    ", "BMP", 8'h20, 16'd0, 16'd3, 32'd1000);
        set_entry(40, 1, "IMG2    ", "BMP", 8'h20, 16'd0, 16'd4, 32'd2000);
        set_entry(40, 2, "AAAAAAAA", "LFN", 8'h0F, 16'd0, 16'd0, 32'd0);   // 长文件名项，跳过
        set_entry(40, 3, "SUBDIR  ", "   ", 8'h10, 16'd0, 16'd7, 32'd0);   // 目录，跳过
        set_entry(40, 4, "NOTE    ", "TXT", 8'h20, 16'd0, 16'd8, 32'd500); // 非 BMP，跳过
        img[40*512 + 5*32] = 8'h00;                                        // 终止

        do_start();
        wait_done();

        chk(err_code === 4'd0, "用例1 err_code 应为 0");
        $display("  [diag 用例1] img_count=%0d err=%0d state=%0d t0=%0d/%0d t1=%0d/%0d",
                 img_count, err_code, state_code,
                 tbl_clus_dbg(0), tbl_size_dbg(0), tbl_clus_dbg(1), tbl_size_dbg(1));
        chk(img_count === 5'd2, "用例1 应找到 2 张 BMP");
        rd_idx = 4'd0; #1;
        chk(rd_ok === 1'b1, "用例1 表项0 应有效");
        chk(rd_clus === 32'd3, "用例1 表项0 起始簇应为 3");
        chk(rd_size === 32'd1000, "用例1 表项0 大小应为 1000");
        rd_idx = 4'd1; #1;
        chk(rd_clus === 32'd4, "用例1 表项1 起始簇应为 4");
        chk(rd_size === 32'd2000, "用例1 表项1 大小应为 2000");
        rd_idx = 4'd2; #1;
        chk(rd_ok === 1'b0, "用例1 表项2 应为空");
        rd_idx = 4'd0;

        // ================= 用例 2：跨簇根目录链 =================
        // 簇 2（扇区 40）第 15 项是有效 BMP；FAT[2]=5 -> 簇 5（扇区 43）
        build_bpb(16'd512, 8'd1, 16'd32, 8'd1, 16'd0, 32'd8, 32'd2);
        fat_set(32'd2, 32'd5);
        fat_set(32'd5, 32'h0FFFFFFF);
        for (i = 0; i < 15; i = i + 1)
            img[40*512 + i*32] = 8'hE5;                                    // 已删除项
        set_entry(40, 15, "IMG7    ", "BMP", 8'h20, 16'd0, 16'd7, 32'd7000);
        set_entry(43, 0, "IMG9    ", "BMP", 8'h20, 16'd0, 16'd9, 32'd9000);
        img[43*512 + 1*32] = 8'h00;

        do_start();
        wait_done();

        chk(err_code === 4'd0, "用例2 err_code 应为 0（跟 FAT 链）");
        $display("  [diag 用例2] img_count=%0d err=%0d state=%0d t0=%0d/%0d t1=%0d/%0d",
                 img_count, err_code, state_code,
                 tbl_clus_dbg(0), tbl_size_dbg(0), tbl_clus_dbg(1), tbl_size_dbg(1));
        chk(img_count === 5'd2, "用例2 应跨簇找到 2 张 BMP");
        rd_idx = 4'd0; #1;
        chk(rd_clus === 32'd7 && rd_size === 32'd7000, "用例2 表项0 应为 簇7/7000");
        rd_idx = 4'd1; #1;
        chk(rd_clus === 32'd9 && rd_size === 32'd9000, "用例2 表项1 应为 簇9/9000");
        rd_idx = 4'd0;

        // ================= 用例 3：坏 BPB（BytsPerSec=1024）=================
        build_bpb(16'd1024, 8'd1, 16'd32, 8'd1, 16'd0, 32'd8, 32'd2);
        do_start();
        wait_done();
        chk(err_code === 4'd1, "用例3 err_code 应为 1");

        // ================= 用例 4：SecPerClus 非 2 的幂 -> 错误码 2 =================
        build_bpb(16'd512, 8'd3, 16'd32, 8'd1, 16'd0, 32'd8, 32'd2);
        do_start();
        wait_done();
        chk(err_code === 4'd2, "用例4 err_code 应为 2");

        // ================= 用例 5：FAT 链指向空簇 -> 错误码 6 =================
        // 注意：根目录扇区必须**没有 0x00 终止项**，否则状态机在目录里就结束了，
        // 根本走不到读 FAT 那一步（第一版就是这么写的，结果错误码永远是 0）。
        build_bpb(16'd512, 8'd1, 16'd32, 8'd1, 16'd0, 32'd8, 32'd2);
        for (i = 0; i < 16; i = i + 1)
            img[40*512 + i*32] = 8'hE5;         // 全是已删除项，无终止符
        fat_set(32'd2, 32'd0);                  // 空簇，非法
        do_start();
        wait_done();
        chk(err_code === 4'd6, "用例5 err_code 应为 6");

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
        #20_000_000;
        $display("TIMEOUT (tb)");
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
