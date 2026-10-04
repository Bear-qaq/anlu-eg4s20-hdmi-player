//=============================================================================
// 模块：seg_display
// 功能：4 位数码管动态扫描 + 十六进制译码。
//
// 电平约定（当前板卡：硬木「大拇指」+ M0 底板）：
//   seg_data[7:0] = {DP, g, f, e, d, c, b, a}，**高有效**（1 = 点亮）
//   seg_sel[3:0]  一位选通，**低有效**
//
// SEG_ACTIVE_LOW 保留为参数，便于同一模块支持其它段选极性的板卡。
//
// 端口：
//   clk       50 MHz
//   rst_n     低有效复位
//   disp_val  待显示的 16 bit 数值（16 进制 4 位）
//   dp_mask   DP 小数点使能，1 = 点亮该位的小数点
//=============================================================================
`timescale 1ns / 1ps

module seg_display #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter SCAN_FREQ   = 200,         // 每位刷新率 = SCAN_FREQ * 4
    parameter SEG_ACTIVE_LOW = 0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] disp_val,
    input  wire [3:0]  dp_mask,
    output reg  [3:0]  seg_sel,
    output reg  [7:0]  seg_data
);

    localparam [31:0] SCAN_COUNT = CLK_FREQ_HZ / (SCAN_FREQ * 4);

    // ---------------------------------------------------------------------
    // ★ disp_val / dp_mask 可能来自**任意时钟域**：本例里这个 16 bit 状态字同时
    //   拼了 25 MHz 像素域（媒体层状态/张数）、125 MHz 内存域（帧仓 slot_ready、
    //   fs_state）和 100 MHz SD 域（SD 就绪/超时）的寄存器。这里统一做两级同步
    //   之后再译码，两个好处：
    //   ① 消除亚稳态，也避免"同一次显示里高位是新的、低位是旧的"这种错乱；
    //   ② **把跨域路径变短**：译码逻辑挪到同步器之后，跨域那一跳只剩
    //      「源寄存器 → 走线 → 同步器的 D」。原来译码（LUT5×2+LUT4×2）直接挂在
    //      跨域路径上，加上 3.4 ns 走线共 5.275 ns；而 STA 对 125 MHz→50 MHz
    //      只给 4 ns 预算（按最坏边沿对齐，PLL 倍频关系也照最坏算），
    //      于是这条路径成了全设计最紧的一条 —— WNS 一度只剩 20 ps。
    //      这是 M3 之后一直存在的关键路径，之前一直被当成"布局运气"。
    // ---------------------------------------------------------------------
    reg [15:0] dv_s1, dv_s2;
    reg [3:0]  dp_s1, dp_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dv_s1 <= 16'd0;  dv_s2 <= 16'd0;
            dp_s1 <= 4'd0;   dp_s2 <= 4'd0;
        end else begin
            dv_s1 <= disp_val;   dv_s2 <= dv_s1;
            dp_s1 <= dp_mask;    dp_s2 <= dp_s1;
        end
    end

    reg [31:0] scan_timer;
    reg [2:0]  scan_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_timer <= 32'd0;
            scan_idx   <= 3'd0;
        end else if (scan_timer >= SCAN_COUNT - 32'd1) begin
            scan_timer <= 32'd0;
            scan_idx   <= (scan_idx == 3'd3) ? 3'd0 : (scan_idx + 3'd1);
        end else begin
            scan_timer <= scan_timer + 32'd1;
        end
    end

    // 当前位对应的 4 bit 半字节（第 0 位是最低位）—— 用**同步后**的值
    reg [3:0] nibble;
    always @(*) begin
        case (scan_idx)
            3'd0:    nibble = dv_s2[3:0];
            3'd1:    nibble = dv_s2[7:4];
            3'd2:    nibble = dv_s2[11:8];
            default: nibble = dv_s2[15:12];
        endcase
    end

    // 十六进制译码，高有效：bit6=g ... bit0=a
    reg [6:0] seg7;
    always @(*) begin
        case (nibble)
            4'h0:    seg7 = 7'b011_1111;
            4'h1:    seg7 = 7'b000_0110;
            4'h2:    seg7 = 7'b101_1011;
            4'h3:    seg7 = 7'b100_1111;
            4'h4:    seg7 = 7'b110_0110;
            4'h5:    seg7 = 7'b110_1101;
            4'h6:    seg7 = 7'b111_1101;
            4'h7:    seg7 = 7'b000_0111;
            4'h8:    seg7 = 7'b111_1111;
            4'h9:    seg7 = 7'b110_1111;
            4'hA:    seg7 = 7'b111_0111;
            4'hB:    seg7 = 7'b111_1100;
            4'hC:    seg7 = 7'b011_1001;
            4'hD:    seg7 = 7'b101_1110;
            4'hE:    seg7 = 7'b111_1001;
            default: seg7 = 7'b111_0001;
        endcase
    end

    // 位选（低有效）与段输出；消隐期间全灭
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_sel  <= 4'b1111;
            seg_data <= SEG_ACTIVE_LOW ? 8'hFF : 8'h00;
        end else begin
            seg_sel  <= ~(4'b0001 << scan_idx);
            if (SEG_ACTIVE_LOW)
                seg_data <= {~dp_s2[scan_idx], ~seg7};
            else
                seg_data <= {dp_s2[scan_idx], seg7};
        end
    end

endmodule
