RTL_DIR   := ../rtl
TB_DIR    := ../tb
SW_DIR    := ../sw/stage0
SW_DIR_S1 := ../sw/stage1
SW_DIR_S2 := ../sw/stage2
SW_DIR_S3 := ../sw/stage3
OBJ_DIR   := obj_dir

VERILATOR := verilator
CFLAGS    := -std=c++14

# --Wno-WIDTHEXPAND: suppress upstream axi_pkg.sv:203 width warning (PULP library bug)
# PULP_AXI_INC / AXI_PKG_SV are required for all invocations: kronos_pkg.sv always
# imports `AXI_TYPEDEF_ALL since the stage3 AXI switch plan.
PULP_AXI_INC  := -I/home/popes/opensoc/hw/ip/pulp_axi/include
AXI_PKG_SV    := /home/popes/opensoc/hw/ip/pulp_axi/src/axi_pkg.sv
AXI_FLAGS     := $(PULP_AXI_INC) --Wno-WIDTHEXPAND

TOP       := kronos_top
SIM_BIN   := $(OBJ_DIR)/V$(TOP)

SV_FILES  := $(AXI_PKG_SV) \
             $(RTL_DIR)/kronos_pkg.sv \
             $(RTL_DIR)/stage0/kronos_alu.sv \
             $(RTL_DIR)/stage0/kronos_decode.sv \
             $(RTL_DIR)/stage0/kronos_regfile.sv \
             $(RTL_DIR)/stage0/kronos_lsu.sv \
             $(RTL_DIR)/stage0/kronos_csr.sv \
             $(RTL_DIR)/stage0/kronos_top.sv

TB_ALU_FILES := $(AXI_PKG_SV) \
                $(RTL_DIR)/kronos_pkg.sv \
                $(RTL_DIR)/stage0/kronos_alu.sv \
                $(TB_DIR)/stage0/tb_alu.sv

TB_REGFILE_FILES := $(AXI_PKG_SV) \
                    $(RTL_DIR)/kronos_pkg.sv \
                    $(RTL_DIR)/stage0/kronos_regfile.sv \
                    $(TB_DIR)/stage0/tb_regfile.sv

TB_DECODE_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage0/kronos_decode.sv \
                   $(TB_DIR)/stage0/tb_decode.sv

TB_LSU_S1_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage1/kronos_lsu.sv \
                   $(TB_DIR)/stage1/tb_lsu_s1.sv

TB_FWD_FILES := $(AXI_PKG_SV) \
                $(RTL_DIR)/kronos_pkg.sv \
                $(RTL_DIR)/stage1/kronos_forward.sv \
                $(TB_DIR)/stage1/tb_forward.sv

TB_HZ_FILES := $(AXI_PKG_SV) \
               $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(TB_DIR)/stage1/tb_hazard.sv

TB_MULDIV_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage2/kronos_muldiv.sv \
                   $(TB_DIR)/stage2/tb_muldiv.sv

SV_FILES_S1 := $(AXI_PKG_SV) \
               $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage0/kronos_alu.sv \
               $(RTL_DIR)/stage0/kronos_decode.sv \
               $(RTL_DIR)/stage0/kronos_regfile.sv \
               $(RTL_DIR)/stage0/kronos_csr.sv \
               $(RTL_DIR)/stage1/kronos_lsu.sv \
               $(RTL_DIR)/stage1/kronos_forward.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(RTL_DIR)/stage1/kronos_top.sv

SIM_BIN_S1 := $(OBJ_DIR)/s1/Vkronos_top

SV_FILES_S2 := $(AXI_PKG_SV) \
               $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage0/kronos_alu.sv \
               $(RTL_DIR)/stage2/kronos_decode.sv \
               $(RTL_DIR)/stage0/kronos_regfile.sv \
               $(RTL_DIR)/stage0/kronos_csr.sv \
               $(RTL_DIR)/stage1/kronos_lsu.sv \
               $(RTL_DIR)/stage1/kronos_forward.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(RTL_DIR)/stage2/kronos_muldiv.sv \
               $(RTL_DIR)/stage2/kronos_top.sv

SIM_BIN_S2 := $(OBJ_DIR)/s2/Vkronos_top

.PHONY: help build build-s1 build-s2 build-s3 run-% run-s0-% run-s1-% run-s2-% run-s3-% \
        run-s3-latency-% sim-alu sim-regfile sim-decode sim-compliance \
        sim-compliance-s1 sim-lsu-s1 sim-forward sim-hazard \
        sim-muldiv sim-compliance-s2 sim-decompress sim-align sim-lsu-s3 sim-bpred \
        sim-compliance-s3 clean

.DEFAULT_GOAL := help

help:
	@echo "kronos-riscv simulation targets"
	@echo ""
	@echo "Build simulators:"
	@echo "  make build          Build stage 0 simulator (RV32I, OBI)"
	@echo "  make build-s1       Build stage 1 simulator (RV32I, OBI, pipeline)"
	@echo "  make build-s2       Build stage 2 simulator (RV32IM, OBI)"
	@echo "  make build-s3       Build stage 3 simulator (RV32IMC, AXI4)"
	@echo ""
	@echo "Run tests:"
	@echo "  make run-<test>              Run stage 0 test (e.g. run-test_alu)"
	@echo "  make run-s1-<test>           Run stage 1 test (e.g. run-s1-test_forwarding)"
	@echo "  make run-s2-<test>           Run stage 2 test (e.g. run-s2-test_mul)"
	@echo "  make run-s3-<test>           Run stage 3 test (e.g. run-s3-test_c_basic)"
	@echo "  make run-s3-latency-<test>   Run stage 3 test with latency 2/4"
	@echo ""
	@echo "Unit testbenches:"
	@echo "  make sim-alu         ALU (stage 0)"
	@echo "  make sim-regfile     Register file (stage 0)"
	@echo "  make sim-decode      Decoder (stage 0)"
	@echo "  make sim-lsu-s1      LSU OBI FSM (stage 1)"
	@echo "  make sim-forward     Forwarding unit (stage 1)"
	@echo "  make sim-hazard      Hazard/stall control (stage 1)"
	@echo "  make sim-muldiv      Multiply/divide unit (stage 2)"
	@echo "  make sim-decompress  RV32C instruction expander (stage 3)"
	@echo "  make sim-align       Fetch alignment buffer (stage 3)"
	@echo "  make sim-lsu-s3      LSU AXI4 FSM (stage 3)"
	@echo "  make sim-bpred       Branch predictor (stage 3)"
	@echo ""
	@echo "Regression suites:"
	@echo "  make sim-compliance     Full regression (= sim-compliance-s2)"
	@echo "  make sim-compliance-s1  Stage 1: all sw/ programs + rv32ui compliance"
	@echo "  make sim-compliance-s2  Stage 2: all sw/ programs + rv32ui compliance"
	@echo "  make sim-compliance-s3  Stage 3: all sw/ programs (stages 0-3)"
	@echo ""
	@echo "Housekeeping:"
	@echo "  make clean           Remove build artifacts"

build: $(SIM_BIN)

$(SIM_BIN): $(SV_FILES) sim_main_obi.cpp
	$(VERILATOR) --cc --exe --build -Wall --Wno-UNUSED \
	  --top-module $(TOP) \
	  $(SV_FILES) sim_main_obi.cpp \
	  -CFLAGS "$(CFLAGS)" \
	  $(AXI_FLAGS) \
	  -o V$(TOP)

build-s1: $(SIM_BIN_S1)

$(SIM_BIN_S1): $(SV_FILES_S1) sim_main_obi.cpp
	$(VERILATOR) --cc --exe --build -Wall --Wno-UNUSED \
	  --top-module kronos_top \
	  $(SV_FILES_S1) sim_main_obi.cpp \
	  -CFLAGS "$(CFLAGS)" \
	  $(AXI_FLAGS) \
	  -Mdir $(OBJ_DIR)/s1 \
	  -o Vkronos_top

run-%: build
	./$(SIM_BIN) $(SW_DIR)/build/$*.hex

run-s0-%: build
	./$(SIM_BIN) $(SW_DIR)/build/$*.hex

run-s1-%: build-s1
	./$(SIM_BIN_S1) $(SW_DIR_S1)/build/$*.hex

sim-alu:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_alu $(TB_ALU_FILES) $(AXI_FLAGS) -o tb_alu
	./obj_dir/tb_alu

sim-regfile:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_regfile $(TB_REGFILE_FILES) $(AXI_FLAGS) -o tb_regfile
	./obj_dir/tb_regfile

sim-decode:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_decode $(TB_DECODE_FILES) $(AXI_FLAGS) -o tb_decode
	./obj_dir/tb_decode

sim-lsu-s1:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_lsu_s1 $(TB_LSU_S1_FILES) $(AXI_FLAGS) -o tb_lsu_s1
	./obj_dir/tb_lsu_s1

sim-forward:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_forward $(TB_FWD_FILES) $(AXI_FLAGS) -o tb_forward
	./obj_dir/tb_forward

sim-hazard:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_hazard $(TB_HZ_FILES) $(AXI_FLAGS) -o tb_hazard
	./obj_dir/tb_hazard

sim-compliance: sim-compliance-s2

sim-compliance-s1: build-s1
	$(MAKE) -C $(SW_DIR) all
	$(MAKE) -C $(SW_DIR_S1) all
	$(MAKE) -C $(SW_DIR)/compliance run SIM=../../../sim/$(SIM_BIN_S1)
	@pass=0; fail=0; \
	for hex in $(SW_DIR)/build/*.hex $(SW_DIR_S1)/build/*.hex; do \
	  out=$$(./$(SIM_BIN_S1) $$hex 2>&1); \
	  x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	  if [ "$$x10" = "0" ]; then \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL: $$hex (x10=$$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "Stage 1 regression: $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]

sim-muldiv:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_muldiv $(TB_MULDIV_FILES) $(AXI_FLAGS) -o tb_muldiv
	./obj_dir/tb_muldiv

build-s2: $(SIM_BIN_S2)

$(SIM_BIN_S2): $(SV_FILES_S2) sim_main_obi.cpp
	$(VERILATOR) --cc --exe --build -Wall --Wno-UNUSED --Wno-WIDTHEXPAND \
	  --top-module kronos_top \
	  $(SV_FILES_S2) sim_main_obi.cpp \
	  -CFLAGS "$(CFLAGS)" \
	  $(AXI_FLAGS) \
	  -Mdir $(OBJ_DIR)/s2 \
	  -o Vkronos_top

run-s2-%: build-s2
	./$(SIM_BIN_S2) $(SW_DIR_S2)/build/$*.hex

sim-compliance-s2: build-s2
	$(MAKE) -C $(SW_DIR) all
	$(MAKE) -C $(SW_DIR_S1) all
	$(MAKE) -C $(SW_DIR_S2) all
	$(MAKE) -C $(SW_DIR)/compliance run SIM=../../../sim/$(SIM_BIN_S2)
	@pass=0; fail=0; \
	for hex in $(SW_DIR)/build/*.hex $(SW_DIR_S1)/build/*.hex $(SW_DIR_S2)/build/*.hex; do \
	  out=$$(./$(SIM_BIN_S2) $$hex 2>&1); \
	  x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	  if [ "$$x10" = "0" ]; then \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL: $$hex (x10=$$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "Stage 2 regression: $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]

SV_FILES_S3 := $(AXI_PKG_SV) \
               $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage0/kronos_alu.sv \
               $(RTL_DIR)/stage2/kronos_decode.sv \
               $(RTL_DIR)/stage0/kronos_regfile.sv \
               $(RTL_DIR)/stage0/kronos_csr.sv \
               $(RTL_DIR)/stage3/kronos_lsu.sv \
               $(RTL_DIR)/stage1/kronos_forward.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(RTL_DIR)/stage2/kronos_muldiv.sv \
               $(RTL_DIR)/stage3/kronos_decompress.sv \
               $(RTL_DIR)/stage3/kronos_align.sv \
               $(RTL_DIR)/stage3/kronos_bpred.sv \
               $(RTL_DIR)/stage3/kronos_top.sv \
               sim_top.sv

TOP_S3     := sim_top
SIM_BIN_S3 := $(OBJ_DIR)/s3/V$(TOP_S3)

TB_DECOMPRESS_FILES := $(AXI_PKG_SV) \
                       $(RTL_DIR)/kronos_pkg.sv \
                       $(RTL_DIR)/stage3/kronos_decompress.sv \
                       $(TB_DIR)/stage3/tb_decompress.sv

sim-decompress:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_decompress $(TB_DECOMPRESS_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_decompress
	./$(OBJ_DIR)/tb_decompress/Vtb_decompress

TB_ALIGN_FILES := $(AXI_PKG_SV) \
                  $(RTL_DIR)/kronos_pkg.sv \
                  $(RTL_DIR)/stage3/kronos_decompress.sv \
                  $(RTL_DIR)/stage3/kronos_align.sv \
                  $(TB_DIR)/stage3/tb_align.sv

sim-align:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_align $(TB_ALIGN_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_align
	./$(OBJ_DIR)/tb_align/Vtb_align

TB_LSU_S3_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage3/kronos_lsu.sv \
                   $(TB_DIR)/stage3/tb_lsu_s3.sv

build-s3: $(SIM_BIN_S3)

$(SIM_BIN_S3): $(SV_FILES_S3) sim_main.cpp
	$(VERILATOR) --cc --exe --build -Wall --Wno-UNUSED --Wno-WIDTHEXPAND --Wno-PINCONNECTEMPTY \
	  --top-module $(TOP_S3) \
	  $(SV_FILES_S3) sim_main.cpp \
	  -CFLAGS "$(CFLAGS)" \
	  -Mdir $(OBJ_DIR)/s3 \
	  $(PULP_AXI_INC) \
	  -o V$(TOP_S3)

run-s3-%: build-s3
	./$(SIM_BIN_S3) $(SW_DIR_S3)/build/$*.hex

run-s3-latency-%: build-s3
	./$(SIM_BIN_S3) $(SW_DIR_S3)/build/$*.hex 2 4

sim-lsu-s3:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_lsu_s3 $(TB_LSU_S3_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_lsu_s3
	./$(OBJ_DIR)/tb_lsu_s3/Vtb_lsu_s3

TB_BPRED_FILES := $(AXI_PKG_SV) \
                  $(RTL_DIR)/kronos_pkg.sv \
                  $(RTL_DIR)/stage3/kronos_bpred.sv \
                  $(TB_DIR)/stage3/tb_bpred.sv

sim-bpred:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_bpred $(TB_BPRED_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_bpred
	./$(OBJ_DIR)/tb_bpred/Vtb_bpred

sim-compliance-s3: build-s3
	$(MAKE) -C $(SW_DIR) all
	$(MAKE) -C $(SW_DIR_S1) all
	$(MAKE) -C $(SW_DIR_S2) all
	$(MAKE) -C $(SW_DIR_S3) all
	@pass=0; fail=0; \
	for hex in $(SW_DIR)/build/*.hex $(SW_DIR_S1)/build/*.hex \
	           $(SW_DIR_S2)/build/*.hex \
	           $$(ls $(SW_DIR_S3)/build/*.hex 2>/dev/null); do \
	  [ -f "$$hex" ] || continue; \
	  out=$$(./$(SIM_BIN_S3) $$hex 2>&1); \
	  x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	  if [ "$$x10" = "0" ]; then \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL: $$hex (x10=$$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "Stage 3 regression: $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]

clean:
	rm -rf $(OBJ_DIR)
	$(MAKE) -C $(SW_DIR) clean
	$(MAKE) -C $(SW_DIR)/compliance clean
