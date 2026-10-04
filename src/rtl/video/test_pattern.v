//=============================================================================
// 模块：test_pattern
// 功能：内建测试图，四种画面，用来在没有 TF 卡的情况下验证时钟、时序、帧仓与
//       切换特效。带自检价值，不是临时凑数的彩条。
//
// 为什么需要四种画面：切换特效（淡入淡出/滑动）必须要有**明显不同**的两帧才能
// 看出来。帧仓每一槽存一帧，`pattern_sel` 由装载层逐槽递增，于是相邻两槽的内容
// 差异很大，A/B 混合效果一目了然。
//
//   0 彩条   ：8 条标准彩条 + 白边框 + 底部灰阶 + 移动方块（判断帧是否在刷新）
//   1 灰阶   ：横向 8 bit 灰阶渐变
//   2 棋盘   ：32 像素棋盘
//   3 十字线 ：中心十字 + 四角标记（判断是否有像素错位/过扫描）
//
// 端口：
//   x,y       像素坐标（de 有效时才有意义）
//   frame_cnt 每帧 +1 的帧计数器，驱动移动方块
//   sel       画面选择 0..3
//   rgb       24 bit RGB888 输出
//=============================================================================
`timescale 1ns / 1ps

module test_pattern #(
    parameter H_ACTIVE = 640,
    parameter V_ACTIVE = 480
)(
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [7:0]  frame_cnt,
    input  wire [1:0]  sel,
    output reg  [23:0] rgb
);

    localparam [11:0] BORDER     = 12'd8;
    localparam [11:0] H_LAST     = H_ACTIVE[11:0] - 12'd1;   // 639
    localparam [11:0] V_LAST     = V_ACTIVE[11:0] - 12'd1;   // 479
    localparam [11:0] RAMP_TOP   = 12'd440;
    localparam [11:0] BLOCK_SIZE = 12'd16;
    localparam [11:0] BLOCK_Y    = 12'd232;

    // 移动方块：每帧右移 16 像素，40 帧循环一周
    wire [11:0] block_x = {frame_cnt[5:0], 4'b0000};

    wire in_border = (x < BORDER) || (x > (H_LAST - BORDER)) ||
                     (y < BORDER) || (y > (V_LAST - BORDER));
    wire in_block  = (x >= block_x) && (x < (block_x + BLOCK_SIZE)) &&
                     (y >= BLOCK_Y)  && (y < (BLOCK_Y + BLOCK_SIZE));
    wire in_ramp   = (y >= RAMP_TOP) && (y < (V_LAST - BORDER));

    // 8 条彩条：白 黄 青 绿 品 红 蓝 黑
    reg [23:0] bar_color;
    always @(*) begin
        case (x[9:7])
            3'd0:    bar_color = 24'hFF_FF_FF;
            3'd1:    bar_color = 24'hFF_FF_00;
            3'd2:    bar_color = 24'h00_FF_FF;
            3'd3:    bar_color = 24'h00_FF_00;
            3'd4:    bar_color = 24'hFF_00_FF;
            3'd5:    bar_color = 24'hFF_00_00;
            3'd6:    bar_color = 24'h00_00_FF;
            default: bar_color = 24'h00_00_00;
        endcase
    end

    // 灰阶：用 x 的高 8 位做亮度，R=G=B
    wire [7:0] gray = x[9:2];

    // ---- 画面 1：横向 8 bit 灰阶 ----
    wire [7:0] g1 = x[9:2];

    // ---- 画面 2：32 像素棋盘 ----
    wire chk = x[5] ^ y[5];

    // ---- 画面 3：中心十字 + 四角标记（判断像素错位/过扫描）----
    wire in_cross  = ((x > 12'd312) && (x < 12'd328)) ||
                     ((y > 12'd232) && (y < 12'd248));
    wire in_corner = ((x < 12'd48) || (x > 12'd591)) &&
                     ((y < 12'd48) || (y > 12'd431));

    reg [23:0] pat0, pat1, pat2, pat3;

    always @(*) begin
        // 画面 0：彩条 + 白边框 + 移动方块 + 底部灰阶
        if (in_border)      pat0 = 24'hFF_FF_FF;
        else if (in_block)  pat0 = 24'hFF_20_20;
        else if (in_ramp)   pat0 = {gray, gray, gray};
        else                pat0 = bar_color;

        // 画面 1：灰阶（顶部一条白条便于判断帧边界）
        pat1 = (y < 12'd32) ? 24'hFF_FF_FF : {g1, g1, g1};

        // 画面 2：棋盘（青 / 深蓝）
        pat2 = chk ? 24'h00_C0_C0 : 24'h10_10_60;

        // 画面 3：黑底 + 绿色十字 + 四角绿块
        pat3 = (in_cross || in_corner) ? 24'h20_FF_20 : 24'h00_00_00;
    end

    always @(*) begin
        case (sel)
            2'd0:    rgb = pat0;
            2'd1:    rgb = pat1;
            2'd2:    rgb = pat2;
            default: rgb = pat3;
        endcase
    end

endmodule
