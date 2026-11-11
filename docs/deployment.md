# Deployment

Firmware, ESP32 and app parts. PL and PS deployment steps (bitstream, boot image, SD card, key loading) are
described in [`fpga/pl/README.md`](../fpga/pl/README.md) and [`fpga/ps/README.md`](../fpga/ps/README.md); the PL owner
adds them to this page.

## Pre-field checklist

| Item | Required state |
|---|---|
| TX power | `TX_OUTPUT_POWER = 17` on all boards. KG200Z needs > 15 dBm (HP PA only); <= 15 gives no TX. |
| Test modes | `TEST_FAR_NODE 0`, `TEST_GW_IGNORE_DIRECT 0` |
| Key | Real network key on all nodes and on the Zybo; the dummy key `00 01 ... 0F` nowhere |
| Security mode | `SECURE_ENABLED 1`, `SECURE_ONLY 1` |
| RDP | Level 1 (option byte `BB`) on nodes, set last. Never Level 2. See [`security.md`](security.md#readout-protection-nodes) |
| Firmware version | Same on every board (V1.17.3). All nodes >= V1.17.2 before PL v11+ is live |
| Roles | Exactly one gateway per Zybo (`GATEWAY_MODE 1`) |
| Whitelist | All node addresses, including `VIRTUAL_NODES` addresses, are in the Zybo whitelist |
| BLE names | Unique per bridge, or the app's `kDeviceName` matches |
| Map | `assets/map.mbtiles` present in the app build |

## Provisioning a node

1. Set the role in `Core/Inc/app_mode.h` (board table in [`firmware/stm32wl/README.md`](../firmware/stm32wl/README.md#settings-per-board)).
2. Create `net_key.h` from `net_key.example.h` with the real key.
3. Build and flash. Check the boot log for `APPLICATION_VERSION`, `SECURE:` and `MODE=`.
4. JOIN nodes: join from the phone (team, number, PIN) and wait for the admin approval; the node sends no position
   before that.
5. Set RDP Level 1 as the last step.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Node log shows the table, phone shows no nodes | `NODE_UART_BRIDGE 0` | Set `NODE_UART_BRIDGE 1` on the node with the ESP32 |
| UART to ESP32 or Zybo drops after the node sleeps | USART1 does not run in STOP2 | STOP2 is disabled in bridge / gateway mode (`sys_conf.h`) |
| ST-LINK cannot connect while the board sleeps | SWD is off in STOP2 | `DEBUGGER_ENABLED 1`; recover with BOOT0 if needed |
| KG200Z transmits but the gateway hears nothing | Only the HP PA is wired to the antenna | `TX_OUTPUT_POWER` 17 dBm |
| Node transmits no position ("kimlik yok") | Flashed with `JOIN_ENABLED 1` and no JOIN done | Join from the phone, or build with `JOIN_ENABLED 0` |
| Nothing received between two boards | Both boards flashed with `GATEWAY_MODE 1` | Flash one as node |
| ACKs get lost | Node ACKs collide with gateway repeats | ACK sent 3x at random gaps; downlink retry on the relayer |
| Nodes drop from the table after a Zybo restart | Whitelist in RAM | Membership list is kept on the SD card on the Zybo |
| `Failed to start GDB server` | Wrong ST-LINK selected or cable reversed | Select the correct ST-LINK serial number; red stripe = pin 1 |
| Two phones connect to each other's bridge | Both ESP32 advertise `LoRaNode-BLE` | Rename one bridge and that phone's `kDeviceName` |
| dev_id printed as `0x%lX` wrongly in log | Lightweight printf lacks `%l` | `%08X` with `(unsigned int)` |
| Many nodes request relay at once while their uplink still arrives ("+D") | Shared downlink interruption, or only the gateway TX power was lowered | Expected behaviour; see [`testing.md`](testing.md#relay-selection-field-tests-v117x) |
| Node does not leave relay mode | Weak downlink (SNR < 0 dB) or `E3` copies only | Improve the downlink; leaving needs 2 direct tables, SNR >= 0 dB |
| Replay rejections after re-flashing | Counter page erased (e.g. RDP regression) | Avoid RDP regression; see [`security.md`](security.md#readout-protection-nodes) |

## Known issues

- BLE link to the phone is unauthenticated ([`security.md`](security.md#known-gaps)).
- Single shared network key.
- Whitelist changes on the Zybo and the `VIRTUAL_NODES` addresses must be kept in sync by hand.
- A phone in the background on iPhone stops BLE; keep the app in the foreground.
