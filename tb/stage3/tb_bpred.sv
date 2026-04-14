// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// tb_bpred.sv — Unit tests for kronos_bpred.
module tb_bpred;
  logic        clk, rst_n;
  logic [31:0] pc;
  logic        pred_taken;
  logic [31:0] pred_target;
  logic        upd_valid;
  logic [31:0] upd_pc, upd_target;
  logic        upd_taken, upd_is_jal;

  int failures = 0;

  kronos_bpred #(.BPRED_BITS(6), .BTB_BITS(4)) u_dut (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .pc_i          (pc),
    .pred_taken_o  (pred_taken),
    .pred_target_o (pred_target),
    .upd_valid_i   (upd_valid),
    .upd_pc_i      (upd_pc),
    .upd_taken_i   (upd_taken),
    .upd_target_i  (upd_target),
    .upd_is_jal_i  (upd_is_jal)
  );

  always #5 clk = ~clk;
  task tick; @(posedge clk); #1; endtask

  // update task: is_jal=0 for conditional branch, is_jal=1 for JAL
  task update(input logic [31:0] upc, input logic taken,
              input logic [31:0] tgt, input logic is_jal);
    upd_valid = 1; upd_pc = upc; upd_taken = taken;
    upd_target = tgt; upd_is_jal = is_jal;
    tick;
    upd_valid = 0;
  endtask

  initial begin
    clk = 0; rst_n = 0;
    upd_valid = 0; upd_pc = 0; upd_taken = 0;
    upd_target = 0; upd_is_jal = 0;
    repeat(4) tick;
    rst_n = 1;

    // Test 1: cold-start — no prediction
    pc = 32'h0000_0100;
    #1;
    if (pred_taken !== 1'b0) begin
      $display("FAIL T1: cold-start should predict not-taken, got %b", pred_taken);
      failures++;
    end

    // Test 2: 2-bit counter saturation — 4 taken → strong-taken
    repeat(4) update(32'h0000_0100, 1'b1, 32'h0000_00C0, 1'b0);
    pc = 32'h0000_0100; #1;
    if (pred_taken !== 1'b1) begin
      $display("FAIL T2: after 4 taken, should predict taken, got %b", pred_taken);
      failures++;
    end
    if (pred_target !== 32'h0000_00C0) begin
      $display("FAIL T2: target wrong: got 0x%08x", pred_target);
      failures++;
    end

    // Test 3: 1 not-taken → 11→10 (still predict taken)
    update(32'h0000_0100, 1'b0, 32'h0000_0104, 1'b0);
    pc = 32'h0000_0100; #1;
    if (pred_taken !== 1'b1) begin
      $display("FAIL T3: 11→10 should still predict taken, got %b", pred_taken);
      failures++;
    end

    // Test 4: 2nd not-taken → 10→01 (predict not-taken)
    update(32'h0000_0100, 1'b0, 32'h0000_0104, 1'b0);
    pc = 32'h0000_0100; #1;
    if (pred_taken !== 1'b0) begin
      $display("FAIL T4: 10→01 should predict not-taken, got %b", pred_taken);
      failures++;
    end

    // Test 5: BTB tag mismatch → no prediction even if counter says taken
    repeat(4) update(32'h0000_0100, 1'b1, 32'h0000_00C0, 1'b0);
    // 0x200 maps to BTB index 0 (same slot as 0x100) but with a different tag — BTB tag mismatch
    pc = 32'h0000_0200; #1;
    if (pred_taken !== 1'b0) begin
      $display("FAIL T5: BTB tag mismatch should give pred_taken=0, got %b", pred_taken);
      failures++;
    end

    // Test 6: JAL always predicted taken after one training
    // 0x400 maps to the same BTB/BPRED index as 0x100 but has a different tag (16 vs 4)
    update(32'h0000_0400, 1'b1, 32'h0000_0300, 1'b1);  // JAL update
    pc = 32'h0000_0400; #1;
    if (pred_taken !== 1'b1 || pred_target !== 32'h0000_0300) begin
      $display("FAIL T6: JAL after training: taken=%b target=0x%08x",
               pred_taken, pred_target);
      failures++;
    end

    // Test 7: JAL counter-skip — counter state must be unchanged after JAL update.
    // Train a branch at 0x500 to weak-taken (counter=10 after 3 taken, 1 not-taken).
    // Then issue a JAL update at 0x500. Counter must remain at whatever state it was.
    // Re-check that prediction is still taken (counter MSB still 1).
    repeat(3) update(32'h0000_0500, 1'b1, 32'h0000_0600, 1'b0); // branch taken x3 → counter=11
    update(32'h0000_0500, 1'b0, 32'h0000_0504, 1'b0);           // branch not-taken → counter=10
    pc = 32'h0000_0500; #1;
    // Counter should be 10 → pred_taken=1
    if (pred_taken !== 1'b1) begin
      $display("FAIL T7a: pre-JAL counter should be 10 (pred_taken=1), got %b", pred_taken);
      failures++;
    end
    // Now fire a JAL update at same PC — counter must NOT change
    update(32'h0000_0500, 1'b1, 32'h0000_0700, 1'b1);  // JAL update
    pc = 32'h0000_0500; #1;
    // Counter still 10 → pred_taken must still be 1
    if (pred_taken !== 1'b1) begin
      $display("FAIL T7b: JAL must not modify counter; pred_taken should still be 1, got %b",
               pred_taken);
      failures++;
    end
    // Verify the BTB was updated to new JAL target
    if (pred_target !== 32'h0000_0700) begin
      $display("FAIL T7c: JAL must update BTB target; expected 0x700, got 0x%08x", pred_target);
      failures++;
    end

    // Test 8: BTB invalidated when counter reaches strong not-taken (00)
    // Use 0x1C0: BPRED index=48 (unique), BTB index=0 (shared with other tests — tag=7 distinguishes)
    // Step 1: train to strong-taken (4 taken updates: 01→10→11→11, BTB written)
    repeat(4) update(32'h0000_01C0, 1'b1, 32'h0000_01D0, 1'b0);
    pc = 32'h0000_01C0; #1;
    if (pred_taken !== 1'b1) begin
      $display("FAIL T8a: after 4 taken, should predict taken, got %b", pred_taken);
      failures++;
    end
    // Step 2: 4 not-taken updates: counter 11→10→01→00
    //         On the 01→00 transition (3rd not-taken), BTB entry is invalidated
    repeat(4) update(32'h0000_01C0, 1'b0, 32'h0000_01C4, 1'b0);
    // Step 3: counter MSB=0 and BTB.valid=0 → pred_taken must be 0
    pc = 32'h0000_01C0; #1;
    if (pred_taken !== 1'b0) begin
      $display("FAIL T8b: after 4 not-taken (counter=00, BTB cleared), pred_taken should be 0, got %b",
               pred_taken);
      failures++;
    end

    if (failures == 0) $display("PASS: all tb_bpred checks");
    else               $display("FAIL: %0d tb_bpred checks failed", failures);
    $finish;
  end
endmodule
