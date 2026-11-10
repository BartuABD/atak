# Test frames for tb_secure_rx.sv: gateway UART frames in, expected frames out (the old plain format).
import os, struct, sys
from cryptography.hazmat.primitives.ciphers.aead import AESCCM
KEY = bytes(range(16))
def crc8(b):
    c = 0
    for x in b:
        c ^= x
        for _ in range(8): c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c
def sec(dev, ctr, inner, key=KEY, rdev=None):
    hdr = bytes([0x51]) + struct.pack('<II', dev, ctr) if rdev is None else           bytes([0x52]) + struct.pack('<III', dev, ctr, rdev)
    return hdr + AESCCM(key, tag_length=4).encrypt(struct.pack('<II', dev, ctr) + bytes(5), inner, hdr)
def uart(body):                     # body = everything between LEN and CRC
    return bytes([0xAA, 0x55, len(body)]) + body + bytes([crc8(bytes([len(body)]) + body)])
RS = bytes([0xC4, 0x08])            # gateway RSSI -60, SNR 8
def pos(addr, seq, lat, lon, fl=0): return struct.pack('<HBiiB', addr, seq, lat, lon, fl)
P_FAR = pos(0x8203, 9, 410100000, 289800000, 0x02)          # BRAVO-3, wants relay
C1 = bytes([0xC1]) + struct.pack('<HHB', 0x8101, 0xFFFF, 0x21) + bytes([3]) + struct.pack('<ii', 410000000, 289000000)
C5 = bytes([0xC5]) + struct.pack('<HHB', 0x8203, 0xFFFE, 7) + bytes([1]) + struct.pack('<HB', 0xFFFE, 0x44) + bytes(5)
A1 = bytes([0xA1, 0, 0, 0xFE, 0xFF, 2]) + struct.pack('<I', 0xCAFE0001) + bytes([3, 0]) + struct.pack('<H', 1234) + bytes([1, 15, 80])
assert len(C1) == 15 and len(C5) == 15 and len(A1) == 17
D_A, D_R1, D_R2, D_FAR = 0x12345678, 0x0000157C, 0x00001764, 0x00000F53
far_pkt = sec(D_FAR, 500, P_FAR)
T = []   # (name, secure_only, in_bytes, expected_out_bytes, cut)
pa = pos(0x8101, 7, 410082000, 289784000, 1)
T.append(('firmware vector position', 1, uart(sec(D_A, 1, pa) + RS), uart(pa + RS), 0))
T.append(('same frame again = replay', 1, uart(sec(D_A, 1, pa) + RS), b'', 0))
T.append(('secure C1 command', 1, uart(sec(D_A, 2, C1) + RS), uart(C1 + RS), 0))
T.append(('secure A1 join request', 1, uart(sec(0xCAFE0001, 1, A1) + RS), uart(A1 + RS), 0))
T.append(('late frame inside window (ctr 5 after 9)', 1, uart(sec(D_A, 9, pa) + RS) , uart(pa + RS), 0))
T.append(('  ... ctr 5', 1, uart(sec(D_A, 5, pa) + RS), uart(pa + RS), 0))
T.append(('  ... ctr 5 again = replay', 1, uart(sec(D_A, 5, pa) + RS), b'', 0))
T.append(('ctr 100 then ctr 60 = too old', 1, uart(sec(D_A, 100, pa) + RS), uart(pa + RS), 0))
T.append(('  ... ctr 60', 1, uart(sec(D_A, 60, pa) + RS), b'', 0))
e1 = bytes([0xE1]) + struct.pack('<H', 0x157C) + bytes([0xB0, 0x05]) + far_pkt
T.append(('nested E1 relayed position', 1, uart(sec(D_R1, 1, e1) + RS),
          uart(bytes([0xE1]) + struct.pack('<H', 0x157C) + bytes([0xB0, 0x05]) + P_FAR + RS), 0))
e1b = bytes([0xE1]) + struct.pack('<H', 0x1764) + bytes([0xA8, 0x02]) + far_pkt
T.append(('same far frame via 2nd relayer = dup', 1, uart(sec(D_R2, 1, e1b) + RS), b'', 0))
T.append(('far node direct after relayed = MERGE (v11)', 1, uart(far_pkt + RS), uart(P_FAR + RS), 0, 0, 1))
T.append(('  ... direct again = replay', 1, uart(far_pkt + RS), b'', 0))
far_c5 = sec(D_FAR, 501, C5)
e2 = bytes([0xE2]) + struct.pack('<H', 0x157C) + bytes([0xB0, 0x05]) + far_c5
T.append(('nested E2 relayed C5 ack', 1, uart(sec(D_R1, 2, e2) + RS), uart(C5 + RS), 0))
e3 = bytes([0xE3]) + struct.pack('<H', 0x157C) + sec(0xFFFFFFFE, 77, C1)
T.append(('E3 (our downlink relayed back) dropped', 1, uart(sec(D_R1, 3, e3) + RS), b'', 0))
bad = bytearray(sec(D_A, 200, pa)); bad[-1] ^= 1
T.append(('bad MIC, secure_only=1: dropped', 1, uart(bytes(bad) + RS), b'', 0))
T.append(('bad MIC, secure_only=0: sent on as plain', 0, uart(bytes(bad) + RS), uart(bytes(bad) + RS), 0))
wk = sec(D_A, 201, pa, key=bytes(16))
T.append(('wrong key: dropped', 1, uart(wk + RS), b'', 0))
pp = pos(0x8151, 3, 1, 2)            # plain position starting with 0x51
T.append(('plain position (0x51 first), secure_only=0', 0, uart(pp + RS), uart(pp + RS), 0))
T.append(('plain position, secure_only=1: dropped', 1, uart(pp + RS), b'', 0))
T.append(('plain C1, secure_only=0', 0, uart(C1 + RS), uart(C1 + RS), 0))
bc = bytearray(uart(pa + RS)); bc[-1] ^= 0xFF
T.append(('bad CRC: sent on unchanged', 1, bytes(bc), bytes(bc), 0))
T.append(('bad LEN 0x05: AA 55 05 sent on', 1, bytes([0xAA, 0x55, 0x05]), bytes([0xAA, 0x55, 0x05]), 0))
cut = uart(sec(D_A, 300, pa) + RS)[:12]
T.append(('cut off after 12 bytes: sent on as it came', 1, cut, cut, 1))
T.append(('next frame after the cut works', 1, uart(sec(D_A, 301, pa) + RS), uart(pa + RS), 0))
# ---- v10: 0x52 (relay request naming its relayer); the 6th field = expected fwd_rdev after the test
P_RQ = pos(0x8203, 10, 410100100, 289800100, 0x02)
T.append(('v10 0x52 direct position, relay_dev 157C', 1, uart(sec(D_FAR, 600, P_RQ, rdev=0x0000157C) + RS), uart(P_RQ + RS), 0, 0x0000157C))
far52 = sec(D_FAR, 601, P_RQ, rdev=0xD74C4050)
T.append(('v10 nested E1 with a 0x52 far packet', 1,
          uart(sec(D_R1, 10, bytes([0xE1]) + struct.pack('<H', 0x157C) + bytes([0xB0, 0x05]) + far52) + RS),
          uart(bytes([0xE1]) + struct.pack('<H', 0x157C) + bytes([0xB0, 0x05]) + P_RQ + RS), 0, 0xD74C4050))
T.append(('v10 0x51 frame after it: relay_dev 0', 1, uart(sec(D_A, 400, pa) + RS), uart(pa + RS), 0, 0))
far52c = sec(D_FAR, 602, C5, rdev=0xD74C4050)
T.append(('v10 nested E2 with a 0x52 far C5', 1,
          uart(sec(D_R1, 11, bytes([0xE2]) + struct.pack('<H', 0x157C) + bytes([0xB0, 0x05]) + far52c) + RS),
          uart(C5 + RS), 0, 0xD74C4050))
T.append(('v10 relay_dev FFFFFFFF (anyone)', 1, uart(sec(D_FAR, 603, P_RQ, rdev=0xFFFFFFFF) + RS), uart(P_RQ + RS), 0, 0xFFFFFFFF))
tam = bytearray(sec(D_FAR, 604, P_RQ, rdev=0x0000157C)); tam[10] ^= 0x01     # relay_dev changed on the way
T.append(('v10 relay_dev tampered: MIC fails, dropped', 1, uart(bytes(tam) + RS), b'', 0))
# ---- node firmware V1.17 golden frames (firmware PC test harness), gateway RSSI -90 / SNR -5
GD = {}
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fw_golden_frames.py')).read(), GD)
for nm, u, pl, rd in GD['FRAMES']:
    T.append(('GOLDEN V1.17 ' + nm, 1, u, pl, 0, rd))
# ---- v11: relayed copy of a position first heard DIRECTLY -> sent on (bit 2 "via relay too"), once
def e1w(relayer, rctr, far, rid=0x157C, rs=bytes([0xB0, 0x05])):
    return uart(sec(relayer, rctr, bytes([0xE1]) + struct.pack('<H', rid) + rs + far) + RS)
def e1out(far_plain, rid=0x157C, rs=bytes([0xB0, 0x05])):
    return uart(bytes([0xE1]) + struct.pack('<H', rid) + rs + far_plain + RS)
P_U = pos(0x8203, 20, 410100200, 289800200, 0x02)
fu = sec(D_FAR, 700, P_U)
T.append(('v11 far node direct (ctr 700)', 1, uart(fu + RS), uart(P_U + RS), 0, 0, 0))
T.append(('v11 E1 copy of it = MERGE, sent on', 1, e1w(D_R1, 20, fu), e1out(P_U), 0, 0, 1))
T.append(('v11 same via 2nd relayer = dup (once)', 1, e1w(D_R2, 20, fu, 0x1764, bytes([0xA8, 0x02])), b'', 0))
P_V = pos(0x8203, 21, 410100300, 289800300, 0x02)
fv = sec(D_FAR, 701, P_V)
T.append(('v11 relayed first (ctr 701)', 1, e1w(D_R1, 21, fv), e1out(P_V), 0, 0, 0))
T.append(('v11 ... direct copy after = MERGE', 1, uart(fv + RS), uart(P_V + RS), 0, 0, 1))
T.append(('v11 ... 3rd copy (direct) = replay', 1, uart(fv + RS), b'', 0))
P_W = pos(0x8203, 22, 410100400, 289800400, 0x02)
fw = sec(D_FAR, 702, P_W); fx = sec(D_FAR, 703, P_U)
T.append(('v11 direct ctr 702', 1, uart(fw + RS), uart(P_W + RS), 0))
T.append(('v11 direct ctr 703', 1, uart(fx + RS), uart(P_U + RS), 0))
T.append(('v11 E1 copy of 702 (not newest) = dup', 1, e1w(D_R1, 22, fw), b'', 0))
fc = sec(D_FAR, 704, C5)
T.append(('v11 direct C5 (ctr 704)', 1, uart(fc + RS), uart(C5 + RS), 0))
T.append(('v11 E2 copy of a command = dup', 1,
          uart(sec(D_R1, 23, bytes([0xE2]) + struct.pack('<H', 0x157C) + bytes([0xB0, 0x05]) + fc) + RS), b'', 0))
P_X = pos(0x8203, 23, 410100500, 289800500, 0x02)
f52 = sec(D_FAR, 705, P_X, rdev=0x0000157C)
T.append(('v11 0x52 direct (ctr 705, relay_dev 157C)', 1, uart(f52 + RS), uart(P_X + RS), 0, 0x0000157C))
T.append(('v11 E1 copy of the 0x52 = MERGE', 1, e1w(D_R1, 24, f52), e1out(P_X), 0, 0x0000157C, 1))
out = ['// generated by gen_srx.py - do not edit', f'localparam NT = {len(T)};',
       'reg [7:0] TI [0:NT-1][0:79]; reg [7:0] TO [0:NT-1][0:79]; integer TIN [0:NT-1], TON [0:NT-1];',
       'reg TSO [0:NT-1]; reg TCUT [0:NT-1]; reg [8*48-1:0] TNAME [0:NT-1];',
       'reg TRC [0:NT-1]; reg [31:0] TRD [0:NT-1]; reg TUC [0:NT-1]; reg TUP [0:NT-1];', 'initial begin']
for i, t in enumerate(T):
    nm, so, ib, ob, ct = t[:5]
    rc, rd = (1, t[5]) if len(t) > 5 else (0, 0)
    uc, up = (1, t[6]) if len(t) > 6 else (0, 0)
    out.append(f"    TRC[{i}] = {rc}; TRD[{i}] = 32'h{rd:08x}; TUC[{i}] = {uc}; TUP[{i}] = {up};")
    assert len(ib) <= 80 and len(ob) <= 80
    out.append(f'    TNAME[{i}] = "{nm}"; TSO[{i}] = {so}; TCUT[{i}] = {ct}; TIN[{i}] = {len(ib)}; TON[{i}] = {len(ob)};')
    out.append('    ' + ' '.join(f"TI[{i}][{j}] = 8'h{b:02x};" for j, b in enumerate(ib)))
    if ob: out.append('    ' + ' '.join(f"TO[{i}][{j}] = 8'h{b:02x};" for j, b in enumerate(ob)))
out.append('end')
open(sys.argv[1], 'w', newline='\n').write('\n'.join(out) + '\n')
print(len(T), 'tests')
