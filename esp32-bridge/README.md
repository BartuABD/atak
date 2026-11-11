# ESP32 BLE bridge

The STM32WL has no BLE. The bridge sits between a node and the phone: it forwards the node's UART frames to the
phone as BLE notifications and the phone's commands back to the node over UART. It is built on Espressif's NimBLE
`bluetooth/nimble/bt_spp_server` example; application code is in [`main/main.c`](main/main.c).

The link phone ↔ bridge is plain. The secure envelope (`0x51` / `0x52`) is added and removed by the node, so the
bridge only handles inner packets. System context: [`docs/architecture.md`](../docs/architecture.md).

## Board

| | |
|---|---|
| Chip | ESP32-S3 in the current setup. The code is chip-independent (UART1 on GPIO4 / GPIO5, NimBLE) and also builds for ESP32-C3. |
| ESP-IDF | v6.1 (last build). `nimble_peripheral_utils` comes from the IDF example tree (`main/idf_component.yml` points at `${IDF_PATH}`), so build from an ESP-IDF shell. |
| Config | `sdkconfig.defaults`: BT enabled, BLE only, NimBLE host, no Bluedroid. `sdkconfig` is generated per target and git-ignored. |

## Wiring to the node

| ESP32 | STM32WL | Direction |
|---|---|---|
| GPIO4 (UART1 RX) | PB6 (USART1 TX; NUCLEO D1) | node → bridge |
| GPIO5 (UART1 TX) | PB7 (USART1 RX; NUCLEO D0) | bridge → node |
| GND | GND | common ground, both sides 3.3 V |

UART 115200 8N1. Framing is the same as on the gateway ↔ Zybo link: `AA 55 LEN payload CRC8`, CRC-8 poly `0x07`,
init `0`, computed over `LEN` + payload. The receive side is the same byte-wise state machine
(`SYNC0 / SYNC1 / LEN / DATA / CRC`) as in the firmware; frames with a bad CRC are dropped and counted.

## BLE

| | |
|---|---|
| Device name | `LoRaNode-BLE` (`ble_svc_gap_device_name_set` in `app_main`) |
| Service | `0xABF0` (`BLE_SVC_SPP_UUID16`) |
| Characteristic | `0xABF1` (`BLE_SVC_SPP_CHR_UUID16`), flags `READ \| WRITE \| NOTIFY` |
| Advertising | undirected connectable, general discoverable, service UUID in the advertisement |
| Pairing | none required: the bridge never initiates security and the characteristic has no encrypt / authenticate flags, so any central can read, write and subscribe |

The original example's other characteristics (`0xABF2`..`0xABF4`) are not implemented; one characteristic carries
both directions.

If two bridges run side by side, change the name in one of them and set `kDeviceName` to the same value in that
phone's app ([`mobile-app/`](../mobile-app/)); otherwise a phone may connect to the other bridge.

## Data paths

### Node → phone

Every valid UART frame is sent as one notification containing the payload only (no `AA 55`, `LEN` or CRC). The
bridge does not filter by type. Types it recognises (for log output only):

| Type | Length | Content |
|---|---|---|
| `0xD1` | 2 + 12·N | Location table, N records of 12 B |
| `0xC3` | 15 | Admin decision on a delete request |
| `0xC1` | 15 | Command from the network |
| `0xC6` | 8 | Node status: own entry present in the table |
| `0xCB` | 8 | JOIN status |

The notification is sent to every connection that has subscribed. If the negotiated ATT MTU is smaller than
`len + 3`, the data is cut to `MTU − 3`; the bridge logs a warning and does not fragment. A table of N nodes is
`2 + 12·N` bytes, so the phone must request a larger MTU.

### Phone → node

A write to `0xABF1` is accepted only if it is exactly 15 bytes (`CMD_PACKET_LEN`) and the first byte is one of:

| Type | Meaning |
|---|---|
| `0xC1` | Marker / command |
| `0xC2` | Delete request |
| `0xC4` | Phone position, delivered to the connected node only (not sent over LoRa) |
| `0xC5` | ACK, kind SEEN |
| `0xC9` | JOIN parameters (team, number, PIN) |
| `0xCC` | Leave team |

Anything else is dropped with a warning. Accepted packets are wrapped in `AA 55 15 <packet> CRC8` and written to
UART1 TX. Writes longer than 32 B are rejected with `BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN`. Field layouts:
[`docs/protocol.md`](../docs/protocol.md).

## Build and flash

```bash
cd esp32-bridge
idf.py set-target esp32s3        # or esp32c3
idf.py build
idf.py -p PORT flash monitor     # exit the monitor with Ctrl-]
```

## Known limitations

- No pairing, bonding or encryption on the BLE link. Anyone in range can read the table and write commands.
- No fragmentation of notifications; relies on the phone raising the ATT MTU.
- Single characteristic for both directions; no flow control towards the phone beyond what NimBLE queues.
- No inter-byte timeout in the UART frame parser.
- `main.c` still carries the unused UART0 passthrough from the example (`ble_spp_uart_init`); the bridge itself
  uses UART1 only. Log strings and comments are Turkish.
- The project is still named `spp_server` in `CMakeLists.txt`.
