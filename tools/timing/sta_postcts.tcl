set postcts_status [catch {
if {[llength $argv] != 6} {
    error "usage: sta_postcts.tcl scripts_dir step_env odb sdc reports corner"
}
lassign $argv scripts_dir step_env odb sdc reports corner
file mkdir $reports
file delete -force $reports/metrics.txt $reports/metrics.txt.tmp
set ::env(SCRIPTS_DIR) $scripts_dir
set ::env(_TCL_ENV_IN) $step_env
source $scripts_dir/openroad/common/io.tcl

set models {}
foreach key [array names ::env _LIB_CORNER_*] {
    if {[lindex $::env($key) 0] eq $corner} {
        set models [lrange $::env($key) 1 end]
    }
}
if {[llength $models] == 0 && [info exists ::env(LIB)]} {
    dict for {pattern libraries} $::env(LIB) {
        if {[string match $pattern $corner]} {
            lappend models {*}$libraries
        }
    }
}
if {[llength $models] == 0} { error "corner absent from step environment: $corner" }
foreach key [array names ::env _LIB_CORNER_*] { unset ::env($key) }
set ::env(_LIB_CORNER_0) [linsert $models 0 $corner]
set ::env(CURRENT_ODB) $odb
set ::env(_SDC_IN) $sdc
# This report reads the saved design without resizing cells.
if {![info exists ::env(_PNR_EXCLUDED_CELLS)]} { set ::env(_PNR_EXCLUDED_CELLS) {} }
set_cmd_units -time ns -capacitance pF -current mA -voltage V -resistance kOhm -distance um
set sta_report_default_digits 6
read_current_odb
set_propagated_clock [all_clocks]
source $scripts_dir/openroad/common/set_rc.tcl
estimate_parasitics -placement
if {[llength [all_clocks]] == 0} { error "no clocks in saved design" }
foreach clock [all_clocks] {
    if {![get_property $clock is_propagated]} { error "unpropagated clock" }
}
set clocked_pins [dict create]
foreach pin [all_registers -clock [all_clocks] -clock_pins] {
    dict set clocked_pins [get_full_name $pin] 1
}
set unclocked_pins {}
foreach pin [all_registers -clock_pins] {
    set name [get_full_name $pin]
    if {![dict exists $clocked_pins $name]} { lappend unclocked_pins $name }
}
set coverage [open $reports/clock_coverage.rpt w]
puts $coverage "Unclocked register clock pins: [llength $unclocked_pins]"
foreach name [lsort $unclocked_pins] { puts $coverage $name }
close $coverage

set setup [worst_slack -corner $corner -max]
set hold [worst_slack -corner $corner -min]
foreach value [list $setup $hold] {
    if {!($value > -1e20 && $value < 1e20)} { error "no finite timing result" }
}
set result [open $reports/metrics.txt.tmp w]
set status [expr {[llength $unclocked_pins] == 0 ? "complete" : "incomplete_clock_coverage"}]
puts $result "status $status"
puts $result "scope post_cts_placement_estimate"
puts $result "corner $corner"
puts $result "setup_slack_ns $setup"
puts $result "hold_slack_ns $hold"
puts $result "setup_tns_ns [total_negative_slack -corner $corner -max]"
puts $result "hold_tns_ns [total_negative_slack -corner $corner -min]"
puts $result "propagated_clocks [llength [all_clocks]]"
puts $result "unclocked_register_clock_pins [llength $unclocked_pins]"
close $result
report_checks -sort_by_slack -path_delay max -group_path_count 100 -corner $corner -fields {slew cap input net fanout} -format full_clock_expanded > $reports/setup.rpt
report_checks -sort_by_slack -path_delay min -group_path_count 100 -corner $corner -fields {slew cap input net fanout} -format full_clock_expanded > $reports/hold.rpt
report_check_types -violators -verbose -max_delay -min_delay -recovery -removal -clock_gating_setup -clock_gating_hold -max_slew -min_slew -max_capacitance -min_capacitance -max_fanout -min_fanout -min_pulse_width -min_period -corner $corner > $reports/violations.rpt
check_setup -verbose -unconstrained_endpoints -multiple_clock -no_clock -no_input_delay -loops -generated_clocks > $reports/coverage.rpt
report_parasitic_annotation -report_unannotated > $reports/parasitics.rpt
report_clock_properties > $reports/clocks.rpt
file rename -force $reports/metrics.txt.tmp $reports/metrics.txt
if {[llength $unclocked_pins] != 0} { error "saved design has unclocked registers; see clock_coverage.rpt" }
} postcts_error]
if {$postcts_status} {
    puts stderr $postcts_error
    exit 1
}
puts "POSTCTS_STA_COMPLETE"
exit 0
