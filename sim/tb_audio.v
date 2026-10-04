//=============================================================================
// testbench：音频链（audio_clk_gen + acr_gen + wavetable_osc + audio_synth）
//
// 为什么音频必须有仿真：这条链**没有任何引脚**，示波器/逻辑分析仪都摸不到，
// 加密核的音频口是黑盒内部。上板只能"用耳朵听"，而耳朵听不出
// 「每 6 个样本差 1 拍」这种量级的错误 —— 但 HDMI 接收端的 ACR 会。
//
// 四组检查：
//   ① audio_clk_gen：48 kHz 节拍**长期零误差**（2400 个样本恰好 1,250,000 拍）
//      + 间隔只有 520/521 两种 + 每小时钟的分布符合 5:1
//   ② acr_gen：CTS=25000 / N=6144 恒定；而且**每个 ACR 周期恰好 25000 拍、
//      恰好 48 个样本** —— 这一条才是"ACR 与真实采样率完全自洽"的证明
//   ③ wavetable_osc：音高表 / 四象限折叠 / 包络（期望值按频率公式独立算出）
//   ④ audio_synth：8 条曲目 x 16 步**逐步**验音高与静音、混音不溢出、左右一致
//
// ★ 为什么可以在 10 ns 时钟上验"48 kHz"：
//   分数累加器数的是**时钟个数**，25e6/48e3 = 3125/6 是精确有理数，
//   所以「间隔只能是 520 或 521 拍、2400 个样本恰好 1,250,000 拍」这个结论
//   与时钟真实周期无关。真实频率（25 MHz）由 constr/timing.sdc 的 create_clock 保证。
//   这样仿真时间被压掉 4 倍。
// ★ 音高期望值是**按 f = 523.251 * 2^((code-1)/12) 独立算出来的**，不是抄 RTL 的表，
//   所以它抓得出表里的错值 —— 例如"音高表只写到 13、而 TRACK_2/TRACK_5 里出现
//   14/15，落进 default 变成没声音"那个 bug。
// ★ 合成器的 8 条曲目 x 16 步全部跑一遍，每步都验音高，所以 14/15 那种
//   "某几步莫名其妙不出声"的问题不可能漏过。
//=============================================================================
`timescale 1ns / 1ps

module tb_audio;

    localparam integer NOTE_TICKS_TB = 24_000;   // 每步样本数（真实值 12000，这里放大以提分辨率）
    localparam integer SKIP          = 3_000;    // 每步首尾各丢多少样本（躲开包络沿）
    localparam integer WIN           = NOTE_TICKS_TB - 2*SKIP;  // = 18000
    localparam integer OSAMP         = 48_000;   // 振荡器测量窗口（= 1 秒音频时间）

    reg clk = 1'b0;
    always #5 clk = ~clk;            // 10 ns

    reg rst_n = 1'b0;
    initial begin #100 rst_n = 1'b1; end

    integer errors, checks;

    task chk; input cond; input [8*72-1:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                if (errors <= 20) $display("  FAIL %0s", msg);
            end
        end
    endtask

    task chk_int; input integer got; input integer want; input integer tol;
                  input [8*72-1:0] msg;
        begin
            checks = checks + 1;
            if ((got < want - tol) || (got > want + tol)) begin
                errors = errors + 1;
                if (errors <= 20) $display("  FAIL %0s: 期望 %0d±%0d 实得 %0d", msg, want, tol, got);
            end
        end
    endtask

    // 每个有效样本都查一次左右一致性（便宜，且能抓到混音/寄存器写错）
    integer lr_bad;
    initial lr_bad = 0;

    // 临时诊断开关（只在曲目0第0步打开，打印两边内部状态）
    reg dbg_on;
    integer m_maxd;
    integer dbg_n;

    //=========================================================================
    // ① audio_clk_gen + ② acr_gen
    //=========================================================================
    wire sample_tick, acr_valid;
    wire [19:0] acr_cts, acr_n;

    audio_clk_gen #(.PIXEL_CLK_HZ (25_000_000), .SAMPLE_RATE (48_000)) u_clkgen (
        .pixel_clk  (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick)
    );

    acr_gen #(.PIXEL_CLK_KHZ (25_000), .SAMPLE_RATE (48_000), .ACR_N (6144)) u_acr (
        .pixel_clk (clk),
        .rst_n     (rst_n),
        .acr_valid (acr_valid),
        .acr_cts   (acr_cts),
        .acr_n     (acr_n)
    );

    // 时钟域统计（全部在一个 always 里用阻塞赋值，避免跨块竞争）
    integer clk_cnt;
    integer last_tick_clk;
    integer first_tick_clk;
    integer n_520, n_521, n_bad, n_int, tick_n, tick_sum;
    integer acr_last_clk, acr_last_samp;
    integer acr_per_n, acr_clk_err, acr_samp_err, acr_val_n;
    integer acr_cts_bad, acr_n_bad;
    integer k;

    initial begin
        clk_cnt = 0; last_tick_clk = -1; first_tick_clk = 0;
        n_520 = 0; n_521 = 0; n_bad = 0; n_int = 0; tick_n = 0; tick_sum = 0;
        acr_last_clk = 0; acr_last_samp = 0;
        acr_per_n = 0; acr_clk_err = 0; acr_samp_err = 0; acr_val_n = 0;
        acr_cts_bad = 0; acr_n_bad = 0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt = 0;
        end else begin
            clk_cnt = clk_cnt + 1;

            if (sample_tick) begin
                if (last_tick_clk >= 0) begin
                    k = clk_cnt - last_tick_clk;
                    tick_sum = tick_sum + k;
                    n_int    = n_int + 1;
                    if      (k == 520) n_520 = n_520 + 1;
                    else if (k == 521) n_521 = n_521 + 1;
                    else               n_bad = n_bad + 1;
                end
                if (tick_n == 0) first_tick_clk = clk_cnt;
                last_tick_clk = clk_cnt;
                tick_n        = tick_n + 1;
            end

            if (acr_valid) begin
                if (acr_val_n > 0) begin
                    // 一个 ACR 周期内的拍数与样本数
                    if ((clk_cnt - acr_last_clk) != 25_000) acr_clk_err = acr_clk_err + 1;
                    if ((tick_n  - acr_last_samp) != 48)     acr_samp_err = acr_samp_err + 1;
                    acr_per_n = acr_per_n + 1;
                end
                acr_last_clk  = clk_cnt;
                acr_last_samp = tick_n;
                acr_val_n     = acr_val_n + 1;
                if (acr_cts !== 20'd25_000) acr_cts_bad = acr_cts_bad + 1;
                if (acr_n   !== 20'd6144)   acr_n_bad   = acr_n_bad + 1;
            end
        end
    end

    //=========================================================================
    // ③④ 合成器：用"假快节拍"（每 2 拍一个 sample_tick）驱动，
    //     sample_tick 语义与真实完全一致（都是"一个样本一次"），只是把
    //     25 MHz 下 521 拍/样本压成 2 拍/样本，仿真时间降两个数量级。
    //=========================================================================
    reg fdiv;
    reg syn_tick;
    reg syn_rst_n;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fdiv     <= 1'b0;
            syn_tick <= 1'b0;
        end else begin
            fdiv     <= ~fdiv;
            syn_tick <= ~fdiv;      // 每 2 拍一个 tick
        end
    end

    reg [2:0]  track_sel3;
    reg [3:0]  vol;
    wire       audio_valid;
    wire signed [23:0] audio_l, audio_r;

    audio_synth #(.SAMPLE_RATE (48_000), .NOTE_TICKS (NOTE_TICKS_TB)) u_synth (
        .clk         (clk),
        .rst_n       (syn_rst_n),
        .sample_tick (syn_tick),
        .track_sel   (track_sel3),
        .vol         (vol),
        .audio_valid (audio_valid),
        .audio_l     (audio_l),
        .audio_r     (audio_r)
    );

    always @(posedge clk) begin
        if (audio_valid && (audio_l !== audio_r)) lr_bad = lr_bad + 1;
    end

    // ---- 振荡器单独一份，用来独立验音高表 ----
    reg                osc_on;
    reg  [31:0]        osc_inc;
    reg  [7:0]         osc_env;
    wire signed [23:0] osc_out;

    wavetable_osc u_osc (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (syn_tick),
        .note_on     (osc_on),
        .phase_inc   (osc_inc),
        .env         (osc_env),
        .sample      (osc_out)
    );

    // ---- 等 n 个 sample_tick ----
    // ★ 返回时**再往前一拍**：sample_tick 是"本拍"的事件，而振荡器/合成器的
    //   输出寄存器是在这个边沿之后才更新的，所以必须多走一拍再去读 audio_valid /
    //   osc_out，否则读到的永远是上一拍的值（第一版就是这么错的：整段 ns=0）。
    task wait_tick; input integer n;
        integer m;
        begin
            for (m = 0; m < n; m = m + 1) begin
                @(posedge clk); #1;
                while (!syn_tick) begin @(posedge clk); #1; end
                @(posedge clk); #1;
            end
        end
    endtask

    // ---- 音高期望表：按 f = 523.251 * 2^((code-1)/12) 独立算出（×1000 定点）----
    // 振荡器窗口 OSAMP=48000 个样本 = 1 秒音频，所以周期数 == 频率(Hz)
    function integer osc_exp_milli;
        input [3:0] code;
        begin
            case (code)
                4'd1:  osc_exp_milli = 523251;
                4'd2:  osc_exp_milli = 554365;
                4'd3:  osc_exp_milli = 587329;
                4'd4:  osc_exp_milli = 622254;
                4'd5:  osc_exp_milli = 659255;
                4'd6:  osc_exp_milli = 698456;
                4'd7:  osc_exp_milli = 739989;
                4'd8:  osc_exp_milli = 783991;
                4'd9:  osc_exp_milli = 830609;
                4'd10: osc_exp_milli = 880000;
                4'd11: osc_exp_milli = 932327;
                4'd12: osc_exp_milli = 987766;
                4'd13: osc_exp_milli = 1046502;
                4'd14: osc_exp_milli = 1108730;
                4'd15: osc_exp_milli = 1174659;
                default: osc_exp_milli = 0;
            endcase
        end
    endfunction

    // 合成器的音高判据已改为"与金标模型逐样本比对"（见下方 syn_step），
    // 原来那张"0.375*f 周期数"的表随之作废，不再保留。

    // ---- 相位增量期望表（同样按公式独立算出，用来直接喂振荡器）----
    function [31:0] osc_inc_of;
        input [3:0] code;
        begin
            case (code)
                4'd1:  osc_inc_of = 32'd46819719;
                4'd2:  osc_inc_of = 32'd49603764;
                4'd3:  osc_inc_of = 32'd52553357;
                4'd4:  osc_inc_of = 32'd55678342;
                4'd5:  osc_inc_of = 32'd58989149;
                4'd6:  osc_inc_of = 32'd62496826;
                4'd7:  osc_inc_of = 32'd66213081;
                4'd8:  osc_inc_of = 32'd70150316;
                4'd9:  osc_inc_of = 32'd74321671;
                4'd10: osc_inc_of = 32'd78741067;
                4'd11: osc_inc_of = 32'd83423255;
                4'd12: osc_inc_of = 32'd88383837;
                4'd13: osc_inc_of = 32'd93639414;
                4'd14: osc_inc_of = 32'd99207503;
                4'd15: osc_inc_of = 32'd105106688;
                default: osc_inc_of = 32'd0;
            endcase
        end
    endfunction

    // ---- 曲目表（TB 侧独立抄一份，作为"应该播什么"的规格）----
    function [63:0] track_of;
        input [2:0] tr;
        begin
            case (tr)
                3'd0:    track_of = 64'h1234_5678_9ABC_D123;
                3'd1:    track_of = 64'h1358_5312_468A_8642;
                3'd2:    track_of = 64'h1A2B_3C4D_5E6F_7A8B;
                3'd3:    track_of = 64'h8642_1975_3121_2345;
                3'd4:    track_of = 64'h1113_1518_1A18_1513;
                3'd5:    track_of = 64'hABCD_EF01_2345_6789;
                3'd6:    track_of = 64'h159D_159D_26AE_26AE;
                default: track_of = 64'h1C1B_1A19_1817_1615;
            endcase
        end
    endfunction

    function [3:0] track_nib;
        input [2:0] tr; input integer st;
        reg [63:0] b;
        begin
            b         = track_of(tr);
            b         = b >> (st * 4);
            track_nib = b[3:0];
        end
    endfunction

    //=========================================================================
    // 金标模型：用 DUT 同一个 wavetable_osc，但相位增量/包络/混音全部由 TB
    // 按独立规格给出，逐样本与 DUT 输出比对。
    // 锁步方式：TB 用一个与 DUT 内部 (tick_cnt, step_idx) **同规则**更新的镜像
    // 计数器（同一个 syn_rst_n 复位、同一个 syn_tick 推进），所以组合出来的
    // ref_inc/ref_env/ref_on 恒等于 DUT 在这一拍应当用的值。
    // 必须放在 syn_step task **之前**（Verilog-2001 先声明后使用）。
    //=========================================================================
    integer tb_tick;    // 镜像 tick_cnt，0..NOTE_TICKS_TB-1
    integer tb_step;    // 镜像 step_idx，0..15

    always @(posedge clk or negedge syn_rst_n) begin
        if (!syn_rst_n) begin
            tb_tick <= 0;
            tb_step <= 0;
        end else if (syn_tick) begin
            if (tb_tick == NOTE_TICKS_TB - 1) begin
                tb_tick <= 0;
                tb_step <= (tb_step == 15) ? 0 : (tb_step + 1);
            end else begin
                tb_tick <= tb_tick + 1;
            end
        end
    end

    function [31:0] cur_inc;      // 本步应当用的相位增量（TB 独立公式表）
        input [2:0] tr; input integer st;
        reg [3:0] c;
        begin
            c       = track_nib(tr, st);
            cur_inc = osc_inc_of(c);
        end
    endfunction

    function [7:0] cur_env;       // 本拍应当用的包络（起音/收音各 2048 个样本）
        input integer t;
        integer tail;
        begin
            tail = NOTE_TICKS_TB - t;
            if      (t < 2048)      cur_env = t / 8;
            else if (tail < 2048)   cur_env = tail / 8;
            else                    cur_env = 8'd255;
        end
    endfunction

    wire [31:0] ref_inc = cur_inc(track_sel3, tb_step);
    wire [7:0]  ref_env = cur_env(tb_tick);
    wire        ref_on  = (track_nib(track_sel3, tb_step) != 4'd0);

    wire signed [23:0] g_lead, g_sub1, g_sub2, g_mix;
    wire signed [25:0] g_sum;

    wavetable_osc u_g_lead (
        .clk (clk), .rst_n (syn_rst_n), .sample_tick (syn_tick),
        .note_on (ref_on), .phase_inc (ref_inc), .env (ref_env), .sample (g_lead)
    );
    wavetable_osc u_g_sub1 (
        .clk (clk), .rst_n (syn_rst_n), .sample_tick (syn_tick),
        .note_on (ref_on), .phase_inc ({1'b0, ref_inc[31:1]}), .env (ref_env), .sample (g_sub1)
    );
    wavetable_osc u_g_sub2 (
        .clk (clk), .rst_n (syn_rst_n), .sample_tick (syn_tick),
        .note_on (ref_on), .phase_inc ({2'b00, ref_inc[31:2]}), .env (ref_env), .sample (g_sub2)
    );

    assign g_sum = g_lead + (g_sub1 >>> 1) + (g_sub2 >>> 1);
    assign g_mix = g_sum >>> 1;            // vol=8 时单位增益

    // DUT 的 audio_l 比"本拍算出来的样本"晚一拍（输出寄存器），所以金标也延一拍
    reg signed [23:0] g_mix_d;
    always @(posedge clk) g_mix_d <= g_mix;

    // ---- 测量：振荡器（收满 OSAMP 个样本，返回过零次数与正负峰值）----
    integer last_sgn;

    task osc_measure;
        input  [31:0]       inc;
        output integer      zc;
        output integer      pk;
        output integer      mn;
        integer m, sgn;
        begin
            osc_on = 1'b0;
            wait_tick(2);
            osc_inc = inc;
            osc_env = 8'd255;
            osc_on  = 1'b1;
            wait_tick(4);
            zc = 0; pk = 0; mn = 0; last_sgn = 0;
            for (m = 0; m < OSAMP; m = m + 1) begin
                wait_tick(1);
                sgn = (osc_out > 0) ? 1 : ((osc_out < 0) ? -1 : 0);
                if (sgn != 0) begin
                    if ((last_sgn != 0) && (sgn != last_sgn)) zc = zc + 1;
                    last_sgn = sgn;
                end
                if (osc_out > pk)       pk = osc_out;
                if ((0 - osc_out) > mn) mn = (0 - osc_out);
            end
        end
    endtask

    // ---- 测量：合成器一步（窗口内逐样本与金标模型比对 + 静音/幅度统计）----
    // ★ 为什么不用"数过零"来测合成器的音高：输出是「主声部 + 低八度 + 低两个八度」
    //   的混合波形，慢声部会整体抬降基线，过零数**不等于**主声部频率（实测能差 40%）。
    //   改用金标模型逐样本比对：三个 wavetable_osc（与 DUT 同一模块、但相位增量与包络
    //   由 TB 按独立公式给出）+ TB 自己写的混音，容差 ±4 LSB。
    //   这样音高表、步序列、包络、三声部增益、输出寄存器**一次全验**。
    //   （金标模型的声明/例化放在本 task 之前，Verilog-2001 要求先声明后使用。）
    task syn_step;
        output integer maxd;    // 窗口内与金标的最大偏差
        output integer nz;
        output integer pk;
        output integer ns;
        integer m, d;
        begin
            maxd = 0; nz = 0; pk = 0; ns = 0;
            for (m = 0; m < NOTE_TICKS_TB; m = m + 1) begin
                wait_tick(1);
                if (audio_valid) begin
                    ns = ns + 1;
                    if ((m >= SKIP) && (m < (NOTE_TICKS_TB - SKIP))) begin
                        d = audio_l - g_mix_d;
                        if (d < 0) d = 0 - d;
                        if (d > maxd) maxd = d;
                        if (audio_l != 0) nz = nz + 1;
                        if (audio_l > pk)       pk = audio_l;
                        if ((0 - audio_l) > pk) pk = (0 - audio_l);
                    end
                end
            end
        end
    endtask

    //=========================================================================
    // ⚠️ ModelSim 10.6e 对 **integer 形参做位选**会算出错误结果
    //    （见 PROGRESS.md 里 tb_bmp_stream_decoder 那条），所以循环变量一律
    //    先落到定宽 reg 再用，绝不写 i[3:0] 这种。
    //=========================================================================
    integer tr, st, i, zc, pk, mn, nz, ns, exp_milli, maxd, worst;
    reg [3:0] code4;
    reg [2:0] tr3;
    integer bad_pitch, bad_silent, bad_sound, bad_peak, n_rest, n_note;

    initial begin
        errors = 0; checks = 0;
        track_sel3 = 3'd0; vol = 4'd8;
        osc_on = 1'b0; osc_inc = 32'd0; osc_env = 8'd0;
        syn_rst_n = 1'b0;
        bad_pitch = 0; bad_silent = 0; bad_sound = 0; bad_peak = 0;
        n_rest = 0; n_note = 0; worst = 0;

        #100 rst_n = 1'b1;

        //=====================================================================
        // ①② 等 2400 个采样节拍（= 50 ms 音频时间）
        //=====================================================================
        while (tick_n < 2400) @(posedge clk);

        $display("  [速率] 样本数=%0d 间隔总数=%0d 总和=%0d 拍", tick_n, n_int, tick_sum);
        $display("  [速率] 间隔 520 拍=%0d 次, 521 拍=%0d 次, 其他=%0d 次", n_520, n_521, n_bad);
        chk(n_bad == 0,                          "48kHz 节拍间隔只能有 520/521 两种");
        // 2399 个间隔 = 第 1 个 tick 到第 2400 个 tick：
        //   ceil(3125*2400/6) - ceil(3125*1/6) = 1250000 - 521 = 1249479
        // 分数累加器的取整方式是"第 m 个 tick 落在第 ceil(3125m/6) 拍"，
        // 所以这个数必须是**精确**的 1249479 —— 差 1 就说明有累积误差。
        chk_int(tick_sum, 1_249_479, 0,          "2399 个间隔的总拍数必须精确等于 1249479");
        // 两个绝对时间戳之差也必须精确等于 1249479（独立于 tick_sum 的交叉验证）
        chk_int(last_tick_clk - first_tick_clk, 1_249_479, 0,
                "第 1 个到第 2400 个 tick 之间的拍数必须精确等于 1249479（长期零误差）");
        // 第 1 个 tick 落在第 521 拍（ceil(3125/6)），TB 是在 tick 之后的那个边沿
        // 才观测到 sample_tick 的，所以读数比 DUT 内部时刻晚 1 拍，容差取 1。
        chk_int(first_tick_clk, 521, 1,          "第 1 个样本应落在第 521 拍附近");
        chk_int(n_520,    (2399/6), 2,           "520 拍间隔占比必须是 1/6");
        chk_int(n_521,    2399 - (2399/6), 2,    "521 拍间隔占比必须是 5/6");

        $display("  [ACR] 周期数=%0d 拍数不符=%0d 样本数不符=%0d CTS错=%0d N错=%0d",
                 acr_per_n, acr_clk_err, acr_samp_err, acr_cts_bad, acr_n_bad);
        chk(acr_per_n  > 40,            "50 ms 内应当有 40 个以上 ACR 包");
        chk(acr_clk_err  == 0,          "每个 ACR 周期必须恰好 25000 拍");
        chk(acr_samp_err == 0,          "每个 ACR 周期必须恰好 48 个样本（CTS/N 与真实采样率自洽）");
        chk(acr_cts_bad  == 0,          "ACR CTS 必须恒为 25000");
        chk(acr_n_bad    == 0,          "ACR N 必须恒为 6144");

        //=====================================================================
        // ③ 振荡器音高表（15 个音符，逐个独立验）
        //=====================================================================
        for (i = 1; i <= 15; i = i + 1) begin
            code4 = i;
            osc_measure(osc_inc_of(code4), zc, pk, mn);
            exp_milli = osc_exp_milli(code4);
            // 过零次数 zc => 周期数 = zc/2，比较 (zc*1000) 与 (2*期望)
            chk_int(zc * 1000, exp_milli * 2, 6000,
                    "振荡器音高（窗口 48000 样本，期望周期数=频率Hz）");
            if (zc * 1000 < exp_milli * 2 - 6000 || zc * 1000 > exp_milli * 2 + 6000)
                $display("      ↑ 音符码 %0d：期望 %0d mHz 实得 %0d", i, exp_milli, zc * 500);
            chk(pk > 7_900_000,                 "振荡器正峰值应接近满幅（表峰值 8116675）");
            chk(mn > 7_900_000,                 "振荡器必须有满幅负半周（象限折叠的符号位）");
            chk(pk <= 8_388_607,                "振荡器输出不得超过 24bit 有符号满幅");
        end

        // 休止：note_on=0 必须输出全零，且相位清零
        osc_on = 1'b0; osc_env = 8'd255;
        wait_tick(4);
        zc = 0;
        for (i = 0; i < 64; i = i + 1) begin
            wait_tick(1);
            if (osc_out != 0) zc = zc + 1;
        end
        chk(zc == 0, "note_on=0（休止）时振荡器必须输出全零");

        //=====================================================================
        // ④ 合成器：8 条曲目 x 16 步逐步验
        //=====================================================================
        for (tr = 0; tr < 8; tr = tr + 1) begin
            tr3        = tr;
            track_sel3 = tr3;
            syn_rst_n  = 1'b0;
            wait_tick(4);
            syn_rst_n  = 1'b1;
            wait_tick(4);
            for (st = 0; st < 16; st = st + 1) begin
                syn_step(maxd, nz, pk, ns);
                code4 = track_nib(tr3, st);
                chk_int(ns, NOTE_TICKS_TB, 0, "每步窗口内的样本数必须是 24000");
                chk(pk <= 8_388_607, "混音输出不得超过 24bit 有符号满幅");
                if (maxd > 4) begin
                    bad_pitch = bad_pitch + 1;
                    if (bad_pitch <= 8)
                        $display("  FAIL 曲目%0d 第%0d步 音符码%0d 与金标模型最大偏差 %0d LSB",
                                 tr, st, code4, maxd);
                end
                if (code4 == 4'd0) begin
                    n_rest = n_rest + 1;
                    if (nz != 0) begin
                        bad_silent = bad_silent + 1;
                        $display("  FAIL 曲目%0d 第%0d步 音符码0（休止）却有 %0d 个非零样本", tr, st, nz);
                    end
                end else begin
                    n_note = n_note + 1;
                    if (nz == 0) begin
                        bad_sound = bad_sound + 1;
                        $display("  FAIL 曲目%0d 第%0d步 音符码%0d 却完全没有声音", tr, st, code4);
                    end
                    if (pk < 2_000_000) begin
                        bad_peak = bad_peak + 1;
                        $display("  FAIL 曲目%0d 第%0d步 音符码%0d 幅度过小（峰值 %0d）", tr, st, code4, pk);
                    end
                end
                if (maxd > worst) worst = maxd;
            end
        end
        chk(bad_silent == 0, "所有休止步都必须完全静音");
        chk(bad_sound  == 0, "所有非零音符步都必须出音（14/15 号音符码曾经是哑的）");
        chk(bad_peak   == 0, "有声步的幅度必须正常（混音增益没写错）");
        chk(bad_pitch  == 0, "每一步都必须与金标模型逐样本一致（音高/包络/混音/步序列）");
        chk(n_note > 100,    "应当跑过 100 步以上的有声步（覆盖 8 条曲目）");
        chk(lr_bad == 0,     "左右声道必须逐样本完全一致");
        $display("  [合成] 与金标最大偏差 = %0d LSB（容差 4）", worst);

        $display("  [合成] 有声步=%0d 休止步=%0d 音高错=%0d 该响没响=%0d 该停没停=%0d",
                 n_note, n_rest, bad_pitch, bad_sound, bad_silent);

        repeat (20) @(posedge clk);
        $display("---------------------------------------------");
        $display("checks : %0d", checks);
        $display("errors : %0d", errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #250_000_000;
        $display("TIMEOUT (tb_audio) tick=%0d tr=%0d st=%0d", tick_n, tr, st);
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
