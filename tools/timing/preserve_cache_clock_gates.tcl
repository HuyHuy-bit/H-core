set preserve_status [catch {
if {[llength $argv] != 2} {
    error "usage: preserve_cache_clock_gates.tcl placed.odb prepared.odb"
}
lassign $argv input output
if {[file normalize $input] eq [file normalize $output]} { error "use a separate output database" }
read_db $input
set gates 0
foreach inst [[ord::get_db_block] getInsts] {
    if {[string match sky130_fd_sc_hd__dlclkp_* [[$inst getMaster] getName]]} {
        set pin [$inst findITerm CLK]
        if {$pin eq "NULL" || [$pin getNet] eq "NULL"} { error "input clock gate is disconnected" }
        if {![$inst isPlaced]} { error "input clock gate is not placed" }
        # Preserve legal gate positions during CTS.
        $inst setPlacementStatus FIRM
        incr gates
    }
}
if {$gates == 0} { error "no SKY130 cache clock gates found" }
file mkdir [file dirname $output]
write_db $output.tmp
file rename -force $output.tmp $output
puts "PRESERVED_CLOCK_GATE_PLACEMENT $gates"
} preserve_error]
if {$preserve_status} {
    puts stderr $preserve_error
    exit 1
}
exit 0
