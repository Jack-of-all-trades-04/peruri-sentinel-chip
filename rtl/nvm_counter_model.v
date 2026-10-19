// nvm_counter_model: model of the host chip's NVM that stores the tamper
// record (demo board and simulation only; in a product the NVM belongs to the
// parent secure element and this module is not used). Two independent word
// slots (copy A and copy B). It has no reset input: the record survives a
// core power-on reset, which is the point.
//
// On the FPGA the slots are plain registers, so a real board power-off (or
// reprogramming) clears them; the board demo emulates "card removed from the
// reader" by resetting only the core, while this model keeps its contents,
// as the parent chip's NVM would.
//
// Power-up content (INIT_BLANK):
//   1  both slots blank (all ones, CRC fails): an un-personalised device; the
//      controller boots into lockdown (fail-secure). Used by the tests.
//   0  both slots hold a valid personalised record {seq 1, counters 0}; used
//      by the board demo so it starts unlocked.
//
// Handshake: a transaction starts on the RISING edge of rd_en / wr_en; the
// address (and write data) are latched then, so a held enable does not start
// a second transaction. Read: rd_valid pulses RD_LAT cycles later with
// rd_data. Write: wr_done pulses WR_LAT cycles later. One transaction of each
// kind at a time.
//
// Tearing: if power_ok is low at any time during a write, the write is torn:
// the target slot is left corrupted (one payload bit flipped, CRC byte
// cleared) so the CRC check rejects it; the other slot keeps its last value.
module nvm_counter_model #(
    parameter integer CW         = 4,
    parameter integer RECW       = 17 + 2*CW,   // must match tamper_persist_fsm
    parameter integer RD_LAT     = 2,           // 1..255
    parameter integer WR_LAT     = 8,           // 1..255
    parameter integer INIT_BLANK = 1
) (
    input  wire            clk,
    input  wire            power_ok,
    input  wire            rd_en,
    input  wire            rd_addr,
    output reg  [RECW-1:0] rd_data = {RECW{1'b0}},
    output reg             rd_valid = 1'b0,
    input  wire            wr_en,
    input  wire            wr_addr,
    input  wire [RECW-1:0] wr_data,
    output reg             wr_done = 1'b0
);
    localparam integer PW = RECW - 8;

`include "crc_util.vh"

    function [RECW-1:0] good_record;       // {seq = 1, in_progress = 0, counters 0} + CRC
        input dummy;
        reg [PW-1:0] payload;
        begin
            payload     = {8'd1, {(PW-8){1'b0}}};
            good_record = {payload, crc8_07(PW, {{(256-PW){1'b0}}, payload})};
        end
    endfunction

    localparam [RECW-1:0] INIT = (INIT_BLANK != 0) ? {RECW{1'b1}} : good_record(1'b0);

    reg [RECW-1:0] mem0 = INIT;
    reg [RECW-1:0] mem1 = INIT;
    reg            rd_en_d = 1'b0, wr_en_d = 1'b0;
    reg            rbusy = 1'b0, wbusy = 1'b0, torn = 1'b0, r_addr = 1'b0, w_addr = 1'b0;
    reg [RECW-1:0] w_data = {RECW{1'b0}};
    reg [7:0]      rcnt = 8'd0, wcnt = 8'd0;

    // corrupted copy left by a torn write
    wire [RECW-1:0] torn_data = (w_data ^ ({{(RECW-1){1'b0}}, 1'b1} << 8)) & {{(RECW-8){1'b1}}, 8'h00};

    always @(posedge clk) begin
        rd_valid <= 1'b0;
        wr_done  <= 1'b0;
        rd_en_d  <= rd_en;
        wr_en_d  <= wr_en;

        // ---- read ----
        if (!rbusy && rd_en && !rd_en_d) begin
            rbusy  <= 1'b1;
            rcnt   <= RD_LAT[7:0];
            r_addr <= rd_addr;
        end else if (rbusy) begin
            if (rcnt <= 8'd1) begin
                rbusy    <= 1'b0;
                rd_data  <= r_addr ? mem1 : mem0;
                rd_valid <= 1'b1;
            end else
                rcnt <= rcnt - 8'd1;
        end

        // ---- write ----
        if (!wbusy && wr_en && !wr_en_d) begin
            wbusy  <= 1'b1;
            wcnt   <= WR_LAT[7:0];
            torn   <= !power_ok;
            w_addr <= wr_addr;
            w_data <= wr_data;
        end else if (wbusy) begin
            if (!power_ok) torn <= 1'b1;
            if (wcnt <= 8'd1) begin
                wbusy   <= 1'b0;
                wr_done <= 1'b1;
                if (w_addr) mem1 <= (torn || !power_ok) ? torn_data : w_data;
                else        mem0 <= (torn || !power_ok) ? torn_data : w_data;
            end else
                wcnt <= wcnt - 8'd1;
        end
    end
endmodule
