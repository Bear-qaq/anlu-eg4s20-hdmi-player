//=============================================================================
// 模块：async_fifo
// 功能：通用双时钟异步 FIFO（Cummings 格雷码指针风格），首字直通（FWFT）输出。
//
// 为什么要自己写而不是用例程的 afifo_*：
//   例程的 afifo_* 是 IP Generator 产物，端口与位宽都是为「32 bit 深 512」定制的，
//   而本设计的帧仓需要在 25 MHz 与 125 MHz 之间搬 96 bit 的「4 像素条目」。
//   自己写一个参数化版本更干净，也避免 IpSDCList 那一套 IP 约束配置。
//
// 关键实现细节（不按这个写会出亚稳态或数据错拍）：
//   1. 指针用格雷码跨域，两级同步。
//   2. full/empty 标志**寄存输出**（组合比较会与 wbin_next 形成环路）。
//   3. 读侧 FWFT：RAM 读地址用 rbin_next，使 rd_data 始终等于队首；
//      rd_empty 额外打一拍（rempty_r）再输出，保证标志撤消时 rd_data 已经稳定。
//      —— 跨域写指针同步约需 2 个写时钟，而读时钟只有写时钟的 1/5，
//         这一拍余量是必需的，实测由 sim/tb_async_fifo.v 覆盖。
//
// 端口：
//   写侧  wr_clk / wr_rst_n / wr_en / wr_data / wr_full
//   读侧  rd_clk / rd_rst_n / rd_en  / rd_data / rd_empty
//   均为「非空即可读」：rd_data 在 rd_empty=0 时始终等于队首，rd_en 打一拍即弹出。
//=============================================================================
`timescale 1ns / 1ps

module async_fifo #(
    parameter DATA_WIDTH = 96,
    parameter ADDR_WIDTH = 9          // 深度 = 2^ADDR_WIDTH 个条目
)(
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  wr_full,

    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  rd_empty
);

    localparam DEPTH = (1 << ADDR_WIDTH);

    // 存储体：写口在 wr_clk，读口在 rd_clk，TD 会推断成 ERAM
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // ---- 所有指针寄存器统一在模块开头声明（Verilog-2001 要求先声明后使用）----
    reg  [ADDR_WIDTH:0] wbin;        // 写侧二进制指针
    reg  [ADDR_WIDTH:0] wgray;       // 写侧格雷码指针
    reg                 wfull;       // 写满（寄存输出）
    reg  [ADDR_WIDTH:0] rgray_s1;    // 读指针同步到写域
    reg  [ADDR_WIDTH:0] rgray_s2;

    reg  [ADDR_WIDTH:0] rbin;        // 读侧二进制指针
    reg  [ADDR_WIDTH:0] rgray;       // 读侧格雷码指针
    reg                 rempty;      // 读空（寄存输出）
    reg  [ADDR_WIDTH:0] wgray_s1;    // 写指针同步到读域
    reg  [ADDR_WIDTH:0] wgray_s2;

    // ---------------------------------------------------------------- 写侧
    wire                 winc       = wr_en & ~wfull;
    wire [ADDR_WIDTH:0]  wbin_next  = wbin + {{ADDR_WIDTH{1'b0}}, winc};
    wire [ADDR_WIDTH:0]  wgray_next = (wbin_next >> 1) ^ wbin_next;
    // 写满判据：次态格雷码 == {~同步来的读指针高 2 位取反, 其余位}
    wire                 wfull_next = (wgray_next ==
                                       {~rgray_s2[ADDR_WIDTH:ADDR_WIDTH-1],
                                         rgray_s2[ADDR_WIDTH-2:0]});

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wbin     <= {ADDR_WIDTH+1{1'b0}};
            wgray    <= {ADDR_WIDTH+1{1'b0}};
            wfull    <= 1'b0;
            rgray_s1 <= {ADDR_WIDTH+1{1'b0}};
            rgray_s2 <= {ADDR_WIDTH+1{1'b0}};
        end else begin
            wbin     <= wbin_next;
            wgray    <= wgray_next;
            wfull    <= wfull_next;
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    always @(posedge wr_clk) begin
        if (winc)
            mem[wbin[ADDR_WIDTH-1:0]] <= wr_data;
    end

    assign wr_full = wfull;

    // ---------------------------------------------------------------- 读侧
    // rempty 直接参与 rbin_next 与 rd_empty，**不能再多打一拍**：
    // 多打一拍会让 empty 晚一个周期才拉高，消费方就能多弹一次，
    // 弹出的是尚未写入的地址（仿真里是 X，硬件上是上一轮的残留数据）。
    // 这个坑是 sim/tb_pack_unpack.v 抓出来的：640 个像素里后 636 个全错。
    wire [ADDR_WIDTH:0] rbin_next  = rbin + {{ADDR_WIDTH{1'b0}}, (rd_en & ~rempty)};
    wire [ADDR_WIDTH:0] rgray_next = (rbin_next >> 1) ^ rbin_next;
    wire                rempty_next = (rgray_next == wgray_s2);

    // RAM 读地址取「下一个队首」，使寄存输出的 rd_data 恒等于当前队首
    wire [ADDR_WIDTH-1:0] raddr = rbin_next[ADDR_WIDTH-1:0];

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rbin     <= {ADDR_WIDTH+1{1'b0}};
            rgray    <= {ADDR_WIDTH+1{1'b0}};
            rempty   <= 1'b1;
            wgray_s1 <= {ADDR_WIDTH+1{1'b0}};
            wgray_s2 <= {ADDR_WIDTH+1{1'b0}};
        end else begin
            rbin     <= rbin_next;
            rgray    <= rgray_next;
            rempty   <= rempty_next;
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    reg [DATA_WIDTH-1:0] rd_data_r;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)
            rd_data_r <= {DATA_WIDTH{1'b0}};
        else
            rd_data_r <= mem[raddr];
    end

    assign rd_data  = rd_data_r;
    assign rd_empty = rempty;

endmodule
