// output_release_gate (CLK_sys domain)
//
// Holds the AES result internally and releases it only when no alarm was
// seen during the operation (op_start .. aes_done) and during the H cycles
// after aes_done.
//
//   cycle T      : aes_done = 1 (alarm here still blocks)
//   T+1 .. T+H   : HOLD, alarm here still blocks
//   T+H+1        : RELEASE (ct_valid = 1 for one cycle) or SUPPRESS
//
// ct_out reads as zero whenever ct_valid is 0, so a held or blocked result
// is never visible on the output port.
//
// enable = 0 models "Sentinel OFF" for the demo: alarms are ignored and
// every result is released. lockdown = 1 suppresses every release.
module output_release_gate #(
    parameter integer H = 4
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         enable,
    input  wire         lockdown,
    input  wire         op_start,
    input  wire         aes_done,
    input  wire [127:0] ct_raw,
    input  wire         alarm,
    output wire [127:0] ct_out,
    output reg          ct_valid,
    output reg          gate_blocked
);
    localparam [1:0] S_IDLE = 2'd0, S_OP = 2'd1, S_HOLD = 2'd2;

    reg [1:0]   st;
    reg [127:0] ct_hold;
    reg         blocked;
    reg [7:0]   hcnt;

    wire alarm_eff = enable & alarm;

    assign ct_out = ct_valid ? ct_hold : 128'h0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st           <= S_IDLE;
            ct_hold      <= 128'h0;
            blocked      <= 1'b0;
            hcnt         <= 8'd0;
            ct_valid     <= 1'b0;
            gate_blocked <= 1'b0;
        end else begin
            ct_valid     <= 1'b0;
            gate_blocked <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (op_start) begin
                        st      <= S_OP;
                        blocked <= alarm_eff;
                    end
                end
                S_OP: begin
                    if (alarm_eff) blocked <= 1'b1;
                    if (aes_done) begin
                        ct_hold <= ct_raw;
                        hcnt    <= 8'd0;
                        st      <= S_HOLD;
                    end
                end
                S_HOLD: begin
                    if (hcnt == H - 1) begin
                        st <= S_IDLE;
                        if (blocked || alarm_eff || lockdown) begin
                            gate_blocked <= 1'b1;
                            ct_hold      <= 128'h0;   // drop the suspect result
                        end else begin
                            ct_valid <= 1'b1;
                        end
                        blocked <= 1'b0;
                    end else begin
                        if (alarm_eff) blocked <= 1'b1;
                        hcnt <= hcnt + 8'd1;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
