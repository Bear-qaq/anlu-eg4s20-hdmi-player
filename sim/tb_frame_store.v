//=============================================================================
// testbench：frame_store（8 槽帧仓）
//
// 用**小帧**（16 像素 x 4 行）跑，因为帧仓的尺寸全是参数化的，
// 而 640x480 一帧要 12.3 ms 仿真时间，太慢。
//   1 行 = 16 像素 = 4 个条目 = 12 个字
//   1 槽 = 12 字 x 4 行 = 48 字
//
// SDRAM 换成行为级桩（`sdram_model`，见文件末尾）：固定读延迟 + 立即写。
// 这样加密黑盒不进仿真，帧仓的所有逻辑都能验证。
//
// 验证目标：
//   1. **打包格式**：直接检查 SDRAM 里的字，确认「4 像素 3 字、小端字节序」
//   2. **原子提交**：整幅写完那拍 slot_ready 才置位（写一半时读不到）
//   3. **行预取**：读引擎按整行突发取数，热起来之后解包器严格 1 像素/时钟
//   4. **回读正确**：写进去的像素原样读回来
//   5. **wr_vflip**：自下而上写入时，第 0 行落在内存最后一行
//   6. **双端口**：A 读当前槽、B 读上一槽
//=============================================================================
`timescale 1ns / 1ps

module tb_frame_store;

    localparam LW  = 12;    // 每行字数（16 像素）
    localparam LN  = 4;     // 行数
    localparam SW  = LW*LN; // 每槽字数 = 48
    localparam NPIX_LINE = 16;
    localparam WARM = 2*LW/3;   // 2 行的条目数

    reg clk_vid = 1'b0;
    reg clk_mem = 1'b0;
    always #20 clk_vid = ~clk_vid;      // 25 MHz
    always #4  clk_mem = ~clk_mem;      // 125 MHz

    reg rst_n = 1'b0;
    initial begin #301 rst_n = 1'b1; end

    // ---------------------------------------------------------------- DUT
    reg         wr_de;
    reg  [23:0] wr_pixel;
    reg         wr_vflip;

    reg         rd_en_a, rd_stall_a, rd_en_b, rd_stall_b;
    wire [23:0] px_a, px_b;
    wire        vld_a, vld_b;
    wire        un_a, un_b;
    wire        warm_a, warm_b;
    wire [7:0]  slot_ready;
    wire [3:0]  fs_state;

    wire        sdr_init_done, sdr_init_ref_vld, sdr_busy;
    wire        app_wr_en;
    wire [20:0] app_wr_addr;
    wire [3:0]  app_wr_dm;
    wire [31:0] app_wr_din;
    wire        app_rd_en;
    wire [20:0] app_rd_addr;
    wire        sdr_rd_en;
    wire [31:0] sdr_rd_dout;

    frame_store #(
        .N_SLOT     (8),
        .LINE_WORDS (LW),
        .LINES      (LN),
        .SLOT_WORDS (SW),
        .FIFO_AW    (9),
        .WARM_ENTS  (WARM),
        .RD_DRAIN   (5'd24)
    ) u_dut (
        .mem_clk          (clk_mem),
        .mem_rst_n        (rst_n),
        .vid_clk          (clk_vid),
        .vid_rst_n        (rst_n),
        .wr_de            (wr_de),
        .wr_pixel         (wr_pixel),
        .wr_vflip         (wr_vflip),
        .rd_a_en          (rd_en_a),
        .rd_a_stall       (rd_stall_a),
        .rd_b_en          (rd_en_b),
        .rd_b_stall       (rd_stall_b),
        .rd_a_pixel       (px_a),
        .rd_b_pixel       (px_b),
        .rd_a_valid       (vld_a),
        .rd_b_valid       (vld_b),
        .rd_a_underrun    (un_a),
        .rd_b_underrun    (un_b),
        .rd_a_warm        (warm_a),
        .rd_b_warm        (warm_b),
        .slot_ready       (slot_ready),
        .state_code       (fs_state),
        .sdr_init_done    (sdr_init_done),
        .sdr_init_ref_vld (sdr_init_ref_vld),
        .sdr_busy         (sdr_busy),
        .app_wr_en        (app_wr_en),
        .app_wr_addr      (app_wr_addr),
        .app_wr_dm        (app_wr_dm),
        .app_wr_din       (app_wr_din),
        .app_rd_en        (app_rd_en),
        .app_rd_addr      (app_rd_addr),
        .sdr_rd_en        (sdr_rd_en),
        .sdr_rd_dout      (sdr_rd_dout)
    );

    // ---------------------------------------------------------------- SDRAM 桩
    sdram_model #(.ADDR_BITS(21), .RD_LAT(8)) u_sdram (
        .clk              (clk_mem),
        .rst_n            (rst_n),
        .sdr_init_done    (sdr_init_done),
        .sdr_init_ref_vld (sdr_init_ref_vld),
        .sdr_busy         (sdr_busy),
        .app_wr_en        (app_wr_en),
        .app_wr_addr      (app_wr_addr),
        .app_wr_dm        (app_wr_dm),
        .app_wr_din       (app_wr_din),
        .app_rd_en        (app_rd_en),
        .app_rd_addr      (app_rd_addr),
        .sdr_rd_en        (sdr_rd_en),
        .sdr_rd_dout      (sdr_rd_dout)
    );

    // ---------------------------------------------------------------- 统计
    integer errors, checks, i, l, c;
    reg [23:0] exp_pix, exp_p0, exp_p1, exp_p2, got_cnt;
    reg [31:0] sd_w0, sd_row1, sd_last;
    reg [95:0] e1, e2;
    integer rd_got;
    reg [23:0] wr_hist [0:LN*NPIX_LINE-1];
    reg        saw_ready0;

    // ⚠️ 不要写 mkpix = {8'h10 + ln[7:0], ...}：对 integer 形参做位选，
    //    ModelSim 会算出错误结果（在 tb_bmp_stream_decoder 上踩过一次）。
    //    先各自算成 8 bit 局部变量再拼接才稳。
    function [23:0] mkpix;
        input integer ln, col;
        reg [7:0] r, g, b;
        begin
            r = 8'h10 + ln;
            g = 8'h20 + col;
            b = 8'h30 + ln + col;
            mkpix = {r, g, b};
        end
    endfunction

    task chk; input cond; input [8*64-1:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                if (errors <= 15) $display("  FAIL %0s", msg);
            end
        end
    endtask

    // 写侧：一行 NPIX_LINE 个像素，像素间无空隙，行间留 8 拍空隙（模拟消隐）
    // slot：本帧应当落到哪个槽 —— 必须等**本帧那个槽**的 ready 位，
    //       不能一律等 slot_ready[0]：第 2 帧之后 slot 0 一直是 1，
    //       循环会立刻退出，读到的还是没提交的半成品（踩过一次）。
    task write_frame;
        input vf;
        input integer slot;
        begin
            wr_vflip = vf;
            for (l = 0; l < LN; l = l + 1) begin
                for (c = 0; c < NPIX_LINE; c = c + 1) begin
                    @(negedge clk_vid);
                    wr_de    = 1'b1;
                    wr_pixel = mkpix(l, c);
                    @(posedge clk_vid);
                end
                @(negedge clk_vid);
                wr_de = 1'b0;
                repeat (8) @(posedge clk_vid);
            end
            // 等提交
            i = 0;
            while (!slot_ready[slot] && i < 200000) begin @(posedge clk_vid); i = i + 1; end
        end
    endtask

    // 读侧：自定拍 —— 只认 vld_a 有效的拍，凑满 NPIX_LINE 个像素再进消隐。
    // 为什么不能"死数 16 拍"：解包器冷启动时要 1~2 拍把首个条目预取进 cur，
    // 这段冒泡落在哪一行取决于开始采样时解包器的内部相位，死数拍数会少收一个像素。
    task read_frame;
        begin
            rd_got = 0;
            for (l = 0; l < LN; l = l + 1) begin
                c = 0;
                i = 0;
                while (c < NPIX_LINE && i < 2000) begin
                    @(negedge clk_vid);
                    rd_stall_a = 1'b0;
                    rd_stall_b = 1'b0;
                    @(posedge clk_vid);
                    #1;
                    if (vld_a) begin
                        exp_pix = mkpix(l, c);
                        checks  = checks + 1;
                        if (px_a !== exp_pix) begin
                            errors = errors + 1;
                            if (errors <= 15)
                                $display("  FAIL 回读像素 %0d: 期望 %06h 实得 %06h",
                                         rd_got, exp_pix, px_a);
                        end
                        rd_got = rd_got + 1;
                        c = c + 1;
                    end
                    i = i + 1;
                end
                @(negedge clk_vid);
                rd_stall_a = 1'b1;
                rd_stall_b = 1'b1;
                repeat (8) @(posedge clk_vid);
            end
            @(negedge clk_vid);
            rd_stall_a = 1'b1;
            rd_stall_b = 1'b1;
        end
    endtask

    initial begin
        errors = 0; checks = 0; rd_got = 0;
        wr_de = 0; wr_pixel = 0; wr_vflip = 0;
        rd_en_a = 1'b1; rd_stall_a = 1'b1;
        rd_en_b = 1'b1; rd_stall_b = 1'b1;

        #301 rst_n = 1'b1;
        repeat (10) @(posedge clk_vid);

        // ============ 用例 1：正常写入 + 原子提交 ============
        write_frame(1'b0, 0);
        chk(slot_ready[0] === 1'b1, "写完整幅后 slot_ready[0] 应为 1");

        // 打包格式检查：SDRAM 第 0 个字应当是 {B1, R0, G0, B0}
        //   像素 p = {R,G,B}；条目 = 4 像素 x 24bit；word0 = 条目[31:0]
        //   → [31:24]=像素1的 B，[23:16]=像素0的 R，[15:8]=像素0的 G，[7:0]=像素0的 B
        // 注意两处 ModelSim 限制：
        //   ① `u_sdram.mem[0][7:0]` 这种「层次引用 + 位选」不接受 → 先读进 reg
        //   ② `mkpix(0,0)[7:0]` 这种「函数调用结果 + 位选」也不接受 → 先存进 reg
        exp_p0  = mkpix(0,0);
        exp_p1  = mkpix(0,1);
        exp_p2  = mkpix(1,0);
        sd_w0   = u_sdram.mem[0];
        sd_row1 = u_sdram.mem[LW];
        chk(sd_w0[7:0]   === exp_p0[7:0],   "打包: word0[7:0] 应为像素0的 B");
        chk(sd_w0[15:8]  === exp_p0[15:8],  "打包: word0[15:8] 应为像素0的 G");
        chk(sd_w0[23:16] === exp_p0[23:16], "打包: word0[23:16] 应为像素0的 R");
        chk(sd_w0[31:24] === exp_p1[7:0],   "打包: word0[31:24] 应为像素1的 B");
        // 第 2 行第 0 个字应当落在 LW 偏移处
        chk(sd_row1[7:0] === exp_p2[7:0], "打包: 第 1 行首字应在 LW 偏移处");

        // ---- 二分定位：直接把第 1 行的 3 个字拼成条目，看写入侧对不对 ----
        // 若这里全过而回读错，问题在取数/解包侧；若这里就错，问题在打包/写入侧。
        e1 = {u_sdram.mem[LW+2], u_sdram.mem[LW+1], u_sdram.mem[LW]};
        chk(e1[23:0]  === mkpix(1,0), "写入侧: 行1 条目像素0");
        chk(e1[47:24] === mkpix(1,1), "写入侧: 行1 条目像素1");
        chk(e1[71:48] === mkpix(1,2), "写入侧: 行1 条目像素2");
        chk(e1[95:72] === mkpix(1,3), "写入侧: 行1 条目像素3");
        // 第 2 组的 3 个字应当紧接着
        e2 = {u_sdram.mem[LW+5], u_sdram.mem[LW+4], u_sdram.mem[LW+3]};
        chk(e2[23:0]  === mkpix(1,4), "写入侧: 行1 第2组像素0");
        chk(e2[47:24] === mkpix(1,5), "写入侧: 行1 第2组像素1");

        // ============ 用例 2：回读 ============
        // 等 warm
        i = 0;
        while (!(warm_a && warm_b) && i < 200000) begin @(posedge clk_vid); i = i + 1; end
        chk(warm_a === 1'b1, "攒够余量后 warm_a 应为 1");
        read_frame();
        chk(rd_got == LN*NPIX_LINE, "应回读 4x16 个像素");
        chk(un_a === 1'b0, "读端口 A 不应欠载");

        // ============ 用例 3：垂直翻转 ============
        // 重新写一帧，vflip=1。
        // ⚠️ 这一帧进的是**槽 1**（上一帧提交后 wr_slot 已经自增），
        //    所以地址要从 slot_base(1) = SW 起算，不能再用槽 0 的基址。
        write_frame(1'b1, 1);
        exp_p0  = mkpix(0,0);
        sd_last = u_sdram.mem[SW + (LN-1)*LW];
        // 第 0 行（像素 (0,0) 的 B）应落在槽 1 的第 LN-1 = 3 行首字
        chk(sd_last[7:0] === exp_p0[7:0],
            "vflip: 第 0 行应落在内存最后一行");

        repeat (20) @(posedge clk_vid);
        $display("---------------------------------------------");
        $display("checks : %0d", checks);
        $display("errors : %0d", errors);
        $display("slot_ready = %08b, fs_state = %0d", slot_ready, fs_state);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #80_000_000;
        $display("TIMEOUT (tb) slot_ready=%08b state=%0d rd_got=%0d", slot_ready, fs_state, rd_got);
        $display("RESULT: FAIL");
        $finish;
    end

endmodule


//=============================================================================
// 行为级 SDRAM 桩：替代加密黑盒 `sdr_as_ram` + `EG_PHY_SDRAM_2M_32`
//
// 只建模帧仓真正依赖的三件事：
//   1. 上电后过 INIT_CYC 拍拉起 sdr_init_done
//   2. 写立即生效（真实控制器有 App_wr_en 到内部阵列的延迟，但对帧仓不可见）
//   3. **读有固定延迟 RD_LAT 拍**，且支持背靠背连续读
//      —— 这一点很关键：帧仓的读引擎是按「整行突发」发命令的，
//         如果桩只支持单次读，突发逻辑根本测不出来。
//
// 存储只开 2^MEM_BITS 个字（测试帧很小，不需要 8 MB 全开，开了仿真会变慢）。
//=============================================================================
module sdram_model #(
    parameter ADDR_BITS = 21,
    parameter MEM_BITS  = 16,
    parameter RD_LAT    = 8,
    parameter INIT_CYC  = 100
)(
    input  wire                  clk,
    input  wire                  rst_n,
    output reg                   sdr_init_done,
    output wire                  sdr_init_ref_vld,
    output wire                  sdr_busy,
    input  wire                  app_wr_en,
    input  wire [ADDR_BITS-1:0]  app_wr_addr,
    input  wire [3:0]            app_wr_dm,
    input  wire [31:0]           app_wr_din,
    input  wire                  app_rd_en,
    input  wire [ADDR_BITS-1:0]  app_rd_addr,
    output wire                  sdr_rd_en,
    output wire [31:0]           sdr_rd_dout
);

    reg [31:0] mem [0:(1<<MEM_BITS)-1];

    reg [15:0] init_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_cnt      <= 16'd0;
            sdr_init_done <= 1'b0;
        end else if (init_cnt < INIT_CYC[15:0]) begin
            init_cnt      <= init_cnt + 16'd1;
            sdr_init_done <= 1'b0;
        end else begin
            sdr_init_done <= 1'b1;
        end
    end

    assign sdr_init_ref_vld = 1'b0;
    assign sdr_busy         = ~sdr_init_done;

    always @(posedge clk) begin
        if (app_wr_en) mem[app_wr_addr[MEM_BITS-1:0]] <= app_wr_din;
    end

    // 读流水线：把请求逐拍往后推 RD_LAT 拍
    reg  [RD_LAT-1:0]   vld_p;
    reg  [ADDR_BITS-1:0] addr_p [0:RD_LAT-1];
    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_p <= {RD_LAT{1'b0}};
            for (k = 0; k < RD_LAT; k = k + 1) addr_p[k] <= {ADDR_BITS{1'b0}};
        end else begin
            vld_p[0]  <= app_rd_en;
            addr_p[0] <= app_rd_addr;
            for (k = 1; k < RD_LAT; k = k + 1) begin
                vld_p[k]  <= vld_p[k-1];
                addr_p[k] <= addr_p[k-1];
            end
        end
    end

    assign sdr_rd_en   = vld_p[RD_LAT-1];
    assign sdr_rd_dout = mem[addr_p[RD_LAT-1][MEM_BITS-1:0]];

endmodule
