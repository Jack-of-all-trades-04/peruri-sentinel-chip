// snn_lif_engine: N_NEU leaky integrate-and-fire neurons over the 12-bit
// spike_bus, plus a coincidence output layer (CLK_sentinel domain).
//
// On every tick, for each neuron i:
//   V_i <- V_i - (V_i >>> LEAK_SHIFT) + sum_j S_j * W_ij
//   if V_i >= VTH: neuron fires, V_i <- 0
//   V_i is clamped to [0, VMAX]
// S_j is 0 or 1, so S_j * W_ij is a select, not a multiplication: the
// datapath is adders and shifts only (0 DSP).
// anomaly_alarm pulses for one cycle when at least COINC_MIN neurons fire
// on the same tick.
//
// Weights (offline-tuned constants; parameters, no memory block):
//   W_SELF  from RO channel i to neuron i
//   W_NEIGH from the two neighbouring RO channels (i-1, i+1, wrapping)
//   W_TDL   from the TDL channel (spike_bus[8]) to every neuron
// Defaults: one RO spike alone does not fire (W_SELF = VTH/2); the same RO
// spiking on two or three consecutive windows does, and two neighbouring
// ROs spiking together fire faster. A TDL event alone does not fire
// (W_TDL = VTH/4): it is already handled by the fast path (gate and tamper
// FSM), so here it only adds evidence when RO spikes coincide with it.
// A larger W_TDL would count one glitch twice (fast path, then LIF).
module snn_lif_engine #(
    parameter integer N_NEU      = 8,
    parameter integer VW         = 12,     // membrane width (signed)
    parameter integer LEAK_SHIFT = 2,
    parameter integer VTH        = 64,
    parameter integer W_SELF     = 32,
    parameter integer W_NEIGH    = 16,
    parameter integer W_TDL      = 16,
    parameter integer COINC_MIN  = 1
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              tick,
    input  wire [11:0]       spike_bus,
    output reg  [N_NEU-1:0]  fire,
    output reg               anomaly_alarm
);
    localparam integer VMAX = (1 << (VW - 1)) - 1;

    reg signed [VW-1:0] v [0:N_NEU-1];

    function integer wgt;      // weight from input j to neuron i
        input integer i;
        input integer j;
        begin
            if (j == 8)                                      wgt = W_TDL;
            else if (j > 8)                                  wgt = 0;
            else if (j == i)                                 wgt = W_SELF;
            else if (j == (i + 1) % N_NEU || j == (i + N_NEU - 1) % N_NEU) wgt = W_NEIGH;
            else                                             wgt = 0;
        end
    endfunction

    integer i, j, nf;
    reg signed [VW+4:0] acc;
    reg [N_NEU-1:0]     f_next;
    reg signed [VW-1:0] v_next [0:N_NEU-1];

    always @(*) begin
        nf = 0;
        for (i = 0; i < N_NEU; i = i + 1) begin
            acc = v[i] - (v[i] >>> LEAK_SHIFT);
            for (j = 0; j < 12; j = j + 1)
                if (spike_bus[j]) acc = acc + wgt(i, j);
            if (acc >= VTH) begin
                f_next[i] = 1'b1;
                v_next[i] = {VW{1'b0}};
                nf = nf + 1;
            end else begin
                f_next[i] = 1'b0;
                if (acc < 0)         v_next[i] = {VW{1'b0}};
                else if (acc > VMAX) v_next[i] = VMAX;
                else                 v_next[i] = acc[VW-1:0];
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N_NEU; i = i + 1) v[i] <= {VW{1'b0}};
            fire          <= {N_NEU{1'b0}};
            anomaly_alarm <= 1'b0;
        end else begin
            anomaly_alarm <= 1'b0;
            if (tick) begin
                for (i = 0; i < N_NEU; i = i + 1) v[i] <= v_next[i];
                fire          <= f_next;
                anomaly_alarm <= (nf >= COINC_MIN);
            end
        end
    end
endmodule
