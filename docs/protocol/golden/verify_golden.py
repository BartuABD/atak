#!/usr/bin/env python3
"""Independent check of golden_frames.json with Python 'cryptography' AESCCM (tag 4).
Opens every envelope (and nested inner packets), compares the plaintext, checks the UART CRC-8.
usage: python3 -I verify_golden.py [golden_frames.json]"""
import json, os, struct, sys
from cryptography.hazmat.primitives.ciphers.aead import AESCCM

def crc8(b):
    c = 0
    for x in b:
        c ^= x
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c

def check(aes, name, air_hex, pt_hex, direction):
    air, want = bytes.fromhex(air_hex), bytes.fromhex(pt_hex)
    hl = 13 if air[0] == 0x52 else 9
    nonce = air[1:9] + bytes([direction]) + bytes(4)
    got = aes.decrypt(nonce, air[hl:], air[:hl])
    assert got == want, '%s: plaintext differs' % name

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'golden_frames.json')
d = json.load(open(path))
aes = AESCCM(bytes.fromhex(d['key_hex']), tag_length=4)
for f in d['frames']:
    check(aes, f['name'], f['air_hex'], f['plaintext_hex'], 0 if f['direction'] == 'node_to_zybo' else 1)
    if 'uart_hex' in f:
        u = bytes.fromhex(f['uart_hex'])
        assert u[:2] == b'\xaa\x55' and u[-1] == crc8(u[2:-1]), f['name'] + ': UART CRC'
    if 'inner' in f:
        check(aes, f['name'] + '/inner', f['inner']['air_hex'], f['inner']['plaintext_hex'], 0)
        assert bytes.fromhex(f['inner']['air_hex']) == bytes.fromhex(f['plaintext_hex'])[5:], f['name'] + ': inner not unchanged'
    print('ok  ', f['name'])
