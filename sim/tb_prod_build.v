// BUILD: prod
// Production build of peruri_sentinel_core (compiled WITHOUT DEMO_BUILD):
//   - no request is accepted before a key is written
//   - the key is written once through key_wr_en / key_wr_data and gives the
//     FIPS-197 C.1 ciphertext
//   - a second write in the same power-on session is ignored (sealed),
//     also after a user reset
//   - an alarm during an operation blocks the release and is counted
//   - N alarms: zeroize + lockdown; no request is served afterwards and a
//     user reset does not undo it (the build has no unlock port)
//   - after zeroize the vault stays sealed: a new key cannot be written
//     in the same power-on session
//   - a core with a blank (un-personalised) NVM boots into lockdown
// The absence of the demo ports themselves is checked by syn/yosys_check.sh.
`timescale 1ns/1ps
module tb_prod_build;
    reg clk = 0;
    always #10 clk = ~clk;

    reg          rst_n = 0, por_n = 0, op_req = 0, alarm_in = 0;
    reg          key_wr_en = 0;
    reg  [127:0] key_wr_data = 0;
    wire [127:0] ct_out;
    wire         ct_valid, gate_blocked, lockdown, busy, key_is_zero;
    wire [3:0]   tamper_counter;
    localparam [127:0] KEY  = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] KEY2 = 128'hffeeddccbbaa99887766554433221100;
    localparam [127:0] PT   = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] EXP  = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    // host NVM model holding a valid personalised record
    localparam integer RECW = 17 + 2*4;
    wire nvm_rd_en, nvm_rd_addr, nvm_rd_valid, nvm_wr_en, nvm_wr_addr, nvm_wr_done;
    wire [RECW-1:0] nvm_rd_data, nvm_wr_data;
    nvm_counter_model #(.CW(4), .INIT_BLANK(0)) u_nvm (
        .clk(clk), .power_ok(1'b1),
        .rd_en(nvm_rd_en), .rd_addr(nvm_rd_addr), .rd_data(nvm_rd_data), .rd_valid(nvm_rd_valid),
        .wr_en(nvm_wr_en), .wr_addr(nvm_wr_addr), .wr_data(nvm_wr_data), .wr_done(nvm_wr_done)
    );

    peruri_sentinel_core #(.H(4), .N(4)) dut (
        .clk(clk), .rst_n(rst_n), .por_n(por_n), .op_req(op_req), .pt(PT),
        .alarm_in(alarm_in), .key_wr_en(key_wr_en), .key_wr_data(key_wr_data),
        .power_warn(1'b0),
        .nvm_rd_en(nvm_rd_en), .nvm_rd_addr(nvm_rd_addr), .nvm_rd_data(nvm_rd_data),
        .nvm_rd_valid(nvm_rd_valid), .nvm_wr_en(nvm_wr_en), .nvm_wr_addr(nvm_wr_addr),
        .nvm_wr_data(nvm_wr_data), .nvm_wr_done(nvm_wr_done), .tear_count(),
        
        .ct_out(ct_out), .ct_valid(ct_valid), .gate_blocked(gate_blocked),
        .tamper_counter(tamper_counter), .lockdown(lockdown), .busy(busy),
        .key_is_zero(key_is_zero)
    );


    // second production core with a BLANK (un-personalised) NVM: must boot
    // into fail-secure lockdown and never release anything
    wire b_rd_en, b_rd_addr, b_rd_valid, b_wr_en, b_wr_addr, b_wr_done;
    wire [RECW-1:0] b_rd_data, b_wr_data;
    wire [127:0] b_ct_out;
    wire b_ct_valid, b_lockdown, b_key_is_zero;
    nvm_counter_model #(.CW(4), .INIT_BLANK(1)) u_nvm_blank (
        .clk(clk), .power_ok(1'b1),
        .rd_en(b_rd_en), .rd_addr(b_rd_addr), .rd_data(b_rd_data), .rd_valid(b_rd_valid),
        .wr_en(b_wr_en), .wr_addr(b_wr_addr), .wr_data(b_wr_data), .wr_done(b_wr_done)
    );
    peruri_sentinel_core #(.H(4), .N(4)) dut_blank (
        .clk(clk), .rst_n(rst_n), .por_n(por_n), .op_req(op_req), .pt(PT),
        .alarm_in(1'b0), .key_wr_en(key_wr_en), .key_wr_data(key_wr_data), .power_warn(1'b0),
        .nvm_rd_en(b_rd_en), .nvm_rd_addr(b_rd_addr), .nvm_rd_data(b_rd_data),
        .nvm_rd_valid(b_rd_valid), .nvm_wr_en(b_wr_en), .nvm_wr_addr(b_wr_addr),
        .nvm_wr_data(b_wr_data), .nvm_wr_done(b_wr_done), .tear_count(),
        .ct_out(b_ct_out), .ct_valid(b_ct_valid), .gate_blocked(), .tamper_counter(),
        .lockdown(b_lockdown), .busy(), .key_is_zero(b_key_is_zero)
    );
    integer n_blank_rel = 0;
    always @(posedge clk) if (b_ct_valid) n_blank_rel = n_blank_rel + 1;

    integer n_ok = 0, n_bad = 0, n_blk = 0, errors = 0, k;
    always @(posedge clk) begin
        if (ct_valid) begin
            if (ct_out == EXP) n_ok = n_ok + 1; else n_bad = n_bad + 1;
        end
        if (gate_blocked) n_blk = n_blk + 1;
    end

    task check;
        input            cond;
        input [8*64-1:0] name;
        begin
            if (!cond) begin
                $display("FAIL %0s (ok=%0d bad=%0d blk=%0d cnt=%0d lock=%b)",
                         name, n_ok, n_bad, n_blk, tamper_counter, lockdown);
                errors = errors + 1;
            end else
                $display("  ok %0s", name);
        end
    endtask

    task write_key;
        input [127:0] k;
        begin
            @(negedge clk) begin key_wr_en = 1; key_wr_data = k; end
            @(negedge clk) begin key_wr_en = 0; key_wr_data = 0; end
        end
    endtask

    // one request; if `attack` the alarm is held for a few cycles mid-op
    task op;
        input attack;
        begin
            @(negedge clk) op_req = 1;
            @(negedge clk) op_req = 0;
            if (attack) begin
                repeat (6) @(negedge clk);
                alarm_in = 1; repeat (2) @(negedge clk); alarm_in = 0;
            end
            repeat (100) @(negedge clk);
        end
    endtask

    task user_reset;
        begin
            @(negedge clk) rst_n = 0; repeat (3) @(negedge clk); rst_n = 1;
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        por_n = 1; rst_n = 1;
        repeat (40) @(negedge clk);       // boot: NVM record read

        op(0);
        check(n_ok == 0 && n_bad == 0 && n_blk == 0 && key_is_zero,
              "no key written: request refused, nothing released");

        write_key(KEY);
        op(0);
        check(n_ok == 1 && n_bad == 0, "key written once: FIPS-197 C.1 ciphertext released");

        write_key(KEY2);
        op(0);
        check(n_ok == 2 && n_bad == 0, "second key write ignored (vault sealed)");
        user_reset;
        write_key(KEY2);
        op(0);
        check(n_ok == 3 && n_bad == 0, "user reset does not reopen the vault");

        op(1);
        check(n_ok == 3 && n_bad == 0 && n_blk == 1 && tamper_counter == 1,
              "alarm during the operation: release blocked, counted");
        for (k = 0; k < 3; k = k + 1) op(1);
        check(lockdown && key_is_zero && tamper_counter == 4 && n_bad == 0,
              "N = 4 alarms: zeroize and lockdown");
        op(0);
        check(n_ok == 3, "no release in lockdown");
        for (k = 0; k < 3; k = k + 1) user_reset;
        op(0);
        check(lockdown && key_is_zero && n_ok == 3, "user resets do not undo lockdown");
        write_key(KEY);
        op(0);
        check(key_is_zero && n_ok == 3, "no key can be written after zeroize in this session");

        check(b_lockdown && b_key_is_zero && n_blank_rel == 0,
              "blank (un-personalised) NVM: fail-secure lockdown, nothing released");

        if (errors == 0) $display("PASS tb_prod_build");
        else             $display("FAIL tb_prod_build (%0d errors)", errors);
        $finish;
    end
endmodule
