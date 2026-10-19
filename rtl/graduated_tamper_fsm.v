// graduated_tamper_fsm: persistent tamper level.
//
// tamper_counter increments once per RISING EDGE of alarm, inside or outside
// an operation, so a long sticky alarm counts once. When the counter reaches
// N the FSM requests zeroize and enters LOCKDOWN.
//
// Persistence: counter and lockdown are reset only by por_n (power-on /
// reconfiguration), not by the user reset. In the ASIC the counter needs
// OTP/eFuse/host NVM; this RTL does not model that.
//
// Debug unlock (demo rehearsals only): the port exists only in DEMO_BUILD,
// and only acts when DEMO_UNLOCK = 1.
module graduated_tamper_fsm #(
    parameter integer N           = 4,
    parameter integer DEMO_UNLOCK = 1
) (
    input  wire       clk,
    input  wire       por_n,
    input  wire       alarm,
`ifdef DEMO_BUILD
    input  wire       debug_unlock,
`endif
    output reg  [3:0] tamper_counter,
    output reg        zeroize_req,
    output reg        lockdown_state
);
`ifndef DEMO_BUILD
    wire debug_unlock = 1'b0;     // production: no unlock port at all
`endif
    reg alarm_d;
    wire alarm_rise = alarm & ~alarm_d;

    always @(posedge clk or negedge por_n) begin
        if (!por_n) begin
            alarm_d        <= 1'b0;
            tamper_counter <= 4'd0;
            zeroize_req    <= 1'b0;
            lockdown_state <= 1'b0;
        end else begin
            alarm_d <= alarm;
            if (DEMO_UNLOCK != 0 && debug_unlock) begin
                tamper_counter <= 4'd0;
                zeroize_req    <= 1'b0;
                lockdown_state <= 1'b0;
            end else begin
                if (alarm_rise && tamper_counter != 4'hf)
                    tamper_counter <= tamper_counter + 4'd1;
                if (tamper_counter >= N || (alarm_rise && tamper_counter + 1 >= N)) begin
                    zeroize_req    <= 1'b1;   // ZEROIZE
                    lockdown_state <= 1'b1;   // then LOCKDOWN (held)
                end
            end
        end
    end
endmodule
