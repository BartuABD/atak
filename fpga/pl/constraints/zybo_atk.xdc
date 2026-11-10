## zybo_atk.xdc - pins for zybo_atk_top on the Zybo Z7-20 (locations from Digilent's board files, part0_pins.xml)

## 125 MHz board oscillator
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports sysclk]
create_clock -period 8.000 -name sysclk [get_ports sysclk]

## BTN0 = reset
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports btn0]

## UART RX on Pmod JC pin 1 (top row, the pin marked 1). Pull-up: an unconnected pin stays at idle (1)
## (2026-10-22: moved from JE1 = V12 to JC1, the connection works better there)
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports uart_rx]

## UART TX (downlink) on Pmod JC pin 2 -> gateway STM32 D0 (PB7, USART1_RX)
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports uart_tx]

## BTN1 = send the downlink table now
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS33 } [get_ports btn1]

## switches SW0..SW3
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports {sw[3]}]

## LEDs LD0..LD3
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]

## the inputs are asynchronous (synchronized inside): no input timing to check
set_false_path -from [get_ports {btn0 btn1 uart_rx sw[*]}]
set_false_path -to   [get_ports {led[*] uart_tx}]
