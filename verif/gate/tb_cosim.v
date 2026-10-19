// Co-simulation: RTL peruri_sentinel_core against its sky130 gate netlist
// (modules renamed with a gl_ prefix by run_cosim.sh), side by side with the
// same random inputs. Every output is compared on every cycle.
//
// Stimulus per cycle (random, seeded): operation requests, plaintext, the
// DFA fault hook (round, byte, mask), alarm, Sentinel enable, debug unlock,
// power_warn, user reset and, rarely, power-on reset. Each side has its own
// NVM model; the NVM bus is compared too. The demo key is fixed by the
// netlist parameters. Any difference is a FAIL.
//
// This complements the formal equivalence check (verif/eqy) for the parts
// where eqy's induction is inconclusive (feedback LFSR, AES round state).
`timescale 1ns/1ps
module tb_cosim;
    reg clk = 0;
    always #5 clk = ~clk;

    reg          rst_n = 0, por_n = 0, sentinel_en = 1, op_req = 0;
    reg  [127:0] pt = 0;
    reg          fault_en = 0, alarm_in = 0, debug_unlock = 0, power_warn = 0;
    reg  [3:0]   fault_round = 0, fault_byte = 0;
    reg  [7:0]   fault_mask = 0;

    wire [127:0] ct_a, ct_b;
    wire         v_a, v_b, blk_a, blk_b, lock_a, lock_b, busy_a, busy_b, kz_a, kz_b;
    wire [3:0]   cnt_a, cnt_b, rnd_a, rnd_b, tc_a, tc_b;

    // one NVM model per side (deterministic, same inputs -> same record)
    localparam integer RECW = 25;
    wire a_rd_en, a_rd_addr, a_rd_valid, a_wr_en, a_wr_addr, a_wr_done;
    wire b_rd_en, b_rd_addr, b_rd_valid, b_wr_en, b_wr_addr, b_wr_done;
    wire [RECW-1:0] a_rd_data, a_wr_data, b_rd_data, b_wr_data;
    nvm_counter_model #(.CW(4), .INIT_BLANK(0)) nvm_a (
        .clk(clk), .power_ok(1'b1), .rd_en(a_rd_en), .rd_addr(a_rd_addr), .rd_data(a_rd_data),
        .rd_valid(a_rd_valid), .wr_en(a_wr_en), .wr_addr(a_wr_addr), .wr_data(a_wr_data), .wr_done(a_wr_done));
    nvm_counter_model #(.CW(4), .INIT_BLANK(0)) nvm_b (
        .clk(clk), .power_ok(1'b1), .rd_en(b_rd_en), .rd_addr(b_rd_addr), .rd_data(b_rd_data),
        .rd_valid(b_rd_valid), .wr_en(b_wr_en), .wr_addr(b_wr_addr), .wr_data(b_wr_data), .wr_done(b_wr_done));

    peruri_sentinel_core rtl (
        .clk(clk), .rst_n(rst_n), .por_n(por_n), .sentinel_en(sentinel_en), .op_req(op_req),
        .pt(pt), .fault_en(fault_en), .fault_round(fault_round), .fault_byte(fault_byte),
        .fault_mask(fault_mask), .alarm_in(alarm_in), .debug_unlock(debug_unlock),
        .power_warn(power_warn),
        .nvm_rd_en(a_rd_en), .nvm_rd_addr(a_rd_addr), .nvm_rd_data(a_rd_data), .nvm_rd_valid(a_rd_valid),
        .nvm_wr_en(a_wr_en), .nvm_wr_addr(a_wr_addr), .nvm_wr_data(a_wr_data), .nvm_wr_done(a_wr_done),
        .tear_count(tc_a),
        .ct_out(ct_a), .ct_valid(v_a), .gate_blocked(blk_a), .tamper_counter(cnt_a),
        .lockdown(lock_a), .busy(busy_a), .round_idx(rnd_a), .key_is_zero(kz_a)
    );
    gl_peruri_sentinel_core gl (
        .clk(clk), .rst_n(rst_n), .por_n(por_n), .sentinel_en(sentinel_en), .op_req(op_req),
        .pt(pt), .fault_en(fault_en), .fault_round(fault_round), .fault_byte(fault_byte),
        .fault_mask(fault_mask), .alarm_in(alarm_in), .debug_unlock(debug_unlock),
        .power_warn(power_warn),
        .nvm_rd_en(b_rd_en), .nvm_rd_addr(b_rd_addr), .nvm_rd_data(b_rd_data), .nvm_rd_valid(b_rd_valid),
        .nvm_wr_en(b_wr_en), .nvm_wr_addr(b_wr_addr), .nvm_wr_data(b_wr_data), .nvm_wr_done(b_wr_done),
        .tear_count(tc_b),
        .ct_out(ct_b), .ct_valid(v_b), .gate_blocked(blk_b), .tamper_counter(cnt_b),
        .lockdown(lock_b), .busy(busy_b), .round_idx(rnd_b), .key_is_zero(kz_b)
    );

    wire [150+2*RECW+3:0] out_a = {ct_a, v_a, blk_a, cnt_a, tc_a, lock_a, busy_a, rnd_a, kz_a,
                                   a_rd_en, a_rd_addr, a_wr_en, a_wr_addr, a_wr_data, a_rd_data};
    wire [150+2*RECW+3:0] out_b = {ct_b, v_b, blk_b, cnt_b, tc_b, lock_b, busy_b, rnd_b, kz_b,
                                   b_rd_en, b_rd_addr, b_wr_en, b_wr_addr, b_wr_data, b_rd_data};

    integer cyc, errors = 0, ncycles, seed, n_valid = 0, n_blk = 0, n_lock = 0, n_fault_ops = 0;
    initial begin
        if (!$value$plusargs("CYCLES=%d", ncycles)) ncycles = 200000;
        if (!$value$plusargs("SEED=%d", seed))      seed = 1;
        repeat (3) @(negedge clk);
        por_n = 1; rst_n = 1;
        for (cyc = 0; cyc < ncycles; cyc = cyc + 1) begin
            @(negedge clk);
            // compare (both sides settled after the posedge)
            if (out_a !== out_b) begin
                errors = errors + 1;
                if (errors <= 5)
                    $display("FAIL tb_cosim: cycle %0d rtl=%h gl=%h", cyc, out_a, out_b);
            end
            if (v_a) n_valid = n_valid + 1;
            if (blk_a) n_blk = n_blk + 1;
            if (lock_a) n_lock = n_lock + 1;
            // new random inputs
            op_req       = ($random(seed) % 8) == 0;
            pt           = {$random(seed), $random(seed), $random(seed), $random(seed)};
            fault_en     = ($random(seed) % 4) == 0;
            fault_round  = $random(seed);
            fault_byte   = $random(seed);
            fault_mask   = $random(seed);
            alarm_in     = ($random(seed) % 256) == 0;
            sentinel_en  = ($random(seed) % 16) != 0;
            debug_unlock = ($random(seed) % 200) == 0;
            power_warn   = ($random(seed) % 512) == 0;
            rst_n        = ($random(seed) % 1024) != 0;
            por_n        = ($random(seed) % 8192) != 0;
            if (op_req && fault_en) n_fault_ops = n_fault_ops + 1;
        end
        $display("cosim: %0d cycles, %0d releases, %0d blocked, %0d lockdown cycles, %0d faulted requests",
                 ncycles, n_valid, n_blk, n_lock, n_fault_ops);
        if (errors == 0) $display("PASS tb_cosim");
        else             $display("FAIL tb_cosim (%0d mismatching cycles)", errors);
        $finish;
    end
endmodule
