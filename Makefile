# QuikMini build and test
#   make test     PE unit test + full top-level test
#   make lint     Verilator lint of the RTL (-Wall)
#   make pe       PE unit test only
#   make sim      top-level test only (generates vectors first)
#   make sim TRACE=1   also dump build/quikmini.vcd
#   make synth    Vivado synthesis + timing (needs Vivado on Linux)

VERILATOR ?= verilator
PYTHON    ?= python3
VIVADO    ?= vivado
BUILD     := build

RTL := rtl/qm_pe.sv rtl/qm_skew.sv rtl/qm_bank.sv rtl/qm_array.sv rtl/quikmini.sv

VFLAGS := --binary --timing --timescale 1ns/1ps -j 0
ifeq ($(TRACE),1)
VFLAGS += --trace +define+TRACE
endif

.PHONY: all test lint pe sim vectors synth clean

all: test

test: lint pe sim

lint:
	$(VERILATOR) --lint-only -Wall --top-module quikmini $(RTL)

pe:
	mkdir -p $(BUILD)/pe
	$(VERILATOR) $(VFLAGS) --top-module tb_pe -Mdir $(BUILD)/pe tb/tb_pe.sv rtl/qm_pe.sv
	$(BUILD)/pe/Vtb_pe

vectors: $(BUILD)/vectors.txt

$(BUILD)/vectors.txt: scripts/gen_vectors.py
	$(PYTHON) scripts/gen_vectors.py $@

sim: $(BUILD)/vectors.txt
	mkdir -p $(BUILD)/top
	$(VERILATOR) $(VFLAGS) --top-module tb_quikmini -Mdir $(BUILD)/top tb/tb_quikmini.sv $(RTL)
	$(BUILD)/top/Vtb_quikmini +vectors=$(BUILD)/vectors.txt

synth:
	mkdir -p $(BUILD)/syn
	$(VIVADO) -mode batch -source syn/build.tcl -log $(BUILD)/vivado.log -journal $(BUILD)/vivado.jou

clean:
	rm -rf $(BUILD)
