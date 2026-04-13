// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_top.sv (stage2) — 5-stage in-order pipeline with RV32M.
// Stages: IF → ID → EX → MEM → WB
// Reuses stage0: kronos_regfile, kronos_alu, kronos_csr (with MISA_EXT=I+M)
// Reuses stage1: kronos_lsu, kronos_forward, kronos_hazard
// New in stage2:  kronos_decode (RV32I+M), kronos_muldiv
module kronos_top
  import kronos_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  input  logic        instr_rvalid_i,
  output logic [31:0] instr_addr_o,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,
  output logic        data_req_o,
  input  logic        data_gnt_i,
  input  logic        data_rvalid_i,
  output logic        data_we_o,
  output logic [ 3:0] data_be_o,
  output logic [31:0] data_addr_o,
  output logic [31:0] data_wdata_o,
  input  logic [31:0] data_rdata_i,
  input  logic        data_err_i,
  input  logic        irq_timer_i,
  input  logic [14:0] irq_fast_i,
  input  logic [31:0] boot_addr_i
);

  // -------------------------------------------------------------------------
  // Pipeline registers (owned by kronos_top)
  // -------------------------------------------------------------------------
  if_id_reg_t  if_id_q;
  id_ex_reg_t  id_ex_q;
  ex_mem_reg_t ex_mem_q;
  mem_wb_reg_t mem_wb_q;

  logic [31:0] pc_q;

  // -------------------------------------------------------------------------
  // Hazard / forwarding control
  // -------------------------------------------------------------------------
  logic      pc_en, if_id_en, id_ex_en, ex_mem_en, mem_wb_en;
  logic      if_id_flush, id_ex_flush;
  fwd_sel_e  fwd_rs1_sel, fwd_rs2_sel;

  // -------------------------------------------------------------------------
  // ID-stage wires
  // -------------------------------------------------------------------------
  decoded_instr_t id_dec;
  logic [63:0]    rs1_rdata_64, rs2_rdata_64;
  // WB→ID bypass: when WB writes the same register that ID is reading in the
  // same cycle, forward the write data so the consumer sees the up-to-date
  // value.  wb_result comes from the registered mem_wb_q so there is no
  // combinatorial loop.
  logic [31:0]    rs1_data_id, rs2_data_id;
  logic           wb_writing;

  // -------------------------------------------------------------------------
  // EX-stage wires
  // -------------------------------------------------------------------------
  logic [31:0] fwd_rs1_data, fwd_rs2_data;
  logic [31:0] alu_a, alu_b, alu_result;
  logic [31:0] ex_result;      // STAGE2: mux of alu_result vs muldiv_result
  logic [31:0] ex_pc_next;
  logic        ex_redirect;
  logic        branch_taken;
  logic        irq_pending;
  logic [31:0] csr_rdata, trap_vector, mepc;
  logic [31:0] trap_cause;
  logic        csr_valid;

  // STAGE2: muldiv signals
  logic [31:0] muldiv_result;
  logic        muldiv_busy, muldiv_valid, muldiv_idle;
  logic        muldiv_stall;
  logic        combined_stall;  // mem_stall | muldiv_stall

  // -------------------------------------------------------------------------
  // MEM-stage wires
  // -------------------------------------------------------------------------
  logic [31:0] lsu_rdata;
  logic        lsu_valid;
  logic        mem_stall;

  // -------------------------------------------------------------------------
  // WB-stage wires
  // -------------------------------------------------------------------------
  logic [31:0] wb_result;     // 32-bit: used as forwarding source
  logic [63:0] wb_result_64;  // 64-bit: written to regfile

  // =========================================================================
  // Submodule instantiations
  // =========================================================================

  // stage2/kronos_decode.sv is used instead of stage0/kronos_decode.sv.
  // Both modules are named `kronos_decode`; the fileset determines which is compiled.
  kronos_decode u_decode (
    .instr_i (if_id_q.instr),
    .dec_o   (id_dec)
  );

  kronos_regfile u_regfile (
    .clk_i       (clk_i),
    .rs1_addr_i  (id_dec.rs1),
    .rs2_addr_i  (id_dec.rs2),
    .rs1_rdata_o (rs1_rdata_64),
    .rs2_rdata_o (rs2_rdata_64),
    .rd_addr_i   (mem_wb_q.dec.rd),
    .rd_wen_i    (mem_wb_q.valid & mem_wb_q.dec.rd_wen),
    .rd_wdata_i  (wb_result_64)
  );

  kronos_forward u_forward (
    .id_ex_rs1_i      (id_ex_q.dec.rs1),
    .id_ex_rs1_used_i (id_ex_q.dec.rs1_used),
    .id_ex_rs2_i      (id_ex_q.dec.rs2),
    .id_ex_rs2_used_i (id_ex_q.dec.rs2_used),
    .ex_mem_rd_i      (ex_mem_q.dec.rd),
    .ex_mem_rd_wen_i  (ex_mem_q.dec.rd_wen & ex_mem_q.valid),
    .ex_mem_is_load_i (ex_mem_q.dec.is_load),
    .mem_wb_rd_i      (mem_wb_q.dec.rd),
    .mem_wb_rd_wen_i  (mem_wb_q.dec.rd_wen & mem_wb_q.valid),
    .fwd_rs1_sel_o    (fwd_rs1_sel),
    .fwd_rs2_sel_o    (fwd_rs2_sel)
  );

  // STAGE2: combined_stall replaces raw mem_stall for hazard unit.
  // muldiv_stall: asserted while any muldiv instruction is live in EX and not yet done.
  assign muldiv_stall   = id_ex_q.valid & id_ex_q.dec.is_muldiv & ~muldiv_valid;
  assign combined_stall = mem_stall | muldiv_stall;

  kronos_hazard u_hazard (
    .id_ex_is_load_i  (id_ex_q.dec.is_load),
    .id_ex_rd_i       (id_ex_q.dec.rd),
    .id_ex_valid_i    (id_ex_q.valid),
    .if_id_rs1_used_i (id_dec.rs1_used),
    .if_id_rs1_i      (id_dec.rs1),
    .if_id_rs2_used_i (id_dec.rs2_used),
    .if_id_rs2_i      (id_dec.rs2),
    .ex_redirect_i    (ex_redirect),
    .mem_stall_i      (combined_stall),   // STAGE2: OR of mem_stall + muldiv_stall
    .pc_en_o          (pc_en),
    .if_id_en_o       (if_id_en),
    .id_ex_en_o       (id_ex_en),
    .ex_mem_en_o      (ex_mem_en),
    .mem_wb_en_o      (mem_wb_en),
    .if_id_flush_o    (if_id_flush),
    .id_ex_flush_o    (id_ex_flush)
  );

  kronos_alu u_alu (
    .op_i     (id_ex_q.dec.alu_op),
    .a_i      (alu_a),
    .b_i      (alu_b),
    .result_o (alu_result)
  );

  // STAGE2: muldiv unit.
  // req_i is pulsed once when a muldiv instruction first enters EX (idle_o=1)
  // and no LSU stall is active (to avoid an lsu_rdata capture hazard).
  kronos_muldiv u_muldiv (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .req_i    (id_ex_q.valid & id_ex_q.dec.is_muldiv & muldiv_idle & ~mem_stall),
    .op_i     (id_ex_q.dec.muldiv_op),
    .a_i      (fwd_rs1_data),
    .b_i      (fwd_rs2_data),
    .result_o (muldiv_result),
    .busy_o   (muldiv_busy),
    .valid_o  (muldiv_valid),
    .idle_o   (muldiv_idle)
  );

  // STAGE2: muldiv result replaces alu_result when the EX instruction is muldiv.
  assign ex_result = id_ex_q.dec.is_muldiv ? muldiv_result : alu_result;

  kronos_csr #(.MISA_EXT(26'h1100)) u_csr (  // STAGE2: I+M bits
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .req_i         (id_ex_q.valid & id_ex_q.dec.is_csr),
    .addr_i        (id_ex_q.dec.csr_addr),
    .funct3_i      (id_ex_q.dec.csr_funct3),
    .use_imm_i     (id_ex_q.dec.csr_use_imm),
    .rs1_data_i    (fwd_rs1_data),
    .rs1_addr_i    (id_ex_q.dec.rs1),
    .rdata_o       (csr_rdata),
    .valid_o       (csr_valid),
    .trap_i        (id_ex_q.valid & (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak |
                                      id_ex_q.dec.illegal  | irq_pending)),
    .trap_pc_i     (id_ex_q.pc),
    .trap_cause_i  (trap_cause),
    .mret_i        (id_ex_q.valid & id_ex_q.dec.is_mret),
    .trap_vector_o (trap_vector),
    .mepc_o        (mepc),
    .irq_timer_i   (irq_timer_i),
    .irq_fast_i    (irq_fast_i),
    .irq_pending_o (irq_pending)
  );

  kronos_lsu u_lsu (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .req_i         (ex_mem_q.valid & (ex_mem_q.dec.is_load | ex_mem_q.dec.is_store)),
    .we_i          (ex_mem_q.dec.is_store),
    .addr_i        (ex_mem_q.alu_result),
    .wdata_i       (ex_mem_q.rs2_data),
    .funct3_i      (ex_mem_q.dec.mem_funct3),
    .rdata_o       (lsu_rdata),
    .valid_o       (lsu_valid),
    .mem_stall_o   (mem_stall),
    .data_req_o    (data_req_o),
    .data_gnt_i    (data_gnt_i),
    .data_rvalid_i (data_rvalid_i),
    .data_we_o     (data_we_o),
    .data_be_o     (data_be_o),
    .data_addr_o   (data_addr_o),
    .data_wdata_o  (data_wdata_o),
    .data_rdata_i  (data_rdata_i),
    .data_err_i    (data_err_i)
  );

  // =========================================================================
  // PC register
  // =========================================================================
  logic [31:0] pc_next;
  assign pc_next = ex_redirect ? ex_pc_next : pc_q + 32'd4;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) pc_q <= boot_addr_i;
    else if (pc_en) pc_q <= pc_next;
  end

  // =========================================================================
  // IF stage
  // =========================================================================
  assign instr_req_o  = rst_ni;
  assign instr_addr_o = pc_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      if_id_q <= '0;
    end else if (if_id_flush) begin
      if_id_q <= '0;
    end else if (if_id_en) begin
      if_id_q.pc    <= pc_q;
      if_id_q.instr <= instr_rdata_i;
      if_id_q.valid <= instr_rvalid_i;
    end
  end

  // =========================================================================
  // ID stage
  // =========================================================================
  // kronos_decode and kronos_regfile driven by if_id_q (instantiated above)

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      id_ex_q <= '0;
    end else if (id_ex_flush) begin
      id_ex_q <= '0;
    end else if (id_ex_en) begin
      id_ex_q.pc       <= if_id_q.pc;
      id_ex_q.dec      <= id_dec;
      id_ex_q.rs1_data <= rs1_data_id;
      id_ex_q.rs2_data <= rs2_data_id;
      id_ex_q.valid    <= if_id_q.valid;
    end
  end

  // =========================================================================
  // EX stage
  // =========================================================================

  // Forwarding muxes
  always_comb begin
    unique case (fwd_rs1_sel)
      FWD_NONE:  fwd_rs1_data = id_ex_q.rs1_data;
      FWD_EXMEM: fwd_rs1_data = ex_mem_q.alu_result;
      FWD_MEMWB: fwd_rs1_data = wb_result;
      default:   fwd_rs1_data = id_ex_q.rs1_data;
    endcase
    unique case (fwd_rs2_sel)
      FWD_NONE:  fwd_rs2_data = id_ex_q.rs2_data;
      FWD_EXMEM: fwd_rs2_data = ex_mem_q.alu_result;
      FWD_MEMWB: fwd_rs2_data = wb_result;
      default:   fwd_rs2_data = id_ex_q.rs2_data;
    endcase
  end

  // ALU operand selection
  assign alu_a = id_ex_q.dec.use_pc  ? id_ex_q.pc        : fwd_rs1_data;
  assign alu_b = id_ex_q.dec.use_imm ? id_ex_q.dec.imm   : fwd_rs2_data;

  // Branch comparator
  always_comb begin
    branch_taken = 1'b0;
    if (id_ex_q.valid & id_ex_q.dec.is_branch) begin
      unique case (id_ex_q.dec.branch_funct3)
        3'b000:  branch_taken = (fwd_rs1_data == fwd_rs2_data);
        3'b001:  branch_taken = (fwd_rs1_data != fwd_rs2_data);
        3'b100:  branch_taken = ($signed(fwd_rs1_data) <  $signed(fwd_rs2_data));
        3'b101:  branch_taken = ($signed(fwd_rs1_data) >= $signed(fwd_rs2_data));
        3'b110:  branch_taken = (fwd_rs1_data <  fwd_rs2_data);
        3'b111:  branch_taken = (fwd_rs1_data >= fwd_rs2_data);
        default: branch_taken = 1'b0;
      endcase
    end
  end

  // Trap cause encoding
  always_comb begin
    if      (irq_pending)               trap_cause = 32'h80000007; // M-mode timer IRQ
    else if (id_ex_q.dec.illegal)       trap_cause = 32'd2;
    else if (id_ex_q.dec.is_ecall)      trap_cause = 32'd11;
    else                                trap_cause = 32'd3;        // ebreak
  end

  // PC redirect target
  always_comb begin
    if      (id_ex_q.valid & (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak |
                               id_ex_q.dec.illegal  | irq_pending))
      ex_pc_next = trap_vector;
    else if (id_ex_q.valid & id_ex_q.dec.is_mret)
      ex_pc_next = mepc;
    else if (id_ex_q.valid & id_ex_q.dec.is_jalr)
      ex_pc_next = (fwd_rs1_data + id_ex_q.dec.imm) & ~32'd1;
    else if (id_ex_q.valid & id_ex_q.dec.is_jal)
      ex_pc_next = id_ex_q.pc + id_ex_q.dec.imm;
    else if (branch_taken)
      ex_pc_next = id_ex_q.pc + id_ex_q.dec.imm;
    else
      ex_pc_next = id_ex_q.pc + 32'd4;
  end

  assign ex_redirect = id_ex_q.valid &
    (id_ex_q.dec.is_jal | id_ex_q.dec.is_jalr | branch_taken |
     id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak | id_ex_q.dec.illegal |
     id_ex_q.dec.is_mret  | irq_pending);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex_mem_q <= '0;
    end else if (ex_mem_en) begin
      ex_mem_q.pc         <= id_ex_q.pc;
      ex_mem_q.dec        <= id_ex_q.dec;
      ex_mem_q.alu_result <= ex_result;     // STAGE2: ex_result, not alu_result
      ex_mem_q.rs2_data   <= fwd_rs2_data;
      ex_mem_q.pc_next    <= ex_pc_next;
      ex_mem_q.csr_rdata  <= csr_rdata;
      ex_mem_q.redirect   <= ex_redirect;
      // Squash valid on IRQ: instruction is re-fetched after MRET
      ex_mem_q.valid      <= id_ex_q.valid & ~irq_pending;
    end
  end

  // =========================================================================
  // MEM stage (kronos_lsu driven by ex_mem_q, instantiated above)
  // =========================================================================

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_wb_q <= '0;
    end else if (mem_wb_en) begin
      mem_wb_q.dec        <= ex_mem_q.dec;
      mem_wb_q.alu_result <= ex_mem_q.alu_result;
      mem_wb_q.lsu_rdata  <= lsu_rdata;
      mem_wb_q.csr_rdata  <= ex_mem_q.csr_rdata;
      mem_wb_q.pc4        <= ex_mem_q.pc + 32'd4;
      mem_wb_q.valid      <= ex_mem_q.valid;
    end
  end

  // =========================================================================
  // WB→ID bypass (3-cycle RAW)
  // =========================================================================
  assign wb_writing  = mem_wb_q.valid & mem_wb_q.dec.rd_wen & (mem_wb_q.dec.rd != 5'd0);
  assign rs1_data_id = (wb_writing && mem_wb_q.dec.rd == id_dec.rs1) ? wb_result
                                                                       : rs1_rdata_64[31:0];
  assign rs2_data_id = (wb_writing && mem_wb_q.dec.rd == id_dec.rs2) ? wb_result
                                                                       : rs2_rdata_64[31:0];

  // =========================================================================
  // WB stage
  // =========================================================================
  always_comb begin
    unique case (mem_wb_q.dec.wb_sel)
      WB_ALU:  wb_result = mem_wb_q.alu_result;
      WB_MEM:  wb_result = mem_wb_q.lsu_rdata;
      WB_PC4:  wb_result = mem_wb_q.pc4;
      WB_CSR:  wb_result = mem_wb_q.csr_rdata;
      default: wb_result = mem_wb_q.alu_result;
    endcase
  end

  always_comb begin
    unique case (mem_wb_q.dec.wb_sel)
      WB_ALU:  wb_result_64 = {{32{wb_result[31]}}, wb_result};
      WB_MEM:  wb_result_64 = {{32{wb_result[31]}}, wb_result};
      WB_PC4:  wb_result_64 = {32'b0, wb_result};
      WB_CSR:  wb_result_64 = {32'b0, wb_result};
      default: wb_result_64 = {{32{wb_result[31]}}, wb_result};
    endcase
  end

endmodule
