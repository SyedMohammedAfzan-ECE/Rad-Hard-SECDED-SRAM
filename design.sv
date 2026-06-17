`timescale 1ns/1ps

//======================================================
// 2K x 16 SRAM with SEC-DED Protection
//======================================================
module sram_2kx16_secded (
    input  logic        clk,
    input  logic        cs,
    input  logic        we,
    input  logic        oe,
    input  logic [10:0] addr,
    input  logic [15:0] wdata,

    output logic [15:0] rdata,
    output logic        sec_err,
    output logic        ded_err
);

    // Physical Memory: [21:16] = parity bits, [15:0] = user data
    logic [21:0] mem [0:2047];

    // Internal Signals
    logic [5:0]  write_parity;
    logic [21:0] raw_mem_read;
    logic [15:0] fixed_data;
    logic        sec_err_int;
    logic        ded_err_int;

    // SEC-DED Encoder (Combinational)
    assign write_parity[0] = wdata[0]^wdata[1]^wdata[3]^wdata[4]^wdata[6]^wdata[8]^wdata[10]^wdata[11]^wdata[13]^wdata[15];
    assign write_parity[1] = wdata[0]^wdata[2]^wdata[3]^wdata[5]^wdata[6]^wdata[9]^wdata[10]^wdata[12]^wdata[13];
    assign write_parity[2] = wdata[1]^wdata[2]^wdata[3]^wdata[7]^wdata[8]^wdata[9]^wdata[10]^wdata[14]^wdata[15];
    assign write_parity[3] = wdata[4]^wdata[5]^wdata[6]^wdata[7]^wdata[8]^wdata[9]^wdata[10];
    assign write_parity[4] = wdata[11]^wdata[12]^wdata[13]^wdata[14]^wdata[15];
    assign write_parity[5] = ^wdata ^ ^write_parity[4:0]; // Overall Parity

    // Synchronous Read/Write Access
    always_ff @(posedge clk) begin
        if (cs && we)
            mem[addr] <= {write_parity, wdata};
        
        if (cs && !we)
            raw_mem_read <= mem[addr];
    end

    // SEC-DED Decoder Instance
    sec_ded_decoder u_decoder (
        .raw_data   (raw_mem_read[15:0]),
        .raw_parity (raw_mem_read[21:16]),
        .fixed_data (fixed_data),
        .sec_err    (sec_err_int),
        .ded_err    (ded_err_int)
    );

    // Output Assignments with Tri-State Buffer
    assign rdata   = (cs && !we && oe) ? fixed_data  : 16'hzzzz;
    assign sec_err = (cs && !we && oe) ? sec_err_int : 1'b0;
    assign ded_err = (cs && !we && oe) ? ded_err_int : 1'b0;

endmodule

//======================================================
// SEC-DED Decoder Combinational Block
//======================================================
module sec_ded_decoder (
    input  logic [15:0] raw_data,
    input  logic [5:0]  raw_parity,
    output logic [15:0] fixed_data,
    output logic        sec_err,
    output logic        ded_err
);

    logic [4:0] calc_p;
    logic [4:0] syndrome;
    logic       overall_check;

    always_comb begin
        // Defaults to prevent latches
        fixed_data = raw_data;
        sec_err    = 1'b0;
        ded_err    = 1'b0;

        // Recalculate SEC Parity Bits
        calc_p[0] = raw_data[0]^raw_data[1]^raw_data[3]^raw_data[4]^raw_data[6]^raw_data[8]^raw_data[10]^raw_data[11]^raw_data[13]^raw_data[15];
        calc_p[1] = raw_data[0]^raw_data[2]^raw_data[3]^raw_data[5]^raw_data[6]^raw_data[9]^raw_data[10]^raw_data[12]^raw_data[13];
        calc_p[2] = raw_data[1]^raw_data[2]^raw_data[3]^raw_data[7]^raw_data[8]^raw_data[9]^raw_data[10]^raw_data[14]^raw_data[15];
        calc_p[3] = raw_data[4]^raw_data[5]^raw_data[6]^raw_data[7]^raw_data[8]^raw_data[9]^raw_data[10];
        calc_p[4] = raw_data[11]^raw_data[12]^raw_data[13]^raw_data[14]^raw_data[15];

        // Calculate Syndrome & Overall Parity
        syndrome = calc_p ^ raw_parity[4:0];
        overall_check = (^raw_data) ^ (^raw_parity[4:0]) ^ raw_parity[5];

        // Error Classification
        if ((syndrome == 5'd0) && (overall_check == 1'b0)) begin
            sec_err = 1'b0;
            ded_err = 1'b0;
        end
        else if ((syndrome != 5'd0) && (overall_check == 1'b1)) begin
            sec_err = 1'b1;
            case (syndrome)
                5'd3  : fixed_data[0]  = ~raw_data[0];
                5'd5  : fixed_data[1]  = ~raw_data[1];
                5'd6  : fixed_data[2]  = ~raw_data[2];
                5'd7  : fixed_data[3]  = ~raw_data[3];
                5'd9  : fixed_data[4]  = ~raw_data[4];
                5'd10 : fixed_data[5]  = ~raw_data[5];
                5'd11 : fixed_data[6]  = ~raw_data[6];
                5'd12 : fixed_data[7]  = ~raw_data[7];
                5'd13 : fixed_data[8]  = ~raw_data[8];
                5'd14 : fixed_data[9]  = ~raw_data[9];
                5'd15 : fixed_data[10] = ~raw_data[10];
                5'd17 : fixed_data[11] = ~raw_data[11];
                5'd18 : fixed_data[12] = ~raw_data[12];
                5'd19 : fixed_data[13] = ~raw_data[13];
                5'd20 : fixed_data[14] = ~raw_data[14];
                5'd21 : fixed_data[15] = ~raw_data[15];
                default : fixed_data = raw_data; // Error in parity bit itself
            endcase
        end
        else if ((syndrome != 5'd0) && (overall_check == 1'b0)) begin
            ded_err = 1'b1; // Double error detected
        end
        else begin
            sec_err = 1'b1; // Overall parity bit error only
        end
    end
endmodule
