# Verification

## Methods and tools

| Method | Tools and checks |
| --- | --- |
| RTL simulation | Verilator with C++ reference models, directed cases, randomized seeds, assertions, and stall/reset tests. |
| Architectural comparison | Sail and Spike compare retired events against RTL; selected ACT4 architectural tests check instruction behavior. |
| Formal verification | SymbiYosys/Yosys run bounded memory checks, combinational forwarding proofs, rename induction, and reachability covers. |
| Mutation testing | Deliberate RTL faults check whether simulations and proofs detect incorrect behavior. |
| Static checks | Verilator lint and Yosys synthesis checks catch structural issues. |
| Host tests | Python `unittest` checks reference models, trace comparison, protocols, and test runners. |
| Waveform inspection | GTKWave displays execution, retirement, recovery, and memory activity from simulation. |

These methods describe the verification infrastructure. The evidence below records
selected results, not a fresh pass of every gate.

## Evidence

| Evidence | Screenshot | Scope |
| --- | --- | --- |
| Whole-core execution | [GTKWave](images/core-waveform.png) | 17 directed events match the software model; cached RV32M trace/physical lockstep. |
| RV32M RTL | [Simulation](images/muldiv-results.png) | Fresh baseline seeds; full mutation/synthesis gate not rerun. |
| Store forwarding | [Formal results](images/formal-results.png) | Combinational selector checks; excludes temporal queue/memory behavior. |
| Rename ownership | [Formal results](images/formal-results.png) | Inductive safety with at most four in-flight instructions and workload registers x0–x3. |

These are actual tool-window captures. The formal screenshot displays
retained runs after source/archive checks, including covers and mutations;
the proofs were not rerun for the capture.

The retained waveform uses `chip_top`'s core configuration, excluding its reset wrapper.
Younger ALU work completes before the divide, then retires after it. Branch
recovery skips a wrong-path store; forwarding supplies the load with 26.
PCs/results are decimal, store addresses hexadecimal. Values apply when their
corresponding accept bits assert. The time axis is simulated, not measured timing.

## Reproduce

```sh
python3 -m unittest tests.test_backend_acceptance tests.test_m_reference tests.test_measurement_receipts tests.test_unit_runner tests.test_sail_log
```

| Scope | Command |
| --- | --- |
| Fast checks | `make check-fast` |
| Full RTL, formal, and architectural gates | `make check-all` |
| Full RV32M unit gate | `make muldiv-unit-check` |
| Forwarding proofs | `make store-forward-check` |
| Rename ownership | `make rename-recovery-ownership-check` |

Use the [toolchain](../../config/toolchain.lock) and
[synthesis](../../config/synthesis.lock) pins. Full regression, full ISA acceptance,
and physical timing closure are not established by these selected results.

[Architecture](../architecture/README.md)
