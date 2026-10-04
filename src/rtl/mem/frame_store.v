//=============================================================================
// 模块：frame_store
// 功能：N 槽帧仓。本设计「缓存层」的核心，替代例程的 BUF0/BUF1 乒乓结构。
//
// ★ 与例程 frame_read_write 的差异（逐条，都是结构性的）：
//   1. **8 个槽轮转**，不是 2 个。例程只有 write_buf_idx/disp_buf_idx 两个索引，
//      内存里同时只存得下 2 张图，切图必须重新从 SD 卡读一遍。
//   2. **整幅写完才单拍原子置位 READY**（slot_ready 位图）。显示侧只认 READY，
//      所以「看到半帧」在结构上不可能 —— 不是靠切换时机侥幸避开。
//   3. **显示优先仲裁**：读突发优先于写。例程是读写互锁（写侧条件含 ~App_rd_busy、
//      读侧含 ~App_wr_busy），没有优先级，显示带宽没有保障。
//   4. **双读端口 A/B**，各自独立的行预取通道与 FIFO。这是淡入淡出/滑动切换的
//      硬件前提 —— 混合两帧要求两帧同时可读，例程的乒乓结构做不到。
//   5. **24bpp 打包存储**（4 像素 3 字），例程 1 像素 1 字、低 8 位恒 0 丢弃。
//   6. **欠载上报**：读侧断流置 underrun 并给状态码，例程静默重复像素。
//
// 槽容量（字地址）：
//   1 行 = 640 像素 x 3 字节 = 1920 字节 = 480 字
//   1 槽 = 480 字 x 480 行 = 230400 字
//   8 槽 = 1843200 字；SDRAM 共 2097152 字，余 253952 字（约 0.97 MB）
//
// 时序契约（写侧源必须满足）：
//   按光栅顺序连续送 640x480 个像素，每行 640 个、共 480 行。
//   640/4 = 160 整除，所以行边界天然落在条目边界上，不需要行末补齐。
//
// SDRAM 控制器在本模块**外面**（放在 top 里），本模块只暴露 App_* / Sdr_* 接口，
// 这样配一个行为级 SDRAM 桩就能在 ModelSim 里独立仿真（见 sim/tb_frame_store.v）。
//=============================================================================
`timescale 1ns / 1ps

module frame_store #(
    parameter N_SLOT     = 8,
    parameter LINE_WORDS = 480,
    parameter LINES      = 480,
    parameter SLOT_WORDS = 230400,
    parameter FIFO_AW    = 9,       // 每端口 FIFO 深度 = 2^FIFO_AW 个 96bit 条目
    parameter WARM_ENTS  = 320,     // 攒够多少个条目才放行显示（= 2 行）
    parameter RD_DRAIN   = 5'd24    // 读命令发完后等多少拍再放开总线
)(
    // ---- 内存域 125 MHz ----
    input  wire        mem_clk,
    input  wire        mem_rst_n,

    // ---- 像素域 25 MHz ----
    input  wire        vid_clk,
    input  wire        vid_rst_n,

    // 写入侧像素流（像素域）
    input  wire        wr_de,
    input  wire [23:0] wr_pixel,
    input  wire        wr_vflip,       // 1 = 自下而上写入（BMP 的 biHeight>0）

    // 显示侧读端口（像素域）
    input  wire        rd_a_en,
    input  wire        rd_a_stall,
    input  wire        rd_b_en,
    input  wire        rd_b_stall,
    output wire [23:0] rd_a_pixel,
    output wire [23:0] rd_b_pixel,
    output wire        rd_a_valid,
    output wire        rd_b_valid,
    output wire        rd_a_underrun,
    output wire        rd_b_underrun,
    output wire        rd_a_warm,
    output wire        rd_b_warm,

    // 槽状态与诊断
    output reg  [7:0]  slot_ready,
    output reg  [3:0]  state_code,

    // SDRAM 用户接口（控制器在 top 里，本模块只驱动/采样这些线）
    input  wire        sdr_init_done,
    input  wire        sdr_init_ref_vld,
    input  wire        sdr_busy,
    output wire        app_wr_en,
    output wire [20:0] app_wr_addr,
    output wire [3:0]  app_wr_dm,
    output wire [31:0] app_wr_din,
    output wire        app_rd_en,
    output wire [20:0] app_rd_addr,
    input  wire        sdr_rd_en,
    input  wire [31:0] sdr_rd_dout
);

    localparam [8:0]  LW_M1  = LINE_WORDS[8:0] - 9'd1;                 // 479
    localparam [8:0]  LN_M1  = LINES[8:0] - 9'd1;                      // 479
    localparam [9:0]  ENT_L  = LINE_WORDS[9:0] / 10'd3;                // 160
    // ★ 读引擎的 rd_got 计的是**条目**（每 3 个字推一个），不是字。
    //   早期版本拿它跟 LW_M1（字数）比，于是「一行取完」的条件永远不成立：
    //   一行只发 LINE_WORDS 个读命令、只回来 LINE_WORDS/3 个条目，
    //   而判据要等 LINE_WORDS-1 个条目 —— 读引擎取完一行就再也不请求了。
    //   在 640x480 的真实配置下就是「只取一行然后永久停住」，
    //   只有 sim/tb_frame_store.v 这种带 SDRAM 桩的仿真才抓得到。
    localparam [9:0]  ENT_M1 = ENT_L - 10'd1;
    localparam [20:0] SLOTW  = SLOT_WORDS[20:0];
    localparam [20:0] LINEW  = LINE_WORDS[20:0];
    localparam [2:0]  SLOTM1 = N_SLOT[2:0] - 3'd1;
    localparam integer LW_INT = LINE_WORDS;
    localparam integer LN_INT = LINES;
    // 垂直翻转时第一行的落点偏移 = (行数-1) * 每行字数
    localparam [20:0] VFLIP_OFF = (LN_INT - 1) * LW_INT;

    // 槽基址 = 槽号 * 每槽字数。
    // 写成参数化乘法而不是硬编码移位：早期版本把 230400 拆成
    // (s<<17)+(s<<16)+(s<<15)+(s<<10)，好处是省一个乘法器，
    // 坏处是**换任何别的帧尺寸就静默算错**（仿真里想用小帧做 tb 立刻踩到）。
    // 槽号只在装载完成时变一次，组合乘法完全不在关键路径上。
    function [20:0] slot_base;
        input [2:0] s;
        begin
            slot_base = s * SLOT_WORDS[20:0];
        end
    endfunction

    // =====================================================================
    // 一、写侧：像素打包 -> 跨域 -> 组字 -> 写 SDRAM
    // =====================================================================
    wire        went_en;
    wire [95:0] went;

    pixel_packer u_wpack (
        .clk      (vid_clk),
        .rst_n    (vid_rst_n),
        .pix_en   (wr_de),
        .pix      (wr_pixel),
        .flush    (1'b0),
        .entry_en (went_en),
        .entry    (went)
    );

    wire        wfifo_full;
    wire [95:0] wfifo_dout;
    wire        wfifo_empty;
    wire        wfifo_rd_en;

    async_fifo #(.DATA_WIDTH(96), .ADDR_WIDTH(FIFO_AW)) u_wfifo (
        .wr_clk   (vid_clk),
        .wr_rst_n (vid_rst_n),
        .wr_en    (went_en),
        .wr_data  (went),
        .wr_full  (wfifo_full),
        .rd_clk   (mem_clk),
        .rd_rst_n (mem_rst_n),
        .rd_en    (wfifo_rd_en),
        .rd_data  (wfifo_dout),
        .rd_empty (wfifo_empty)
    );

    // =====================================================================
    // 二、显示槽与总线仲裁
    // =====================================================================
    reg [2:0] disp_slot_m;     // 当前显示槽（内存域），只在读行号回绕时被读引擎 A 锁存
    reg [2:0] disp_slot_pm;    // 上一个显示槽，供读引擎 B 用 —— 特效的「前一帧」就是它

    localparam [2:0] ARB_IDLE  = 3'd0;
    localparam [2:0] ARB_RD_A  = 3'd1;
    localparam [2:0] ARB_RD_B  = 3'd2;
    localparam [2:0] ARB_DRAIN = 3'd3;
    localparam [2:0] ARB_WR    = 3'd4;

    reg [2:0] arb_state;
    reg [4:0] drain_cnt;
    reg [2:0] arb_last;
    // ★ 排空阶段必须继续收数据，否则会丢掉读突发的**尾部若干个字**：
    //   最后一个读命令发出后状态机立刻离开 ARB_RD_x 进 ARB_DRAIN，
    //   而它的数据要 RD_LAT 拍之后才回来。早期版本只在 ARB_RD_x 里收数，
    //   结果每行的最后几个字被丢掉 -> 行计数永远到不了头 -> 读引擎彻底卡死
    //   （现象：warm 一直不拉高、一个像素都读不出来）。
    reg       drain_is_a;

    // ---- 读端口 A 的取数引擎状态 ----
    reg [2:0]  rd_slot_a;      // 本帧使用的槽（行号回绕时锁存）
    reg [20:0] rd_addr_a;      // 下一个读命令的地址
    reg [20:0] rd_lbase_a;     // 本行首地址
    reg [8:0]  rd_issued_a;    // 本行已发出的读命令数
    reg [8:0]  rd_got_a;       // 本行已收回的字数
    reg [8:0]  rd_line_a;      // 本行行号
    reg [1:0]  rd_grp_a;       // 条目内已收字数 0..2
    reg [95:0] rd_ent_a;
    reg [15:0] rd_warm_a;      // 已推送条目数（warm 判据）

    // ---- 读端口 B ----
    reg [2:0]  rd_slot_b;
    reg [20:0] rd_addr_b;
    reg [20:0] rd_lbase_b;
    reg [8:0]  rd_issued_b;
    reg [8:0]  rd_got_b;
    reg [8:0]  rd_line_b;
    reg [1:0]  rd_grp_b;
    reg [95:0] rd_ent_b;
    reg [15:0] rd_warm_b;

    reg        rd_push_a, rd_push_b;
    reg        chg_a, chg_b;       // 本拍行切换（用于重载地址）

    wire       rdfifo_a_full, rdfifo_a_empty;
    wire [95:0] rdfifo_a_dout;
    wire       rdfifo_a_rd_en;
    wire       rdfifo_b_full, rdfifo_b_empty;
    wire [95:0] rdfifo_b_dout;
    wire       rdfifo_b_rd_en;

    wire rd_burst_active = (arb_state == ARB_RD_A) || (arb_state == ARB_RD_B) ||
                           (arb_state == ARB_DRAIN);

    // 谁的数据在这一拍回来：突发中就是当前端口，排空中是刚结束的那个端口
    wire cap_a = (arb_state == ARB_RD_A) ||
                 ((arb_state == ARB_DRAIN) &&  drain_is_a);
    wire cap_b = (arb_state == ARB_RD_B) ||
                 ((arb_state == ARB_DRAIN) && !drain_is_a);

    wire slot_ok_a = slot_ready[rd_slot_a];
    wire slot_ok_b = slot_ready[rd_slot_b];

    wire req_a = (rd_issued_a < LINE_WORDS[8:0]) && !rdfifo_a_full && slot_ok_a;
    wire req_b = (rd_issued_b < LINE_WORDS[8:0]) && !rdfifo_b_full && slot_ok_b;

    async_fifo #(.DATA_WIDTH(96), .ADDR_WIDTH(FIFO_AW)) u_rdfifo_a (
        .wr_clk   (mem_clk),
        .wr_rst_n (mem_rst_n),
        .wr_en    (rd_push_a),
        .wr_data  (rd_ent_a),
        .wr_full  (rdfifo_a_full),
        .rd_clk   (vid_clk),
        .rd_rst_n (vid_rst_n),
        .rd_en    (rdfifo_a_rd_en),
        .rd_data  (rdfifo_a_dout),
        .rd_empty (rdfifo_a_empty)
    );

    async_fifo #(.DATA_WIDTH(96), .ADDR_WIDTH(FIFO_AW)) u_rdfifo_b (
        .wr_clk   (mem_clk),
        .wr_rst_n (mem_rst_n),
        .wr_en    (rd_push_b),
        .wr_data  (rd_ent_b),
        .wr_full  (rdfifo_b_full),
        .rd_clk   (vid_clk),
        .rd_rst_n (vid_rst_n),
        .rd_en    (rdfifo_b_rd_en),
        .rd_data  (rdfifo_b_dout),
        .rd_empty (rdfifo_b_empty)
    );

    // =====================================================================
    // 三、写引擎
    // =====================================================================
    reg [2:0]  wr_slot;
    reg [20:0] wr_addr_r;
    reg [8:0]  wr_word;
    reg [8:0]  wr_lines_done;
    reg [95:0] wr_hold;
    reg [1:0]  wr_hold_idx;
    reg        wr_hold_valid;
    reg        wr_vf_frame;     // 本帧冻结的 vflip 方向
    reg        wr_frame_act;    // 本帧已开始、尚未提交

    wire [31:0] wr_word_sel = (wr_hold_idx == 2'd0) ? wr_hold[31:0]  :
                              (wr_hold_idx == 2'd1) ? wr_hold[63:32] : wr_hold[95:64];

    wire wr_can = sdr_init_done && !rd_burst_active;

    // wr_vflip 只在两次装载之间变化、一次装载期间保持不变，
    // 所以用两级同步器取到内存域即可（不会在装载中途变）。
    // ★ 方向必须**按帧冻结**（wr_vf_frame），不能直接拿同步后的实时值用：
    //   帧首基址是在上一帧提交那一拍算的，那一刻拿到的还是上一帧的方向，
    //   而逐行推进却用实时值 —— 两帧之间改方向时，基址和推进方向会打架。
    //   正确做法：帧间空闲期每拍跟踪 wr_vf 并重算帧首基址，帧一开始就冻结。
    reg [1:0] wv_sync;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) wv_sync <= 2'b00;
        else            wv_sync <= {wv_sync[0], wr_vflip};
    end
    wire wr_vf = wv_sync[1];

    assign app_wr_en   = wr_hold_valid && wr_can;
    assign app_wr_addr = wr_addr_r;
    assign app_wr_din  = wr_word_sel;
    assign app_wr_dm   = 4'b0000;      // 四字节全有效

    // 入口条目：只有在写缓冲空的时候才弹，保证数据不错位
    assign wfifo_rd_en = !wfifo_empty && !wr_hold_valid && wr_can;

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            wr_slot        <= 3'd0;
            wr_addr_r      <= slot_base(3'd0);
            wr_word        <= 9'd0;
            wr_lines_done  <= 9'd0;
            wr_hold        <= 96'd0;
            wr_hold_idx    <= 2'd0;
            wr_hold_valid  <= 1'b0;
            slot_ready     <= 8'd0;
            disp_slot_m    <= 3'd0;
            disp_slot_pm   <= 3'd0;
            wr_vf_frame    <= 1'b0;
            wr_frame_act   <= 1'b0;
        end else begin
            // ---- 帧间空闲期：跟踪 wr_vf 并重算帧首基址 ----
            // 必须放在本块**最前面**：帧首第 0 个字那一拍 wr_frame_act 还是 0，
            // 本段会采样方向，而后面「写字并推进地址」会把 wr_addr_r 覆盖成 基址+1，
            // 同一个 always 块里后写的赋值生效，正好是想要的顺序。
            if (!wr_frame_act) begin
                wr_vf_frame <= wr_vf;
                wr_addr_r   <= slot_base(wr_slot) + (wr_vf ? VFLIP_OFF : 21'd0);
            end

            // ---- 取条目 ----
            if (wfifo_rd_en) begin
                wr_hold       <= wfifo_dout;
                wr_hold_valid <= 1'b1;
                wr_hold_idx   <= 2'd0;
            end else if (app_wr_en) begin
                if (wr_hold_idx == 2'd2)
                    wr_hold_valid <= 1'b0;
                else
                    wr_hold_idx <= wr_hold_idx + 2'd1;
            end

            // ---- 写字并推进地址 ----
            if (app_wr_en) begin
                // 帧首第 0 个字：本帧开始，冻结方向（本章开头那段已把 wr_vf_frame 采好）
                if ((wr_word == 9'd0) && (wr_lines_done == 9'd0))
                    wr_frame_act <= 1'b1;

                if (wr_word == LW_M1) begin
                    wr_word <= 9'd0;
                    if (wr_lines_done == LN_M1) begin
                        // ★ 整幅写完：单拍原子提交
                        slot_ready[wr_slot] <= 1'b1;
                        disp_slot_pm        <= disp_slot_m;   // 旧帧退位成「前一帧」
                        disp_slot_m         <= wr_slot;
                        wr_lines_done       <= 9'd0;
                        wr_slot             <= (wr_slot == SLOTM1) ? 3'd0 : (wr_slot + 3'd1);
                        wr_frame_act        <= 1'b0;
                        // 下一帧基址留给「帧间空闲期」那段按下一帧的方向重算，
                        // 这里只给个安全值，避免毛刺期用到旧地址
                        wr_addr_r           <= slot_base((wr_slot == SLOTM1) ? 3'd0
                                                                             : (wr_slot + 3'd1));
                    end else begin
                        wr_lines_done <= wr_lines_done + 9'd1;
                        if (wr_vf_frame)
                            // 垂直翻转：下一行在内存里更靠前，
                            // 本行末地址 +1 再退一整行的两倍
                            wr_addr_r <= wr_addr_r + 21'd1 - (LINE_WORDS[20:0] << 1);
                        else
                            wr_addr_r <= wr_addr_r + 21'd1;   // 行升序：下一行首地址 = 本行末 + 1
                    end
                end else begin
                    wr_word   <= wr_word + 9'd1;
                    wr_addr_r <= wr_addr_r + 21'd1;
                end
            end
        end
    end

    // =====================================================================
    // 四、仲裁状态机（app_rd_en 的选通语义见下面 rd_go_* 之后的 assign）
    // =====================================================================
    // 读端口被授权且还在发命令
    wire rd_go_a = (arb_state == ARB_RD_A) && (rd_issued_a < LINE_WORDS[8:0]) && !rdfifo_a_full;
    wire rd_go_b = (arb_state == ARB_RD_B) && (rd_issued_b < LINE_WORDS[8:0]) && !rdfifo_b_full;

    // ★ app_rd_en 是「每字一个选通」，不是「读状态有效」：
    //   例程 frame_fifo_read.v 就是这么用的（`burst_cnt + App_rd_en < BURST_SIZE`
    //   决定本拍还发不发），一个字一个 strobe，地址每个 strobe 自增 1。
    //   早期写成 (arb_state == ARB_RD_A) 会在最后一个字之后**多发一个 strobe**，
    //   而此时 rd_addr_a 已经自增到下一行首字 —— 收数据那一拍把下一行的首字
    //   当成本轮第 1 个字塞进 96 bit 条目，组相 rd_grp_a 从此错位 1：
    //   每行第 1 个条目变成 {w1, w0, w0}（第 1 个像素碰巧对，其余全错），
    //   且每行最后一个字永远收不到。由 sim/tb_frame_store.v 定位。
    assign app_rd_en   = rd_go_a || rd_go_b;
    assign app_rd_addr = rd_go_a ? rd_addr_a : rd_addr_b;

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            arb_state <= ARB_IDLE;
            arb_last  <= 3'd1;      // 下次优先给 A
            drain_cnt <= 5'd0;
        end else begin
            case (arb_state)
                ARB_IDLE: begin
                    if (req_a && (arb_last != 3'd0))
                        arb_state <= ARB_RD_A;
                    else if (req_b)
                        arb_state <= ARB_RD_B;
                    else if (req_a)
                        arb_state <= ARB_RD_A;
                    else if (wr_hold_valid)
                        arb_state <= ARB_WR;
                    else
                        arb_state <= ARB_IDLE;
                end
                ARB_RD_A: begin
                    if (rd_issued_a >= LINE_WORDS[8:0]) begin
                        arb_state  <= ARB_DRAIN;
                        drain_cnt  <= 5'd0;
                        drain_is_a <= 1'b1;
                        arb_last   <= 3'd1;
                    end
                end
                ARB_RD_B: begin
                    if (rd_issued_b >= LINE_WORDS[8:0]) begin
                        arb_state  <= ARB_DRAIN;
                        drain_cnt  <= 5'd0;
                        drain_is_a <= 1'b0;
                        arb_last   <= 3'd0;
                    end
                end
                ARB_DRAIN: begin
                    // 等最后几个读命令的数据回来再放开总线，避免把数据算到别的端口头上
                    if (drain_cnt >= RD_DRAIN)
                        arb_state <= ARB_IDLE;
                    else
                        drain_cnt <= drain_cnt + 5'd1;
                end
                ARB_WR: begin
                    arb_state <= ARB_IDLE;
                end
                default: arb_state <= ARB_IDLE;
            endcase
        end
    end

    // =====================================================================
    // 五、读引擎：发命令 + 收数据组条目
    // =====================================================================
    // 发命令
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            rd_slot_a   <= 3'd0;
            rd_line_a   <= 9'd0;
            rd_issued_a <= 9'd0;
            rd_got_a    <= 9'd0;
            rd_grp_a    <= 2'd0;
            rd_ent_a    <= 96'd0;
            rd_addr_a   <= slot_base(3'd0);
            rd_lbase_a  <= slot_base(3'd0);
            rd_warm_a   <= 16'd0;
            rd_push_a   <= 1'b0;
            chg_a       <= 1'b0;
        end else begin
            rd_push_a <= 1'b0;
            chg_a     <= 1'b0;

            // ---- 发读命令 ----
            if (rd_go_a) begin
                rd_issued_a <= rd_issued_a + 9'd1;
                rd_addr_a   <= rd_addr_a + 21'd1;
            end

            // ---- 收数据、组条目、推进行 ----
            if (sdr_rd_en && cap_a) begin
                case (rd_grp_a)
                    2'd0: rd_ent_a[31:0]  <= sdr_rd_dout;
                    2'd1: rd_ent_a[63:32] <= sdr_rd_dout;
                    default: begin
                        rd_ent_a[95:64] <= sdr_rd_dout;
                        rd_push_a       <= 1'b1;
                        rd_warm_a       <= rd_warm_a + 16'd1;
                    end
                endcase
                rd_grp_a <= (rd_grp_a == 2'd2) ? 2'd0 : (rd_grp_a + 2'd1);

                if (rd_grp_a == 2'd2) begin
                    if (rd_got_a == ENT_M1[8:0]) begin
                        // 本行取完，切到下一行
                        rd_got_a    <= 9'd0;
                        rd_issued_a <= 9'd0;
                        rd_lbase_a  <= rd_lbase_a + LINEW;
                        rd_addr_a   <= rd_lbase_a + LINEW;
                        chg_a       <= 1'b1;
                        if (rd_line_a == LN_M1) begin
                            rd_line_a  <= 9'd0;
                            rd_slot_a  <= disp_slot_m;          // 帧边界换槽
                            rd_lbase_a <= slot_base(disp_slot_m);
                            rd_addr_a  <= slot_base(disp_slot_m);
                        end else begin
                            rd_line_a <= rd_line_a + 9'd1;
                        end
                    end else begin
                        rd_got_a <= rd_got_a + 9'd1;
                    end
                end
            end
        end
    end

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            rd_slot_b   <= 3'd0;
            rd_line_b   <= 9'd0;
            rd_issued_b <= 9'd0;
            rd_got_b    <= 9'd0;
            rd_grp_b    <= 2'd0;
            rd_ent_b    <= 96'd0;
            rd_addr_b   <= slot_base(3'd0);
            rd_lbase_b  <= slot_base(3'd0);
            rd_warm_b   <= 16'd0;
            rd_push_b   <= 1'b0;
            chg_b       <= 1'b0;
        end else begin
            rd_push_b <= 1'b0;
            chg_b     <= 1'b0;

            if (rd_go_b) begin
                rd_issued_b <= rd_issued_b + 9'd1;
                rd_addr_b   <= rd_addr_b + 21'd1;
            end

            if (sdr_rd_en && cap_b) begin
                case (rd_grp_b)
                    2'd0: rd_ent_b[31:0]  <= sdr_rd_dout;
                    2'd1: rd_ent_b[63:32] <= sdr_rd_dout;
                    default: begin
                        rd_ent_b[95:64] <= sdr_rd_dout;
                        rd_push_b       <= 1'b1;
                        rd_warm_b       <= rd_warm_b + 16'd1;
                    end
                endcase
                rd_grp_b <= (rd_grp_b == 2'd2) ? 2'd0 : (rd_grp_b + 2'd1);

                if (rd_grp_b == 2'd2) begin
                    if (rd_got_b == ENT_M1[8:0]) begin
                        rd_got_b    <= 9'd0;
                        rd_issued_b <= 9'd0;
                        rd_lbase_b  <= rd_lbase_b + LINEW;
                        rd_addr_b   <= rd_lbase_b + LINEW;
                        chg_b       <= 1'b1;
                        if (rd_line_b == LN_M1) begin
                            rd_line_b  <= 9'd0;
                            rd_slot_b  <= disp_slot_pm;        // 端口 B 取「前一帧」
                            rd_lbase_b <= slot_base(disp_slot_pm);
                            rd_addr_b  <= slot_base(disp_slot_pm);
                        end else begin
                            rd_line_b <= rd_line_b + 9'd1;
                        end
                    end else begin
                        rd_got_b <= rd_got_b + 9'd1;
                    end
                end
            end
        end
    end

    // =====================================================================
    // 六、像素域解包与 warm 门控
    // =====================================================================
    frame_reader u_rda (
        .clk         (vid_clk),
        .rst_n       (vid_rst_n),
        .en          (rd_a_en),
        .stall       (rd_a_stall),
        .rd_empty    (rdfifo_a_empty),
        .rd_data     (rdfifo_a_dout),
        .rd_en       (rdfifo_a_rd_en),
        .pixel_valid (rd_a_valid),
        .pixel       (rd_a_pixel),
        .underrun    (rd_a_underrun)
    );

    frame_reader u_rdb (
        .clk         (vid_clk),
        .rst_n       (vid_rst_n),
        .en          (rd_b_en),
        .stall       (rd_b_stall),
        .rd_empty    (rdfifo_b_empty),
        .rd_data     (rdfifo_b_dout),
        .rd_en       (rdfifo_b_rd_en),
        .pixel_valid (rd_b_valid),
        .pixel       (rd_b_pixel),
        .underrun    (rd_b_underrun)
    );

    // warm：攒够 WARM_ENTS 个条目再放行显示。
    // 这一步是必需的：解包器消费速率与取数速率同为「1 条目/4 像素时钟」，
    // 一有数据就开读会让 FIFO 永远只剩 1 个条目，任何抖动立即欠载。
    // （这个结论是 sim/tb_pack_unpack.v 跑出来的，不是猜的。）
    reg warm_a_m, warm_b_m;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            warm_a_m <= 1'b0;
            warm_b_m <= 1'b0;
        end else begin
            if (rd_warm_a >= WARM_ENTS[15:0]) warm_a_m <= 1'b1;
            if (rd_warm_b >= WARM_ENTS[15:0]) warm_b_m <= 1'b1;
        end
    end

    reg [2:0] warm_a_s, warm_b_s;
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            warm_a_s <= 3'b000;
            warm_b_s <= 3'b000;
        end else begin
            warm_a_s <= {warm_a_s[1:0], warm_a_m};
            warm_b_s <= {warm_b_s[1:0], warm_b_m};
        end
    end

    assign rd_a_warm = warm_a_s[2];
    assign rd_b_warm = warm_b_s[2];

    // =====================================================================
    // 七、诊断状态码（送数码管）
    //   bit3 = 当前在读，bit2 = 当前在写，bit1 = 有欠载，bit0 = SDRAM 初始化完成
    //   注：SDRAM 控制器实例在 top 里，不在本模块内 —— 这样本模块可以配行为级
    //   桩做仿真（sim/tb_frame_store.v），加密黑盒不进仿真。
    // =====================================================================
    wire sdr_busy_unused = sdr_busy ^ sdr_init_ref_vld;   // 仅用于消除未用信号告警

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n)
            state_code <= 4'd0;
        else
            state_code <= {rd_burst_active, app_wr_en,
                           rd_a_underrun | rd_b_underrun, sdr_init_done};
    end

endmodule
