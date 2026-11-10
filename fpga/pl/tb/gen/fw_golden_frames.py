# Golden frames from the node firmware test suite (firmware V1.16/V1.17, test key 00 01 .. 0f): (name, gateway frame in, expected plain frame out, chosen relayer). Used by gen_srx.py.
FRAMES = [
    ('1 direct 0x52', bytes.fromhex('aa 55 1f 52 55 ba c8 a3 05 00 00 00 01 00 00 a0 33 2b f5 23 54 fd b4 65 f3 74 f4 b6 64 d4 02 46 a6 fb 48'), bytes.fromhex('aa 55 0e 53 0f 04 9c a6 6d 18 00 bc 32 11 02 a6 fb 68'), 0xA0000001),
    ('2 relay_dev FFFFFFFF', bytes.fromhex('aa 55 1f 52 55 ba c8 a3 13 00 00 00 ff ff ff ff ff 72 42 43 bd a3 9c df 73 04 3a 2b 68 b7 0d d8 a6 fb f3'), bytes.fromhex('aa 55 0e 53 0f 11 2e ab 6d 18 00 bc 32 11 02 a6 fb 86'), 0xFFFFFFFF),
    ('3 nested E1 0x52', bytes.fromhex('aa 55 31 51 50 40 4c d7 05 00 00 00 25 97 0e bc 5b 84 c9 f6 56 fb 13 2c e4 f5 ff cd f1 bf d6 f8 03 ad 6b 3f f9 66 af dc 42 ba 03 e3 ef 8f f7 73 ea b2 a6 fb 00'), bytes.fromhex('aa 55 13 e1 64 17 ab fd 03 82 05 11 11 11 11 11 11 11 11 03 a6 fb 68'), 0xD74C4050),
    ('4 nested E2 0x52', bytes.fromhex('aa 55 34 51 50 40 4c d7 06 00 00 00 64 a3 9f 6f 00 40 cc 55 33 87 4d 36 91 69 c0 4b 0f ec 71 19 7d 69 00 78 34 e5 49 16 f0 b9 e1 00 44 ad 28 57 4c 57 5c 7b 9f a6 fb 37'), bytes.fromhex('aa 55 11 c5 03 82 fe ff 03 01 fe ff 40 00 00 00 00 00 a6 fb a4'), 0xD74C4050),
    ('x other node FFFFFFFF', bytes.fromhex('aa 55 1f 52 44 33 22 11 34 00 00 00 ff ff ff ff 9a 00 84 0b b0 ae a6 e0 a8 ac 0e f7 79 00 b7 c5 a6 fb 1e'), bytes.fromhex('aa 55 0e 03 82 06 11 11 11 11 11 11 11 11 03 a6 fb 5f'), 0xFFFFFFFF),
]
