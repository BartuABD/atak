# create_project.tcl - creates the Vivado project of the A.T.A.K. PL (Zybo Z7-20) from the sources in this repo.
#
#   cd fpga/pl
#   vivado -mode batch -source scripts/create_project.tcl [-tclargs <build dir>]
#
# Result: <build dir>/atak_pl.xpr (default: fpga/pl/build). Needs Vivado 2025.2 and the Digilent board files
# (board part digilentinc.com:zybo-z7-20:part0:1.2).

set here  [file normalize [file dirname [info script]]]
set pl    [file dirname $here]
set build [expr {$argc > 0 ? [file normalize [lindex $argv 0]] : "$pl/build"}]

create_project atak_pl $build -part xc7z020clg400-1 -force
set_property board_part digilentinc.com:zybo-z7-20:part0:1.2 [current_project]
set_property target_language Verilog [current_project]
set_property ip_repo_paths [list $pl/ip] [current_project]
update_ip_catalog

# RTL of the module reference atk_axi (must be in the project before the block design is created)
foreach m {uart_rx frame_parser addr_filter aes128_enc ccm_core replay_window secure_rx atk_rx_top location_table
           downlink_frame_builder uart_tx cmd_fifo admin_tx secure_tx atk_server atk_axi} {
    add_files -norecurse $pl/rtl/$m.v
}
add_files -norecurse $pl/rtl/whitelist.mem
add_files -fileset constrs_1 -norecurse [list $pl/constraints/atak_linux.xdc $pl/constraints/hdmi_tx.xdc]
update_compile_order -fileset sources_1

# block design "system": Zynq PS, atk_axi at 0x4000_0000, HDMI output (VDMA, VTC, rgb2dvi)
source $here/system_bd.tcl
make_wrapper -files [get_files system.bd] -top
add_files -norecurse $build/atak_pl.gen/sources_1/bd/system/hdl/system_wrapper.v
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "created $build/atak_pl.xpr"
