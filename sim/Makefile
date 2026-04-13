RTL_DIR   := ../rtl
TB_DIR    := ../tb
SW_DIR    := ../sw/stage0
SW_DIR_S1 := ../sw/stage1
OBJ_DIR   := obj_dir

VERILATOR := verilator
CFLAGS    := -std=c++14

TOP       := kronos_top
SIM_BIN   := $(OBJ_DIR)/V$(TOP)

SV_FILES  := $(RTL_DIR)/kronos_pkg.sv \
             $(RTL_DIR)/stage0/kronos_alu.sv \
             $(RTL_DIR)/stage0/kronos_decode.sv \
             $(RTL_DIR)/stage0/kronos_regfile.sv \
             $(RTL_DIR)/stage0/kronos_lsu.sv \
             $(RTL_DIR)/stage0/kronos_csr.sv \
             $(RTL_DIR)/stage0/kronos_top.sv

TB_ALU_FILES := $(RTL_DIR)/kronos_pkg.sv \
                $(RTL_DIR)/stage0/kronos_alu.sv \
                $(TB_DIR)/stage0/tb_alu.sv

TB_REGFILE_FILES := $(RTL_DIR)/kronos_pkg.sv \
                    $(RTL_DIR)/stage0/kronos_regfile.sv \
                    $(TB_DIR)/stage0/tb_regfile.sv

TB_DECODE_FILES := $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage0/kronos_decode.sv \
                   $(TB_DIR)/stage0/tb_decode.sv

TB_LSU_S1_FILES := $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage1/kronos_lsu.sv \
                   $(TB_DIR)/stage1/tb_lsu_s1.sv

TB_FWD_FILES := $(RTL_DIR)/kronos_pkg.sv \
                $(RTL_DIR)/stage1/kronos_forward.sv \
                $(TB_DIR)/stage1/tb_forward.sv

TB_HZ_FILES := $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(TB_DIR)/stage1/tb_hazard.sv

SV_FILES_S1 := $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage0/kronos_alu.sv \
               $(RTL_DIR)/stage0/kronos_decode.sv \
               $(RTL_DIR)/stage0/kronos_regfile.sv \
               $(RTL_DIR)/stage0/kronos_csr.sv \
               $(RTL_DIR)/stage1/kronos_lsu.sv \
               $(RTL_DIR)/stage1/kronos_forward.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(RTL_DIR)/stage1/kronos_top.sv

SIM_BIN_S1 := $(OBJ_DIR)/s1/Vkronos_top

.PHONY: build build-s1 run-% run-s0-% run-s1-% sim-alu sim-regfile sim-decode sim-compliance sim-compliance-s1 sim-lsu-s1 sim-forward sim-hazard clean

build: $(SIM_BIN)

$(SIM_BIN): $(SV_FILES) sim_main.cpp
	$(VERILATOR) --cc --exe --build -Wall --Wno-UNUSED \
	  --top-module $(TOP) \
	  $(SV_FILES) sim_main.cpp \
	  -CFLAGS "$(CFLAGS)" \
	  -o V$(TOP)

build-s1: $(SIM_BIN_S1)

$(SIM_BIN_S1): $(SV_FILES_S1) sim_main.cpp
	$(VERILATOR) --cc --exe --build -Wall --Wno-UNUSED \
	  --top-module kronos_top \
	  $(SV_FILES_S1) sim_main.cpp \
	  -CFLAGS "$(CFLAGS)" \
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
	  --top-module tb_alu $(TB_ALU_FILES) -o tb_alu
	./obj_dir/tb_alu

sim-regfile:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_regfile $(TB_REGFILE_FILES) -o tb_regfile
	./obj_dir/tb_regfile

sim-decode:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_decode $(TB_DECODE_FILES) -o tb_decode
	./obj_dir/tb_decode

sim-lsu-s1:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_lsu_s1 $(TB_LSU_S1_FILES) -o tb_lsu_s1
	./obj_dir/tb_lsu_s1

sim-forward:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_forward $(TB_FWD_FILES) -o tb_forward
	./obj_dir/tb_forward

sim-hazard:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_hazard $(TB_HZ_FILES) -o tb_hazard
	./obj_dir/tb_hazard

sim-compliance: build
	$(MAKE) -C $(SW_DIR)/compliance run

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

clean:
	rm -rf $(OBJ_DIR)
	$(MAKE) -C $(SW_DIR) clean
	$(MAKE) -C $(SW_DIR)/compliance clean
