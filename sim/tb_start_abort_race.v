// Start/abort race test for peruri_sentinel_core.
//
// The DPA hiding block delays the AES start (`go`) by 0..3 dummy cycles after
// op_grant. If the controller aborts the operation (power_warn after the MARK
// write) and its abort commit_fin lands in the SAME cycle as `go`, the core
// must not start the AES: the output gate would leave IDLE in that cycle,
// miss the commit pulse and wait for it forever (core stuck busy).
//
// A short NVM write latency (1..4 cycles) and a power_warn pulse swept over
// the cycles after op_grant make the two events collide. The monitor counts
// the cycles in which `go & op_live & commit_fin` held (the cycles in which
// the pre-fix logic would have started the AES); at least one must happen.
// After every aborted operation the core must return to idle (busy = 0)
// without releasing anything, the tear must be counted, and a following clean
// operation must release the correct ciphertext.
`timescale 1ns/1ps

module race_harness #(
    parameter integer WL = 1
) (
    input  wire         clk,
    output reg          done,
    output reg  [31:0]  errors,
    output reg  [31:0]  coinc,
    output reg  [31:0]  trials
);
    localparam integer CW = 8, RECW = 17 + 2*CW;
    localparam [127:0] PT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] EXP = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    reg  rst_n = 0, por_n = 0, op_req = 0, power_warn = 0;
    wire [127:0] ct_out;
    wire ct_valid, gate_blocked, lockdown, busy, key_is_zero;
    wire [CW-1:0] tamper_counter, tear_count;
    wire [3:0] round_idx;
    wire nvm_rd_en, nvm_rd_addr, nvm_rd_valid, nvm_wr_en, nvm_wr_addr, nvm_wr_done;
    wire [RECW-1:0] nvm_rd_data, nvm_wr_data;

    // Local NVM stub with a write latency of WL cycles from the (registered)
    // wr_en rising edge to wr_done: WL = 1 is the fastest a synchronous NVM
    // can answer (wr_done in the cycle after wr_en). nvm_counter_model needs
    // at least 2 cycles, which is one cycle too slow for the abort commit_fin
    // to reach a go that comes 4 cycles after op_grant.
    localparam integer PW = 9 + 2*CW;
`include "crc_util.vh"
    function [RECW-1:0] good_rec;           // {seq 1, in_progress 0, counters 0}
        input dummy;
        reg [PW-1:0] payload;
        begin
            payload  = {8'd1, {(PW-8){1'b0}}};
            good_rec = {payload, crc8_07(PW, {{(256-PW){1'b0}}, payload})};
        end
    endfunction
    reg [RECW-1:0] mem0, mem1, w_d, rd_data_r;
    reg            rd_valid_r, wr_done_r, rd_en_d, wr_en_d, wbusy, w_a;
    reg [7:0]      wcnt;
    initial begin
        mem0 = good_rec(1'b0); mem1 = good_rec(1'b0);
        w_d = 0; rd_data_r = 0; rd_valid_r = 0; wr_done_r = 0; rd_en_d = 0; wr_en_d = 0;
        wbusy = 0; w_a = 0; wcnt = 0;
    end
    always @(posedge clk) begin
        rd_valid_r <= 1'b0; wr_done_r <= 1'b0; rd_en_d <= nvm_rd_en; wr_en_d <= nvm_wr_en;
        if (nvm_rd_en && !rd_en_d) begin
            rd_data_r  <= nvm_rd_addr ? mem1 : mem0;
            rd_valid_r <= 1'b1;
        end
        if (nvm_wr_en && !wr_en_d) begin
            if (WL == 1) begin
                if (nvm_wr_addr) mem1 <= nvm_wr_data; else mem0 <= nvm_wr_data;
                wr_done_r <= 1'b1;
            end else begin
                wbusy <= 1'b1; wcnt <= WL - 1; w_a <= nvm_wr_addr; w_d <= nvm_wr_data;
            end
        end else if (wbusy) begin
            if (wcnt <= 8'd1) begin
                wbusy <= 1'b0; wr_done_r <= 1'b1;
                if (w_a) mem1 <= w_d; else mem0 <= w_d;
            end else wcnt <= wcnt - 8'd1;
        end
    end
    assign nvm_rd_data = rd_data_r; assign nvm_rd_valid = rd_valid_r;
    assign nvm_wr_done = wr_done_r;

    peruri_sentinel_core #(.N(255), .M(255), .CW(CW)) dut (
        .clk(clk), .rst_n(rst_n), .por_n(por_n), .sentinel_en(1'b1), .op_req(op_req),
        .pt(PT), .fault_en(1'b0), .fault_round(4'd0), .fault_byte(4'd0), .fault_mask(8'd0),
        .alarm_in(1'b0), .debug_unlock(1'b0), .power_warn(power_warn),
        .nvm_rd_en(nvm_rd_en), .nvm_rd_addr(nvm_rd_addr), .nvm_rd_data(nvm_rd_data),
        .nvm_rd_valid(nvm_rd_valid), .nvm_wr_en(nvm_wr_en), .nvm_wr_addr(nvm_wr_addr),
        .nvm_wr_data(nvm_wr_data), .nvm_wr_done(nvm_wr_done), .tear_count(tear_count),
        .ct_out(ct_out), .ct_valid(ct_valid),
        .gate_blocked(gate_blocked), .tamper_counter(tamper_counter), .lockdown(lockdown),
        .busy(busy), .round_idx(round_idx), .key_is_zero(key_is_zero)
    );

    // cycle-exact coincidence monitor (pre-edge values, as the flops sample them)
    initial coinc = 32'd0;
    always @(posedge clk)
        if (dut.go && dut.op_live && dut.commit_fin && !dut.lockdown) coinc <= coinc + 32'd1;

    // any release seen during an aborted trial
    reg abort_trial = 1'b0, leaked = 1'b0;
    always @(posedge clk) if (abort_trial && ct_valid) leaked <= 1'b1;

    task chk; input cond; input [8*64-1:0] nm; begin
        if (!cond) begin
            $display("FAIL WL=%0d %0s (busy=%b tear=%0d trial=%0d)", WL, nm, busy, tear_count, trials);
            errors = errors + 1;
        end
    end endtask

    task wait_idle; input integer lim; integer t; begin
        t = 0;
        while (busy && t < lim) begin @(negedge clk); t = t + 1; end
    end endtask

    integer d, rep, t;
    reg [CW-1:0] tear_before;
    initial begin
        done = 1'b0; errors = 32'd0; trials = 32'd0;
        repeat (3) @(negedge clk);
        por_n = 1; rst_n = 1;
        wait_idle(600); repeat (2) @(negedge clk);
        chk(!busy, "boot reaches idle");

        for (d = 0; d < 5; d = d + 1) begin
            for (rep = 0; rep < 16; rep = rep + 1) begin
                trials = trials + 1;
                tear_before = tear_count;
                leaked = 1'b0;
                // aborted operation: pulse power_warn d cycles after op_grant
                @(negedge clk) op_req = 1; @(negedge clk) op_req = 0;
                t = 0; while (!dut.op_grant && t < 200) begin @(negedge clk); t = t + 1; end
                chk(dut.op_grant, "op_grant seen");
                abort_trial = 1'b1;
                repeat (d) @(negedge clk);
                power_warn = 1; @(negedge clk); power_warn = 0;
                wait_idle(300);
                repeat (4) @(negedge clk);
                abort_trial = 1'b0;
                chk(!busy, "core returns to idle after the abort (no hang)");
                chk(!dut.req_pending && !dut.op_live, "req_pending and op_live cleared");
                chk(!leaked, "nothing released for an aborted operation");
                chk(tear_count == tear_before + 1'b1, "abort counted as one tear");
                chk(!lockdown, "no lockdown");
                // the next operation works
                @(negedge clk) op_req = 1; @(negedge clk) op_req = 0;
                t = 0; while (!(ct_valid && ct_out == EXP) && t < 300) begin @(negedge clk); t = t + 1; end
                chk(ct_valid && ct_out == EXP, "next operation releases the correct ciphertext");
                wait_idle(300); repeat (2) @(negedge clk);
                chk(!busy, "idle after the next operation");
            end
        end
        done = 1'b1;
    end
endmodule

module tb_start_abort_race;
    reg clk = 0; always #5 clk = ~clk;
    wire [3:0]  done;
    wire [31:0] e1, e2, e3, e4, c1, c2, c3, c4, n1, n2, n3, n4;

    race_harness #(.WL(1)) h1 (.clk(clk), .done(done[0]), .errors(e1), .coinc(c1), .trials(n1));
    race_harness #(.WL(2)) h2 (.clk(clk), .done(done[1]), .errors(e2), .coinc(c2), .trials(n2));
    race_harness #(.WL(3)) h3 (.clk(clk), .done(done[2]), .errors(e3), .coinc(c3), .trials(n3));
    race_harness #(.WL(4)) h4 (.clk(clk), .done(done[3]), .errors(e4), .coinc(c4), .trials(n4));

    integer tot_err, tot_coinc;
    initial begin
        wait (&done);
        repeat (4) @(negedge clk);
        tot_err   = e1 + e2 + e3 + e4;
        tot_coinc = c1 + c2 + c3 + c4;
        $display("coincidences (go & op_live & abort commit_fin) per NVM write latency 1..4: %0d %0d %0d %0d",
                 c1, c2, c3, c4);
        if (tot_coinc < 1) begin
            $display("FAIL tb_start_abort_race (no cycle-exact coincidence happened: test is vacuous)");
        end else if (tot_err != 0) begin
            $display("FAIL tb_start_abort_race (%0d errors)", tot_err);
        end else
            $display("PASS tb_start_abort_race");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL tb_start_abort_race (watchdog)");
        $finish;
    end
endmodule
