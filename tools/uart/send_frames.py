"""send_frames.py - step 6 hardware test: sends hand-made gateway frames from the PC (USB-TTL adapter, 3.3 V) into
the Zybo's Pmod JE pin 1, so the PL can be tested without the STM32.

    pip install pyserial
    python send_frames.py COM5            (your adapter's port: Device Manager -> Ports (COM & LPT))

Sends, 1 s apart: a frame from 1764 (in the list), from 157C (in the list), from 1234 (not in the list), a frame
with a wrong CRC, a frame with LEN = 0x20. Then repeats. Ctrl+C stops.
On the Zybo (SW3 down): LD0 flashes for accepted, LD1 for not-in-list, LD2 for CRC / LEN errors; LD3 = heartbeat.
"""
import struct
import sys
import time

import serial


def crc8(data: bytes) -> int:
    """CRC-8, polynomial 0x07, init 0x00, no reflection, no final XOR."""
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def frame(addr, seq, lat, lon, flags=0, rssi=-15, snr=12, length=14, bad_crc=False):
    """[AA][55][LEN][addr seq lat lon flags][RSSI][SNR][CRC8], little-endian payload."""
    body = bytes([length]) + struct.pack("<HBiiB", addr, seq, lat, lon, flags) + struct.pack("<bb", rssi, snr)
    c = crc8(body) ^ (0xFF if bad_crc else 0)
    return b"\xAA\x55" + body + bytes([c])


assert crc8(b"123456789") == 0xF4
assert frame(0x1764, 13, 410093170, 289786300).hex(" ").upper() == \
    "AA 55 0E 64 17 0D 72 86 71 18 BC C9 45 11 00 F1 0C 70"

TESTS = [
    ("1764, in the list      -> LD0", lambda s: frame(0x1764, s, 410093170 + s, 289786300)),
    ("157C, in the list      -> LD0", lambda s: frame(0x157C, s, 410093170, 289786300 + s)),
    ("1234, NOT in the list  -> LD1", lambda s: frame(0x1234, s, 410093170, 289786300)),
    ("1764, wrong CRC        -> LD2", lambda s: frame(0x1764, s, 410093170, 289786300, bad_crc=True)),
    ("LEN = 0x20             -> LD2", lambda s: frame(0x1764, s, 410093170, 289786300, length=0x20)[:4]),
]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with serial.Serial(sys.argv[1], 115200, bytesize=8, parity="N", stopbits=1) as port:
        seq = 0
        while True:
            for name, make in TESTS:
                f = make(seq & 0xFF)
                port.write(f)
                port.flush()
                print(f"{name}   {f.hex(' ').upper()}")
                seq += 1
                time.sleep(1.0)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
