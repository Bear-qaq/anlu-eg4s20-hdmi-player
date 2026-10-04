//=============================================================================
// 模块：top
// 功能：HDMI 多媒体播放系统顶层。
//
// 当前形态（板级迁移版）：媒体层已接入，目标板为硬木课堂「大拇指」EG4S20 + M0 底板。
//   TF 卡 ──> sector_source(SD 驱动 100MHz + 512B 异步 FIFO)
//          ──> media_loader(FAT32 目录索引 -> 按簇链读文件 -> BMP 解码)
//          ──> frame_store(8 槽 + 打包 + 原子提交) ──> SDRAM
//          ──> 双端口行预取 ──> frame_mixer(直通/淡入淡出/滑动) ──> HDMI 1.4b 核
//
//   内建测试图只作为**无卡时的降级显示源**，不再写入帧仓 ——
//   这样媒体流与测试图流不会在同一槽里混帧，也就不需要「接管时机」那套协调逻辑。
//
// 与官方例程的顶层差异（详见 docs/ARCH_DIFF.md）：
//   1. 2 颗 PLL（例程 3 颗，多一颗专供音频）。音频不另开时钟，直接在像素域合成。
//   2. 没有 I2S 三线，也没有 I2S_receiver —— 并行 PCM 直接进加密核。
//   3. 8 槽帧仓 + 原子提交 + 双读端口（例程 BUF0/BUF1 乒乓、单读端口）。
//   4. 图片处理走 FAT32 目录索引 + 流式 BMP 解码（例程是物理扇区盲扫 'BM'）。
//   5. 复位带 POR 计数 + **两颗 PLL 的锁定门控**（例程 ex5 两者都没有）。
//   6. 数码管显示 16 bit 诊断状态字，不是 4 bit 状态码。
//=============================================================================
`timescale 1ns / 1ps

module top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        key1,
    output wire [3:0]  key_col,
    input  wire [3:0]  key_row,

    output wire [3:0]  seg_sel,
    output wire [7:0]  seg_data,

    output wire        HDMI_CLK_P,
    output wire        HDMI_D2_P,
    output wire        HDMI_D1_P,
    output wire        HDMI_D0_P,

    output wire        sd_ncs,
    output wire        sd_dclk,
    output wire        sd_mosi,
    input  wire        sd_miso
);

    // 像素域配置
    reg [2:0]  track_sel;
    reg [3:0]  vol;
    reg  [1:0] fx_mode;
    wire       fx_start;

    // =====================================================================
    // 视频时序参数。必须与下方 HDMI 发送核例化参数严格一致。
    // =====================================================================
    localparam H_ACTIVE = 640;
    localparam H_FP     = 16;
    localparam H_SYNC   = 96;
    localparam H_BP     = 48;
    localparam V_ACTIVE = 480;
    localparam V_FP     = 10;
    localparam V_SYNC   = 2;
    localparam V_BP     = 33;

    // =====================================================================
    // 时钟与复位
    // =====================================================================
    wire por_rst_n;
    wire vid_pll_locked;
    wire mem_pll_locked;
    wire pixel_clk;      // 25 MHz
    wire serial_clk;     // 125 MHz（HDMI PHY 串行）
    wire mem_clk;        // 125 MHz（SDRAM 用户接口）
    wire mem_clk_sft;    // 125 MHz 相移 180°
    wire sd_clk;         // 100 MHz（SD 卡 SPI 驱动）
    wire pixel_rst_n;
    wire mem_rst_n;

    reset_gen u_reset_gen (
        .clk             (clk),
        .rst_n_async     (rst_n),
        .por_rst_n       (por_rst_n),
        .pixel_clk       (pixel_clk),
        .pll_locked      (vid_pll_locked),
        .pixel_rst_n     (pixel_rst_n),
        .mem_clk         (mem_clk),
        .mem_pll_locked  (mem_pll_locked),
        .mem_rst_n       (mem_rst_n)
    );

    video_clock u_video_clock (
        .refclk       (clk),
        .rst_n_async  (por_rst_n),
        .pll_locked   (vid_pll_locked),
        .pixel_clk    (pixel_clk),
        .serial_clk   (serial_clk)
    );

    mem_clock u_mem_clock (
        .refclk       (clk),
        .rst_n_async  (por_rst_n),
        .pll_locked   (mem_pll_locked),
        .clk_100      (sd_clk),
        .clk_125      (mem_clk),
        .clk_125_sft  (mem_clk_sft)
    );

    // =====================================================================
    // 视频时序 + 坐标延迟
    //   帧仓解包器与混合器各占一拍，所以视频输出用 de_d2/x_d2/y_d2 对齐；
    //   混合器按坐标做特效，用 x_d1。
    // =====================================================================
    wire [11:0] vx, vy;
    wire        vde, vhs_n, vs_n, frame_start;

    video_timing #(
        .H_ACTIVE (H_ACTIVE), .H_FP (H_FP), .H_SYNC (H_SYNC), .H_BP (H_BP),
        .V_ACTIVE (V_ACTIVE), .V_FP (V_FP), .V_SYNC (V_SYNC), .V_BP (V_BP)
    ) u_video_timing (
        .pixel_clk   (pixel_clk),
        .rst_n       (pixel_rst_n),
        .x           (vx),
        .y           (vy),
        .de          (vde),
        .hs_n        (vhs_n),
        .vs_n        (vs_n),
        .frame_start (frame_start)
    );

    reg [11:0] x_d1, y_d1, x_d2, y_d2;
    reg        de_d1, de_d2;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            x_d1 <= 12'd0;  y_d1 <= 12'd0;  de_d1 <= 1'b0;
            x_d2 <= 12'd0;  y_d2 <= 12'd0;  de_d2 <= 1'b0;
        end else begin
            x_d1 <= vx;     y_d1 <= vy;     de_d1 <= vde;
            x_d2 <= x_d1;   y_d2 <= y_d1;   de_d2 <= de_d1;
        end
    end

    reg [7:0] frame_cnt;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n)  frame_cnt <= 8'd0;
        else if (frame_start) frame_cnt <= frame_cnt + 8'd1;
    end

    // ---- 内建测试图（仅作为无卡时的降级显示源）----
    wire [23:0] pattern_disp;
    test_pattern #(
        .H_ACTIVE (H_ACTIVE), .V_ACTIVE (V_ACTIVE)
    ) u_test_pattern (
        .x         (x_d2),               // 与混合器输出同拍
        .y         (y_d2),
        .frame_cnt (frame_cnt),
        .sel       (frame_cnt[7:6]),     // 约每 4 秒换一幅，纯粹为了演示好看
        .rgb       (pattern_disp)
    );

    // =====================================================================
    // 媒体层：TF 卡 -> FAT32 -> BMP -> 像素流
    // =====================================================================
    wire        med_sec_req;
    wire [31:0] med_sec_addr;
    wire        med_src_ack;
    wire        med_src_byte_en;
    wire [7:0]  med_src_byte;
    wire        med_src_last;

    wire        med_pix_en;
    wire [23:0] med_pix;
    wire        med_pix_vflip;
    wire        med_pix_row_end;
    wire        med_img_done;
    wire [2:0]  med_load_slot;
    wire [4:0]  med_img_count;
    wire [7:0]  med_img_loaded;
    wire [3:0]  med_err;
    wire [3:0]  med_state;

    // 上电约 84 ms 后启动一次「扫描 + 装载」
    reg [20:0] boot_cnt;
    wire media_start = (boot_cnt == 21'h1F_FFFF);

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n)         boot_cnt <= 21'd0;
        else if (!media_start)    boot_cnt <= boot_cnt + 21'd1;
    end

    media_loader #(
        .N_MAX (16), .IMG_W (H_ACTIVE), .IMG_H (V_ACTIVE)
    ) u_media_loader (
        .clk         (pixel_clk),
        .rst_n       (pixel_rst_n),
        .start       (media_start),
        .sec_req     (med_sec_req),
        .sec_addr    (med_sec_addr),
        .src_ack     (med_src_ack),
        .src_byte_en (med_src_byte_en),
        .src_byte    (med_src_byte),
        .src_last    (med_src_last),
        .pix_en      (med_pix_en),
        .pix         (med_pix),
        .pix_vflip   (med_pix_vflip),
        .pix_row_end (med_pix_row_end),
        .img_done    (med_img_done),
        .load_slot   (med_load_slot),
        .img_count   (med_img_count),
        .img_loaded  (med_img_loaded),
        .err_code    (med_err),
        .state_code  (med_state)
    );

    wire sd_init_done;
    wire sd_timeout;

    sector_source #(
        .TIMEOUT_CYC (27'd67_000_000),
        .FIFO_AW     (9)
    ) u_sector_source (
        .sd_clk      (sd_clk),
        .rst_n       (rst_n),
        .SD_nCS      (sd_ncs),
        .SD_DCLK     (sd_dclk),
        .SD_MOSI     (sd_mosi),
        .SD_MISO     (sd_miso),
        .sd_init_done(sd_init_done),
        .clk         (pixel_clk),
        .sec_req     (med_sec_req),
        .sec_addr    (med_sec_addr),
        .src_ack     (med_src_ack),
        .src_byte_en (med_src_byte_en),
        .src_byte    (med_src_byte),
        .src_last    (med_src_last),
        .sd_timeout  (sd_timeout)
    );

    // =====================================================================
    // 帧仓 + SDRAM：写入源就是媒体层
    // =====================================================================
    wire        fs_init_done, fs_init_ref_vld, fs_busy;
    wire        fs_wr_en;
    wire [20:0] fs_wr_addr;
    wire [3:0]  fs_wr_dm;
    wire [31:0] fs_wr_din;
    wire        fs_rd_en;
    wire [20:0] fs_rd_addr;
    wire        fs_rd_vld;
    wire [31:0] fs_rd_dout;

    wire [23:0] fs_pixel, fs_pixel_b;
    wire        fs_valid, fs_valid_b;
    wire        fs_underrun, fs_underrun_b;
    wire        fs_warm, fs_warm_b;
    wire [7:0]  slot_ready;
    wire [3:0]  fs_state;

    reg video_en;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n)
            video_en <= 1'b0;
        else if (!video_en && fs_warm && fs_warm_b && frame_start)
            video_en <= 1'b1;
    end

    frame_store #(
        .N_SLOT     (8),
        .LINE_WORDS (480),
        .LINES      (480),
        .SLOT_WORDS (230400),
        .FIFO_AW    (9),
        .WARM_ENTS  (320),
        .RD_DRAIN   (5'd24)
    ) u_frame_store (
        .mem_clk          (mem_clk),
        .mem_rst_n        (mem_rst_n),
        .vid_clk          (pixel_clk),
        .vid_rst_n        (pixel_rst_n),

        .wr_de            (med_pix_en),
        .wr_pixel         (med_pix),
        .wr_vflip         (med_pix_vflip),

        .rd_a_en          (video_en),
        .rd_a_stall       (~vde),
        .rd_b_en          (video_en),
        .rd_b_stall       (~vde),
        .rd_a_pixel       (fs_pixel),
        .rd_b_pixel       (fs_pixel_b),
        .rd_a_valid       (fs_valid),
        .rd_b_valid       (fs_valid_b),
        .rd_a_underrun    (fs_underrun),
        .rd_b_underrun    (fs_underrun_b),
        .rd_a_warm        (fs_warm),
        .rd_b_warm        (fs_warm_b),

        .slot_ready       (slot_ready),
        .state_code       (fs_state),

        .sdr_init_done    (fs_init_done),
        .sdr_init_ref_vld (fs_init_ref_vld),
        .sdr_busy         (fs_busy),
        .app_wr_en        (fs_wr_en),
        .app_wr_addr      (fs_wr_addr),
        .app_wr_dm        (fs_wr_dm),
        .app_wr_din       (fs_wr_din),
        .app_rd_en        (fs_rd_en),
        .app_rd_addr      (fs_rd_addr),
        .sdr_rd_en        (fs_rd_vld),
        .sdr_rd_dout      (fs_rd_dout)
    );

    sdram_ctrl u_sdram (
        .clk              (mem_clk),
        .clk_sft          (mem_clk_sft),
        .rst              (~mem_rst_n),
        .sdr_init_done    (fs_init_done),
        .sdr_init_ref_vld (fs_init_ref_vld),
        .sdr_busy         (fs_busy),
        .app_wr_en        (fs_wr_en),
        .app_wr_addr      (fs_wr_addr),
        .app_wr_dm        (fs_wr_dm),
        .app_wr_din       (fs_wr_din),
        .app_rd_en        (fs_rd_en),
        .app_rd_addr      (fs_rd_addr),
        .sdr_rd_en        (fs_rd_vld),
        .sdr_rd_dout      (fs_rd_dout)
    );

    // =====================================================================
    // 显示输出：有装载好的图就出帧仓+混合器，否则降级出内建测试图
    //   rgb_to_axis 的 en 恒为 1 —— 内容选择已经在 disp_rgb 上做完了，
    //   否则无卡时会连测试图一起被强制成黑屏。
    // =====================================================================
    wire have_img = (slot_ready != 8'd0);

    wire [23:0] fx_pixel;
    wire        fx_busy;
    wire [7:0]  fx_alpha;
    wire [11:0] fx_slide;

    frame_mixer u_frame_mixer (
        .clk       (pixel_clk),
        .rst_n     (pixel_rst_n),
        .en        (video_en && fs_valid && fs_valid_b),
        .mode      (fx_mode),
        .alpha     (fx_alpha),
        .slide_pos (fx_slide),
        .x         (x_d1),
        .pix_a     (fs_pixel),
        .pix_b     (fs_pixel_b),
        .pix_out   (fx_pixel)
    );

    effect_ctrl #(
        .STEP_DIV (16'd32768), .H_ACTIVE (H_ACTIVE)
    ) u_effect_ctrl (
        .clk       (pixel_clk),
        .rst_n     (pixel_rst_n),
        .start     (fx_start),
        .mode      (fx_mode),
        .busy      (fx_busy),
        .alpha     (fx_alpha),
        .slide_pos (fx_slide)
    );

    wire [23:0] disp_rgb = have_img ? (fs_valid ? fx_pixel : 24'h00_00_00)
                                    : pattern_disp;

    wire        axis_user, axis_valid, axis_last;
    wire [23:0] axis_data;

    rgb_to_axis #(.H_ACTIVE (H_ACTIVE)) u_rgb_to_axis (
        .pixel_clk  (pixel_clk),
        .rst_n      (pixel_rst_n),
        .en         (1'b1),
        .x          (x_d2),
        .y          (y_d2),
        .de         (de_d2),
        .rgb        (disp_rgb),
        .axis_user  (axis_user),
        .axis_valid (axis_valid),
        .axis_last  (axis_last),
        .axis_data  (axis_data)
    );

    // =====================================================================
    // 音频：像素域内直接合成 48 kHz PCM
    // =====================================================================
    wire sample_tick, audio_valid, acr_valid;
    wire [23:0] audio_l, audio_r;
    wire [19:0] acr_cts, acr_n;

    audio_clk_gen #(.PIXEL_CLK_HZ (25_000_000), .SAMPLE_RATE (48_000)) u_audio_clk_gen (
        .pixel_clk (pixel_clk), .rst_n (pixel_rst_n), .sample_tick (sample_tick)
    );

    audio_synth #(.SAMPLE_RATE (48_000), .NOTE_TICKS (12_000)) u_audio_synth (
        .clk         (pixel_clk),
        .rst_n       (pixel_rst_n),
        .sample_tick (sample_tick),
        .track_sel   (track_sel),
        .vol         (vol),
        .audio_valid (audio_valid),
        .audio_l     (audio_l),
        .audio_r     (audio_r)
    );

    acr_gen #(.PIXEL_CLK_KHZ (25_000), .SAMPLE_RATE (48_000), .ACR_N (6144)) u_acr_gen (
        .pixel_clk (pixel_clk), .rst_n (pixel_rst_n),
        .acr_valid (acr_valid), .acr_cts (acr_cts), .acr_n (acr_n)
    );

    // =====================================================================
    // 按键
    // =====================================================================
    wire key1_press, key1_long, key2_press, key2_long;
    wire key2_n = &key_row;

    // M0 底板矩阵键盘没有独立 key2。这里把四列同时拉低，读取四行的“任意键”
    // 合成信号；按住矩阵中任意一个键都会使某一行拉低。这样在保留
    // key_debounce 短按/长按语义的同时，满足赛题“至少两个本地按键”的要求。
    // 将来若需要区分 16 个键位，可在不改变 top 端口的前提下替换为完整扫描器。
    assign key_col = 4'b0000;

    key_debounce #(.CLK_FREQ_HZ (50_000_000), .DEBOUNCE_MS (20), .LONG_MS (1000)) u_key1 (
        .clk (clk), .rst_n (por_rst_n), .key_n (key1),
        .press_pulse (key1_press), .long_pulse (key1_long)
    );

    key_debounce #(.CLK_FREQ_HZ (50_000_000), .DEBOUNCE_MS (20), .LONG_MS (1000)) u_key2 (
        .clk (clk), .rst_n (por_rst_n), .key_n (key2_n),
        .press_pulse (key2_press), .long_pulse (key2_long)
    );

    reg track_toggle, vol_toggle, fxmode_toggle;
    always @(posedge clk or negedge por_rst_n) begin
        if (!por_rst_n) begin
            track_toggle  <= 1'b0;
            vol_toggle    <= 1'b0;
            fxmode_toggle <= 1'b0;
        end else begin
            if (key1_press) track_toggle  <= ~track_toggle;
            if (key2_press) fxmode_toggle <= ~fxmode_toggle;
            if (key2_long)  vol_toggle    <= ~vol_toggle;
        end
    end

    reg [2:0] track_sync, vol_sync, fxmode_sync;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            track_sync  <= 3'b000;
            vol_sync    <= 3'b000;
            fxmode_sync <= 3'b000;
        end else begin
            track_sync  <= {track_sync[1:0],  track_toggle};
            vol_sync    <= {vol_sync[1:0],    vol_toggle};
            fxmode_sync <= {fxmode_sync[1:0], fxmode_toggle};
        end
    end

    wire track_step  = track_sync[2]  ^ track_sync[1];
    wire vol_step    = vol_sync[2]    ^ vol_sync[1];
    wire fxmode_step = fxmode_sync[2] ^ fxmode_sync[1];

    // ---- 音视频联动：曲目跟着「当前正在显示的那张图」走 ----
    // 赛题扩展要求(2) 是「音视频联动：图片切换时音频同步切换」。
    // 这里把 track_sel 绑到「已装载完成张数 - 1」—— 帧仓每提交一张图才 +1，
    // 而显示的就是最后提交的那一槽，所以这个序号恒等于当前显示图片的序号。
    // 图片序号 k 落在槽 (k mod 8)，取低 3 位正好是槽号，绕回时也一致。
    // key1 短按从"选曲"改成"叠加偏移"，手动换曲的能力保留。
    // med_img_loaded 是 pixel_clk 域的寄存器输出，与 track_sel 同域，无需同步器。
    reg  [2:0] track_off;
    wire [3:0] img_now    = (med_img_loaded == 8'd0) ? 4'd0 : (med_img_loaded[3:0] - 4'd1);
    wire [2:0] track_auto = img_now[2:0];

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            track_off <= 3'd0;
            vol       <= 4'd8;
        end else begin
            if (track_step) track_off <= track_off + 3'd1;
            if (vol_step)   vol       <= (vol >= 4'd8) ? 4'd2 : (vol + 4'd2);
        end
    end

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) track_sel <= 3'd0;
        else              track_sel <= track_auto + track_off;
    end

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) fx_mode <= 2'd2;
        else if (fxmode_step) begin
            case (fx_mode)
                2'd0:    fx_mode <= 2'd2;
                2'd2:    fx_mode <= 2'd3;
                default: fx_mode <= 2'd0;
            endcase
        end
    end

    reg fx_auto_done;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n)   fx_auto_done <= 1'b0;
        else if (video_en)  fx_auto_done <= 1'b1;
    end

    assign fx_start = (video_en && !fx_auto_done) || track_step;

    // =====================================================================
    // 数码管状态字（本板只有 4 位）
    //   [15:12] {SD 超时, SD 初始化完成, 媒体层出错, 帧仓有图}
    //   [11:8]  帧仓状态（bit3 读 / bit2 写 / bit1 欠载 / bit0 就绪）
    //   [7:4]   已装载张数低 4 位
    //   [3:0]   找到张数低 4 位
    // =====================================================================
    wire [15:0] status_word = {sd_timeout, sd_init_done, |med_err, have_img,
                               fs_state, med_img_loaded[3:0], med_img_count[3:0]};

    seg_display #(.CLK_FREQ_HZ (50_000_000), .SCAN_FREQ (200)) u_seg_display (
        .clk      (clk),
        .rst_n    (por_rst_n),
        .disp_val (status_word),
        .dp_mask  (4'b0000),
        .seg_sel  (seg_sel),
        .seg_data (seg_data)
    );

    // =====================================================================
    // EDID 读取触发：上电约 4 ms 后打一拍
    // =====================================================================
    reg [19:0] edid_cnt;
    reg        edid_trig;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            edid_cnt  <= 20'd0;
            edid_trig <= 1'b0;
        end else if (edid_cnt == 20'd100_000) begin
            edid_cnt  <= edid_cnt;
            edid_trig <= 1'b1;
        end else begin
            edid_cnt  <= edid_cnt + 20'd1;
            edid_trig <= 1'b0;
        end
    end

    // =====================================================================
    // HDMI 1.4b 发送核（加密黑盒）+ TMDS PHY
    // =====================================================================
    wire        edid_valid;
    wire [7:0]  edid_data;
    wire        axis_ready;
    wire        video_locked;
    wire [9:0]  tmds_ch0, tmds_ch1, tmds_ch2, tmds_clk;
    wire        hdmi_ddc_scl_unused;
    wire        hdmi_ddc_sda_unused;

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ("EG"),
        .HTOTAL            (800),
        .HSA               (96),
        .HFP               (16),
        .HBP               (48),
        .HACTIVE           (640),
        .VTOTAL            (525),
        .VSA               (2),
        .VFP               (10),
        .VBP               (33),
        .VACTIVE           (480),
        .VIDEO_VIC         (1),
        .VIDEO_TPG         ("Disable"),
        .VIDEO_FORMAT      ("RGB"),
        .AUDIO_SAMPLE_RATE ("48K"),
        .IIC_SCL_DIV       (250)
    ) u_hdmi_core (
        .I_pixel_clk        (pixel_clk),
        .I_rst              (~pixel_rst_n),
        .I_edid_read_trig   (edid_trig),
        .O_edid_read_valid  (edid_valid),
        .O_edid_read_data   (edid_data),
        .I_axis_s_user      (axis_user),
        .I_axis_s_valid     (axis_valid),
        .I_axis_s_last      (axis_last),
        .I_axis_s_data      (axis_data),
        .O_axis_s_ready     (axis_ready),
        .I_audio_valid      (audio_valid),
        .I_audio_left_data  (audio_l),
        .I_audio_right_data (audio_r),
        .I_acr_valid        (acr_valid),
        .I_acr_cts          (acr_cts),
        .I_acr_n            (acr_n),
        .O_video_locked     (video_locked),
        .O_ddc_scl          (hdmi_ddc_scl_unused),
        .IO_ddc_sda         (hdmi_ddc_sda_unused),
        .O_ch0_tmds_data    (tmds_ch0),
        .O_ch1_tmds_data    (tmds_ch1),
        .O_ch2_tmds_data    (tmds_ch2),
        .O_clk_tmds_data    (tmds_clk)
    );

    hdmi_phy_wrapper #(.DEVICE ("EG")) u_hdmi_phy (
        .I_pixel_clk        (pixel_clk),
        .I_serial_clk       (serial_clk),
        .I_rst              (~pixel_rst_n),
        .I_tmds_channel_0   (tmds_ch0),
        .I_tmds_channel_1   (tmds_ch1),
        .I_tmds_channel_2   (tmds_ch2),
        .I_tmds_channel_clk (tmds_clk),
        .O_tmds_ch0_p       (HDMI_D0_P),
        .O_tmds_ch1_p       (HDMI_D1_P),
        .O_tmds_ch2_p       (HDMI_D2_P),
        .O_tmds_clk_p       (HDMI_CLK_P)
    );

    // 未使用但需要保留 / 消除告警的信号
    wire unused_ok = vhs_n ^ vs_n ^ video_locked ^ edid_valid ^ axis_ready ^
                     |edid_data ^ fs_underrun ^ fs_underrun_b ^ fx_busy ^
                     key1_long ^ key2_long ^ |y_d1 ^ |med_pix_row_end ^
                     |med_img_done ^ |med_load_slot ^
                     hdmi_ddc_scl_unused;

endmodule
