"""sniff_frames.py - listens on a COM port and decodes the gateway frames, to check the STM32 gateway WITHOUT the Zybo.

Wiring (USB-TTL adapter, 3.3 V):  adapter RX <- NUCLEO D1 (PB6, USART1_TX),  adapter GND <- NUCLEO GND.
(Only RX and GND: the adapter only listens.)

    pip install pyserial
    python sniff_frames.py COM5

Prints every frame with its fields and whether the CRC is right; bytes that are not part of a frame are shown as
"garbage". Ctrl+C stops.
"""
import struct
import sys

import serial


def crc8(data: bytes) -> int:
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    buf = bytearray()
    with serial.Serial(sys.argv[1], 115200, bytesize=8, parity="N", stopbits=1, timeout=0.1) as port:
        print(f"listening on {sys.argv[1]} at 115200 8N1 ...")
        while True:
            buf += port.read(64)
            while len(buf) >= 2:
                start = buf.find(b"\xAA\x55")
                if start < 0:
                    print(f"garbage: {bytes(buf[:-1]).hex(' ').upper()}")
                    del buf[:-1]                       # keep a last AA: it may start the next frame
                    break
                if start > 0:
                    print(f"garbage: {bytes(buf[:start]).hex(' ').upper()}")
                    del buf[:start]
                if len(buf) < 18:
                    break
                f = bytes(buf[:18])
                if f[2] != 0x0E:
                    print(f"bad LEN 0x{f[2]:02X}: {f[:3].hex(' ').upper()}")
                    del buf[:2]
                    continue
                addr, seq, lat, lon, flags = struct.unpack("<HBiiB", f[3:15])
                rssi, snr = struct.unpack("<bb", f[15:17])
                ok = crc8(f[2:17]) == f[17]
                print(f"addr {addr:04X} seq {seq:3d} lat {lat / 1e7:.7f} lon {lon / 1e7:.7f} flags {flags} "
                      f"rssi {rssi} snr {snr}  CRC {'ok' if ok else 'WRONG'}   {f.hex(' ').upper()}")
                del buf[:18]


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
