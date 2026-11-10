## atak_linux.xdc - Pmod JC pins of atk_axi in the Linux block design (Zybo Z7-20)
## The block-design ports must be named uart_rx and uart_tx (rename them after "Make External").

## JC pin 1 = UART RX <- gateway STM32 D1 (PB6, USART1_TX). Pull-up: unconnected = idle.
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports uart_rx]
## JC pin 2 = UART TX -> gateway STM32 D0 (PB7, USART1_RX)
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports uart_tx]

set_false_path -from [get_ports uart_rx]
set_false_path -to   [get_ports uart_tx]
