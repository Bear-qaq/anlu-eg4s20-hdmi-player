//=============================================================================
// 模块：media_loader
// 功能：媒体层编排。把「FAT32 目录索引」「按簇链读文件」「BMP 流解码」串成一条链，
//       最终吐出一张张 24 bit 像素流给帧仓写入侧。
//
// 数据流：
//   扇区源 --> fat32_index --> 目录表 {起始簇, 文件大小}
//                 |
//                 +--> 逐图：按 FAT 簇链读文件的每个扇区
//                          --> bmp_stream_decoder（解头 + 出像素）
//                          --> pix_en / pix / pix_vflip 给帧仓
//
// ★ 与例程的差异：例程 `sd_card_bmp` 是「盲扫扇区 -> 记下 4 个扇区号 -> 每次切图
//   重新从那个扇区整帧读」，而且长度靠 `ceil(file_len/512)` 猜。
//   本模块先从目录项拿到**文件真实字节数**，再按 FAT 链把文件流式读出来 ——
//   读到 0 字节就是读完，天然支持碎片化文件。
//
// 扇区源是共享的：扫描阶段归 fat32_index，装载阶段归本模块的读文件状态机。
// 两者复用同一组 sec_req/sec_addr，字节流按 src_ack 握手区分归属。
//
// 端口：
//   start      上升沿启动「扫描 + 装载全部图片」一次
//   sec_*      扇区源接口（接 SD 驱动适配器；仿真时接行为模型）
//   pix_*      像素输出 -> 帧仓写入侧
//   load_slot  当前正在装载第几槽
//   img_count  找到几张图
//   err_code   0 正常 / 1 目录扫描失败 / 2 FAT 链断裂或文件损坏 / 3 BMP 头非法
//=============================================================================
`timescale 1ns / 1ps

module media_loader #(
    parameter N_MAX     = 16,
    parameter IMG_W     = 640,
    parameter IMG_H     = 480,
    parameter IMGEND_TMO= 16'd4096     // 等解码器 frame_end 的超时拍数（防御性）
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,

    // ---- 扇区源 ----
    output wire        sec_req,
    output wire [31:0] sec_addr,
    input  wire        src_ack,
    input  wire        src_byte_en,
    input  wire [7:0]  src_byte,
    input  wire        src_last,

    // ---- 像素输出（接帧仓写入侧）----
    output wire        pix_en,
    output wire [23:0] pix,
    output wire        pix_vflip,
    output wire        pix_row_end,
    output wire        img_done,
    output wire [2:0]  load_slot,

    // ---- 诊断 ----
    output wire [4:0]  img_count,
    output wire [7:0]  img_loaded,
    output reg  [3:0]  err_code,
    output reg  [3:0]  state_code
);

    localparam [3:0] L_IDLE   = 4'd0;
    localparam [3:0] L_SCAN   = 4'd1;
    localparam [3:0] L_NEXT   = 4'd2;
    localparam [3:0] L_DATA   = 4'd3;
    localparam [3:0] L_FAT    = 4'd4;
    localparam [3:0] L_FATJ   = 4'd5;
    localparam [3:0] L_IMGEND = 4'd6;
    localparam [3:0] L_DONE   = 4'd7;
    localparam [3:0] L_ERR    = 4'd8;

    reg [3:0]  state;
    reg [3:0]  img_idx;
    reg [7:0]  loaded_cnt;

    // ---------------------------------------------------------------- 子模块连线
    reg         idx_start;
    wire        idx_done;
    wire        idx_sec_req;
    wire [31:0] idx_sec_addr;
    wire [3:0]  idx_err;
    wire [31:0] g_data_start, g_rsvd, g_fatsz;
    wire [7:0]  g_spc;
    wire [3:0]  g_log2;
    wire [31:0] tbl_clus, tbl_size;
    wire        tbl_ok;

    reg         dec_start;
    wire        dec_hdr_done, dec_hdr_ok, dec_vflip, dec_pix_en, dec_row_end, dec_frame_end;
    wire [3:0]  dec_err;
    wire [23:0] dec_pix;
    wire [8:0]  dec_src_row;

    // 读文件状态
    reg  [31:0] cur_clus;
    reg  [31:0] size_left;
    reg  [15:0] clus_sec_left;
    reg  [31:0] my_sec_addr;
    reg         my_sec_req;
    reg  [9:0]  sec_bcnt;
    reg         wait_ack;
    reg         hdr_bad;
    reg  [15:0] imgend_tmo;
    reg  [31:0] fat_val;
    reg  [1:0]  fat_byte;
    reg  [8:0]  fat_off;

    wire own_src = (state == L_DATA) || (state == L_FAT);

    // ---------------------------------------------------------------- 扇区源复用
    assign sec_req  = (state == L_SCAN) ? idx_sec_req : my_sec_req;
    assign sec_addr = (state == L_SCAN) ? idx_sec_addr : my_sec_addr;

    // ack / last 只在本模块拥有扇区源时才算数（扫描阶段的 ack 不能清本模块的门槛）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                      wait_ack <= 1'b1;
        else if (src_ack && own_src)     wait_ack <= 1'b0;
        else if (src_last && own_src)    wait_ack <= 1'b1;
    end

    // ---------------------------------------------------------------- fat32_index
    fat32_index #(.N_MAX(N_MAX)) u_index (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (idx_start),
        .sec_req      (idx_sec_req),
        .sec_addr     (idx_sec_addr),
        .src_ack      (src_ack),
        .src_byte_en  (src_byte_en),
        .src_byte     (src_byte),
        .src_last     (src_last),
        .img_count    (img_count),
        .done         (idx_done),
        .err_code     (idx_err),
        .state_code   (),
        .rd_idx       (img_idx),
        .rd_clus      (tbl_clus),
        .rd_size      (tbl_size),
        .rd_ok        (tbl_ok),
        .o_data_start (g_data_start),
        .o_rsvd       (g_rsvd),
        .o_fatsz      (g_fatsz),
        .o_spc        (g_spc),
        .o_spc_log2   (g_log2)
    );

    // ---------------------------------------------------------------- BMP 解码器
    // 只在装载阶段喂字节；文件读完后不再喂，解码器自己会停在 S_DONE
    wire dec_byte_en = src_byte_en && own_src && !wait_ack && (size_left != 32'd0);

    bmp_stream_decoder #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_bmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (dec_start),
        .byte_en   (dec_byte_en),
        .byte_in   (src_byte),
        .hdr_done  (dec_hdr_done),
        .hdr_ok    (dec_hdr_ok),
        .err_code  (dec_err),
        .vflip     (dec_vflip),
        .pix_en    (dec_pix_en),
        .pix       (dec_pix),
        .src_row   (dec_src_row),
        .row_end   (dec_row_end),
        .frame_end (dec_frame_end)
    );

    assign pix_en      = dec_pix_en;
    assign pix         = dec_pix;
    assign pix_vflip   = dec_vflip;
    assign pix_row_end = dec_row_end;
    assign img_done    = dec_frame_end;
    assign load_slot   = img_idx[2:0];
    assign img_loaded  = loaded_cnt;

    // 簇号 -> 首扇区
    function [31:0] clus_first_sec;
        input [31:0] c;
        begin
            clus_first_sec = g_data_start + ((c - 32'd2) << g_log2);
        end
    endfunction

    // FAT 项所在扇区与扇区内偏移
    wire [31:0] my_fat_sec = g_rsvd + (cur_clus >> 7);
    wire [8:0]  my_fat_off = {cur_clus[6:0], 2'b00};

    // 头部是否非法（锁存，供 L_IMGEND 判定）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hdr_bad <= 1'b0;
        else if (state == L_NEXT) hdr_bad <= 1'b0;
        else if (dec_hdr_done)    hdr_bad <= ~dec_hdr_ok;
    end

    // ★ dec_frame_end 是**单拍脉冲**，而它出现的时刻是「文件最后一个字节被吃进去」
    //   那一拍 —— 那时状态机还在 L_DATA 里把本扇区剩下的字节收完（文件通常不会
    //   正好占满整扇区）。等走到 L_IMGEND 时脉冲早就没了，必须就地锁存。
    //   （实测症状：像素全对、vflip 对、err=0，只有 loaded 计数为 0。）
    reg seen_frame_end;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) seen_frame_end <= 1'b0;
        else if (state == L_NEXT) seen_frame_end <= 1'b0;
        else if (dec_frame_end)   seen_frame_end <= 1'b1;
    end

    // ---------------------------------------------------------------- 主状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= L_IDLE;
            img_idx       <= 4'd0;
            loaded_cnt    <= 8'd0;
            idx_start     <= 1'b0;
            cur_clus      <= 32'd0;
            size_left     <= 32'd0;
            clus_sec_left <= 16'd0;
            my_sec_addr   <= 32'd0;
            my_sec_req    <= 1'b0;
            sec_bcnt      <= 10'd0;
            imgend_tmo    <= 16'd0;
            fat_val       <= 32'd0;
            fat_byte      <= 2'd0;
            fat_off       <= 9'd0;
            dec_start     <= 1'b0;
            err_code      <= 4'd0;
            state_code    <= 4'd0;
        end else begin
            idx_start <= 1'b0;
            dec_start <= 1'b0;

            case (state)
                // -------------------------------------------- 等启动
                L_IDLE: begin
                    my_sec_req <= 1'b0;
                    if (start) begin
                        err_code   <= 4'd0;
                        img_idx    <= 4'd0;
                        loaded_cnt <= 8'd0;
                        idx_start  <= 1'b1;
                        state      <= L_SCAN;
                    end
                end

                // -------------------------------------------- 目录扫描
                L_SCAN: begin
                    my_sec_req <= 1'b0;
                    if (idx_done) begin
                        if (idx_err != 4'd0 || img_count == 5'd0) begin
                            err_code <= 4'd1;
                            state    <= L_ERR;
                        end else begin
                            state <= L_NEXT;
                        end
                    end
                end

                // -------------------------------------------- 取下一张图
                L_NEXT: begin
                    if ({1'b0, img_idx} >= img_count) begin
                        state <= L_DONE;
                    end else if (!tbl_ok || tbl_size == 32'd0) begin
                        img_idx <= img_idx + 4'd1;      // 目录项不可用，跳过
                    end else begin
                        cur_clus      <= tbl_clus;
                        size_left     <= tbl_size;
                        clus_sec_left <= {8'd0, g_spc};
                        my_sec_addr   <= clus_first_sec(tbl_clus);
                        my_sec_req    <= 1'b1;
                        sec_bcnt      <= 10'd0;
                        imgend_tmo    <= 16'd0;
                        dec_start     <= 1'b1;          // 让解码器从头开始
                        state         <= L_DATA;
                    end
                end

                // -------------------------------------------- 读文件数据扇区
                L_DATA: begin
                    if (src_byte_en && !wait_ack) begin
                        sec_bcnt <= sec_bcnt + 10'd1;
                        if (size_left != 32'd0)
                            size_left <= size_left - 32'd1;

                        if (src_last) begin
                            my_sec_req <= 1'b0;
                            sec_bcnt   <= 10'd0;
                            if (size_left <= 32'd1) begin
                                // 本拍扣掉最后一个字节 -> 文件读完
                                imgend_tmo <= 16'd0;
                                state      <= L_IMGEND;
                            end else if (clus_sec_left > 16'd1) begin
                                clus_sec_left <= clus_sec_left - 16'd1;
                                my_sec_addr   <= my_sec_addr + 32'd1;
                                my_sec_req    <= 1'b1;
                                state         <= L_DATA;
                            end else begin
                                fat_off     <= my_fat_off;
                                fat_byte    <= 2'd0;
                                my_sec_addr <= my_fat_sec;
                                my_sec_req  <= 1'b1;
                                state       <= L_FAT;
                            end
                        end
                    end
                end

                // -------------------------------------------- 读 FAT 项
                L_FAT: begin
                    if (src_byte_en && !wait_ack) begin
                        if (sec_bcnt[8:0] == fat_off) begin
                            fat_val[7:0] <= src_byte;
                            fat_byte     <= 2'd1;
                        end else if (fat_byte != 2'd0) begin
                            case (fat_byte)
                                2'd1: fat_val[15:8]  <= src_byte;
                                2'd2: fat_val[23:16] <= src_byte;
                                2'd3: fat_val[31:24] <= src_byte;
                                default: ;
                            endcase
                            fat_byte <= fat_byte + 2'd1;
                        end
                        sec_bcnt <= sec_bcnt + 10'd1;

                        if (src_last) begin
                            my_sec_req <= 1'b0;
                            sec_bcnt   <= 10'd0;
                            state      <= L_FATJ;
                        end
                    end
                end

                L_FATJ: begin
                    if (fat_val[27:0] >= 28'h0FFFFFF8 || fat_val[27:0] < 28'd2) begin
                        // 链断了但文件还没读完 -> 文件损坏
                        err_code <= 4'd2;
                        state    <= L_ERR;
                    end else begin
                        cur_clus      <= {4'd0, fat_val[27:0]};
                        clus_sec_left <= {8'd0, g_spc};
                        my_sec_addr   <= clus_first_sec({4'd0, fat_val[27:0]});
                        my_sec_req    <= 1'b1;
                        sec_bcnt      <= 10'd0;
                        state         <= L_DATA;
                    end
                end

                // -------------------------------------------- 一张图结束
                // 等解码器把最后一行吐完（frame_end）。加超时保护，
                // 万一 BMP 头合法但像素数据不足，也不能卡死在这里。
                L_IMGEND: begin
                    my_sec_req <= 1'b0;
                    imgend_tmo <= imgend_tmo + 16'd1;
                    if (seen_frame_end || imgend_tmo >= IMGEND_TMO) begin
                        if (seen_frame_end) loaded_cnt <= loaded_cnt + 8'd1;
                        if (hdr_bad && err_code == 4'd0) err_code <= 4'd3;
                        img_idx <= img_idx + 4'd1;
                        state   <= L_NEXT;
                    end
                end

                // -------------------------------------------- 全部完成 / 出错
                L_DONE, L_ERR: begin
                    my_sec_req <= 1'b0;
                    if (start) begin
                        err_code   <= 4'd0;
                        img_idx    <= 4'd0;
                        loaded_cnt <= 8'd0;
                        idx_start  <= 1'b1;
                        state      <= L_SCAN;
                    end
                end

                default: state <= L_IDLE;
            endcase

            state_code <= state;
        end
    end

endmodule
