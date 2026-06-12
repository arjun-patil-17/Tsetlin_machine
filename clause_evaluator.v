`timescale 1ns / 1ps

module clause_evaluator #(
    parameter CLAUSES = 512,
    parameter LITERALS = 1536
)(
    input wire clk,
    input wire rst,
    input wire [LITERALS-1:0] patch_in,
    
    // We pass the specific chunk of memory for this class directly to the module
    input wire [LITERALS-1:0] weight_row_in [0:CLAUSES-1], 
    
    output reg [CLAUSES-1:0] clause_active_out
);/* verilator public_module */

    // =========================================================================
    // PROFESSIONAL GENERATE FOR-LOOP: Unrolling 2,048 parallel logic gates
    // =========================================================================
    genvar i;
    generate
        for (i = 0; i < CLAUSES; i = i + 1) begin : gen_clause_logic
            
            // Step 1: Wire up the specific 1536-bit weight row for this clause
            wire [LITERALS-1:0] current_weight = weight_row_in[i];
            
            // Step 2: The Core Tsetlin Math (Zero-Multiplier Logic)
            // A clause outputs '1' ONLY IF all required features (weight == 1) 
            // are present in the patch (patch_in == 1). 
            // Bitwise Logic: (current_weight & ~patch_in) finds MISSING features.
            // If the result is all zeros, the clause evaluates to TRUE (1).
            wire clause_eval = ~|(current_weight & ~patch_in);
            
            // Step 3: Register the output to maintain a clean clock boundary
            always @(posedge clk) begin
                if (rst) begin
                    clause_active_out[i] <= 1'b0;
                end else begin
                    clause_active_out[i] <= clause_eval;
                end
            end
            
        end
    endgenerate

endmodule
