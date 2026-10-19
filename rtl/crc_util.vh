// crc_util.vh: small CRC helpers shared by the NVM record controller and the
// production key integrity check. Pure functions, no state.
//
//   CRC-8  polynomial 0x07 (ATM/ITU), init 0x00, over an arbitrary-width bus,
//          MSB first. Used for the tamper NVM record.
//   CRC-16 CCITT-FALSE, polynomial 0x1021, init 0xFFFF, MSB first. Used for
//          the 128-bit key integrity word (production build, P1-2 item 5).
function automatic [7:0] crc8_07;
    input integer width;
    input [255:0]  data;        // low `width` bits are the message, MSB first
    integer i;
    reg [7:0] c;
    reg       fb;
    begin
        c = 8'h00;
        for (i = width - 1; i >= 0; i = i - 1) begin
            fb = c[7] ^ data[i];
            c  = {c[6:0], 1'b0};
            if (fb) c = c ^ 8'h07;
        end
        crc8_07 = c;
    end
endfunction

function automatic [15:0] crc16_ccitt;
    input [127:0] data;         // 128-bit message, MSB first
    integer i;
    reg [15:0] c;
    reg        fb;
    begin
        c = 16'hFFFF;
        for (i = 127; i >= 0; i = i - 1) begin
            fb = c[15] ^ data[i];
            c  = {c[14:0], 1'b0};
            if (fb) c = c ^ 16'h1021;
        end
        crc16_ccitt = c;
    end
endfunction

