//=============================================================================
// testbench：frame_mixer
//
// 验证目标：
//   1. MODE_A / MODE_B 直通逐位正确
//   2. MODE_FADE 两个端点是**精确**的：alpha=0 逐位等于 A（不允许有加权求和的舍入误差，
//      否则静止画面会持续抖动）；alpha=255 逼近 B
//   3. MODE_FADE 中点值在合理误差内
//   4. MODE_SLIDE 左端全 A、右端全 B、交界处确实在混合
//   5. en=0 时输出黑
//=============================================================================
`timescale 1ns / 1ps

module tb_frame_mixer;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;          // 25 MHz

    reg         en;
    reg  [1:0]  mode;
    reg  [7:0]  alpha;
    reg  [11:0] slide_pos;
    reg  [11:0] x;
    reg  [23:0] pix_a, pix_b;
    wire [23:0] pix_out;

    frame_mixer u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .mode      (mode),
        .alpha     (alpha),
        .slide_pos (slide_pos),
        .x         (x),
        .pix_a     (pix_a),
        .pix_b     (pix_b),
        .pix_out   (pix_out)
    );

    integer errors;
    integer checks;

    // 打一拍后取输出
    task check;
        input [23:0] expect;
        input [8*40-1:0] name;
        begin
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (pix_out !== expect) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("  FAIL %0s: expect %06h got %06h (mode=%0d alpha=%0d x=%0d)",
                             name, expect, pix_out, mode, alpha, x);
            end
        end
    endtask

    // 容差检查（淡入淡出中间值）
    task check_near;
        input [23:0] expect;
        input integer tol;
        input [8*40-1:0] name;
        integer dr, dg, db;
        begin
            @(posedge clk);
            #1;
            checks = checks + 1;
            dr = pix_out[23:16] - expect[23:16];
            dg = pix_out[15:8]  - expect[15:8];
            db = pix_out[7:0]   - expect[7:0];
            if (dr < 0) dr = -dr;
            if (dg < 0) dg = -dg;
            if (db < 0) db = -db;
            if (dr > tol || dg > tol || db > tol) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("  FAIL %0s: expect %06h(+-%0d) got %06h", name, expect, tol, pix_out);
            end
        end
    endtask

    initial begin
        errors    = 0;
        checks    = 0;
        en        = 1'b1;
        mode      = 2'd0;
        alpha     = 8'd0;
        slide_pos = 12'd0;
        x         = 12'd0;
        pix_a     = 24'h11_22_33;
        pix_b     = 24'hAA_BB_CC;

        #101 rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ---- 直通 ----
        mode = 2'd0; check(24'h11_22_33, "MODE_A");
        mode = 2'd1; check(24'hAA_BB_CC, "MODE_B");

        // ---- 淡入淡出端点必须精确 ----
        mode  = 2'd2;
        alpha = 8'd0;   check(24'h11_22_33, "FADE alpha=0 必须逐位等于 A");
        alpha = 8'd255; check(24'hAA_BB_CC, "FADE alpha=255 必须逐位等于 B");
        // 中点：A=0x11, B=0xAA -> 0x11 + (0xAA-0x11)*128/256 = 0x11 + 0x4C = 0x5D
        alpha = 8'd128; check_near(24'h5D_6E_7F, 1, "FADE alpha=128 中点");

        // ---- 滑动 ----
        mode      = 2'd3;
        slide_pos = 12'd320;
        x = 12'd0;   check(24'h11_22_33, "SLIDE 左侧应为 A");
        x = 12'd639; check(24'hAA_BB_CC, "SLIDE 右侧应为 B");
        // 交界中心 x+8 == slide_pos -> d1=0 -> a_slide=0 -> 仍是 A
        x = 12'd312; check(24'h11_22_33, "SLIDE 交界左端应为 A");
        // x+8-slide_pos = 15 -> a_slide=240 -> 接近 B 但不是 B
        x = 12'd327;
        @(posedge clk); #1;
        checks = checks + 1;
        if (pix_out === 24'h11_22_33 || pix_out === 24'hAA_BB_CC) begin
            errors = errors + 1;
            $display("  FAIL SLIDE 交界处应当在混合，实得 %06h", pix_out);
        end

        // ---- en=0 输出黑 ----
        mode = 2'd0; en = 1'b0; check(24'h00_00_00, "en=0 应为黑");
        en = 1'b1;

        repeat (4) @(posedge clk);
        $display("---------------------------------------------");
        $display("checks : %0d", checks);
        $display("errors : %0d", errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #200_000;
        $display("TIMEOUT");
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
