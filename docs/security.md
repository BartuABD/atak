# Security (Phase 1)

Scope: the radio link between nodes, gateway and Zybo, and the key handling around it. Packet field layouts are in
[`protocol.md`](protocol.md); the phone ↔ ESP32 link is covered under [Known gaps](#known-gaps).

## Summary

| Property | Phase 1 |
|---|---|
| Cipher | AES-128-CCM, MIC 4 B |
| Keys | One shared network key (`net_key.h` on nodes, key registers on the Zybo) |
| Authenticated | Every air packet, both directions |
| Replay protection | Per-sender counter, 32-entry window |
| Gateway | Holds no key; forwards secure frames unopened |
| Plain packets | Rejected when `SECURE_ONLY = 1` (firmware) and from reset in PL v12 |

## Envelopes

```
0x51: [0x51][dev_id 4][ctr 4][ciphertext N][MIC 4]                    length N + 13
0x52: [0x52][dev_id 4][ctr 4][relay_dev 4][ciphertext N][MIC 4]       length N + 17
```

| Field | Value |
|---|---|
| AAD | Clear header: first 9 bytes (`0x51`) or first 13 bytes (`0x52`) |
| Nonce (13 B) | `dev_id (4) \| ctr (4) \| dir (1) \| 00 00 00 00` |
| `dir` | 0 = sent by a node, 1 = sent by the Zybo |
| `dev_id` | CRC-32 (IEEE) of the chip's 96-bit UID; Zybo uses `0xFFFFFFFE` (`SEC_DEVID_ZYBO`) |
| Counter | Per sender, +1 per packet |
| `relay_dev` | `0x52` only: dev_id of the neighbour chosen as relayer, `0xFFFFFFFF` = any (`SEC_RELAY_ANY`). It is in the AAD, so it cannot be changed without invalidating the MIC. |

`dev_id` and not the 16-bit address goes into the nonce because addresses change on JOIN and kick.

`0x52` is used only for frames that request a relay: positions with flag bit1, and `C1` / `C2` / `C5` / `A4` while the
node is in relay mode. All other frames use `0x51`.

Nested relay frames: the relayer wraps the far node's secure packet unchanged inside its own `0x51` packet
(`E1` / `E2` payload), and the Zybo wraps its packet for the far node the same way (`E3`). The relayer cannot read or
alter the inner packet. See [`golden frames`](protocol/golden/golden_frames.json) for byte-exact examples.

## Replay protection

- Receiver checks the MIC first, then the counter.
- State per sender: highest counter seen plus a 32-entry window (`SEC_WIN = 32`). A counter already seen, or older
  than the window, is dropped.
- Firmware tracks 16 senders (`SEC_REPLAY_SIZE`); the PL tracks 64 devices.
- The same packet arriving both directly and through a relayer has the same inner counter, so the second copy is
  dropped as a replay.

### Counter persistence (node)

| Item | Value |
|---|---|
| Location | Flash page 126, `0x0803F000` (`SEC_CTR_PAGE`) |
| Layout | 256 slots (`SEC_CTR_SLOTS`) of 8 B: `[ctr][~ctr]`; the page is erased only when full |
| Save interval | Every `SEC_CTR_STEP = 256` packets |
| Boot | Continue from last saved value + 256, so a counter is never reused after a power loss |
| Identity | Flash page 127, `0x0803F800`, magic `0x4E494F4A` ("JOIN") |

The Zybo's downlink counter (`DL_CTR`, PL register `0x09C`) must never repeat under one key.

## Gateway

The gateway never holds the key. It forwards `0x51` frames of at least `SEC_PIPE_MIN_LEN = 25` B and `0x52` frames of
at least `SEC_PIPE_MIN_LEN2 = 29` B to the Zybo unopened, and transmits the Zybo's secure packets `tx_repeat` times.
Authentication, marker re-broadcast and decryption of relayed packets happen on the Zybo.

## Key handling

| Where | How |
|---|---|
| Node / gateway firmware | `SubGHz_Phy/App/net_key.h`, git-ignored. Template `net_key.example.h`. The only tracked `net_key.h` is `firmware/stm32wl/tests/stubs/net_key.h` with the dummy test key `00 01 ... 0F`. |
| Zybo | PL key registers `KEY0..3` (write-only), loaded by `atk_sec.sh` ([`fpga/ps/README.md`](../fpga/ps/README.md)) |
| Exchange | Over a private channel; never in the repository or team chat |
| Test key | `00 01 02 ... 0F` is used by host tests and PL testbench vectors only; it must not be on field devices |

Key and counter registers are not reset by the PL soft reset. From reset, PL v12 runs with `SECURE_ONLY = 1`:
nothing is accepted before the key is loaded.

## Readout protection (nodes)

- Planned just before the field: RDP **Level 1** (option byte `BB`). Level 1 blocks debugger access to flash while
  keeping the chip reprogrammable.
- Never Level 2 (`CC`): irreversible.
- Regression from Level 1 to Level 0 (`AA`) erases flash. Identity and counter are lost; the node then restarts
  with a counter the Zybo's replay window may reject. Avoid re-flashing production nodes through RDP regression.
- While RDP is 0, the network key can be read out of a node.

## Migration modes

| `SECURE_ENABLED` | `SECURE_ONLY` | Behaviour |
|---|---|---|
| 0 | - | Plain packets only |
| 1 | 0 | Both accepted: a packet starting with `0x51` / `0x52` with a valid MIC is secure, anything else plain |
| 1 | 1 | Only secure packets accepted |

## Known gaps

- **Single shared key.** An insider with a node can forge packets as any node and as the Zybo (dev_id
  `0xFFFFFFFE`, direction 1). The key can be extracted from a node while RDP is off.
- **BLE phone ↔ ESP32 is plain and unauthenticated.** No pairing, bonding or encryption; anyone in range can read
  the table and send commands to the node.
- **Metadata in clear.** `dev_id`, counter, packet type / length and `relay_dev` (topology) are visible. RF direction
  finding of transmitters is always possible.
- **4 B MIC.** A forgery has a 2^-32 chance per attempt.
- **Flash loss.** See RDP regression above.

## Phase 2 plan (not implemented)

- Per-device key: `AES-CMAC(master, dev_id)`.
- Group key for broadcast traffic.
- Rekey of the group when a node is kicked.
- Key-id byte in the header.
- Gateway quality may move into the clear header.
- Pairing or encryption on the BLE link.
