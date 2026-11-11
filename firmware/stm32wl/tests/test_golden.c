/* Golden frames (docs/protocol/golden/golden_frames.json): open every envelope with the firmware's
   AES-128-CCM and compare with the plaintext in the file; check the CRC-8 of the UART frames. */
#include <stdio.h>
#include <string.h>
#include "../SubGHz_Phy/App/lora_secure.h"
#include "golden_gen.h"
#define CHECK(c,msg) do{ if(c) printf("  OK   %s\n",msg); else { printf("  FAIL %s\n",msg); fails++; } }while(0)

static uint8_t Crc8(const uint8_t *p, int n)
{
  uint8_t c = 0;
  for (int i = 0; i < n; i++) {
    c ^= p[i];
    for (int b = 0; b < 8; b++) { c = (c & 0x80) ? (uint8_t)((c << 1) ^ 0x07) : (uint8_t)(c << 1); }
  }
  return c;
}

int main(void)
{
  int fails = 0;
  Aes_SetKey(GOLDEN_KEY);
  for (unsigned i = 0; i < GOLDEN_N; i++) {
    const GoldenFrame_t *g = &GOLDEN[i];
    int hl = (g->air[0] == 0x52) ? 13 : 9;
    uint8_t nonce[13];
    memcpy(nonce, &g->air[1], 8);            /* dev_id, counter */
    nonce[8] = (uint8_t)g->dir;
    memset(&nonce[9], 0, 4);
    int n = g->airLen - hl - 4;
    uint8_t out[64];
    char msg[96];
    int ok = (n == g->ptLen) && Ccm_Decrypt(nonce, g->air, (uint32_t)hl, &g->air[hl], out, (uint32_t)n, &g->air[hl + n]);
    snprintf(msg, sizeof msg, "%s: MIC ok", g->name);
    CHECK(ok, msg);
    snprintf(msg, sizeof msg, "%s: plaintext matches", g->name);
    CHECK(ok && memcmp(out, g->pt, (size_t)n) == 0, msg);
    if (g->uartLen) {
      snprintf(msg, sizeof msg, "%s: UART CRC-8", g->name);
      CHECK(g->uart[g->uartLen - 1] == Crc8(&g->uart[2], g->uartLen - 3), msg);
    }
  }
  printf(fails ? "HATA: %d test basarisiz\n" : "HEPSI GECTI\n", fails);
  return fails ? 1 : 0;
}
