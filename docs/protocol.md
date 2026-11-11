# Protocol

Firmware V1.17.3, PL v12. Contract between the node / gateway firmware and the PL server. Changes to this file go
through a pull request approved by both owners.

All multi-byte fields are **little-endian**. Coordinates are `degrees × 1e7` as `int32` (40.9830600 → `409830600`).

Radio: 869.525 MHz, LoRa SF7, BW 125 kHz, CR 4/5, preamble 8, variable length, max 255 B. The packet type is the
first byte plus the length. With `SECURE_ENABLED 1` every air packet is wrapped in the envelope of section 6; the
inner packets are the ones described below. Security background: [`security.md`](security.md).

## 1. Addresses (16 bit)

| Address | Meaning |
|---|---|
| `0x0000` | Phone, or a node without identity (as source only in `A1`) |
| `0x0001 ... 0x7FFF` | Address derived from the board UID (node with JOIN off) |
| `0x8000 \| team << 8 \| number` | Node that joined a team. Team 1 = ALPHA ... 26 = ZULU, number 1-99. `0x8102` = ALPHA-2 |
| `0xFF00 \| team` | Reserved for team addresses |
| `0xFFFE` | Admin (Zybo), `ADDR_ADMIN` |
| `0xFFFF` | Everyone |

**dev_id**: CRC-32 (IEEE) of the chip's 96-bit UID. Used for identity and in the security envelope. The Zybo's dev_id
is `0xFFFFFFFE`.

## 2. Position and table

### 2.1 Position `pos_packet_t` (12 B, node → all)

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `addr` | u16 | Sender |
| 2 | `seq` | u8 | +1 per packet (loss counting) |
| 3 | `lat` | i32 | Latitude × 1e7 |
| 7 | `lon` | i32 | Longitude × 1e7 |
| 11 | `flags` | u8 | see below |

| Bit | Name | Set by | Meaning |
|---|---|---|---|
| 0 | `POS_FLAG_FIX` (`0x01`) | node | GPS fix present |
| 1 | `POS_FLAG_RELAY_REQ` (`0x02`) | node | Node did not see itself fresh in the table for 25 s; a neighbour should relay this packet |
| 2 | `POS_FLAG_VIA_RELAY` (`0x04`) | Zybo (in the table) | A relayed copy of this position arrived. Plain mode: set by the gateway |
| 3..6 | `POS_FLAG_GWQ_SHIFT 3`, mask `0x78` | node | Gateway quality 0..15, see 5.2 |
| 7 | `POS_FLAG_DIRECT` (`0x80`) | Zybo (PL v11+, in the table) | A direct copy of this seq also arrived. Can be set together with bit2 (merged flags, e.g. `0x87`); the admin GUI shows "via XXXX +D" |

The PL merges the direct and the relayed copy of the same `seq` (flags OR-ed). Period: 5000 ms + random `[0, 1000)`
ms. The position comes from the phone (`0xC4`); after 60 s without one (`POS_OVERRIDE_TIMEOUT_MS`) the node falls back
to a fake position (`fix = 0`).

### 2.2 Table `0xD1` (Zybo → all)

```
[0xD1][N][N × 12 B record]        length 2 + 12·N
```

Each record is a `pos_packet_t`. Broadcast by the PL every 10 s. N <= 21 in plain mode (`DL_MAX_RECORDS`); in secure
mode N <= 19 because of the UART limit (18 when relayed in a `0x52` frame).

## 3. Control packets (15 B)

Common header: `[0]` type, `[1..2]` src, `[3..4]` dst, `[5]` msg_id; the rest depends on the type.

| Type | Direction | Content |
|---|---|---|
| `0xC1` marker / command | phone → node → all; admin → node(s) | `[6]` kind: 1 point of interest, 2 danger, 3 rally, 4 come here, 5 wait, 6 check, 7 go back (admin only). `[7..10]` lat, `[11..14]` lon |
| `0xC2` delete request | node → Zybo only | `[7..8]` target src, `[9]` target msg_id |
| `0xC3` admin decision | Zybo → all | `src = 0xFFFE`, `[6]` 1 approve / 2 reject, `[7..8]` target src, `[9]` target msg_id, `[10]` msg_id of the request |
| `0xC5` ACK | node → Zybo only | `[5]` node's ACK counter (`ack_seq`), `[6]` kind: 1 DELIVERED / 2 SEEN, `[7..8]` acked command's src, `[9]` acked msg_id |

- DELIVERED is sent when a command addressed to the node arrives; SEEN when the user presses OK / Find on the phone.
- Each ACK is sent `ACK_REPEAT = 3` times, random gaps, new `ack_seq` each time. The Zybo deduplicates by
  `(src, acked msg_id, kind)`; without an ACK it repeats the command with the same msg_id.
- Receivers deduplicate by `(type, src, msg_id)`.
- `dst = 0xFFFF` (`CMD_DST_ALL`) addresses everyone. The gateway repeats each new `0xC1` `CMD_RELAY_COUNT = 3` times.

## 4. JOIN: team join, kick, leave

| Type | Len | Direction | Fields |
|---|---|---|---|
| `0xA1` join request | 17 | node → Zybo | `[1..2]` 0x0000, `[3..4]` 0xFFFE, `[5]` req_seq, `[6..9]` dev_id, `[10]` team, `[11]` number (0 = admin chooses), `[12..13]` PIN, `[14..15]` fw version, `[16]` battery (0xFF) |
| `0xA2` join answer | 15 | Zybo → node | `[1..2]` 0xFFFE, `[3..4]` 0xFFFF, `[5]` msg_id, `[6..9]` dev_id, `[10..11]` assigned address, `[12]` team, `[13]` number, `[14]` result: 0 OK, 1 wrong PIN, 2 rejected, 3 team full, 4 number taken (`[13]` = suggested) |
| `0xA3` kick / leave confirm | 15 | Zybo → node | `[3..4]` node address, `[5]` msg_id, `[6..9]` dev_id, `[10]` reason: 1 admin kick, 2 leave confirmed |
| `0xA4` leave request | 15 | node → Zybo | `[1..2]` node address, `[3..4]` 0xFFFE, `[5]` msg_id, `[6..9]` dev_id |

- A node without identity sends no position, only `A1` every `JOIN_PERIOD_MS = 10000` + random 5000 ms.
- On approval the node writes the address to flash (page 127) and sends DELIVERED from the new address.
- A kicked node sends DELIVERED from its old address, then erases its identity. A leaving node sends `A4` up to
  `LEAVE_TRIES = 3` times, `LEAVE_RETRY_MS = 5000` apart, and erases its identity on confirmation or when the tries run out.

## 5. Single-hop relay

A node that has not seen itself fresh in the Zybo table for `REACH_TIMEOUT_MS = 25000` sets flag bit1 in its positions
(and uses `0x52` envelopes). A neighbour that reached the admin directly within the last 25 s relays the packet.

| Type | Plain length | Direction | Layout |
|---|---|---|---|
| `0xE1` relayed position | 17 | relayer → gateway | `[0]` E1, `[1..2]` relayer address, `[3]` RSSI the relayer measured, `[4]` SNR, `[5..]` far node's 12 B position |
| `0xE2` relayed uplink control | 20 | relayer → gateway | same header, `[5..]` far node's 15 B control packet (`C1` / `C2` / `C5` / `A4`) |
| `0xE3` relayed downlink | 3 + N | relayer → far node | `[0]` E3, `[1..2]` relayer address, `[3..]` table or admin packet |

The relayer treats the far node as a client for `RELAY_CLIENT_TIMEOUT_MS = 30000` (max `MAX_RELAY_CLIENTS = 4`) and
forwards tables and commands for it as `E3`. A relayed packet is never relayed again.

### 5.1 Relayer rule (`relay_dev` of the `0x52` envelope)

| `relay_dev` | Relayer action |
|---|---|
| its own dev_id | Relay after 20..70 ms |
| `0xFFFFFFFF` | Wait random 100..600 ms; cancel if another neighbour relays first |
| another dev_id | Do not relay; drop the far node from the client list |

### 5.2 Relayer selection (V1.17, secure mode)

The far node chooses its relayer so that the best neighbour relays and only one copy appears.

- **Gateway quality** (flag bits 3..6): 0 unless the node saw itself fresh and direct in the table within 25 s and
  heard the Zybo directly. Otherwise `clamp((SNR + 20) / 2, 1, 15)` of the last direct Zybo frame (`LINK_Q`). 0 means
  the node cannot be a relayer.
- **Score** per neighbour heard directly within `NB_TIMEOUT_MS = 30000`: `min(link quality, neighbour's gateway
  quality)`; link quality = SNR at which the neighbour was heard, same scale. Candidates with quality 0 are skipped.
- **Hysteresis:** the current relayer stays until it disappears or another is better by `NB_HYST_STEPS = 2`.
- **Fallback:** `NB_FAIL_MAX = 2` consecutive positions without overhearing the relayer's `E1` mark it bad for
  `NB_BAD_MS = 60000`. No candidate: `relay_dev = 0xFFFFFFFF`.
- **Own-entry freshness (V1.17.1):** an own table entry counts only if its `seq` is within `OWN_SEQ_FRESH = 4` of the
  last sent seq.
- **Leaving relay mode (V1.17.2 / V1.17.3):** `DIRECT_STREAK_EXIT = 2` consecutive tables, each heard directly (not
  via `E3`), with a fresh own entry, from a direct copy (bit7 if the node has ever seen bit7, else bit2 = 0), and
  `SNR >= DIRECT_EXIT_SNR_MIN = 0` dB. `E3` copies do not reset the streak.
- If the Zybo never sets bit2, the far node treats the seqs it heard being relayed as relayed. This safety is disabled
  as soon as the Zybo sets bit2.

## 6. Secure envelope (`SECURE_ENABLED 1`)

```
0x51: [0x51][dev_id 4][ctr 4][ciphertext N][MIC 4]                  length N + 13, AAD = bytes 0..8
0x52: [0x52][dev_id 4][ctr 4][relay_dev 4][ciphertext N][MIC 4]     length N + 17, AAD = bytes 0..12
```

AES-128-CCM, MIC 4 B, nonce = `dev_id | ctr | dir | 00 00 00 00` (13 B), `dir` 0 = node, 1 = Zybo. `0x52` is used
only for frames that request a relay. Counter, replay window, key handling and known gaps: [`security.md`](security.md).

**Nested relay.** The relayer wraps the far node's secure packet unchanged in its own `0x51` packet:

```
E1 / E2 plaintext = [E1|E2][relayer addr 2][RSSI][SNR][far node's secure packet, unchanged]
E3 plaintext      = [E3][relayer addr 2][Zybo's secure packet, unchanged]
```

The same packet arriving directly and via a relayer carries the same inner counter, so the second copy is dropped
as a replay.

**Gateway is a pipe.** It forwards frames starting with `0x51` and at least `SEC_PIPE_MIN_LEN = 25` B, or `0x52` and at
least `SEC_PIPE_MIN_LEN2 = 29` B, unopened.

**Migration.** `SECURE_ONLY 0` accepts plain and secure packets; `1` only secure packets.

Test vector (key `00 01 ... 0F`, dev_id `0x12345678`, counter 1, dir 0): `golden_frames.json`, entry
`env_0x51_position`.

## 7. UART framing (node ↔ ESP32, gateway ↔ Zybo)

```
[0xAA][0x55][LEN][PAYLOAD (LEN bytes)][CRC8]
CRC8: poly 0x07, init 0x00, over LEN + PAYLOAD
```

The receiver is a byte-wise state machine (`SYNC0 → SYNC1 → LEN → DATA → CRC`); frames with a wrong CRC are dropped
and the next sync is searched. No inter-byte timeout.

### 7.1 Gateway → Zybo

Payload = air packet + RSSI (i8) + SNR (i8), so `LEN = air length + 2`.

| Packet | Plain `LEN` | Secure `LEN` |
|---|---|---|
| Position | 14 | 27 (`0x51`), 31 (`0x52`) |
| Control (`C1` / `C2` / `C5` / `A4`) | 17 | 30 (`0x51`), 34 (`0x52`) |
| `A1` | 19 | 32 |
| `E1` relayed position | 19 | 45 (`0x51` inside), 49 (`0x52` inside) |
| `E2` relayed control | gateway opens it and forwards the inner 15 B with `LEN` 17 | 48 (`0x51` inside), 52 (`0x52` inside) |

With `GW_FORWARD_CMD 1` the gateway also passes each new `0xC1` it heard: `AA 55 11 <15 B> RSSI SNR CRC8` (21 B).
With `GW_FORWARD_RELAY_INFO 1` in plain mode a relayed position goes as `AA 55 13 E1 <relayer 2> <RSSI> <SNR> <12 B>
RSSI SNR CRC8` (23 B).

### 7.2 Zybo → gateway

| Mode | Payload |
|---|---|
| Plain | Table `0xD1` or a 15 B `C1` / `C3` / `A2` / `A3`; the gateway repeats admin packets 3 times |
| Secure | `[tx_repeat][secure packet]`, `LEN = 1 + packet length`. The gateway transmits the packet unchanged `tx_repeat` times (max `SEC_TX_REPEAT_MAX = 5`; table 1, others 3), 400..600 ms apart. Queue of `SEC_TXQ_SIZE = 4` packets |

### 7.3 Node ↔ ESP32 ↔ phone (local, not sent over LoRa)

| Type | Direction | Content |
|---|---|---|
| `0xD1`, `0xC1`, `0xC3` | node → phone | Table and packets from the network (plain form) |
| `0xC1`, `0xC2`, `0xC5` | phone → node | Marker, delete request, SEEN ACK (the node fills `src`) |
| `0xC4` set my position (15 B) | phone → node | `[1..4]` lat, `[5..8]` lon, `[9]` 1 set / 0 back to fake position |
| `0xC6` node status (8 B) | node → phone | `[1..2]` address, `[3]` last sent seq, `[4]` own entry in table, `[5]` seq in table, `[6]` flags in table |
| `0xC9` join parameters (15 B) | phone → node | `[1]` team, `[2]` number, `[3..4]` PIN |
| `0xCB` join status (8 B) | node → phone | `[1]` state (0 disabled, 1 need params, 2 waiting, 3 joined, 4 failed, 5 leaving), `[2]` result (as `A2` plus 5 kicked, 6 left), `[3..4]` address, `[5]` team, `[6]` number, `[7]` req_seq |
| `0xCC` leave team (15 B) | phone → node | none |

## 8. BLE (ESP32 ↔ phone)

Service `0xABF0`, characteristic `0xABF1`, device name `LoRaNode-BLE`. The bridge sends the UART payload as one
notification and wraps phone writes in a UART frame. Details: [`esp32-bridge/README.md`](../esp32-bridge/README.md).

## 9. Golden frames

[`protocol/golden/golden_frames.json`](protocol/golden/golden_frames.json) holds byte-exact frames with the test key
`00 01 ... 0F`: air frame, gateway UART frame, plaintext, decoded fields, and for nested relay frames the inner
packet. Consumers:

| Consumer | How |
|---|---|
| Firmware host test | `firmware/stm32wl/tests/test_golden.c` (via `gen_golden_h.py`): opens every envelope with the firmware's CCM and compares the plaintext; checks the UART CRC-8 |
| Independent check | `docs/protocol/golden/verify_golden.py`: same with Python `cryptography` AESCCM |
| PL testbenches | `fpga/pl/tb/gen/fw_golden_frames.py` currently holds a copy of five of these frames; it can be replaced by a reader of the JSON |

Frames: `env_0x51_position`, `pos_0x52_relay_dev_chosen`, `pos_0x52_relay_dev_any`, `pos_0x52_relay_dev_any_node2`,
`nested_e1_with_0x52`, `nested_e2_with_0x52`, `zybo_a2_join_answer`, `zybo_table_d1`.

Frames in the source file `golden_frames_relay_select_v1.17.txt` describe flag bit7 as reserved; since PL v11 it is
`POS_FLAG_DIRECT`.
