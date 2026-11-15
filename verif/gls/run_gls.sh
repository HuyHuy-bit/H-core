#!/bin/bash
# CoreMark on chip_top, RTL or routed gate-level netlist, same bench and program: zero-delay, two-state, x-initial 0.
# usage: verif/gls/run_gls.sh rtl|gates OUT   (compare the GLS END lines of the two runs)
set -euo pipefail
MODE=$1; OUT=$(realpath -m $2); ROOT=$(cd $(dirname $0)/../.. && pwd)
RUN=$ROOT/out/placement_2026-11-14
PROGRAM=$ROOT/out/rv32m_2026-11-08/task5/rv32im_cached_core_m
CELLS=/home/huy/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130A/libs.ref/sky130_fd_sc_hd/verilog
mkdir -p $OUT
cd $ROOT && python3 -c 'from tools.run_sail_differential import make_header; make_header()'
FLAGS=(--cc --exe --build --build-jobs 4 --top-module chip_top --x-assign 0 --x-initial 0 -Wno-fatal -Wno-lint -Wno-style
       --Mdir $OUT/obj -CFLAGS "-std=c++17 -O1 -I$ROOT/out/fields -I$ROOT/verif/gls" -o chip_top_sim)
if [ $MODE = rtl ]; then
  # the synthesized sources; under Verilator the clock gate is its latch model
  SOURCES=$(python3 -c "import json; print(' '.join(json.load(open('$RUN/physical/config.json'))['VERILOG_FILES']))")
  verilator "${FLAGS[@]}" -DSYNTHESIS $SOURCES $ROOT/verif/gls/chip_top_tb.cpp > $OUT/build.log 2>&1
else
  # routed netlist without fill, decap and tap cells (no logic, no ports)
  grep -Ev '^ *sky130_fd_sc_hd__(fill|decap|tapvpwrvgnd)_[0-9]+ [^ ]+ \(\);$' \
    $RUN/physical/runs/route_fin/final/nl/chip_top.nl.v > $OUT/chip_top.gl.v
  verilator "${FLAGS[@]}" --no-timing --output-split 20000 --output-split-cfuncs 20000 -DFUNCTIONAL -DUNIT_DELAY= \
    $CELLS/primitives.v $CELLS/sky130_fd_sc_hd.v $OUT/chip_top.gl.v $ROOT/verif/gls/chip_top_tb.cpp > $OUT/build.log 2>&1
fi
LOG=$(riscv64-unknown-elf-nm $PROGRAM/coremark.elf | awk '$3=="coremark_log" {print "0x"$1}')
/usr/bin/time -v $OUT/obj/chip_top_sim $PROGRAM/coremark.bin 700000 $LOG 700000 > $OUT/sim.log 2> $OUT/time.log
grep "GLS END" $OUT/sim.log
