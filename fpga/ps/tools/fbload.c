// fbload.c - copies a raw 1280x720 picture (4 bytes per pixel: Blue, Green, Red, unused) into the A.T.A.K. screen
// memory and starts the AXI VDMA read channel, so the picture appears on the Zybo's HDMI TX port.
// The screen memory (0x3F00_0000, reserved "no-map" in the device tree) cannot be written with dd: the kernel's
// /dev/mem write() only accepts normal RAM, but mmap() of /dev/mem works, so this program uses mmap.
// Usage (root):  fbload picture.raw        (the VDMA keeps showing the memory; later writes appear at once)
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#define VDMA_BASE 0x43000000u
#define FB_BASE   0x3F000000u
#define W 1280
#define H 720
#define BPP 4
#define FB_SIZE (W * H * BPP)

int main(int argc, char** argv)
{
    if (argc != 2) { fprintf(stderr, "usage: %s picture.raw\n", argv[0]); return 1; }
    int mem = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem < 0) { perror("/dev/mem"); return 1; }
    uint8_t* fb = mmap(NULL, FB_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mem, FB_BASE);
    volatile uint32_t* vdma = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, mem, VDMA_BASE);
    if (fb == MAP_FAILED || vdma == MAP_FAILED) { perror("mmap"); return 1; }

    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    size_t n = fread(fb, 1, FB_SIZE, f);
    fclose(f);
    printf("copied %zu bytes to screen memory 0x%08X\n", n, FB_BASE);

    vdma[0x00 / 4] = 0x4;                 // MM2S_VDMACR: reset
    usleep(1000);
    vdma[0x00 / 4] = 0x3;                 // run + circular mode
    vdma[0x5C / 4] = FB_BASE;             // MM2S_START_ADDRESS1
    vdma[0x58 / 4] = W * BPP;             // MM2S_FRMDLY_STRIDE
    vdma[0x54 / 4] = W * BPP;             // MM2S_HSIZE (bytes per line)
    vdma[0x50 / 4] = H;                   // MM2S_VSIZE: starts the transfer
    usleep(100000);
    printf("MM2S_VDMACR = 0x%08X   MM2S_VDMASR = 0x%08X   (status bit 0 = halted, bits 4..6 = errors)\n",
           vdma[0x00 / 4], vdma[0x04 / 4]);
    return 0;
}
