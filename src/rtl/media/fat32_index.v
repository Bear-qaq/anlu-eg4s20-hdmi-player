//=============================================================================
// 模块：fat32_index
// 功能：FAT32 根目录索引器。读 0 号扇区解析 BPB，再沿根目录簇链枚举出所有
//       `*.BMP` 文件，把 {起始簇, 文件字节数} 写进片上目录表。
//
// ★ 这是「图片处理方法」与例程最根本的差异（官方红线之一）。
//   例程 bmp_read.v **完全不读文件系统**：从 LBA 0 起逐扇区扫，命中 'BM' 魔数
//   就当一张图，尺寸还是顶层写死的常量。后果是：
//     - 卡上删除残留的旧图会被误认（所以官方才要配套 sync_to_sd.py 先把旧 BMP 的
//       'BM' 改成 'XX' 再拷新图）；
//     - 图片必须物理连续才读得快；
//     - 64 MB 之后的图片永远扫不到（SCAN_MAX_SECTOR=131071）；
//     - 只能固定 4 张（img_sector0..3）。
//   本模块改为**问文件系统**：读 BPB 拿几何参数，遍历根目录簇链读目录项，
//   文件数量不设上限（表深 N_MAX），也不要求物理连续（后续按 FAT 链读）。
//
// 扇区源接口（把 SD 卡抽象掉，纯逻辑就能在 ModelSim 里用合成镜像验证）：
//   sec_req 拉高 + sec_addr 给出 LBA；源接受请求时打一拍 src_ack，
//   随后连续给 512 个字节（src_byte_en 每字节一拍，src_last 标出最后一个字节）。
//
//   ★ `wait_ack` 这道门槛是必需的，不是多余的：
//     目录里遇到 0x00 终止项时状态机会**提前放弃**当前扇区（不再等 src_last），
//     而源仍会把剩余字节吐完。如果下一轮扫描不区分「这是上一扇区的残字节」，
//     就会把它们当成新扇区的开头 —— 实测现象是第二轮扫描收到的「BPB」全是 0，
//     BytsPerSec 校验失败、错误码 1。加了 ack 之后，只有**被接受的请求之后**
//     的字节才会被消费。
//
// 目录表读端口：rd_idx -> rd_clus / rd_size / rd_ok
//
// 错误码：
//   0 正常            1 BytsPerSec != 512   2 SecPerClus 非 2 的幂
//   3 NumFATs == 0    4 FATSz32 == 0        5 RootClus < 2
//   6 FAT 链出现空簇 / 非法簇号
//=============================================================================
`timescale 1ns / 1ps

module fat32_index #(
    parameter N_MAX   = 16,
    parameter MAX_SEC = 16'd4096     // 枚举时的扇区上限（防御性，防止死循环）
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,

    // ---- 扇区源 ----
    output reg         sec_req,
    output reg  [31:0] sec_addr,
    input  wire        src_ack,
    input  wire        src_byte_en,
    input  wire [7:0]  src_byte,
    input  wire        src_last,

    // ---- 结果 ----
    output reg  [4:0]  img_count,
    output reg         done,
    output reg  [3:0]  err_code,
    output reg  [3:0]  state_code,

    // ---- 片上目录表读端口 ----
    input  wire [3:0]  rd_idx,
    output wire [31:0] rd_clus,
    output wire [31:0] rd_size,
    output wire        rd_ok,

    // ---- 几何参数（给 media_loader 按簇链读文件用，扫描完成后有效）----
    output wire [31:0] o_data_start,
    output wire [31:0] o_rsvd,
    output wire [31:0] o_fatsz,
    output wire [7:0]  o_spc,
    output wire [3:0]  o_spc_log2
);

    localparam [3:0] S_IDLE   = 4'd0;
    localparam [3:0] S_BPB    = 4'd1;
    localparam [3:0] S_JUDGE  = 4'd2;
    localparam [3:0] S_DIR    = 4'd3;
    localparam [3:0] S_DIREND = 4'd4;
    localparam [3:0] S_FAT    = 4'd5;
    localparam [3:0] S_FATEND = 4'd6;
    localparam [3:0] S_DONE   = 4'd7;
    localparam [3:0] S_ERR    = 4'd8;

    localparam [4:0] N_MAX5 = N_MAX;

    // ---------------------------------------------------------------- 片上目录表
    // 用寄存器实现（不是 ERAM）：写入索引是变量、读端口也只有一路，
    // 规模只有 16 x 65 bit 约 1040 个寄存器，占 19600 的 5%，比占一块 ERAM 划算。
    reg [31:0] tbl_clus [0:N_MAX-1];
    reg [31:0] tbl_size [0:N_MAX-1];
    reg        tbl_ok   [0:N_MAX-1];

    assign rd_clus = tbl_clus[rd_idx];
    assign rd_size = tbl_size[rd_idx];
    assign rd_ok   = tbl_ok[rd_idx];

    // ---------------------------------------------------------------- BPB 字段
    // 这里**不用移位寄存器**。移位寄存器收集字节时「字节 i 落在哪几位」很容易算错，
    // 而 BPB 字段全是小端、还 u8/u16/u32 混排，位置一错几何参数就全错。
    // 改成 64 字节的寄存器数组按偏移直取，一目了然。
    reg [7:0] bpb [0:63];
    reg [6:0] bpb_cnt;

    wire [15:0] b_byts    = {bpb[12], bpb[11]};
    wire [7:0]  b_spc     = bpb[13];
    wire [15:0] b_rsvd    = {bpb[15], bpb[14]};
    wire [7:0]  b_nfat    = bpb[16];
    wire [15:0] b_rootent = {bpb[18], bpb[17]};
    wire [31:0] b_fatsz   = {bpb[39], bpb[38], bpb[37], bpb[36]};
    wire [31:0] b_rootc   = {bpb[47], bpb[46], bpb[45], bpb[44]};

    wire v_byts = (b_byts == 16'd512);
    wire v_spc  = (b_spc == 8'd1)  || (b_spc == 8'd2)  || (b_spc == 8'd4)  ||
                  (b_spc == 8'd8)  || (b_spc == 8'd16) || (b_spc == 8'd32) ||
                  (b_spc == 8'd64) || (b_spc == 8'd128);
    wire v_nfat = (b_nfat != 8'd0);
    wire v_fats = (b_fatsz != 32'd0);
    wire v_root = (b_rootc >= 32'd2);
    wire bpb_ok = v_byts && v_spc && v_nfat && v_fats && v_root;

    reg [3:0] spc_log2;
    always @(*) begin
        case (b_spc)
            8'd1:    spc_log2 = 4'd0;
            8'd2:    spc_log2 = 4'd1;
            8'd4:    spc_log2 = 4'd2;
            8'd8:    spc_log2 = 4'd3;
            8'd16:   spc_log2 = 4'd4;
            8'd32:   spc_log2 = 4'd5;
            8'd64:   spc_log2 = 4'd6;
            8'd128:  spc_log2 = 4'd7;
            default: spc_log2 = 4'd0;
        endcase
    end

    // 数据区起点 = 保留扇区数 + FAT 数 x 每 FAT 扇区数 + 根目录项占用扇区数
    // （FAT32 的 RootEntCnt 通常为 0，根目录本身走簇链）
    wire [31:0] ds_calc = {16'd0, b_rsvd} + ({24'd0, b_nfat} * b_fatsz)
                        + ({16'd0, b_rootent} >> 4);
    wire [31:0] root_first = ds_calc + ((b_rootc - 32'd2) << spc_log2);

    // ---------------------------------------------------------------- 状态
    reg [3:0]  state;
    reg [31:0] data_start;
    reg [31:0] cur_clus;
    reg [15:0] clus_left;
    reg [31:0] cur_sec;
    reg [15:0] sec_cnt;
    reg [9:0]  byte_cnt;
    reg        wait_ack;
    // ★ 遇到目录终止项时**不能立刻走人**：必须把本扇区剩下的字节收完（收到 src_last），
    //   否则上游「整扇区缓冲」的扇区源里会残留未读字节，下一次请求读到的就是错位数据。
    //   （早期版本在终止项处直接跳 S_DONE，仿真里因为模型每次重发整扇区而看不出问题，
    //     换成 FIFO 缓冲的真实扇区源就会错位。）
    reg        stop_now;

    // 目录项字段（按项内偏移抓）
    reg [7:0]  e_name0;
    reg [23:0] e_ext;
    reg [7:0]  e_attr;
    reg [15:0] e_ch;
    reg [15:0] e_cl;
    reg [31:0] e_size;

    // FAT 项
    reg [31:0] fat_val;
    reg [1:0]  fat_byte;
    reg [8:0]  fat_off;

    // 几何参数锁存（扫描开始时清、S_JUDGE 时写入），供外部按簇链读文件
    reg [31:0] geo_rsvd;
    reg [31:0] geo_fatsz;
    reg [7:0]  geo_spc;
    reg [3:0]  geo_log2;

    assign o_data_start = data_start;
    assign o_rsvd       = geo_rsvd;
    assign o_fatsz      = geo_fatsz;
    assign o_spc        = geo_spc;
    assign o_spc_log2   = geo_log2;

    integer ti;

    // 簇号 -> 首扇区
    function [31:0] clus_first_sec;
        input [31:0] c;
        input [3:0]  lg;
        begin
            clus_first_sec = data_start + ((c - 32'd2) << lg);
        end
    endfunction

    wire [31:0] fat_sec_addr  = {16'd0, b_rsvd} + (cur_clus >> 7);
    wire [8:0]  fat_entry_off = {cur_clus[6:0], 2'b00};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            sec_req    <= 1'b0;
            sec_addr   <= 32'd0;
            bpb_cnt    <= 7'd0;
            data_start <= 32'd0;
            cur_clus   <= 32'd0;
            clus_left  <= 16'd0;
            cur_sec    <= 32'd0;
            sec_cnt    <= 16'd0;
            byte_cnt   <= 10'd0;
            err_code   <= 4'd0;
            img_count  <= 5'd0;
            done       <= 1'b0;
            state_code <= 4'd0;
            fat_val    <= 32'd0;
            fat_byte   <= 2'd0;
            fat_off    <= 9'd0;
            wait_ack   <= 1'b1;
            stop_now   <= 1'b0;
            e_name0    <= 8'd0;
            e_ext      <= 24'd0;
            e_attr     <= 8'd0;
            e_ch       <= 16'd0;
            e_cl       <= 16'd0;
            e_size     <= 32'd0;
            for (ti = 0; ti < N_MAX; ti = ti + 1) begin
                tbl_clus[ti] <= 32'd0;
                tbl_size[ti] <= 32'd0;
                tbl_ok[ti]   <= 1'b0;
            end
        end else begin
            done <= 1'b0;

            // 请求被接受 -> 允许消费字节；一个扇区收完 -> 重新等下一次接受
            if (src_ack)       wait_ack <= 1'b0;
            else if (src_last) wait_ack <= 1'b1;

            case (state)
                // -------------------------------------------- 等启动
                S_IDLE: begin
                    sec_req <= 1'b0;
                    if (start) begin
                        bpb_cnt   <= 7'd0;
                        byte_cnt  <= 10'd0;
                        img_count <= 5'd0;
                        err_code  <= 4'd0;
                        sec_cnt   <= 16'd0;
                        wait_ack  <= 1'b1;
                        for (ti = 0; ti < N_MAX; ti = ti + 1) tbl_ok[ti] <= 1'b0;
                        sec_addr  <= 32'd0;
                        sec_req   <= 1'b1;
                        state     <= S_BPB;
                    end
                end

                // -------------------------------------------- 收 0 号扇区前 64 字节
                S_BPB: begin
                    if (src_byte_en && !wait_ack) begin
                        if (bpb_cnt < 7'd64) begin
                            bpb[bpb_cnt] <= src_byte;
                            bpb_cnt      <= bpb_cnt + 7'd1;
                        end
                        if (src_last) begin
                            sec_req <= 1'b0;
                            state   <= S_JUDGE;
                        end
                    end
                end

                // -------------------------------------------- 校验并算几何参数
                S_JUDGE: begin
                    if (bpb_ok) begin
                        data_start <= ds_calc;
                        geo_rsvd   <= {16'd0, b_rsvd};
                        geo_fatsz  <= b_fatsz;
                        geo_spc    <= b_spc;
                        geo_log2   <= spc_log2;
                        cur_clus   <= b_rootc;
                        clus_left  <= {8'd0, b_spc};
                        cur_sec    <= root_first;
                        sec_addr   <= root_first;
                        byte_cnt   <= 10'd0;
                        err_code   <= 4'd0;
                        sec_req    <= 1'b1;
                        state      <= S_DIR;
                    end else begin
                        if      (!v_byts) err_code <= 4'd1;
                        else if (!v_spc)  err_code <= 4'd2;
                        else if (!v_nfat) err_code <= 4'd3;
                        else if (!v_fats) err_code <= 4'd4;
                        else              err_code <= 4'd5;
                        state <= S_ERR;
                    end
                end

                // -------------------------------------------- 扫一个目录扇区
                S_DIR: begin
                    if (src_byte_en && !wait_ack) begin
                        byte_cnt <= byte_cnt + 10'd1;

                        case (byte_cnt[4:0])
                            5'd0:  e_name0 <= src_byte;
                            5'd8:  e_ext[7:0]   <= src_byte;
                            5'd9:  e_ext[15:8]  <= src_byte;
                            5'd10: e_ext[23:16] <= src_byte;
                            5'd11: e_attr <= src_byte;
                            5'd20: e_ch[7:0]   <= src_byte;
                            5'd21: e_ch[15:8]  <= src_byte;
                            5'd26: e_cl[7:0]   <= src_byte;
                            5'd27: e_cl[15:8]  <= src_byte;
                            5'd28: e_size[7:0]   <= src_byte;
                            5'd29: e_size[15:8]  <= src_byte;
                            5'd30: e_size[23:16] <= src_byte;
                            5'd31: e_size[31:24] <= src_byte;
                            default: ;
                        endcase

                        // 一项结束（项内偏移 31）时判定
                        if (byte_cnt[4:0] == 5'd31 && !stop_now) begin
                            if (e_name0 == 8'h00) begin
                                stop_now <= 1'b1;   // 目录到此为止，但先把本扇区收完
                            end else if (e_name0 != 8'hE5      &&  // 未删除
                                         e_attr        != 8'h0F &&  // 非长文件名项
                                         e_attr[4]     == 1'b0  &&  // 非目录
                                         e_attr[3]     == 1'b0  &&  // 非卷标
                                         e_ext[7:0]    == 8'h42 &&  // 'B'
                                         e_ext[15:8]   == 8'h4D &&  // 'M'
                                         e_ext[23:16]  == 8'h50 &&  // 'P'
                                         img_count < N_MAX5) begin
                                tbl_clus[img_count[3:0]] <= {e_ch, e_cl};
                                tbl_size[img_count[3:0]] <= e_size;
                                tbl_ok[img_count[3:0]]   <= 1'b1;
                                img_count <= img_count + 5'd1;
                            end
                        end

                        if (src_last) begin
                            sec_req  <= 1'b0;
                            byte_cnt <= 10'd0;
                            sec_cnt  <= sec_cnt + 16'd1;
                            state    <= S_DIREND;
                        end
                    end
                end

                // -------------------------------------------- 本目录扇区后续
                S_DIREND: begin
                    if (stop_now) begin
                        state <= S_DONE;            // 本扇区已收完，可以安全收尾
                    end else if (sec_cnt >= MAX_SEC) begin
                        state <= S_DONE;
                    end else if (clus_left > 16'd1) begin
                        clus_left <= clus_left - 16'd1;
                        cur_sec   <= cur_sec + 32'd1;
                        sec_addr  <= cur_sec + 32'd1;
                        sec_req   <= 1'b1;
                        byte_cnt  <= 10'd0;
                        state     <= S_DIR;
                    end else begin
                        // 本簇读完，读 FAT 项拿下一个簇
                        fat_off  <= fat_entry_off;
                        fat_byte <= 2'd0;
                        sec_req  <= 1'b1;
                        sec_addr <= fat_sec_addr;
                        byte_cnt <= 10'd0;
                        state    <= S_FAT;
                    end
                end

                // -------------------------------------------- 读 FAT 项
                S_FAT: begin
                    if (src_byte_en && !wait_ack) begin
                        if (byte_cnt[8:0] == fat_off) begin
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
                        byte_cnt <= byte_cnt + 10'd1;

                        if (src_last) begin
                            sec_req <= 1'b0;
                            state   <= S_FATEND;
                        end
                    end
                end

                // -------------------------------------------- 判定下一个簇
                S_FATEND: begin
                    // FAT32 簇号只用低 28 位；>= 0x0FFFFFF8 表示链结束
                    if (fat_val[27:0] >= 28'h0FFFFFF8) begin
                        state <= S_DONE;
                    end else if (fat_val[27:0] < 28'd2) begin
                        err_code <= 4'd6;
                        state    <= S_ERR;
                    end else begin
                        cur_clus  <= {4'd0, fat_val[27:0]};
                        clus_left <= {8'd0, b_spc};
                        cur_sec   <= clus_first_sec({4'd0, fat_val[27:0]}, spc_log2);
                        sec_addr  <= clus_first_sec({4'd0, fat_val[27:0]}, spc_log2);
                        sec_req   <= 1'b1;
                        byte_cnt  <= 10'd0;
                        state     <= S_DIR;
                    end
                end

                // -------------------------------------------- 结束 / 出错（都接受重新 start）
                S_DONE, S_ERR: begin
                    sec_req <= 1'b0;
                    done    <= 1'b1;
                    if (start) begin
                        bpb_cnt   <= 7'd0;
                        byte_cnt  <= 10'd0;
                        img_count <= 5'd0;
                        err_code  <= 4'd0;
                        sec_cnt   <= 16'd0;
                        wait_ack  <= 1'b1;
                        stop_now  <= 1'b0;
                        for (ti = 0; ti < N_MAX; ti = ti + 1) tbl_ok[ti] <= 1'b0;
                        sec_addr  <= 32'd0;
                        sec_req   <= 1'b1;
                        state     <= S_BPB;
                    end
                end

                default: state <= S_IDLE;
            endcase

            state_code <= state;
        end
    end

endmodule
