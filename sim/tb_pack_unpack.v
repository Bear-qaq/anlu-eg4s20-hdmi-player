//=============================================================================
// testbench：pixel_packer + async_fifo(双向) + frame_reader 全环回
//
// 验证目标：
//   1. 打包格式正确：4 像素 = 3 字，小端字节序，R/G/B 位置不错
//   2. 异步 FIFO 跨时钟（25 MHz <-> 125 MHz，5:1）不丢数、不重复、首字不悬空
//   3. frame_reader 严格 1 像素/时钟，连续一整行零气泡
//   4. 读出侧有整行余量时能扛住内存侧的反压
//
// ⚠️ 这个 TB 第一次跑是 FAIL 的，原因很有价值，记在这里：
//    解包器的消费速率与打包器的生产速率**同为 1 个条目/4 像素时钟**。
//    如果一有数据就开始读，FIFO 里永远只有 1 个条目，任何抖动都会立刻欠载。
//    所以真实设计里 frame_store 必须**先攒满一整行（160 个条目）再放行显示**。
//    本 TB 用 warm 计数器复刻这个行为 —— 这也是 frame_store 的 warm-up 逻辑原型。
//=============================================================================
`timescale 1ns / 1ps

module tb_pack_unpack;

    // ---------------------------------------------------------------- 时钟
    reg clk_vid = 1'b0;      // 25 MHz  -> 40 ns
    reg clk_mem = 1'b0;      // 125 MHz -> 8 ns
    always #20 clk_vid = ~clk_vid;
    always #4  clk_mem = ~clk_mem;

    reg rst_n = 1'b0;
    initial begin
        #301 rst_n = 1'b1;
    end

    localparam NPIX  = 640;
    localparam NENT  = NPIX / 4;      // 160 个条目/行

    // 统计量（提前声明：解包器的使能门控与诊断都要用）
    integer i;
    integer got;
    integer errors;
    integer gaps;
    reg     prev_valid;

    // ---------------------------------------------------------------- 像素源
    reg        pix_en;
    reg [23:0] pix;
    wire       ent_en;
    wire [95:0] ent;

    pixel_packer u_pack (
        .clk      (clk_vid),
        .rst_n    (rst_n),
        .pix_en   (pix_en),
        .pix      (pix),
        .flush    (1'b0),
        .entry_en (ent_en),
        .entry    (ent)
    );

    // ---------------------------------------------------------------- FIFO1：写 25M / 读 125M
    wire        f1_full;
    wire [95:0] f1_dout;
    wire        f1_empty;
    wire        f1_rd_en;

    async_fifo #(.DATA_WIDTH(96), .ADDR_WIDTH(9)) u_f1 (
        .wr_clk   (clk_vid),
        .wr_rst_n (rst_n),
        .wr_en    (ent_en),
        .wr_data  (ent),
        .wr_full  (f1_full),
        .rd_clk   (clk_mem),
        .rd_rst_n (rst_n),
        .rd_en    (f1_rd_en),
        .rd_data  (f1_dout),
        .rd_empty (f1_empty)
    );

    // ---------------------------------------------------------------- 内存侧搬运（模拟帧仓）
    wire f2_full;              // 提前声明：f1_rd_en 要用到（Verilog-2001 先声明后使用）

    // 人为反压：每搬 40 个条目停 200 个 125M 周期（= 8 个条目时间）
    reg [9:0]  stall_cnt;
    reg [15:0] moved;
    always @(posedge clk_mem or negedge rst_n) begin
        if (!rst_n) begin
            stall_cnt <= 10'd0;
            moved     <= 16'd0;
        end else if (f1_rd_en) begin
            moved <= moved + 16'd1;
            if (moved[5:0] == 6'd39 && stall_cnt == 10'd0) stall_cnt <= 10'd200;
            else if (stall_cnt != 10'd0)                stall_cnt <= stall_cnt - 10'd1;
        end else if (stall_cnt != 10'd0) begin
            stall_cnt <= stall_cnt - 10'd1;
        end
    end
    wire mem_paused = (stall_cnt != 10'd0);

    // FWFT 下 rd_en 当拍 rd_data 就是被弹出的条目，寄存一拍转发给 FIFO2
    assign f1_rd_en = ~f1_empty & ~f2_full & ~mem_paused;

    reg         f2_wr_en;
    reg  [95:0] f2_din;
    always @(posedge clk_mem or negedge rst_n) begin
        if (!rst_n) begin
            f2_wr_en <= 1'b0;
            f2_din   <= 96'd0;
        end else begin
            f2_wr_en <= f1_rd_en;
            f2_din   <= f1_dout;
        end
    end

    // 内存侧记录已转发条目数，攒够一整行才放行显示
    reg [15:0] fwd_cnt;
    always @(posedge clk_mem or negedge rst_n) begin
        if (!rst_n) fwd_cnt <= 16'd0;
        else if (f2_wr_en) fwd_cnt <= fwd_cnt + 16'd1;
    end
    reg warm_m;
    always @(posedge clk_mem or negedge rst_n) begin
        if (!rst_n) warm_m <= 1'b0;
        else if (fwd_cnt >= NENT[15:0]) warm_m <= 1'b1;
    end

    // 同步到像素域
    reg [2:0] warm_s;
    always @(posedge clk_vid or negedge rst_n) begin
        if (!rst_n) warm_s <= 3'b000;
        else        warm_s <= {warm_s[1:0], warm_m};
    end
    wire warm = warm_s[2];

    // ---------------------------------------------------------------- FIFO2：写 125M / 读 25M
    wire        f2_empty;
    wire [95:0] f2_dout;
    wire        f2_rd_en;

    async_fifo #(.DATA_WIDTH(96), .ADDR_WIDTH(9)) u_f2 (
        .wr_clk   (clk_mem),
        .wr_rst_n (rst_n),
        .wr_en    (f2_wr_en),
        .wr_data  (f2_din),
        .wr_full  (f2_full),
        .rd_clk   (clk_vid),
        .rd_rst_n (rst_n),
        .rd_en    (f2_rd_en),
        .rd_data  (f2_dout),
        .rd_empty (f2_empty)
    );

    // ---------------------------------------------------------------- 解包
    wire        px_valid;
    wire [23:0] px_out;
    wire        underrun;

    // 使能只在"还需要像素"期间拉高。
    // 理由：真实设计里帧仓的行预取是**连续循环**的，FIFO 不会合法地变空，
    // 所以"使能期间却无数据"就等价于真欠载。而本 TB 只喂一行，喂完就没了，
    // 不收使能的话尾部的正常排空会被误报成欠载。
    wire reader_en = warm && (got < NPIX);

    // 诊断：欠载首次拉高的时刻与已收像素数
    // 注意 underrun_d 必须给初值，否则仿真初期是 X，`!underrun_d` 也是 X，
    // 边沿检测会漏掉第一次跳变。
    reg underrun_d = 1'b0;
    reg underrun_mid;          // 「要求出像素期间真的断过数据」——这才是要判失败的东西
    always @(posedge clk_vid) begin
        if (!rst_n) begin
            underrun_d   <= 1'b0;
            underrun_mid <= 1'b0;
        end else begin
            underrun_d <= underrun;
            if (reader_en && underrun) underrun_mid <= 1'b1;
            if (underrun && !underrun_d)
                $display("  underrun asserted @%0t, got=%0d, en=%0b", $time, got, reader_en);
        end
    end

    frame_reader u_reader (
        .clk         (clk_vid),
        .rst_n       (rst_n),
        .en          (reader_en),
        .stall       (1'b0),          // 本 TB 不模拟行消隐，全程推进
        .rd_empty    (f2_empty),
        .rd_data     (f2_dout),
        .rd_en       (f2_rd_en),
        .pixel_valid (px_valid),
        .pixel       (px_out),
        .underrun    (underrun)
    );

    // ---------------------------------------------------------------- 激励与比对
    function [23:0] exp_pix;
        input integer n;
        begin
            exp_pix = {8'hA0 + n[7:0], 8'h50 + n[7:0], 8'h10 + n[7:0]};
        end
    endfunction

    initial begin
        pix_en     = 1'b0;
        pix        = 24'd0;
        got        = 0;
        errors     = 0;
        gaps       = 0;
        prev_valid = 1'b0;

        @(posedge rst_n);
        repeat (10) @(posedge clk_vid);

        // 送一整行 640 个像素（pix_en 与 pix 同时生效）
        for (i = 0; i < NPIX; i = i + 1) begin
            pix_en <= 1'b1;
            pix    <= exp_pix(i);
            @(posedge clk_vid);
        end
        pix_en <= 1'b0;

        wait (got == NPIX);
        repeat (40) @(posedge clk_vid);

        $display("---------------------------------------------");
        $display("received pixels : %0d / %0d", got, NPIX);
        $display("gaps between px : %0d   (must be 0)", gaps);
        $display("content errors  : %0d", errors);
        $display("underrun (mid)  : %0d   (must be 0, 尾部正常排空不算)", underrun_mid);
        if (got == NPIX && errors == 0 && gaps == 0 && underrun_mid === 1'b0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $display("---------------------------------------------");
        $finish;
    end

    always @(posedge clk_vid) begin
        if (rst_n) begin
            if (px_valid && got < NPIX) begin
                if (!(prev_valid === 1'b1 || got == 0)) gaps = gaps + 1;
                if (px_out !== exp_pix(got)) begin
                    if (errors < 8)
                        $display("  [%0d] expect %06h got %06h @%0t", got, exp_pix(got), px_out, $time);
                    errors = errors + 1;
                end
                got = got + 1;
            end
            prev_valid <= px_valid;
        end
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT: got=%0d errors=%0d", got, errors);
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
