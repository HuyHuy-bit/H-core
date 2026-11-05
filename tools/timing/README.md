Saved post-CTS timing
====================

`sta_postcts.tcl` reads a saved LibreLane database and its saved constraints,
propagates the clocks, and estimates parasitics from placement. It does not
resize cells or modify the database. Run it with the same pinned LibreLane
image and PDK used to produce the database.

Create a Tcl launcher with six arguments, using absolute paths accessible
inside that image:

```tcl
set argv [list /path/to/librelane/scripts /path/to/step/_env.tcl \
    /path/to/step/chip_top.odb /path/to/step/chip_top.sdc \
    /path/to/new/reports nom_tt_025C_1v80]
source /path/to/repository/tools/timing/sta_postcts.tcl
```

Run `openroad -exit -no_init -no_splash /path/to/launcher.tcl`. Use a separate
report directory for each database/corner. Preserve the command, tool/image
identity, launcher, input hashes and reports with the experiment receipt.
The selected corner must be present in the saved step environment.

Success requires exit zero, `POSTCTS_STA_COMPLETE` in the log, and a newly
published `metrics.txt` with `status complete`. Missing clocks, non-finite
timing, command errors, and unclocked registers fail the run. An unclocked
register failure still publishes diagnostic metrics with
`status incomplete_clock_coverage` and lists the pins in `clock_coverage.rpt`.
Stale metrics are removed at the start of a run.

A complete report can contain timing and electrical violations. Inspect
`setup.rpt`, `hold.rpt`, `violations.rpt`, `coverage.rpt`, `clock_coverage.rpt`,
`parasitics.rpt` and `clocks.rpt` before accepting a comparison. The report
covers one selected corner, uses placement estimates, and does not establish
routed timing closure. It omits the optional global worst-clock-skew summary;
the timing paths include the propagated launch and capture clock paths.

Clock-gate placement preparation
-------------------------------

The pinned CTS version disconnected three cache clock-gate inputs in a replay;
holding the gates at their legal positions avoided that failure.
`preserve_cache_clock_gates.tcl` prepares a separate copy of a
legal detailed-placement database with the `sky130_fd_sc_hd__dlclkp_*` cells
marked FIRM. It preserves their existing coordinates and connections and
prevents CTS from relocating/cloning them. This restricts clock optimization;
measure timing with the same preparation in both sides of a comparison.

Use a Tcl launcher:

```tcl
set argv [list /path/to/placed.odb /path/to/prepared.odb]
source /path/to/repository/tools/timing/preserve_cache_clock_gates.tcl
```

Run it with the pinned OpenROAD image and require exit zero and
`PRESERVED_CLOCK_GATE_PLACEMENT` in the log. The input must contain placed,
connected clock gates. Input and output paths must differ.

Resume CTS from a copied LibreLane state that points to the prepared ODB,
retaining its original saved SDC and other views. Preserve the original state,
ODB, preparation command and hashes. Continue through setup/hold repair and
legalization, then run fresh STA from that final saved database. Preparation
alone does not validate the clock tree or establish timing closure.
