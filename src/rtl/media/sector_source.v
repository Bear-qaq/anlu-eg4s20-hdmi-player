//=============================================================================
// 模块：sector_source
// 功能：扇区源适配器。把例程的 SD 卡 SPI 驱动（100 MHz 域）包装成
//       `fat32_index` / `media_loader` 要的四线协议（25 MHz 域）。
//
// 协议（与 sim/tb_fat32_index.v 里的行为模型完全一致）：
//   消费方：sec_req 拉高 + sec_addr 给出 LBA
//   本模块：接受请求时打一拍 src_ack
//   本模块：随后 512 拍 src_byte_en + src_byte，最后一拍 src_last
//   ★ ack 与第一个字节之间**隔一拍** —— 消费方在收到 ack 那拍清 wait_ack，
//     生效在下一拍；同拍给字节会把第一个字节吞掉。
//
// 为什么用「整扇区缓冲」而不是边读边流：
//   25 MHz SPI 下 SD 读一个扇区约 170 µs，而 25 MHz 消费域只要 20 µs 就能吐完
//   512 字节。若边读边流，中途必然断流。用 512 字节异步 FIFO 把整扇区先收进来，
//   两个时钟域就彻底解耦，消费方可以按自己的节奏慢慢读。
//   （FIFO 深度 2^9 = 512，正好一个扇区。）
//
// 端口：
//   sd_clk/sd_rst_n   100 MHz SD 域（sd_rst_n 由本模块从 rst_n 同步而来）
//   SD_*              TF 卡 SPI 引脚
//   sd_init_done      卡初始化完成（上板诊断用）
//   clk/rst_n         25 MHz 消费域
//   sec_*             扇区源协议
//   sd_timeout        读超时（无卡/卡异常），高电平保持，供诊断
//=============================================================================
`timescale 1ns / 1ps

module sector_source #(
    parameter TIMEOUT_CYC = 27'd67_000_000,   // 100 MHz 下约 0.67 s
    parameter FIFO_AW     = 9                 // 512 字节
)(
    // ---- SD 域 100 MHz ----
    input  wire        sd_clk,
    input  wire        rst_n,          // 低有效，本模块内部同步到两域
    output wire        SD_nCS,
    output wire        SD_DCLK,
    output wire        SD_MOSI,
    input  wire        SD_MISO,
    output wire        sd_init_done,

    // ---- 消费域 25 MHz ----
    input  wire        clk,
    input  wire        sec_req,
    input  wire [31:0] sec_addr,
    output reg         src_ack,
    output reg         src_byte_en,
    output reg  [7:0]  src_byte,
    output reg         src_last,

    // ---- 诊断 ----
    output reg         sd_timeout
);

    // ---------------------------------------------------------------- 复位同步
    reg [1:0] sd_rst_sync;
    always @(posedge sd_clk or negedge rst_n) begin
        if (!rst_n) sd_rst_sync <= 2'b00;
        else        sd_rst_sync <= {sd_rst_sync[0], 1'b1};
    end
    wire sd_rst_n = sd_rst_sync[1];

    // SD 驱动的复位是**高有效**，与我的 _n 约定相反
    wire sd_rst = ~sd_rst_n;

    // ---------------------------------------------------------------- 请求跨域
    // sec_req 是电平、sec_addr 在请求期间保持稳定，所以：
    //   请求电平 2 拍同步 + 上升沿检测；地址同步 2 拍后在该上升沿锁存。
    reg [2:0]  req_sync;
    reg [31:0] addr_s1, addr_s2;
    always @(posedge sd_clk or negedge sd_rst_n) begin
        if (!sd_rst_n) begin
            req_sync <= 3'b000;
            addr_s1  <= 32'd0;
            addr_s2  <= 32'd0;
        end else begin
            req_sync <= {req_sync[1:0], sec_req};
            addr_s1  <= sec_addr;
            addr_s2  <= addr_s1;
        end
    end
    wire req_rise = req_sync[2] & ~req_sync[1];

    // 完成信号跨回消费域（toggle + 边沿检测）
    reg done_tog;
    reg [2:0] done_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) done_sync <= 3'b000;
        else        done_sync <= {done_sync[1:0], done_tog};
    end
    wire done_pulse = done_sync[2] ^ done_sync[1];

    // ---------------------------------------------------------------- SD 域 FSM
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_READ = 2'd1;
    localparam [1:0] S_WAIT = 2'd2;

    reg [1:0]  sd_state;
    reg [31:0] latched_addr;
    reg        sd_sec_read_r;
    reg        fifo_wr_en;
    reg [7:0]  fifo_din;
    reg [9:0]  rd_byte_cnt;
    reg [26:0] tmo_cnt;
    reg        end_seen;

    wire [7:0] sd_data;
    wire       sd_data_valid;
    wire       sd_read_end;
    wire       fifo_full;

    always @(posedge sd_clk or negedge sd_rst_n) begin
        if (!sd_rst_n) begin
            sd_state      <= S_IDLE;
            latched_addr  <= 32'd0;
            sd_sec_read_r <= 1'b0;
            fifo_wr_en    <= 1'b0;
            fifo_din      <= 8'd0;
            rd_byte_cnt   <= 10'd0;
            tmo_cnt       <= 27'd0;
            end_seen      <= 1'b0;
            done_tog      <= 1'b0;
            sd_timeout    <= 1'b0;
        end else begin
            fifo_wr_en <= 1'b0;

            case (sd_state)
                S_IDLE: begin
                    sd_sec_read_r <= 1'b0;
                    tmo_cnt       <= 27'd0;
                    if (req_rise) begin
                        latched_addr  <= addr_s2;
                        sd_sec_read_r <= 1'b1;
                        rd_byte_cnt   <= 10'd0;
                        end_seen      <= 1'b0;
                        sd_state      <= S_READ;
                    end
                end

                S_READ: begin
                    // 收数据：只要 valid 就压 FIFO（FIFO 满时丢弃不该发生，但防一手）
                    if (sd_data_valid && !fifo_full) begin
                        fifo_wr_en  <= 1'b1;
                        fifo_din    <= sd_data;
                        rd_byte_cnt <= rd_byte_cnt + 10'd1;
                    end
                    if (sd_read_end) end_seen <= 1'b1;

                    tmo_cnt <= tmo_cnt + 27'd1;
                    if (tmo_cnt >= TIMEOUT_CYC) begin
                        // 无卡或卡异常：放开请求，让上层继续跑（会读到错数据，但不会死锁）
                        sd_sec_read_r <= 1'b0;
                        sd_timeout    <= 1'b1;
                        done_tog      <= ~done_tog;
                        sd_state      <= S_WAIT;
                    end else if (rd_byte_cnt >= 10'd512 && (end_seen || sd_read_end)) begin
                        // 收满一个扇区（同时等下 end，防时序差一拍）
                        sd_sec_read_r <= 1'b0;
                        done_tog      <= ~done_tog;
                        sd_state      <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    // 等上层把 FIFO 抽干、并且撤掉 sec_req，再接受下一次请求
                    if (!sec_req) begin
                        tmo_cnt  <= 27'd0;
                        sd_state <= S_IDLE;
                    end
                end

                default: sd_state <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------- 消费域 FSM
    localparam [1:0] C_IDLE = 2'd0;
    localparam [1:0] C_ACK  = 2'd1;
    localparam [1:0] C_DATA = 2'd2;

    reg [1:0]  c_state;
    reg [9:0]  out_cnt;
    reg        ready;
    wire       fifo_empty;
    wire [7:0] fifo_dout;
    reg        fifo_rd_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_state      <= C_IDLE;
            src_ack      <= 1'b0;
            src_byte_en  <= 1'b0;
            src_byte     <= 8'd0;
            src_last     <= 1'b0;
            out_cnt      <= 10'd0;
            ready        <= 1'b0;
            fifo_rd_en   <= 1'b0;
        end else begin
            src_ack     <= 1'b0;
            src_byte_en <= 1'b0;
            src_last    <= 1'b0;
            fifo_rd_en  <= 1'b0;

            if (done_pulse) ready <= 1'b1;

            case (c_state)
                C_IDLE: begin
                    out_cnt <= 10'd0;
                    if (sec_req && ready) begin
                        src_ack <= 1'b1;      // 打一拍 ack
                        ready   <= 1'b0;
                        c_state <= C_ACK;
                    end
                end

                C_ACK: begin
                    // ack 与第一个字节之间隔一拍（DUT 在这一拍才把门槛清掉）
                    c_state <= C_DATA;
                end

                C_DATA: begin
                    if (!fifo_empty) begin
                        fifo_rd_en  <= 1'b1;
                        src_byte    <= fifo_dout;
                        src_byte_en <= 1'b1;
                        src_last    <= (out_cnt == 10'd511);
                        out_cnt     <= out_cnt + 10'd1;
                        if (out_cnt == 10'd511)
                            c_state <= C_IDLE;
                    end
                end

                default: c_state <= C_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------- 字节 FIFO
    async_fifo #(.DATA_WIDTH(8), .ADDR_WIDTH(FIFO_AW)) u_fifo (
        .wr_clk   (sd_clk),
        .wr_rst_n (sd_rst_n),
        .wr_en    (fifo_wr_en),
        .wr_data  (fifo_din),
        .wr_full  (fifo_full),
        .rd_clk   (clk),
        .rd_rst_n (rst_n),
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_dout),
        .rd_empty (fifo_empty)
    );

    // ---------------------------------------------------------------- SD 驱动
    sd_card_top #(
        .SPI_LOW_SPEED_DIV  (248),
        .SPI_HIGH_SPEED_DIV (0)
    ) u_sd (
        .clk                 (sd_clk),
        .rst                 (sd_rst),
        .SD_nCS              (SD_nCS),
        .SD_DCLK             (SD_DCLK),
        .SD_MOSI             (SD_MOSI),
        .SD_MISO             (SD_MISO),
        .sd_init_done        (sd_init_done),
        .sd_sec_read         (sd_sec_read_r),
        .sd_sec_read_addr    (latched_addr),
        .sd_sec_read_data    (sd_data),
        .sd_sec_read_data_valid (sd_data_valid),
        .sd_sec_read_end     (sd_read_end),
        .sd_sec_write        (1'b0),
        .sd_sec_write_addr   (32'd0),
        .sd_sec_write_data   (8'd0),
        .sd_sec_write_data_req (),
        .sd_sec_write_end    ()
    );

endmodule
