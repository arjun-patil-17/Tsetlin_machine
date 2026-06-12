`timescale 1ns / 1ps

module sliding_window_buffer #(
    parameter IMG_WIDTH = 32,        // CIFAR-10 Width
    parameter IMG_HEIGHT = 32,       // CIFAR-10 Height
    parameter PATCH_SIZE = 8,        // 8x8 Hardware Window
    parameter PIXEL_BITS = 12        // 3 Channels * 4 Thermometer Thresholds
)(
    input wire clk,
    input wire rst,
    input wire valid_in,             // High when a valid pixel streams in
    input wire [PIXEL_BITS-1:0] pixel_in,

    output wire valid_out,           // High when a full 8x8 patch is perfectly aligned
    output wire [(PATCH_SIZE * PATCH_SIZE * PIXEL_BITS * 2) - 1 : 0] patch_out 
);/* verilator public_module */

    // =========================================================================
    // 1. The Line Buffer Memory (2D Shift Register Snake)
    // =========================================================================
    // OPTIMIZATION: We only need to buffer the raw 12-bit pixels! 
    // We will automatically generate the 12-bit negated versions combinationally at the exit bus.
    reg [PIXEL_BITS-1:0] shift_reg [0:PATCH_SIZE-1][0:IMG_WIDTH-1];

    reg [5:0] x_cnt;
    reg [5:0] y_cnt;
    integer dbg_clk_count;
always @(posedge clk) begin
    dbg_clk_count <= dbg_clk_count + 1;
end

    integer r, c;
    always @(posedge clk) begin
        if (rst) begin
            x_cnt <= 0;
            y_cnt <= 0;
            for (r = 0; r < PATCH_SIZE; r = r + 1) begin
                for (c = 0; c < IMG_WIDTH; c = c + 1) begin
                    shift_reg[r][c] <= 0;
                end
            end
        end else if (valid_in) begin
            // Shift newest raw pixel into the start of the snake
            //$display("  [SWB] valid_in fired x_cnt=%0d", x_cnt);
            shift_reg[0][0] <= pixel_in;
            for (c = 1; c < IMG_WIDTH; c = c + 1) begin
                shift_reg[0][c] <= shift_reg[0][c-1];
            end

            // Cascade rows
            for (r = 1; r < PATCH_SIZE; r = r + 1) begin
                shift_reg[r][0] <= shift_reg[r-1][IMG_WIDTH-1];
                for (c = 1; c < IMG_WIDTH; c = c + 1) begin
                    shift_reg[r][c] <= shift_reg[r][c-1];
                end
            end

            // Coordinate Tracking
            if (x_cnt == IMG_WIDTH - 1) begin
                x_cnt <= 0;
                if (y_cnt == IMG_HEIGHT - 1) y_cnt <= 0;
                else y_cnt <= y_cnt + 1;
            end else begin
                x_cnt <= x_cnt + 1;
            end
        end
    end

    // =========================================================================
    // 2. Smart Boundary Flagging
    // =========================================================================
    assign valid_out = valid_in && (y_cnt >= PATCH_SIZE - 1) && (x_cnt >= PATCH_SIZE - 1);

    // =========================================================================
    // 3. HARDWARE/SOFTWARE CO-DESIGN FIX: Blocked vs Interleaved Mapping
    // =========================================================================
    // PyTsetlinMachine exports ALL True features as one solid 768-bit block, 
    // followed by ALL Negated features as a second 768-bit block.
    // This generate loop perfectly mimics the software memory layout.
    localparam NEG_OFFSET = PATCH_SIZE * PATCH_SIZE * PIXEL_BITS; // 768 bits

    genvar gy, gx;
    generate
        for (gy = 0; gy < PATCH_SIZE; gy = gy + 1) begin : gen_patch_y
            for (gx = 0; gx < PATCH_SIZE; gx = gx + 1) begin : gen_patch_x
                
                localparam PIXEL_FLAT_IDX = (gy * PATCH_SIZE + gx) * PIXEL_BITS;
                
                // Extract the specific 12-bit pixel from the shift register
                wire [PIXEL_BITS-1:0] current_pixel = shift_reg[PATCH_SIZE - 1 - gy][PATCH_SIZE - 1 - gx];
                
                // 1. Route TRUE features to the bottom half of the bus [767:0]
                assign patch_out[PIXEL_FLAT_IDX + PIXEL_BITS - 1 : PIXEL_FLAT_IDX] = current_pixel;
                
                // 2. Route NEGATED features to the top half of the bus [1535:768]
                assign patch_out[NEG_OFFSET + PIXEL_FLAT_IDX + PIXEL_BITS - 1 : NEG_OFFSET + PIXEL_FLAT_IDX] = ~current_pixel;
                
            end
        end
    endgenerate

endmodule