// aes128_core: AES-128 encryption, one round per clock cycle (FIPS-197).
//
// Timing: start is sampled in IDLE. The initial AddRoundKey happens on the
// start edge, then rounds 1..10 take one cycle each. done pulses for one
// cycle together with a valid ct_raw, 10 cycles after start.
//
// Demo-only fault hook: when fault_en is high at start, the mask is XORed
// into state byte fault_byte at the beginning of round fault_round. This
// emulates a single-byte fault for DFA demonstrations. Tie fault_en to 0 in
// a production build.
//
// Byte order: byte 0 is bits [127:120]. State is column-major as in FIPS-197
// (bytes 0..3 form column 0).
module aes128_core (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [127:0] key,
    input  wire [127:0] pt,
    input  wire         fault_en,
    input  wire [3:0]   fault_round,
    input  wire [3:0]   fault_byte,
    input  wire [7:0]   fault_mask,
    output reg  [127:0] ct_raw,
    output reg          done,
    output wire         busy,
    output wire [3:0]   round_idx
);

    reg [127:0] state;
    reg [127:0] rk;
    reg [3:0]   round;
    reg         running;
    reg         f_en;
    reg [3:0]   f_round;
    reg [3:0]   f_byte;
    reg [7:0]   f_mask;

    assign busy      = running;
    assign round_idx = round;

    // ---------------- round constant ----------------
    reg [7:0] rcon;
    always @(*) begin
        case (round)
            4'd1:  rcon = 8'h01;
            4'd2:  rcon = 8'h02;
            4'd3:  rcon = 8'h04;
            4'd4:  rcon = 8'h08;
            4'd5:  rcon = 8'h10;
            4'd6:  rcon = 8'h20;
            4'd7:  rcon = 8'h40;
            4'd8:  rcon = 8'h80;
            4'd9:  rcon = 8'h1b;
            4'd10: rcon = 8'h36;
            default: rcon = 8'h00;
        endcase
    end

    // ---------------- key expansion (on the fly) ----------------
    wire [31:0] w0 = rk[127:96];
    wire [31:0] w1 = rk[95:64];
    wire [31:0] w2 = rk[63:32];
    wire [31:0] w3 = rk[31:0];
    wire [31:0] rot = {w3[23:0], w3[31:24]};
    wire [31:0] subw;
    aes_sbox ks0 (.a(rot[31:24]), .y(subw[31:24]));
    aes_sbox ks1 (.a(rot[23:16]), .y(subw[23:16]));
    aes_sbox ks2 (.a(rot[15:8]),  .y(subw[15:8]));
    aes_sbox ks3 (.a(rot[7:0]),   .y(subw[7:0]));
    wire [31:0] tmp = subw ^ {rcon, 24'h0};
    wire [31:0] n0 = w0 ^ tmp;
    wire [31:0] n1 = w1 ^ n0;
    wire [31:0] n2 = w2 ^ n1;
    wire [31:0] n3 = w3 ^ n2;
    wire [127:0] next_rk = {n0, n1, n2, n3};

    // ---------------- fault injection (demo only) ----------------
    wire inject = running && f_en && (round == f_round);
    reg [127:0] fault_vec;
    always @(*) begin
        fault_vec = 128'h0;
        if (inject)
            fault_vec[127 - 8*f_byte -: 8] = f_mask;
    end
    wire [127:0] s_in = state ^ fault_vec;

    // ---------------- SubBytes ----------------
    wire [127:0] sb;
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_sb
            aes_sbox u_sb (.a(s_in[127-8*gi -: 8]), .y(sb[127-8*gi -: 8]));
        end
    endgenerate

    // ---------------- ShiftRows ----------------
    // out byte (col c, row r) = in byte (col (c+r)%4, row r); index = 4*c + r
    wire [127:0] sr;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_sr
            localparam integer C   = gi / 4;
            localparam integer R   = gi % 4;
            localparam integer SRC = 4 * ((C + R) % 4) + R;
            assign sr[127-8*gi -: 8] = sb[127-8*SRC -: 8];
        end
    endgenerate

    // ---------------- MixColumns ----------------
    function [7:0] xt;
        input [7:0] b;
        begin
            xt = {b[6:0], 1'b0} ^ (b[7] ? 8'h1b : 8'h00);
        end
    endfunction

    function [31:0] mixcol;
        input [31:0] c;
        reg [7:0] a0, a1, a2, a3;
        begin
            a0 = c[31:24]; a1 = c[23:16]; a2 = c[15:8]; a3 = c[7:0];
            mixcol[31:24] = xt(a0) ^ (xt(a1) ^ a1) ^ a2 ^ a3;
            mixcol[23:16] = a0 ^ xt(a1) ^ (xt(a2) ^ a2) ^ a3;
            mixcol[15:8]  = a0 ^ a1 ^ xt(a2) ^ (xt(a3) ^ a3);
            mixcol[7:0]   = (xt(a0) ^ a0) ^ a1 ^ a2 ^ xt(a3);
        end
    endfunction

    wire [127:0] mc = {mixcol(sr[127:96]), mixcol(sr[95:64]),
                       mixcol(sr[63:32]),  mixcol(sr[31:0])};

    wire last = (round == 4'd10);
    wire [127:0] round_out = (last ? sr : mc) ^ next_rk;

    // ---------------- sequencing ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= 128'h0;
            rk      <= 128'h0;
            round   <= 4'd0;
            running <= 1'b0;
            done    <= 1'b0;
            ct_raw  <= 128'h0;
            f_en    <= 1'b0;
            f_round <= 4'd0;
            f_byte  <= 4'd0;
            f_mask  <= 8'h0;
        end else begin
            done <= 1'b0;
            if (!running) begin
                if (start) begin
                    state   <= pt ^ key;
                    rk      <= key;
                    round   <= 4'd1;
                    running <= 1'b1;
                    f_en    <= fault_en;
                    f_round <= fault_round;
                    f_byte  <= fault_byte;
                    f_mask  <= fault_mask;
                end
            end else begin
                state <= round_out;
                rk    <= next_rk;
                if (last) begin
                    running <= 1'b0;
                    round   <= 4'd0;
                    done    <= 1'b1;
                    ct_raw  <= round_out;
                end else begin
                    round <= round + 4'd1;
                end
            end
        end
    end

endmodule
