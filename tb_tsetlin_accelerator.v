`timescale 1ns / 1ps

module tb_tsetlin_accelerator;

    reg clk;
    reg rst;
    
    initial clk = 0;
    always begin #5;
    clk = ~clk;
    end

    // =========================================================================
    // PERFORMANCE METRIC TRACKING SIGNALS
    // =========================================================================
    integer global_cycle_count = 0;
    always @(posedge clk) begin
        if (!rst) begin
            global_cycle_count = global_cycle_count + 1;
        end
    end

    integer img_start_cycle;
    integer img_latency_cycles;
    real    img_start_time;
    real    img_latency_ns;
    
    // Summary Accumulators
    integer total_inference_cycles = 0;
    real    total_inference_time_ns = 0.0;
    integer early_trigger_count = 0;

    // Safety Global Watchdog
    initial begin
        #250000000;
        $display("\n[FATAL TIMEOUT] Simulation forced stop at %0t ns.", $time);
        $finish;
    end

    reg pixel_valid_in;
    reg [11:0] pixel_in;
    
    wire [3:0] predicted_class;
    wire prediction_valid;

    // Instantiation drives updated parameters straight into the DUT
    tsetlin_accelerator_top #(
        .CLASSES(3),                  
        .CLAUSES(1200),               
        .LITERALS(1536),
        .PATCHES_PER_IMG(625)
    ) dut (
        .clk(clk),
        .rst(rst),
        .pixel_valid_in(pixel_valid_in),
        .pixel_in(pixel_in),
        .predicted_class(predicted_class),
        .prediction_valid(prediction_valid)
    );

    reg [12287:0] test_images [0:19];
    reg [3:0] test_labels [0:19];

    integer img_idx, pixel_idx;
    reg [12287:0] current_img;
    integer correct_predictions;
    integer watchdog_timer;
    reg prediction_done;

    initial begin
        $display("Loading memory configurations...");
        $readmemb("test_images.memb", test_images);
        $readmemb("test_labels.memb", test_labels);
        
        pixel_valid_in = 0;
        pixel_in = 0;
        correct_predictions = 0;
        
        $display("Asserting Reset...");
        rst = 1;
        #100;
        @(negedge clk);
        rst = 0;
        $display("Reset complete. Starting image stream...\n");
        #20;

        // FIXED: Loop bounds changed to < 20 to properly evaluate all 20 images
        for (img_idx = 0; img_idx < 20; img_idx = img_idx + 1) begin
            current_img = test_images[img_idx];
            $display("\nStreaming Image %0d/20 [True Class: %0d]...", img_idx, test_labels[img_idx]);
            prediction_done = 0;

            // PERFORMANCE START: Capture metrics right before streaming begins
            img_start_cycle = global_cycle_count;
            img_start_time  = $realtime;

            for (pixel_idx = 0; pixel_idx < 1024; pixel_idx = pixel_idx + 1) begin
                @(negedge clk);
                pixel_in = current_img[pixel_idx * 12 +: 12];
                pixel_valid_in = 1'b1;

                if (pixel_idx < 5) begin
                    @(posedge clk);  
                    #1;              
                   // $display("  [TB-TOP] dut.pixel_valid_in=%0b dut.line_buffer.valid_in=%0b",
                      //  dut.pixel_valid_in, dut.line_buffer.valid_in);
                end

                if (prediction_valid == 1'b1 && !prediction_done) begin
                    prediction_done = 1;
                    
                    // PERFORMANCE CAPTURE: Early Prediction Triggered
                    img_latency_cycles = global_cycle_count - img_start_cycle;
                    img_latency_ns     = $realtime - img_start_time;
                    early_trigger_count = early_trigger_count + 1;

                    if (predicted_class === test_labels[img_idx]) begin
                        $display("  -> SUCCESS (Early Trigger): Predicted %0d | Latency: %0d cycles (%0.1f ns)", predicted_class, img_latency_cycles, img_latency_ns);
                        correct_predictions = correct_predictions + 1;
                    end else begin
                        $display("  -> FAILED (Early Trigger): Predicted %0d (Expected %0d) | Latency: %0d cycles", predicted_class, test_labels[img_idx], img_latency_cycles);
                    end
                end
            end
            
            @(negedge clk);
            pixel_valid_in = 1'b0;

            // Pipeline Flush Loop if Early Trigger was not hit
            watchdog_timer = 0;
            while (!prediction_done && watchdog_timer < 5000) begin
                @(negedge clk);
                pixel_in = 12'b0;
                pixel_valid_in = 1'b1;
                watchdog_timer = watchdog_timer + 1;

                if (prediction_valid == 1'b1 && !prediction_done) begin
                    prediction_done = 1;
                    
                    // PERFORMANCE CAPTURE: Normal Pipeline Flush Triggered
                    img_latency_cycles = global_cycle_count - img_start_cycle;
                    img_latency_ns     = $realtime - img_start_time;

                    $display("  [VOTE EXPORT] C0:%0d | C1:%0d | C2:%0d",
                        $signed(dut.class_vote_totals[0]), $signed(dut.class_vote_totals[1]), $signed(dut.class_vote_totals[2]));
                    if (predicted_class === test_labels[img_idx]) begin
                        $display("  -> SUCCESS: Predicted %0d | Latency: %0d cycles (%0.1f ns)", predicted_class, img_latency_cycles, img_latency_ns);
                        correct_predictions = correct_predictions + 1;
                    end else begin
                        $display("  -> FAILED: Predicted %0d (Expected %0d) | Latency: %0d cycles", predicted_class, test_labels[img_idx], img_latency_cycles);
                    end
                end
            end

            @(negedge clk);
            pixel_valid_in = 1'b0;

            if (!prediction_done) begin
                $display("\n[ERROR] PIPELINE STALL: Image %0d failed to generate prediction valid.", img_idx);
                $finish;
            end

            // Accumulate global performance data
            total_inference_cycles = total_inference_cycles + img_latency_cycles;
            total_inference_time_ns = total_inference_time_ns + img_latency_ns;

            // Active module reset between images
            @(negedge clk);
            rst = 1;
            #20;
            @(negedge clk);
            rst = 0;
            #20;
        end

        // =========================================================================
        // FINAL COMPREHENSIVE PERFORMANCE ACCELERATOR REPORT
        // =========================================================================
        $display("\n========================================================");
        $display("                HARDWARE PERFORMANCE REPORT               ");
        $display("========================================================");
        $display("Total Images Evaluated        : %0d", img_idx);
        $display("Hardware Accuracy             : %0d / %0d (%0.1f%%)", correct_predictions, img_idx, (correct_predictions*100.0)/img_idx);
        $display("--------------------------------------------------------");
        $display("Total Execution Cycles        : %0d cycles", total_inference_cycles);
        $display("Total Pure Execution Time     : %0.2f ns", total_inference_time_ns);
        $display("Average Latency Per Image     : %0.2f cycles", (total_inference_cycles * 1.0) / img_idx);
        $display("Average Time Per Inference    : %0.2f ns", total_inference_time_ns / img_idx);
        $display("--------------------------------------------------------");
        $display("Early Classification Triggers : %0d / %0d images", early_trigger_count, img_idx);
        $display("Calculated Throughput (FPS)   : %0.2f Frames/Sec", (img_idx / (total_inference_time_ns * 1e-9)));
        $display("========================================================\n");

        $finish;
    end

endmodule