//=============================================================================
// 模块：reset_gen
// 功能：上电复位（POR）+ 各时钟域的复位同步。
//
// ★ 设计要点（这一版是踩过坑改出来的）：
//   各域复位同步器的**异步置位端只接板级复位端口 rst_n_async**，
//   POR 完成 / PLL 锁定这些「释放条件」放在**数据通路**里，而不是放在异步复位端。
//
//   为什么：如果把 `por_rst_n & pll_locked`（clk 域的寄存器输出）直接接到
//   mem_clk 域触发器的异步复位端，TD 会对它做 recovery 检查，预算只有半个
//   mem_clk 周期（4 ns），实测 SWNS −0.159 ns 违例。而这条路径本来就是异步的，
//   检查它没有意义。改成接端口之后，TD 无从推导发起时钟，这条伪违例自然消失 ——
//   同时也让复位树更干净：异步置位是纯粹的板级信号，释放是各域自己同步的。
//
// 端口：
//   clk            50 MHz 板上晶振 —— POR 计数器跑在这里
//   rst_n_async    板上低有效复位输入（A2），也是各域复位同步器的异步置位源
//   por_rst_n      POR 计数完成（clk 域，高有效）。用作 PLL 复位释放条件与
//                  clk 域逻辑的复位（低有效语义：POR 期间为 0）
//   pixel_clk / pll_locked / pixel_rst_n        像素域
//   mem_clk   / mem_pll_locked / mem_rst_n      内存域
//
// 时序说明：POR 计数 20 位满量程 ≈ 21 ms @50 MHz。
//=============================================================================
`timescale 1ns / 1ps

module reset_gen #(
    parameter POR_CYCLES = 20'hF_FFFF   // 1,048,575 拍 @50 MHz ≈ 21 ms
)(
    input  wire clk,
    input  wire rst_n_async,
    output reg  por_rst_n,

    input  wire pixel_clk,
    input  wire pll_locked,
    output wire pixel_rst_n,

    input  wire mem_clk,
    input  wire mem_pll_locked,
    output wire mem_rst_n
);

    // ---------------------------------------------------------------- POR
    reg [19:0] por_cnt;

    always @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async) begin
            por_cnt   <= 20'd0;
            por_rst_n <= 1'b0;
        end else if (por_cnt == POR_CYCLES) begin
            por_cnt   <= por_cnt;          // 到顶停住，避免回绕
            por_rst_n <= 1'b1;
        end else begin
            por_cnt   <= por_cnt + 20'd1;
            por_rst_n <= 1'b0;
        end
    end

    // ---------------------------------------------------------------- 像素域
    // por_rst_n 是 clk 域单 bit 电平，跨到像素域先做两级同步
    reg [1:0] por_sync_pix;
    always @(posedge pixel_clk or negedge rst_n_async) begin
        if (!rst_n_async) por_sync_pix <= 2'b00;
        else              por_sync_pix <= {por_sync_pix[0], por_rst_n};
    end

    // 释放条件（POR 完成 & PLL 锁定）在像素域内合成，再经两级释放链
    reg [1:0] pixel_rel;
    always @(posedge pixel_clk or negedge rst_n_async) begin
        if (!rst_n_async) pixel_rel <= 2'b00;
        else              pixel_rel <= {pixel_rel[0], (por_sync_pix[1] & pll_locked)};
    end

    assign pixel_rst_n = pixel_rel[1];

    // ---------------------------------------------------------------- 内存域
    reg [1:0] por_sync_mem;
    always @(posedge mem_clk or negedge rst_n_async) begin
        if (!rst_n_async) por_sync_mem <= 2'b00;
        else              por_sync_mem <= {por_sync_mem[0], por_rst_n};
    end

    reg [1:0] mem_rel;
    always @(posedge mem_clk or negedge rst_n_async) begin
        if (!rst_n_async) mem_rel <= 2'b00;
        else              mem_rel <= {mem_rel[0], (por_sync_mem[1] & mem_pll_locked)};
    end

    assign mem_rst_n = mem_rel[1];

endmodule
