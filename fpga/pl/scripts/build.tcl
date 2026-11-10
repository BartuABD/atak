# build.tcl - synthesis, implementation, bitstream and XSA export of the project made by create_project.tcl.
#
#   cd fpga/pl
#   vivado -mode batch -source scripts/build.tcl [-tclargs <build dir>]
#
# Result: <build dir>/system_wrapper.xsa (with the bitstream), the input of fpga/ps/petalinux/build_boot.sh.
# Fails if the design does not meet timing.

set here  [file normalize [file dirname [info script]]]
set build [expr {$argc > 0 ? [file normalize [lindex $argv 0]] : "[file dirname $here]/build"}]

open_project $build/atak_pl.xpr
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set status [get_property STATUS [get_runs impl_1]]
set wns    [get_property STATS.WNS [get_runs impl_1]]
set whs    [get_property STATS.WHS [get_runs impl_1]]
puts "RESULT impl_1: $status  WNS $wns ns  WHS $whs ns"
if {![string match "*write_bitstream Complete*" $status]} { error "implementation failed: $status" }
if {$wns < 0 || $whs < 0} { error "timing not met: WNS $wns ns, WHS $whs ns" }

open_run impl_1
report_utilization -file $build/utilization.txt
report_timing_summary -file $build/timing_summary.txt
write_hw_platform -fixed -include_bit -force -file $build/system_wrapper.xsa
puts "RESULT exported $build/system_wrapper.xsa"
