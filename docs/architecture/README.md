# Architecture

![RTL overview](images/rtl-overview.png)

[RTL sources](../../rtl/)

## At a glance

| Block | Choice |
|---|---|
| Fetch | two instructions per cycle from a line buffer; TAGE direction prediction, eight-entry return stack |
| Rename | 64 physical registers; eight branch checkpoints restore mappings in one step |
| Issue | one unified 16-entry queue; oldest ready instruction per port |
| Execute | port 0: branches, jumps, ALU. Port 1: ALU, RV32M, memory |
| Retire | 32-entry reorder buffer, two per cycle, in order; head ownership gates system and memory side effects |
| Memory | split L1 caches; loads issue early with store forwarding; stores commit at the head |

## Why these choices

Unless noted, measurements use RV32IM CoreMark (2 iterations) on the RTL with
1-cycle memory, checked against the reference model instruction by
instruction. "Region" is the timed CoreMark kernel; "whole run" includes boot.

### TAGE instead of gshare or bimodal

The same RTL built both ways (`cpu_top` parameter `TAGE`), whole run:

| Predictor in RTL | Storage | Cycles | Conditional-branch mispredicts |
|---|---|---|---|
| gshare, 256 entries, 8-bit history | 512 bits | 701,758 | 19,566 |
| TAGE, 256-entry base + 4 × 64 tagged entries | 4,096 bits | **633,494 (−9.7%)** | **10,105 (−48%)** |

Both builds retire the identical instruction trace. This comparison is not at
equal storage, so a trace model replays one branch stream at an equal budget
(RV32I CoreMark region, 207,195 conditional branches):

| Predictor model | Storage | Miss rate |
|---|---|---|
| bimodal, 2,048 entries | 4,096 bits | 23.4% |
| gshare, 2,048 entries, 11-bit history | 4,096 bits | 22.6% |
| TAGE, histories 4/8/16/32 | 4,096 bits | **20.9%** |

At equal storage, TAGE removes 7.4% of gshare's misses. On the same trace the
RTL TAGE misses within 10 branches of this model.

### RV32M in hardware

On RV32I CoreMark, 86% of all branch mispredicts came from libgcc's
bit-serial software multiply. Its per-bit branch is data-random, so no
predictor learns it. Adding RV32M removed the loop.

| CoreMark region | RV32I | RV32IM |
|---|---|---|
| Instructions | 752,576 | 309,900 |
| Cycles | 649,898 | 287,978 (−55.7%) |

Multiplies take three cycles through registered partial products. Divides run
a 32-step restoring loop (34 cycles).

### A 16-entry unified issue queue

- **Capacity is not the limit.** The queue is full in 1.0% of cycles
  (6,591 of 633,494). A larger queue can save at most that much.
- **Selection depth is.** Picking the oldest ready entry is on the chip's
  critical path: 14 of the 61 cells on the worst routed path are in the issue
  queue. A deeper queue lengthens that select.
- Two changes kept the 16-entry select shallow. A tree replaced the serial
  oldest-first scan; the design's maximum gate depth fell from 577 to 277.
  Comparing raw slots instead of subtracting the head cut 4.4% of the queue's
  cells (22 → 20 logic levels), proven equivalent.
- Not measured: smaller sizes. The size is fixed in the RTL, not a parameter.

### Eight branch checkpoints

- Each checkpoint holds a full register-map snapshot, so a mispredict
  recovers in one step instead of walking the reorder buffer.
- Speculative branch history lives in the same eight slots rather than in all
  32 reorder-buffer entries, which keeps predictor repair state small.
- Measured side cost: one checkpoint per rename bundle means a branch in lane
  0 pushes lane 1 to the next cycle. That costs at most 4.7% of region cycles.
  It stays because the parallel TAGE lookup relies on it.
- Not measured: stalls with all eight checkpoints in use (no counter), or
  other counts. The reorder buffer is full in 0.9% of cycles.

### Two issue ports, shared by function

| Instructions issued per cycle (whole run) | Share of cycles |
|---|---|
| two | 37.7% |
| one | 30.0% |
| none | 32.2% |

- **Only port 0 resolves branches.** A branch waiting behind another branch
  costs at most 4.5% of region cycles; branches wait for operands about 12
  times as often. A second resolve port would touch the reorder buffer,
  checkpoints and predictor repair for that small bound.
- **RV32M shares port 1.** Multiplies are 3.0% of region instructions
  (9,396 of 309,900), too few to justify a third port.
- **One memory operation per cycle on port 1.** Loads wait on an older
  store's unknown address in 1.9% of cycles. That bounds what memory-dependence
  prediction could save, so it was not built.

### Pipeline depth trials

| Trial | Cycles | Clock | Verdict |
|---|---|---|---|
| Extra execute stage and fetch buffer | +15.4% | −5.4% period (10× wire estimate) | rejected: slower per instruction |
| Split wakeup, select and bypass across cycles | +0.06 to +0.12 CPI (priced) | not built | kept in one cycle |
| Let a finished cached load retire beside a non-memory instruction | −4.8% region cycles | area +0.05% | **adopted** |

The physical results show the price of keeping wakeup and select in one
cycle: the routed worst path runs wakeup → select → register read (see the
[physical design page](../physical/README.md)).

## Measurement sources

- RTL predictor comparison: `cached_core_m` built with `TAGE=1` and `TAGE=0`,
  CoreMark through `verif/core/fetched_core_tb.cpp` in perf mode.
- Predictor models: `tools/run_predictor_comparison.py`.
- Issue-queue, reorder-buffer and issue-width counters: the same perf bench on
  the routed RTL.
- RV32M, branch-port, pairing, memory-dependence and pipeline trials:
  design-time measurements on earlier versions of this RTL (2026-11-08 to
  2026-11-11), kept in local planning notes. "At most" figures count cycles in
  which the restriction applied, an upper bound on the saving.

[Pipeline reference](https://docs.boom-core.org/en/latest/sections/intro-overview/boom-pipeline.html)
· [Verification](../verification/README.md)
