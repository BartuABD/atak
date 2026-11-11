# Documentation

| # | Document | Content | Owner | Status |
|---|---|---|---|---|
| 1 | [`../README.md`](../README.md) | System summary, diagram, repository map | shared | first version |
| 2 | [`architecture.md`](architecture.md) | Components, data flow, sequence diagrams (uplink, table downlink, admin commands, relay), hardware and wiring | Aykut (draft) | first version |
| 3 | [`protocol.md`](protocol.md) | Packet formats, flag bits, UART framing, golden frames. Contract between firmware and PL | Aykut (draft), Bartu (review) | draft, PR pending review |
| 4 | [`security.md`](security.md) | CCM envelopes, nonce, counters, replay window, key handling, known gaps, Phase 2 | Aykut (draft) | first version |
| 5 | [`../firmware/stm32wl/README.md`](../firmware/stm32wl/README.md) | Node and gateway firmware | Aykut | first version |
| 6 | [`../fpga/pl/README.md`](../fpga/pl/README.md) | PL server: blocks, register map, build, simulation | Bartu | first version |
| 7 | [`../fpga/ps/README.md`](../fpga/ps/README.md) | PS: boot, PL/PS interface, scripts, GUI, build | Bartu | first version |
| 8 | [`../esp32-bridge/README.md`](../esp32-bridge/README.md), [`../mobile-app/README.md`](../mobile-app/README.md) | BLE bridge and app | Aykut | first version |
| 9 | [`testing.md`](testing.md) | Host tests, golden frames, bring-up, field results | shared | firmware parts written; PL parts open |
| 10 | [`deployment.md`](deployment.md) | Pre-field checklist, known issues, troubleshooting | shared | firmware parts written; PL parts open |

## Conventions

- English, Markdown, diagrams in Mermaid.
- Changes to `protocol.md` go through a pull request approved by both firmware and PL owners.
- Golden frames are kept as files under `docs/protocol/golden/` so that firmware host tests and PL testbenches use
  the same data.

## Secrets

Never commit: `net_key.h`, the Zybo key file (`atak_key`), SSH host keys, passwords. Commit an example with a dummy
value instead (`net_key.example.h`). `.gitignore` covers the known file names; check `git status` before each commit.
