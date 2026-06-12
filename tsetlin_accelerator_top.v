`timescale 1ns / 1ps

module tsetlin_accelerator_top #(
    parameter CLASSES = 3,            // CHANGED: 3 Classes (Airplane, Dog, Truck)
    parameter CLAUSES = 1200,         // CHANGED: Scaled to 1200 clauses per class
    parameter LITERALS = 1536,        // 8x8 Patch * 12 channels * 2 polarities
    parameter PATCHES_PER_IMG = 625   // (32-8+1) * (32-8+1)
)(
    input wire clk,
    input wire rst,
    
    // Pixel Streaming Interface
    input wire pixel_valid_in,
    input wire [11:0] pixel_in,
    
    // Final Prediction Interface
    output reg [3:0] predicted_class,
    output reg prediction_valid
);

    // =========================================================================
    // 1. Data Delivery: Instantiate the Sliding Window Line Buffer
    // =========================================================================
    wire patch_valid;
    wire [LITERALS-1:0] patch_data;

    sliding_window_buffer #(
        .IMG_WIDTH(32), .IMG_HEIGHT(32), .PATCH_SIZE(8), .PIXEL_BITS(12)
    ) line_buffer (
        .clk(clk),
        .rst(rst),
        .valid_in(pixel_valid_in),
        .pixel_in(pixel_in),
        .valid_out(patch_valid),
        .patch_out(patch_data)
    );

    // =========================================================================
    // 2. ROM Generation: Loading the weights.memb from Python
    // =========================================================================
    // Dynamically handles (3 classes * 1200 clauses) = 3600 rows
    reg [LITERALS-1:0] weight_memory [0:(CLASSES * CLAUSES) - 1];

    initial begin
        $readmemb("weights.memb", weight_memory);
    end

    // =========================================================================
    // 3. Parallel Class Mapping Layout
    // =========================================================================
    wire [CLAUSES-1:0] class_clause_active [0:CLASSES-1];
    
    genvar c, w;
    generate
        for (c = 0; c < CLASSES; c = c + 1) begin : gen_classes
            
            wire [LITERALS-1:0] local_weights [0:CLAUSES-1];
            for (w = 0; w < CLAUSES; w = w + 1) begin : gen_weight_mapping
                assign local_weights[w] = weight_memory[(c * CLAUSES) + w];
            end

            clause_evaluator #(
                .CLAUSES(CLAUSES), .LITERALS(LITERALS)
            ) evaluator_inst (
                .clk(clk),
                .rst(rst),
                .patch_in(patch_data),
                .weight_row_in(local_weights),
                .clause_active_out(class_clause_active[c])
            );
        end
    endgenerate

    // =========================================================================
    // 4. Spatial Pooling (Accumulating Votes Across the 625 Patches)
    // =========================================================================
    integer class_idx;
    
    // UPDATED: Changed from [9:0] to [10:0] to cleanly hold signed +/- 600 values
    reg signed [10:0] current_patch_vote [0:CLASSES-1]; 

    // UPDATED: Changed from [18:0] to [19:0] to fully prevent overflow at 375,000 max total
    reg signed [19:0] class_vote_totals [0:CLASSES-1]; 
    
    reg [9:0] patch_counter; 
    reg patch_valid_d1;

    // Behavioral Popcount Combinational Tree
integer c_idx, cl_idx;
    
    // Internal registers to count active positive (even) and negative (odd) clauses independently
    reg [10:0] pos_clause_count [0:CLASSES-1];
    reg [10:0] neg_clause_count [0:CLASSES-1];

    always @(*) begin
        for (c_idx = 0; c_idx < CLASSES; c_idx = c_idx + 1) begin
            
            // Step 1: Clear local accumulation bins
            pos_clause_count[c_idx] = 11'd0;
            neg_clause_count[c_idx] = 11'd0;
            
            // Step 2: Unroll the main iteration loop
            // Modulus (%) is replaced by checking bit 0 [0], which executes instantly in hardware.
            for (cl_idx = 0; cl_idx < CLAUSES; cl_idx = cl_idx + 1) begin
                if (class_clause_active[c_idx][cl_idx]) begin
                    if (cl_idx[0] == 1'b0) begin
                        pos_clause_count[c_idx] = pos_clause_count[c_idx] + 11'd1;
                    end else begin
                        neg_clause_count[c_idx] = neg_clause_count[c_idx] + 11'd1;
                    end
                end
            end
            
            // Step 3: Compute the unified directional patch score at a single final node
            // This replaces 1,200 dependency steps with a single balanced subtraction subtraction.
            current_patch_vote[c_idx] = $signed(pos_clause_count[c_idx]) - $signed(neg_clause_count[c_idx]);
        end
    end
    // Sequential Clocking for Accumulators
    always @(posedge clk) begin
        if (rst) begin
            patch_valid_d1 <= 0;
            patch_counter <= 0;
            prediction_valid <= 0;
            for (class_idx = 0; class_idx < CLASSES; class_idx = class_idx + 1) begin
                class_vote_totals[class_idx] <= 0;
            end
        end else begin
            patch_valid_d1 <= patch_valid; 
            prediction_valid <= 0;
            
            if (patch_valid_d1) begin
                for (class_idx = 0; class_idx < CLASSES; class_idx = class_idx + 1) begin
                    // UPDATED sign extension string to pad an 11-bit signed value out to 20 bits safely
                    class_vote_totals[class_idx] <= class_vote_totals[class_idx] + {{9{current_patch_vote[class_idx][10]}}, current_patch_vote[class_idx]};
                end
                
                if (patch_counter == PATCHES_PER_IMG - 1) begin
                    patch_counter <= 0;
                    prediction_valid <= 1; 
                end else begin
                    patch_counter <= patch_counter + 1;
                end
            end else if (prediction_valid) begin
                for (class_idx = 0; class_idx < CLASSES; class_idx = class_idx + 1) begin
                    class_vote_totals[class_idx] <= 0;
                end
            end
        end
        if (patch_valid_d1 && patch_counter == 10) begin
//     $display("[CLAUSE DEBUG] patch_counter=10");
//     $display("  patch_data[11:0]   = %b", patch_data[11:0]);
//     $display("  weight[0][11:0]    = %b", weight_memory[0][11:0]);
//     $display("  weight[0] full     = %b", weight_memory[0]);
//     $display("  clause[0] active   = %b", class_clause_active[0][0]);
//     $display("  clause[1] active   = %b", class_clause_active[0][1]);
//     $display("  total active C0    = %0d", $countones(class_clause_active[0]));
//     $display("  total active C1    = %0d", $countones(class_clause_active[1]));
//     $display("  total active C2    = %0d", $countones(class_clause_active[2]));

//     $display("  weight[0][1535:1524] = %b", weight_memory[0][1535:1524]);
// $display("  patch_data[1535:1524]= %b", patch_data[1535:1524]);
// $display("  weight[0][767:756]   = %b", weight_memory[0][767:756]);
// $display("  patch_data[767:756]  = %b", patch_data[767:756]);

//     $display("[PATCH0] patch_data[11:0]  =%b", patch_data[11:0]);
//     $display("[PATCH0] patch_data[23:12] =%b", patch_data[23:12]);
//     $display("[PATCH0] patch_data[35:24] =%b", patch_data[35:24]);
//     $display("[PATCH0] patch_data[767:756]=%b", patch_data[767:756]);
end
    end

    // =========================================================================
    // 5. Parallel ArgMax (Winner-Takes-All Comparator)
    // =========================================================================
    integer comp_idx;
    // UPDATED: Extended to 20 bits and set minimum ceiling value to match -20'sd524288
    reg signed [19:0] max_val; 
    reg [3:0] max_class;
    
    always @(*) begin
        max_val = -20'sd524288; 
        max_class = 0;
        for (comp_idx = 0; comp_idx < CLASSES; comp_idx = comp_idx + 1) begin
            if (class_vote_totals[comp_idx] > max_val) begin
                max_val = class_vote_totals[comp_idx];
                max_class = comp_idx[3:0];
            end
        end
        predicted_class = max_class;
    end

endmodule