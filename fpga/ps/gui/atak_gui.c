// atak_gui.c - A.T.A.K. admin screen on the Zybo's HDMI output (1280x720).
//
// Draws a map (pre-rendered from MBTiles by tools/mbtiles2map.py), the node positions from the PL location table, the
// markers / commands (0xC1) from the PL command FIFO and the PL counters. Delete requests (0xC2) from phones appear
// in a box on the map with Approve / Reject; the admin can also delete any marker directly (Delete in its details
// box). Every decision goes out as a 0xC3 ADMIN DECISION frame through the PL (atk_axi v4, ADMIN_DATA / ADMIN_CTRL).
// History panel = log of markers, delete requests, decisions and area alarms.
// Admin signals: right click on the map = "send signal" box (POI, hazard, rally, come here, hold here, check area; to
// all or to one node), sent as a 0xC1 with src 0xFFFE.
// Area (geofence): "Area" button, click 3..8 corners, Done. A live node that is outside on 2 position reports in a row
// raises an OUT OF AREA alarm here and gets a 0xC1 kind 7 GO BACK (dst = that node, lat/lon = a point just inside
// the area), repeated every 60 s while it stays outside. The area is kept in a file on the SD card.
// ACKs (0xC5, atk_axi v5): nodes answer admin 0xC1 commands with DELIVERED (node got it; only for commands to one
// node) and SEEN (user tapped OK / Find on the phone alert). Shown next to each admin command (1 tick = delivered,
// 2 ticks = seen). A command to one node with no DELIVERED within 5 s is sent again with the same msg_id (max 2 times).
// Single-hop mesh (atk_axi v6): a node the gateway cannot hear is relayed by a neighbour (0xE1). The node list shows
// "via XXXX", the details box both links (relay and gateway RSSI), the map a dashed line node - relayer. A node heard
// directly with flags bit 1 set asks for a relay (it is missing from the admin table on its side): "needs relay".
// Flags bit 2 = the gateway got this record via a relay (also without relay info): "via relay". Flags are never
// changed: the PL keeps the record raw and sends it back unchanged in the 0xD1 table (the node needs bit 2).
// Teams / join (atk_axi v7): the admin opens teams (Teams button; NATO names ALPHA..ZULU, each with a 4-digit join
// PIN). A device that is not set up sends a JOIN REQUEST 0xA1 (dev_id, team, number, PIN). Wrong PIN, closed team or
// a taken number are answered at once (0xA2 JOIN ANSWER); a good one waits in the JOIN REQUESTS box for Approve /
// Reject. Approved: address 0x8000 | team << 8 | number (ALPHA-2 = 8102), put into the PL whitelist BEFORE the A2
// goes out, A2 re-sent (same msg_id) until the node's DELIVERED arrives. A known device (same dev_id, same team, good
// PIN) gets its old address back without the admin. 3 wrong PINs from one dev_id lock that dev_id, 5 wrong PINs for
// one team within 10 min lock the team, both for 10 min (requests are then ignored). Joined addresses are shown as
// names ("ALPHA-2") everywhere. Teams + members are kept in a file on the SD card (teams.txt).
// Kick / leave (atk_axi v8): the admin kicks a member (Kick in its details box or in the team's member list, press
// twice): 0xA3 KICK (reason 1) to the node, re-sent until its DELIVERED (max 3 tries); then it leaves the whitelist
// and the PL location table (TBL_DELETE), so it is gone from the 0xD1 table too. A member that leaves by itself sends
// 0xA4 LEAVE: removed at once and answered with 0xA3 reason 2 (leave confirmed).
// Mouse first: wheel = zoom, drag = pan, click = select (marker or list row) / buttons, right click (or the Send
// button, then a click on the map) = send signal.
// Keys: arrows pan, + / - zoom, F fit, Esc close / cancel / clear selection, Q quit. Drawing an area: right click or
// Backspace = remove the last corner, Enter = Done.
//
//   sudo ./atak_gui /mnt/sd/map [/mnt/sd/admin_msg_id] [/mnt/sd/area.txt] [/mnt/sd/teams.txt]
//        map directory with map_z14.bin .. map_z17.bin; file that keeps the admin msg_id counter over reboots;
//        file that keeps the area (one "lat lon" per line, 1e-7 degrees)
//
// Hardware: PL server atk_axi v7 (v4..v6 also run, without joins / relay info / ACKs) at 0x4000_0000, screen memory 0x3F00_0000 (BGRX, 5120 bytes per line) read by the
// AXI VDMA at 0x4300_0000. The picture is built in a normal RAM buffer and only the 32-pixel blocks that changed are
// copied to the (uncached) screen memory.
// This program is the only reader of the command FIFO (it sets CMD_RD_COUNT) and the only sender of admin frames.
//
// Built with -DSIM it runs on a PC without hardware: fake nodes / markers / requests, and it writes the screen to a
// file:  ./gui_sim <map dir> [scene] [zoom steps]   scene: 0 plain, 1 marker selected, 2 after "Approve" on request 1
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "font.h"

#define W 1280
#define H 720
#define MAPW 960                     // map area: x 0..959, panel: x 960..1279
#define PX 960
#define FB_BASE 0x3F000000u
#define VDMA_BASE 0x43000000u
#define PL_BASE 0x40000000u
#define PL_ID 0x41544B0Cu            // v12 = v11 + SECURE_ONLY = 1 after power-up (plain frames dropped until atk_sec.sh init)
#define PL_ID_V11 0x41544B0Bu        // v11 = v10 + "any copy": direct + relayed copies merged, flags bit 7 (RELAY_UPG 0x0C8)
#define PL_ID_V10 0x41544B0Au        // v10 = v9 + relay choice: chosen relayer per entry (RDEV 0x240), via-relay bit by the PL
#define PL_ID_V9 0x41544B09u         // v9 = v8 + security: AES-128-CCM secure envelope, replay window (SEC_CTRL 0x088)
#define PL_ID_V8 0x41544B08u         // v8 = v7 + TBL_DELETE (remove a node from the table), 0xA4 LEAVE as a command
#define PL_ID_V7 0x41544B07u         // v7 = v6 + join requests 0xA1 in the command FIFO (JOINS_OK / JOINS_LIMITED)
#define PL_ID_V6 0x41544B06u         // v6 = v5 + relayed positions (VIA words at 0x200)
#define PL_ID_V5 0x41544B05u         // v5 = v4 + 0xC5 ACKs in the command FIFO
#define PL_ID_V4 0x41544B04u
#define FLAG_WANT_RELAY 0x02         // pos flags bit 1: the node does not see itself in the 0xD1 table
#define FLAG_VIA_RELAY 0x04          // pos flags bit 2: this record arrived via a relay (set by the PL since v10)
#define FLAG_DIRECT 0x80             // pos flags bit 7: a direct copy of this seq arrived (set by the PL since v11)
#define GWQ(f) (((f) >> 3) & 15)     // pos flags bits 3..6: the node's own link to the gateway, 0 = none (v10 nodes)
#define FIFO_DEPTH 64
#define HIST 512                     // events kept in RAM
#define DUP_S 60                     // same type + src + msg_id within 60 s = a duplicate (only counted)
#define ADMIN_ADDR 0xFFFE
#define REQ_TIMEOUT_S 60             // the phone gives up waiting after 60 s (a late decision still goes out)
#define SEND_GAP_MS 1000             // at most one admin frame per second
#define AREA_MAX 8                   // corners of the area
#define AREA_REPORTS 2               // position reports in a row needed to change outside <-> inside
#define REMIND_S 60                  // GO BACK repeated this often while a node stays outside
#define KIND_GOBACK 7                // 0xC1 kind sent to a node that left the area
#define INSET_E7 1800                // the GO BACK point is ~20 m inside the area border (1e-7 degrees)
#define ACK_RETRY_S 5                // no DELIVERED from the target node after 5 s: send the command again
#define ACK_TRIES 3                  // first send + 2 re-sends (same msg_id)
#define ACK_NODES 8                  // nodes whose ACKs are kept per command
#define TEAMS 26                     // ALPHA .. ZULU (team 1..26)
#define MEMBERS 64                   // joined devices kept (the PL whitelist has 64 entries)
#define KIND_JOIN 0x20               // kind of a sent 0xA2 in the ACK table (not a 0xC1 kind)
#define KIND_KICK 0x21               // kind of a sent 0xA3 KICK in the ACK table
#define LOCK_S 600                   // wrong-PIN lock time
#define DEV_BAD_MAX 3                // wrong PINs from one dev_id -> that dev_id is locked
#define TEAM_BAD_MAX 5               // wrong PINs for one team within LOCK_S -> the team is locked
#define JOIN_BOX_MAX 3               // join requests shown in the box

// ---------------------------------------------------------------- colours 0xRRGGBB (memory order B G R X)
// tactical theme: near-black green panels, phosphor-green headings, amber selection, blue = own nodes (friendly)
#define C_BG       0x090D0A          // outside the map
#define C_PANEL    0x0E1410
#define C_HEAD     0x060907
#define C_TEXT     0xD6E2D8
#define C_DIM      0x7E9383
#define C_LINE     0x2B3A30
#define C_WHITE    0xFFFFFF          // bright text / symbol on a filled colour
#define C_BOX      0x111913          // box and label backgrounds
#define C_ACC      0x5CF08A          // headings, grid (phosphor green)
#define C_ORANGE   0xFFA726          // warning text
#define C_SELROW   0x2B2810          // selected row
#define C_STAT     0x0A0F0C          // status area
#define C_NODE     0x2196F3          // own node (friendly blue)
#define C_STALE    0x5E6B62
#define C_POI      0x1E88E5          // blue
#define C_HAZARD   0xE53935          // red
#define C_RALLY    0x43A047          // green
#define C_CMD      0xFB8C00          // orange: come here / hold here / check area
#define C_SEL      0xFFC107          // selection (amber)
#define C_HOVER    0x1C2B22
#define C_OK       0x2E7D32          // approve / live
#define C_BAD      0xC62828          // reject / delete
#define C_WARN     0xF9A825          // pending request
#define C_AREA     0x26C6DA          // the area (cyan)

static uint32_t bb[W * H];           // the scene: everything except the cursor overlay (redrawn when needed)
static uint32_t ob[W * H];           // what goes to the screen: the scene + the overlay (cursor, coordinates)
static uint32_t mapc[W * H];         // map layer cache (columns 0..MAPW-1): redrawn only when the view changes
static uint32_t *tgt = bb;           // where the drawing functions draw
static uint32_t shown[W * H];        // what is in the screen memory now
static volatile uint32_t *fb, *vdma, *pl;

// ---------------------------------------------------------------- drawing
static inline void blend(uint32_t *p, uint32_t c, int a)
{
    if (a <= 0) return;
    if (a >= 255) { *p = c; return; }
    uint32_t d = *p;
    uint32_t rb = ((c & 0xFF00FF) * a + (d & 0xFF00FF) * (255 - a)) >> 8;
    uint32_t g = ((c & 0x00FF00) * a + (d & 0x00FF00) * (255 - a)) >> 8;
    *p = (rb & 0xFF00FF) | (g & 0x00FF00);
}

static void fill_rect(int x, int y, int w, int h, uint32_t c, int a)
{
    int x1 = x + w, y1 = y + h;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x1 > W) x1 = W;
    if (y1 > H) y1 = H;
    for (int j = y; j < y1; j++)
        for (int i = x; i < x1; i++) blend(&tgt[j * W + i], c, a);
}

static void frame_rect(int x, int y, int w, int h, uint32_t c, int a)
{
    fill_rect(x, y, w, 1, c, a);
    fill_rect(x, y + h - 1, w, 1, c, a);
    fill_rect(x, y + 1, 1, h - 2, c, a);
    fill_rect(x + w - 1, y + 1, 1, h - 2, c, a);
}

// anti-aliased filled circle (ring if inner > 0)
static void circle(double cx, double cy, double r, double inner, uint32_t c, int a)
{
    int x0 = (int)floor(cx - r - 1), x1 = (int)ceil(cx + r + 1), y0 = (int)floor(cy - r - 1), y1 = (int)ceil(cy + r + 1);
    for (int y = y0; y <= y1; y++) {
        if (y < 0 || y >= H) continue;
        for (int x = x0; x <= x1; x++) {
            if (x < 0 || x >= W) continue;
            double d = hypot(x + 0.5 - cx, y + 0.5 - cy);
            double cov = r + 0.5 - d;
            if (inner > 0) { double ci = d - inner + 0.5; if (ci < cov) cov = ci; }
            if (cov <= 0) continue;
            if (cov > 1) cov = 1;
            blend(&tgt[y * W + x], c, (int)(a * cov));
        }
    }
}

// anti-aliased convex polygon, points clockwise on screen
static void polygon(const double *px, const double *py, int n, uint32_t c, int a)
{
    double minx = 1e9, maxx = -1e9, miny = 1e9, maxy = -1e9;
    for (int i = 0; i < n; i++) {
        if (px[i] < minx) minx = px[i];
        if (px[i] > maxx) maxx = px[i];
        if (py[i] < miny) miny = py[i];
        if (py[i] > maxy) maxy = py[i];
    }
    for (int y = (int)floor(miny) - 1; y <= (int)ceil(maxy) + 1; y++) {
        if (y < 0 || y >= H) continue;
        for (int x = (int)floor(minx) - 1; x <= (int)ceil(maxx) + 1; x++) {
            if (x < 0 || x >= W) continue;
            double mind = 1e9;
            for (int i = 0; i < n; i++) {
                int k = (i + 1) % n;
                double ex = px[k] - px[i], ey = py[k] - py[i], len = hypot(ex, ey);
                double d = -((x + 0.5 - px[i]) * ey - (y + 0.5 - py[i]) * ex) / len;   // > 0 inside (clockwise)
                if (d < mind) mind = d;
            }
            double cov = mind + 0.5;
            if (cov <= 0) continue;
            if (cov > 1) cov = 1;
            blend(&tgt[y * W + x], c, (int)(a * cov));
        }
    }
}

// anti-aliased line, w pixels wide, clipped to the map area. One short span per step along the longer axis, so a
// line across the whole screen stays cheap.
static void line(double x0, double y0, double x1, double y1, double w, uint32_t c, int a)
{
    double t0 = 0, t1 = 1, dx = x1 - x0, dy = y1 - y0, m = w + 2;
    double p[4] = { -dx, dx, -dy, dy }, q[4] = { x0 + m, MAPW - 1 + m - x0, y0 + m, H - 1 + m - y0 };
    for (int i = 0; i < 4; i++) {                              // Liang-Barsky clip to the map (+ margin)
        if (p[i] == 0) { if (q[i] < 0) return; continue; }
        double r = q[i] / p[i];
        if (p[i] < 0) { if (r > t1) return; if (r > t0) t0 = r; }
        else { if (r < t0) return; if (r < t1) t1 = r; }
    }
    double ax = x0 + t0 * dx, ay = y0 + t0 * dy, bx = x0 + t1 * dx, by = y0 + t1 * dy;
    double len = hypot(dx, dy);
    if (len < 0.01) return;
    int steep = fabs(dy) > fabs(dx);
    if (steep) { double t = ax; ax = ay; ay = t; t = bx; bx = by; by = t; }
    if (ax > bx) { double t = ax; ax = bx; bx = t; t = ay; ay = by; by = t; }
    double slope = bx > ax ? (by - ay) / (bx - ax) : 0;
    double hw = w / 2 * len / (steep ? fabs(dy) : fabs(dx));  // half span measured along the short axis
    for (int u = (int)floor(ax); u <= (int)ceil(bx); u++) {
        double v = ay + (u + 0.5 - ax) * slope;
        for (int k = (int)floor(v - hw - 1); k <= (int)ceil(v + hw + 1); k++) {
            double cov = hw + 0.5 - fabs(k + 0.5 - v);
            if (cov <= 0) continue;
            if (cov > 1) cov = 1;
            int x = steep ? k : u, y = steep ? u : k;
            if (x >= 0 && x < MAPW && y >= 0 && y < H) blend(&tgt[y * W + x], c, (int)(a * cov));
        }
    }
}

// any polygon (also concave or crossing itself: even-odd rule), filled without anti-aliasing, clipped to the map
static void fill_poly(const double *px, const double *py, int n, uint32_t c, int a)
{
    double miny = 1e9, maxy = -1e9, xs[16];
    for (int i = 0; i < n; i++) {
        if (py[i] < miny) miny = py[i];
        if (py[i] > maxy) maxy = py[i];
    }
    int y0 = miny < 0 ? 0 : (int)miny, y1 = maxy > H - 1 ? H - 1 : (int)maxy;
    for (int y = y0; y <= y1; y++) {
        double yc = y + 0.5;
        int nx = 0;
        for (int i = 0, j = n - 1; i < n && nx < 16; j = i++)
            if ((py[i] <= yc) != (py[j] <= yc)) xs[nx++] = px[i] + (yc - py[i]) * (px[j] - px[i]) / (py[j] - py[i]);
        for (int i = 1; i < nx; i++)                               // insertion sort, nx <= 16
            for (int k = i; k > 0 && xs[k] < xs[k - 1]; k--) { double t = xs[k]; xs[k] = xs[k - 1]; xs[k - 1] = t; }
        for (int i = 0; i + 1 < nx; i += 2) {
            int xa = (int)ceil(xs[i] - 0.5), xb = (int)ceil(xs[i + 1] - 0.5);
            if (xa < 0) xa = 0;
            if (xb > MAPW) xb = MAPW;
            for (int x = xa; x < xb; x++) blend(&tgt[y * W + x], c, a);
        }
    }
}

static int text(const struct font *f, int x, int y, uint32_t c, int a, const char *s)
{
    for (; *s; s++) {
        unsigned char ch = (unsigned char)*s;
        int g = ch == 0xA9 ? 95 : (ch >= 32 && ch < 127 ? ch - 32 : '?' - 32);
        const unsigned char *bits = f->bits + g * f->w * f->h;
        for (int j = 0; j < f->h; j++) {
            int yy = y + j;
            if (yy < 0 || yy >= H) continue;
            for (int i = 0; i < f->w; i++) {
                int xx = x + i;
                if (xx < 0 || xx >= W) continue;
                int v = bits[j * f->w + i];
                if (v) blend(&tgt[yy * W + xx], c, v * a / 255);
            }
        }
        x += f->w;
    }
    return x;
}

static int textf(const struct font *f, int x, int y, uint32_t c, const char *fmt, ...)
{
    char s[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s, sizeof s, fmt, ap);
    va_end(ap);
    return text(f, x, y, c, 255, s);
}

static void text_right(const struct font *f, int xr, int y, uint32_t c, const char *s)
{
    text(f, xr - (int)strlen(s) * f->w, y, c, 255, s);
}

// ---------------------------------------------------------------- click zones (rebuilt on every draw)
// arg = a node index, or the sequence number of an event (stable even if new events arrive before the click)
enum { A_ZOOM_IN = 1, A_ZOOM_OUT, A_FIT, A_APPROVE, A_REJECT, A_REQ, A_DELETE, A_NODE, A_EV,
       A_AREA, A_AREA_UNDO, A_AREA_DONE, A_AREA_CANCEL, A_AREA_REDRAW, A_AREA_REMOVE, A_AREA_CLOSE,
       A_SEND, A_SEND_CANCEL, A_SIG_TO, A_SIG_KIND, A_SIG_CLOSE, A_BOX,
       A_TEAMS, A_TEAM_OPEN, A_TEAM_PIN, A_TEAM_CLOSE, A_JOIN_OK, A_JOIN_NO, A_KICK, A_TEAM_MEMBERS, A_TEAM_BACK,
       A_SEC_TX, A_SEC_ONLY, A_NIGHT };
struct zone { int x, y, w, h, action, arg; };
static struct zone zones[128];
static int nzones;
static int mx = MAPW / 2, my = H / 2;            // mouse

static void add_zone(int x, int y, int w, int h, int action, int arg)
{
    if (nzones < 128) zones[nzones++] = (struct zone){ x, y, w, h, action, arg };
}
static int hover(int x, int y, int w, int h) { return mx >= x && mx < x + w && my >= y && my < y + h; }

// a button: filled (fg on bg) or outlined; registers its click zone
static void button(int x, int y, int w, int h, const char *label, uint32_t fg, uint32_t bg, int filled, int action, int arg)
{
    int hov = hover(x, y, w, h);
    if (filled) fill_rect(x, y, w, h, bg, hov ? 200 : 255);
    else {
        fill_rect(x, y, w, h, hov ? C_HOVER : C_BOX, 240);
        frame_rect(x, y, w, h, bg, 255);
    }
    const struct font *f = strlen(label) > 1 ? &font_b : &font_l;
    text(f, x + (w - (int)strlen(label) * f->w) / 2, y + (h - f->h) / 2, fg, 255, label);
    add_zone(x, y, w, h, action, arg);
}

// ---------------------------------------------------------------- map
struct mapz { int z, x0, y0, w, h; const uint32_t *px; };
static struct mapz maps[8];
static int nmaps, zi;                // zi = index of the zoom level shown
static double cx, cy;                // map centre, global pixel at maps[zi].z
static void to_geo(double sx, double sy, int32_t *lat, int32_t *lon);
static void to_screen(int32_t lat, int32_t lon, double *sx, double *sy);

static void load_maps(const char *dir)
{
    for (int z = 10; z <= 19 && nmaps < 8; z++) {
        char p[512];
        snprintf(p, sizeof p, "%s/map_z%d.bin", dir, z);
        int fd = open(p, O_RDONLY);
        if (fd < 0) continue;
        struct stat st;
        fstat(fd, &st);
        uint32_t *m = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);   // read from the SD card on demand
        close(fd);
        if (m == MAP_FAILED || memcmp(m, "ATKM", 4)) { fprintf(stderr, "%s: not a map file\n", p); continue; }
        struct mapz *mz = &maps[nmaps++];
        mz->z = m[1]; mz->x0 = m[2]; mz->y0 = m[3]; mz->w = m[4]; mz->h = m[5]; mz->px = m + 8;
        printf("map z%d: %dx%d px\n", mz->z, mz->w, mz->h);
    }
}

static void geo2px(double lat, double lon, int z, double *x, double *y)
{
    double n = 256.0 * (1 << z), r = lat * M_PI / 180;
    *x = (lon + 180.0) / 360.0 * n;
    *y = (1 - log(tan(r) + 1 / cos(r)) / M_PI) / 2 * n;
}

static void clamp_view(void)
{
    struct mapz *m = &maps[zi];
    double lo = m->x0 + MAPW / 2.0, hi = m->x0 + m->w - MAPW / 2.0;
    cx = lo > hi ? m->x0 + m->w / 2.0 : (cx < lo ? lo : cx > hi ? hi : cx);
    lo = m->y0 + H / 2.0; hi = m->y0 + m->h - H / 2.0;
    cy = lo > hi ? m->y0 + m->h / 2.0 : (cy < lo ? lo : cy > hi ? hi : cy);
}

// screen position of lat/lon (1e-7 degrees)
static void to_screen(int32_t lat, int32_t lon, double *sx, double *sy)
{
    double x, y;
    geo2px(lat * 1e-7, lon * 1e-7, maps[zi].z, &x, &y);
    *sx = x - cx + MAPW / 2.0;
    *sy = y - cy + H / 2.0;
}

// lat/lon (1e-7 degrees) under screen position (sx, sy)
static void to_geo(double sx, double sy, int32_t *lat, int32_t *lon)
{
    double n = 256.0 * (1 << maps[zi].z);
    double x = cx + sx - MAPW / 2.0, y = cy + sy - H / 2.0;
    *lon = (int32_t)llround((x / n * 360.0 - 180.0) * 1e7);
    *lat = (int32_t)llround(atan(sinh(M_PI * (1 - 2 * y / n))) * 180 / M_PI * 1e7);
}

static void center_on(int32_t lat, int32_t lon)
{
    geo2px(lat * 1e-7, lon * 1e-7, maps[zi].z, &cx, &cy);
    clamp_view();
}

// zoom one level in (+1) or out (-1), keeping the map point under screen position (sx, sy) in place
static void zoom(int dir, int sx, int sy)
{
    int nz = zi + dir;
    if (nz < 0 || nz >= nmaps) return;
    double f = ldexp(1.0, maps[nz].z - maps[zi].z);
    double gx = cx + sx - MAPW / 2.0, gy = cy + sy - H / 2.0;
    cx = gx * f - (sx - MAPW / 2.0);
    cy = gy * f - (sy - H / 2.0);
    zi = nz;
    clamp_view();
}

// night map (tactical): luminance stretched so the roads stay brightest, then a dark green tint
static int night = 1;
static uint8_t nlut[256];
static void night_lut(void)
{
    for (int l = 0; l < 256; l++) { int v = (l - 200) * 255 / 55; nlut[l] = v < 0 ? 0 : v > 255 ? 255 : v; }
}
static inline uint32_t night_px(uint32_t c)
{
    uint32_t r = c >> 16 & 255, g = c >> 8 & 255, b = c & 255, v = nlut[(77 * r + 150 * g + 29 * b) >> 8];
    return ((r * 20 + v * 50) >> 8) << 16 | ((g * 20 + v * 120) >> 8) << 8 | ((b * 20 + v * 70) >> 8);
}

// grid step (degrees) so that the lines are at least 110 px apart at this zoom
static double grid_step(void)
{
    static const double st[] = { 0.0001, 0.0002, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1 };
    double pxdeg = 256.0 * (1 << maps[zi].z) / 360.0;
    for (int i = 0; i < 13; i++) if (st[i] * pxdeg >= 110) return st[i];
    return 1;
}

static void render_map_cache(void)
{
    static double c_cx = -1, c_cy = -1;
    static int c_zi = -1, c_night = -1;
    if (c_cx == cx && c_cy == cy && c_zi == zi && c_night == night) return;
    c_cx = cx; c_cy = cy; c_zi = zi; c_night = night;
    struct mapz *m = &maps[zi];
    int ox = (int)floor(cx) - MAPW / 2, oy = (int)floor(cy) - H / 2;
    uint32_t bg = night ? 0x050806 : C_BG;
    for (int y = 0; y < H; y++) {
        uint32_t *d = mapc + y * W;
        int my_ = oy + y - m->y0;
        if (my_ < 0 || my_ >= m->h) { for (int x = 0; x < MAPW; x++) d[x] = bg; continue; }
        const uint32_t *src = m->px + (size_t)my_ * m->w;
        int xa = m->x0 - ox, xb = m->x0 + m->w - ox;            // columns with map pixels: xa .. xb-1
        if (xa < 0) xa = 0;
        if (xb > MAPW) xb = MAPW;
        for (int x = 0; x < xa; x++) d[x] = bg;
        for (int x = xb > xa ? xb : xa; x < MAPW; x++) d[x] = bg;
        if (xb <= xa) continue;
        const uint32_t *sp = src + (ox + xa - m->x0);
        if (night) for (int x = xa; x < xb; x++) d[x] = night_px(*sp++);
        else memcpy(d + xa, sp, (size_t)(xb - xa) * 4);
    }
    // coordinate grid with labels (lon along the top, lat on the right)
    uint32_t *save = tgt;
    tgt = mapc;
    double step = grid_step();
    int dec = step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : step >= 0.001 ? 3 : 4;
    int32_t la0, lo0, la1, lo1;
    to_geo(0, 0, &la0, &lo0);
    to_geo(MAPW, H, &la1, &lo1);
    uint32_t gc = night ? C_ACC : 0x1B5E20;
    char l[24];
    for (double lo = ceil(lo0 * 1e-7 / step) * step; lo <= lo1 * 1e-7; lo += step) {
        double sx, sy;
        to_screen(la0, (int32_t)llround(lo * 1e7), &sx, &sy);
        fill_rect((int)sx, 0, 1, H, gc, 45);
        snprintf(l, sizeof l, "%.*f%c", dec, fabs(lo), lo < 0 ? 'W' : 'E');
        text(&font_s, (int)sx + 3, 3, gc, 170, l);
    }
    for (double la = ceil(la1 * 1e-7 / step) * step; la <= la0 * 1e-7; la += step) {
        double sx, sy;
        to_screen((int32_t)llround(la * 1e7), lo0, &sx, &sy);
        fill_rect(0, (int)sy, MAPW, 1, gc, 45);
        snprintf(l, sizeof l, "%.*f%c", dec, fabs(la), la < 0 ? 'S' : 'N');
        text(&font_s, MAPW - (int)strlen(l) * font_s.w - 4, (int)sy - font_s.h - 1, gc, 170, l);
    }
    tgt = save;
}

static void draw_map(void)
{
    render_map_cache();
    for (int y = 0; y < H; y++) memcpy(bb + y * W, mapc + y * W, MAPW * 4);
}

// scale bar (bottom left of the map): the longest round distance up to 120 px
static void draw_scale(void)
{
    int32_t la, lo;
    to_geo(MAPW / 2, H / 2, &la, &lo);
    double mpp = 156543.03392 * cos(la * 1e-7 * M_PI / 180) / (1 << maps[zi].z);   // metres per pixel
    static const int d[] = { 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000 };
    int k = 0;
    while (k < 11 && d[k + 1] / mpp <= 120) k++;
    int w = (int)(d[k] / mpp + 0.5), x = 10, y = H - 22;
    char l[16];
    if (d[k] >= 1000) snprintf(l, sizeof l, "%d km", d[k] / 1000); else snprintf(l, sizeof l, "%d m", d[k]);
    fill_rect(x - 4, y - 4, w + 8 + 8 + (int)strlen(l) * font_s.w, 20, C_BOX, 200);
    fill_rect(x, y + 6, w, 2, C_ACC, 255);
    fill_rect(x, y + 1, 1, 7, C_ACC, 255);
    fill_rect(x + w - 1, y + 1, 1, 7, C_ACC, 255);
    text(&font_s, x + w + 8, y, C_TEXT, 255, l);
}

// ---------------------------------------------------------------- data
struct node { uint16_t addr; uint8_t seq, flags; int32_t lat, lon; int8_t rssi, snr; uint16_t age; int fresh;
              uint16_t via; int8_t via_rssi, via_snr;     // via = relayer (0 = heard directly); rssi / snr = last hop
              uint32_t rdev; };                           // v10: the relayer the node CHOSE (dev_id), 0 = none

// one history event. MARK = a 0xC1 marker / command (from a phone, or src 0xFFFE = sent by this GUI), REQ = a 0xC2
// delete request, DEC = a 0xC3 decision we sent, AREA = a node left (kind 1) / came back into (kind 2) the area
enum { EV_MARK = 1, EV_REQ, EV_DEC, EV_AREA, EV_JOIN };
// EV_JOIN state: what happened to a join request (or a lock it caused)
enum { J_WAIT = 0, J_OK, J_REJ, J_PIN, J_TAKEN, J_CLOSED, J_REJOIN, J_FULL, J_TEAMLOCK, J_DEVLOCK, J_KICKED, J_LEFT };
enum { REQ_PENDING = 0, REQ_APPROVED = 1, REQ_REJECTED = 2 };   // REQ state (= decision code on air)
struct ev {
    int type;
    uint32_t seq, t;             // FIFO sequence number (MARK / REQ; sent by us: 0x80000000 | n; AREA: 0x40000000 | n),
                                 // NOW_S of arrival / send
    uint16_t src, dst;           // AREA: src = the node
    uint8_t id, kind;            // MARK: kind 1..6; DEC: kind = decision 1 / 2; AREA: id = msg_id of the last GO BACK
    int32_t lat, lon;            // MARK only
    int8_t rssi, snr;
    int dups;                    // AREA (left): GO BACK messages sent
    uint16_t tsrc;               // REQ / DEC: target marker (src, msg_id); DEC: rid = msg_id of the request
    uint8_t tid, rid;
    int state;                   // MARK: 1 = deleted; REQ: REQ_*; DEC: 0; JOIN: J_*
    uint32_t dev_id;             // JOIN: the device (CRC32 of its UID); id = req_seq, rid = msg_id of our 0xA2
    uint8_t team, num, fw_maj, fw_min, bat, pin_ok, known, kicked;   // JOIN: as requested (num 0 = any)
    uint16_t addr;               // JOIN: the address it gets / got (0 = none yet)
};

static const char *team_names[TEAMS + 1] = { "?", "ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO", "FOXTROT", "GOLF",
    "HOTEL", "INDIA", "JULIETT", "KILO", "LIMA", "MIKE", "NOVEMBER", "OSCAR", "PAPA", "QUEBEC", "ROMEO", "SIERRA",
    "TANGO", "UNIFORM", "VICTOR", "WHISKEY", "XRAY", "YANKEE", "ZULU" };

static int team_of(uint16_t a)                   // team 1..26 of a joined address (0x8000 | team << 8 | number), else 0
{
    int t = (a >> 8) & 0x7F, n = a & 0xFF;
    return (a & 0x8000) && a < 0xFF00 && t >= 1 && t <= TEAMS && n >= 1 && n <= 99 ? t : 0;
}

static const char *name_of(uint16_t a)           // "ALPHA-2" for a joined address, else "157C" (4 buffers in turn)
{
    static char b[4][16];
    static int k;
    char *s = b[k++ & 3];
    if (team_of(a)) snprintf(s, 16, "%s-%d", team_names[team_of(a)], a & 0xFF);
    else snprintf(s, 16, "%04X", a);
    return s;
}

struct member { uint32_t dev_id; uint16_t addr; };
static struct member members[MEMBERS];
static int nmembers;
static int find_member(uint32_t dev)
{
    for (int i = 0; i < nmembers; i++) if (members[i].dev_id == dev) return i;
    return -1;
}
static int find_member_addr(uint16_t a);
// v10: name of a chosen relayer (dev_id): its team name if it is a member, "ANY" for FFFFFFFF, else the dev_id
static const char *dev_name(uint32_t dev)
{
    static char b[2][24];
    static int k;
    k ^= 1;
    if (dev == 0xFFFFFFFFu) return "ANY";
    for (int m = 0; m < nmembers; m++)
        if (members[m].dev_id == dev) { snprintf(b[k], sizeof b[k], "%s", name_of(members[m].addr)); return b[k]; }
    snprintf(b[k], sizeof b[k], "dev %08X", dev);
    return b[k];
}
// 1 = the node is relayed by another node than the one it chose (only known when the relayer is a member)
static int relay_mismatch(const struct node *n)
{
    if (!n->via || !n->rdev || n->rdev == 0xFFFFFFFFu) return 0;
    int m = find_member_addr(n->via);
    return m >= 0 && members[m].dev_id != n->rdev;
}
static int find_member_addr(uint16_t a)
{
    for (int i = 0; i < nmembers; i++) if (members[i].addr == a) return i;
    return -1;
}

static struct node nodes[64];
static int nnodes;
static struct ev hist[HIST];     // newest first
static int nhist;
static uint32_t out_count, area_count;
static uint32_t now_s, stale_s, c_ok, c_addr, c_crc, c_frm, c_len, c_tmo, c_full, c_sent;
static uint32_t k_wr, k_ovf, k_ok, k_drop, k_dups, adm_sent, c_relays;
static uint32_t pl_id;                           // which atk_axi version runs (v4 .. v9)
static uint32_t k_joins, k_jlim, j_ignored;      // PL: joins passed / rate-limited; GUI: ignored while locked
// v9 security: SEC_CTRL (bit 0 SECURE_TX, bit 1 SECURE_ONLY) and the counters; c1_relayed = node marks re-broadcast
static uint32_t sec_ctrl, s_ok, s_pok, s_pdrop, s_mic, s_rpl, s_dup, s_sent, s_upg, c1_relayed;
static const char *sec_key_file = "/mnt/sd/atak_key", *sec_mode_file = "/mnt/sd/sec_mode";

// admin frames waiting to go out (one per second): 0xC3 decisions and 0xC1 signals / GO BACK messages
struct out { uint8_t type, kind, decision, tid, rid, again, again_id; uint16_t dst, tsrc; int32_t lat, lon;
             uint32_t dev_id, ev_seq; uint8_t team, num, result; uint8_t is_raw, raw[15]; };
                                                 // is_raw: send raw[] unchanged (a node's 0xC1 re-broadcast)
                                                 // again = 1: re-send of admin command again_id (same msg_id)
                                                 // 0xA2: dst = the address given (0 = none), result 0..4
static struct out dq[64];
static int dq_n;
static uint8_t admin_id;                         // msg_id of the next admin frame (0xC3 and 0xC1 share it)
static const char *admin_id_file = "/mnt/sd/admin_msg_id";

// admin 0xC1 commands we sent and the ACKs (0xC5) the nodes returned for them
struct ackn { uint16_t addr; uint8_t dlv, seen; int8_t r_dlv, r_seen; uint32_t t_dlv, t_seen; };
struct sent {
    uint8_t id, kind;
    uint16_t dst;
    int32_t lat, lon;
    uint32_t t, t_last;          // NOW_S of the first / the last send
    int tries;                   // how often it went out
    uint32_t ev_seq;             // history event it belongs to (marker, or the node's LEFT AREA event for GO BACK)
    uint32_t dev_id;             // KICK: the device
    int done;                    // KICK: whitelist + table entry removed
    int n;
    struct ackn a[ACK_NODES];
};
static struct sent sent[64];     // newest first
static int nsent;
static uint32_t a_ok, a_dup, a_unknown;          // ACKs counted / duplicates / for a command we do not know

static const char *kind_name(int k)
{
    static const char *n[] = { "?", "POI", "HAZARD", "RALLY", "COME HERE", "HOLD HERE", "CHECK AREA", "GO BACK" };
    return k >= 1 && k <= 7 ? n[k] : "?";
}
static uint32_t kind_color(int k)
{
    return k == 1 ? C_POI : k == 2 ? C_HAZARD : k == 3 ? C_RALLY : C_CMD;
}

static struct ev *add_event(const struct ev *e)
{
    if (nhist < HIST) nhist++;
    memmove(&hist[1], &hist[0], (nhist - 1) * sizeof hist[0]);
    hist[0] = *e;
    return &hist[0];
}

static int find_marker(uint16_t src, uint8_t id)  // newest marker with this key, or -1
{
    for (int i = 0; i < nhist; i++)
        if (hist[i].type == EV_MARK && hist[i].src == src && hist[i].id == id) return i;
    return -1;
}
static int find_seq(uint32_t seq)
{
    for (int i = 0; i < nhist; i++) if (hist[i].seq == seq) return i;
    return -1;
}
static int find_node(int addr)
{
    for (int i = 0; i < nnodes; i++) if (nodes[i].addr == addr) return i;
    return -1;
}

static struct sent *find_sent(uint8_t id)        // newest admin command with this msg_id
{
    for (int i = 0; i < nsent; i++) if (sent[i].id == id) return &sent[i];
    return NULL;
}
static struct ackn *find_ackn(struct sent *s, uint16_t addr)
{
    for (int i = 0; i < s->n; i++) if (s->a[i].addr == addr) return &s->a[i];
    return NULL;
}

// one 0xC5 from the FIFO: de-duplicated by (src, acked_msgid, kind); ack_seq is not used
static void on_ack(uint16_t src, uint8_t kind, uint16_t acked_src, uint8_t acked_id, int8_t rssi, uint32_t t)
{
    struct sent *s = acked_src == ADMIN_ADDR ? find_sent(acked_id) : NULL;
    if (!s || (kind != 1 && kind != 2)) { a_unknown++; return; }
    struct ackn *a = find_ackn(s, src);
    if (!a) {
        if (s->n == ACK_NODES) { a_unknown++; return; }
        a = &s->a[s->n++];
        *a = (struct ackn){ .addr = src };
    }
    if (kind == 1) {
        if (a->dlv) { a_dup++; return; }
        a->dlv = 1; a->r_dlv = rssi; a->t_dlv = t;
    } else {
        if (a->seen) { a_dup++; return; }
        a->seen = 1; a->r_seen = rssi; a->t_seen = t;
        if (!a->dlv) { a->dlv = 1; a->r_dlv = rssi; a->t_dlv = t; }  // seen implies delivered (its DELIVERED got lost)
    }
    a_ok++;
    printf("ACK %s from %04X for msg_id %u (%s to %04X), RSSI %d\n", kind == 1 ? "DELIVERED" : "SEEN", src, acked_id,
           s->kind == KIND_JOIN ? "JOIN ANSWER" : s->kind == KIND_KICK ? "KICK" : kind_name(s->kind), s->dst, rssi);
}

// ---------------------------------------------------------------- area (geofence)
static int32_t area_lat[AREA_MAX], area_lon[AREA_MAX];
static int area_n;                               // corners of the active area (0 = no area, else 3..AREA_MAX)
static const char *area_file = "/mnt/sd/area.txt";
// per node: position reports seen, outside / inside counts, alarm state
struct geo { uint16_t addr; uint8_t seq; int seen, outc, inc, outside, told; uint32_t t_out, t_told, ev_seq; };
static struct geo geo[64];
static int ngeo;

static struct geo *find_geo(uint16_t addr, int create)
{
    for (int i = 0; i < ngeo; i++) if (geo[i].addr == addr) return &geo[i];
    if (!create || ngeo == 64) return NULL;
    geo[ngeo] = (struct geo){ .addr = addr };
    return &geo[ngeo++];
}

static int in_area(int32_t lat, int32_t lon)     // even-odd rule; lat/lon used as flat x/y (areas are small)
{
    int in = 0;
    for (int i = 0, j = area_n - 1; i < area_n; j = i++) {
        double yi = area_lat[i], yj = area_lat[j], xi = area_lon[i], xj = area_lon[j];
        if ((yi > lat) != (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) in = !in;
    }
    return in;
}

// the GO BACK point: the nearest point of the area border, moved ~20 m towards the middle of the area
static void back_point(int32_t lat, int32_t lon, int32_t *rlat, int32_t *rlon)
{
    double k = cos(lat * 1e-7 * M_PI / 180), best = 1e30, qx = 0, qy = 0, mx_ = 0, my_ = 0;
    for (int i = 0; i < area_n; i++) {           // x = lon * cos(lat), so x and y have the same scale (metres)
        int j = (i + 1) % area_n;
        double ax = area_lon[i] * k, ay = area_lat[i], bx = area_lon[j] * k, by = area_lat[j];
        double px = lon * k, py = lat, dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
        double t = l2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0;
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        double x = ax + t * dx, y = ay + t * dy, d = (px - x) * (px - x) + (py - y) * (py - y);
        if (d < best) { best = d; qx = x; qy = y; }
        mx_ += ax / area_n; my_ += ay / area_n;
    }
    double dx = mx_ - qx, dy = my_ - qy, d = hypot(dx, dy), ix = mx_, iy = my_;
    if (d > INSET_E7) { ix = qx + dx / d * INSET_E7; iy = qy + dy / d * INSET_E7; }
    if (!in_area((int32_t)llround(iy), (int32_t)llround(ix / k))) { ix = qx; iy = qy; }  // concave: keep the border
    *rlat = (int32_t)llround(iy);
    *rlon = (int32_t)llround(ix / k);
}

static void save_area(void)
{
    FILE *f = fopen(area_file, "w");
    if (!f) { printf("could not write %s\n", area_file); return; }
    for (int i = 0; i < area_n; i++) fprintf(f, "%d %d\n", area_lat[i], area_lon[i]);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    printf("area: %d corners saved to %s\n", area_n, area_file);
}

static void load_area(void)
{
    FILE *f = fopen(area_file, "r");
    int la, lo;
    area_n = 0;
    if (f) {
        while (area_n < AREA_MAX && fscanf(f, "%d %d", &la, &lo) == 2) { area_lat[area_n] = la; area_lon[area_n++] = lo; }
        fclose(f);
    }
    if (area_n < 3) area_n = 0;
    printf("area: %d corners (%s)\n", area_n, area_file);
}

#define R(off) pl[(off) / 4]

static void on_join(const uint8_t *b, int8_t rssi, int8_t snr, uint32_t t);
static void on_leave(uint16_t src, uint32_t dev);
static void kick_finish(struct sent *s);

static void poll_pl(void)
{
    now_s = R(0x038); stale_s = R(0x03C);
    c_ok = R(0x00C); c_addr = R(0x010); c_crc = R(0x014); c_frm = R(0x018);
    c_len = R(0x01C); c_tmo = R(0x020); c_full = R(0x024); c_sent = R(0x028);
    k_wr = R(0x04C); k_ovf = R(0x054); k_ok = R(0x058); k_drop = R(0x05C); adm_sent = R(0x074);
    c_relays = pl_id >= PL_ID_V6 ? R(0x078) : 0;
    if (pl_id >= PL_ID_V7) { k_joins = R(0x07C); k_jlim = R(0x080); }
    if (pl_id >= PL_ID_V9) {
        sec_ctrl = R(0x088) & 3;
        s_ok = R(0x0A0); s_pok = R(0x0A4); s_pdrop = R(0x0A8); s_mic = R(0x0AC); s_rpl = R(0x0B0); s_dup = R(0x0B4);
        s_sent = R(0x0BC);
        s_upg = pl_id >= PL_ID_V11 ? R(0x0C8) : 0;     // v11: relayed copies of direct positions
    }

    uint32_t n = R(0x008), fresh = R(0x048);
    if (n > 64) n = 64;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t o = 0x100 + 16 * i;
        uint32_t w0 = R(o), w1 = R(o + 4), w2 = R(o + 8), w3 = R(o + 12);   // word 0 first: consistent copy
        struct node *d = &nodes[i];
        d->addr = w0 & 0xFFFF; d->seq = w0 >> 16;
        d->lat = (int32_t)((w0 >> 24) | (w1 << 8));
        d->lon = (int32_t)((w1 >> 24) | (w2 << 8));
        d->flags = w2 >> 24;
        d->rssi = (int8_t)w3; d->snr = (int8_t)(w3 >> 8); d->age = w3 >> 16;
        d->fresh = i < 32 ? (fresh >> i) & 1 : 1;
        uint32_t v = pl_id >= PL_ID_V6 && i < 16 ? R(0x200 + 4 * i) : 0;
        d->via = v & 0xFFFF; d->via_rssi = (int8_t)(v >> 16); d->via_snr = (int8_t)(v >> 24);
        d->rdev = pl_id >= PL_ID_V10 && i < 16 ? R(0x240 + 4 * i) : 0;
    }
    nnodes = n;

    uint32_t wr = k_wr, rd = R(0x050);
    if (wr - rd > FIFO_DEPTH) rd = wr - FIFO_DEPTH;
    for (; rd != wr; rd++) {
        uint32_t o = 0x800 + 32 * (rd % FIFO_DEPTH);
        uint32_t w0 = R(o), w1 = R(o + 4), w2 = R(o + 8), w3 = R(o + 12), w4 = R(o + 16);
        struct ev e = { 0 };
        int type = w0 & 0xFF;
        e.t = R(o + 20); e.seq = R(o + 24);
        e.src = w0 >> 8; e.dst = (w0 >> 24) | ((w1 & 0xFF) << 8);
        e.id = w1 >> 8;
        e.rssi = (int8_t)w4; e.snr = (int8_t)(w4 >> 8);
        if (type == 0xC1) {
            e.type = EV_MARK;
            e.kind = w1 >> 16;
            e.lat = (int32_t)((w1 >> 24) | (w2 << 8));
            e.lon = (int32_t)((w2 >> 24) | (w3 << 8));
        } else if (type == 0xC2) {      // [7..8] target_src, [9] target_msg_id
            e.type = EV_REQ;
            e.tsrc = (w1 >> 24) | ((w2 & 0xFF) << 8);
            e.tid = w2 >> 8;
            e.state = REQ_PENDING;
        } else if (type == 0xC5) {      // [5] ack_seq, [6] kind, [7..8] acked_src, [9] acked_msg_id
            on_ack(e.src, w1 >> 16, (w1 >> 24) | ((w2 & 0xFF) << 8), w2 >> 8, e.rssi, e.t);
            continue;
        } else if (type == 0xA4) {      // a member leaves its team: [6..9] dev_id
            on_leave(e.src, (w1 >> 16) | (w2 << 16));
            continue;
        } else if (type == 0xA1) {      // join request: 17 bytes, byte 16 (battery) in word 7
            uint8_t b[17];
            uint32_t ww[4] = { w0, w1, w2, w3 };
            for (int j = 0; j < 16; j++) b[j] = ww[j / 4] >> (8 * (j % 4));
            b[16] = R(o + 28);
            on_join(b, e.rssi, e.snr, e.t);
            continue;
        } else
            continue;
        int dup = 0;
        for (int i = 0; i < nhist && hist[i].t + DUP_S > e.t; i++)
            if (hist[i].type == e.type && hist[i].src == e.src && hist[i].id == e.id) { hist[i].dups++; dup = 1; break; }
        if (dup) { k_dups++; continue; }
        add_event(&e);
        // v9, SECURE_TX on: the gateway cannot read the (encrypted) mark any more, so we send it on to everybody,
        // unchanged (same src / msg_id: the nodes dedupe it), first in the queue. Only new marks (not duplicates).
        if (e.type == EV_MARK && (sec_ctrl & 1) && e.src != ADMIN_ADDR && dq_n < 64) {
            struct out r = { .is_raw = 1, .type = 0xC1, .dst = e.dst, .kind = e.kind };
            uint32_t ww[4] = { w0, w1, w2, w3 };
            for (int j = 0; j < 15; j++) r.raw[j] = ww[j / 4] >> (8 * (j % 4));
            memmove(&dq[1], &dq[0], dq_n++ * sizeof dq[0]);
            dq[0] = r;
        }
    }
    R(0x050) = wr;
}

// ---------------------------------------------------------------- decisions
static void save_admin_id(void)
{
    FILE *f = fopen(admin_id_file, "w");
    if (!f) return;
    fprintf(f, "%u\n", admin_id);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
}

static void load_admin_id(void)
{
    FILE *f = fopen(admin_id_file, "r");
    unsigned v;
    if (f && fscanf(f, "%u", &v) == 1) admin_id = (uint8_t)v;
    else admin_id = (uint8_t)(time(NULL) ^ getpid());   // no file yet: start somewhere random
    if (f) fclose(f);
    printf("admin msg_id starts at %u (%s)\n", admin_id, admin_id_file);
}

static void queue_decision(uint16_t dst, uint8_t decision, uint16_t tsrc, uint8_t tid, uint8_t rid)
{
    if (dq_n < 64) dq[dq_n++] = (struct out){ .type = 0xC3, .dst = dst, .tsrc = tsrc, .decision = decision, .tid = tid, .rid = rid };
}

static void queue_signal(uint16_t dst, uint8_t kind, int32_t lat, int32_t lon)
{
    if (dq_n < 64) dq[dq_n++] = (struct out){ .type = 0xC1, .dst = dst, .kind = kind, .lat = lat, .lon = lon };
}

static int resend_queued(uint8_t id)
{
    for (int i = 0; i < dq_n; i++) if (dq[i].again && dq[i].again_id == id) return 1;
    return 0;
}

// commands to one node without a DELIVERED from it: send again (same msg_id) after ACK_RETRY_S, at most ACK_TRIES
static void check_acks(void)
{
    for (int i = 0; i < nsent; i++) {
        struct sent *s = &sent[i];
        if (s->kind == KIND_KICK) {              // DELIVERED, or all tries used: remove it now
            if (s->done) continue;
            struct ackn *a = find_ackn(s, s->dst);
            if ((a && (a->dlv || a->seen)) || (s->tries >= ACK_TRIES && now_s - s->t_last >= ACK_RETRY_S)) {
                kick_finish(s);
                continue;
            }
            if (now_s - s->t_last < ACK_RETRY_S || resend_queued(s->id)) continue;
            if (dq_n < 64) dq[dq_n++] = (struct out){ .type = 0xA3, .dst = s->dst, .dev_id = s->dev_id, .result = 1,
                                                      .again = 1, .again_id = s->id };
            continue;
        }
        if (s->dst == 0xFFFF || s->tries >= ACK_TRIES || now_s - s->t_last < ACK_RETRY_S) continue;
        struct ackn *a = find_ackn(s, s->dst);
        if (a && (a->dlv || a->seen)) continue;
        int newer = 0;                           // a newer command of the same kind to the same node replaces it
        for (int j = 0; j < i; j++) if (sent[j].dst == s->dst && sent[j].kind == s->kind) newer = 1;
        if (newer || resend_queued(s->id)) continue;
        if (s->kind == KIND_JOIN) {              // the A2 again while the device is still a member with that address
            int m = find_member_addr(s->dst);
            if (m < 0 || resend_queued(s->id)) continue;
            if (dq_n < 64) dq[dq_n++] = (struct out){ .type = 0xA2, .dst = s->dst, .dev_id = members[m].dev_id,
                                                      .team = (uint8_t)team_of(s->dst), .num = s->dst & 0xFF,
                                                      .again = 1, .again_id = s->id };
            continue;
        }
        if (s->kind == KIND_GOBACK) {            // only while the node is still outside the area
            struct geo *g = area_n ? find_geo(s->dst, 0) : NULL;
            if (!g || !g->outside) continue;
        } else {
            int e = find_seq(s->ev_seq);         // the admin deleted the marker: no point
            if (e < 0 || hist[e].state) continue;
        }
        if (dq_n < 64) dq[dq_n++] = (struct out){ .type = 0xC1, .dst = s->dst, .kind = s->kind, .lat = s->lat, .lon = s->lon,
                                                  .again = 1, .again_id = s->id };
    }
}

static int goback_queued(uint16_t addr)
{
    for (int i = 0; i < dq_n; i++) if (dq[i].type == 0xC1 && dq[i].kind == KIND_GOBACK && dq[i].dst == addr) return 1;
    return 0;
}

static void drop_gobacks(void)                   // the area was removed / redrawn: unsent GO BACKs are void
{
    int k = 0;
    for (int i = 0; i < dq_n; i++) if (!(dq[i].type == 0xC1 && dq[i].kind == KIND_GOBACK)) dq[k++] = dq[i];
    dq_n = k;
}

static uint32_t area_event(uint16_t addr, int what)   // what: 1 = left, 2 = back inside; returns its seq
{
    struct ev e = { 0 };
    e.type = EV_AREA; e.seq = 0x40000000u | area_count++; e.t = now_s; e.src = addr; e.kind = what;
    add_event(&e);
    printf("node %04X %s the area\n", addr, what == 1 ? "LEFT" : "is back in");
    return e.seq;
}

// called after every PL poll: new position reports move nodes outside / inside; GO BACK every REMIND_S while outside
static void check_area(void)
{
    if (!area_n) return;
    for (int i = 0; i < nnodes; i++) {
        struct node *n = &nodes[i];
        struct geo *g = find_geo(n->addr, 1);
        if (!g) continue;
        if (n->fresh && (!g->seen || n->seq != g->seq)) {    // a new report (a stale entry is an old position)
            g->seen = 1;
            g->seq = n->seq;
            if (in_area(n->lat, n->lon)) {
                g->outc = 0;
                if (g->outside && ++g->inc >= AREA_REPORTS) { g->outside = 0; area_event(n->addr, 2); }
            } else {
                g->inc = 0;
                if (!g->outside && ++g->outc >= AREA_REPORTS) {
                    g->outside = 1; g->told = 0; g->t_out = now_s; g->t_told = now_s - REMIND_S;
                    g->ev_seq = area_event(n->addr, 1);
                }
            }
        }
        if (g->outside && n->fresh && now_s - g->t_told >= REMIND_S && !goback_queued(n->addr)) {
            int32_t la, lo;
            back_point(n->lat, n->lon, &la, &lo);
            queue_signal(n->addr, KIND_GOBACK, la, lo);
            g->t_told = now_s;
        }
    }
}

static void set_area(const int32_t *lat, const int32_t *lon, int n)  // n = 0: remove the area
{
    for (int i = 0; i < n; i++) { area_lat[i] = lat[i]; area_lon[i] = lon[i]; }
    area_n = n;
    ngeo = 0;                                    // every node is judged again against the new area
    drop_gobacks();
    save_area();
}

// ---------------------------------------------------------------- teams and joins
struct team { int open; uint16_t pin; uint32_t lock_until; uint32_t bad_t[TEAM_BAD_MAX]; int bad_i; };
static struct team teams[TEAMS + 1];
struct devlock { uint32_t dev_id; int bad; uint32_t until; };
static struct devlock dlocks[32];
static int ndlocks;
static uint32_t join_n;                          // join events made (their seq = 0x20000000 | n)
static const char *teams_file = "/mnt/sd/teams.txt";

static void save_teams(void)
{
    FILE *f = fopen(teams_file, "w");
    if (!f) { printf("could not write %s\n", teams_file); return; }
    for (int t = 1; t <= TEAMS; t++) if (teams[t].open) fprintf(f, "team %d %04u\n", t, teams[t].pin);
    for (int i = 0; i < nmembers; i++) fprintf(f, "member %08X %04X\n", members[i].dev_id, members[i].addr);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
}

static void load_teams(void)
{
    FILE *f = fopen(teams_file, "r");
    char w[16];
    unsigned a, b;
    nmembers = 0;
    if (f) {
        while (fscanf(f, "%15s", w) == 1) {
            if (!strcmp(w, "team") && fscanf(f, "%u %u", &a, &b) == 2 && a >= 1 && a <= TEAMS) {
                teams[a].open = 1; teams[a].pin = b % 10000;
            } else if (!strcmp(w, "member") && fscanf(f, "%x %x", &a, &b) == 2 && team_of(b) && nmembers < MEMBERS)
                members[nmembers++] = (struct member){ a, (uint16_t)b };
        }
        fclose(f);
    }
    int open = 0;
    for (int t = 1; t <= TEAMS; t++) open += teams[t].open;
    printf("teams: %d open, %d members (%s)\n", open, nmembers, teams_file);
}

// whitelist entries (bit 16 = in use, bits 15..0 = address)
#ifdef SIM
static uint32_t sim_wl[64];
static uint32_t wl_get(int i) { return sim_wl[i]; }
static void wl_put(int i, uint32_t v) { sim_wl[i] = v; }
#else
static uint32_t wl_get(int i) { R(0x040) = i; return R(0x044); }
static void wl_put(int i, uint32_t v) { R(0x040) = i; R(0x044) = v; }
#endif
static int wl_add(uint16_t a)                    // returns 1 if a is in the PL whitelist now
{
    int fr = -1;
    for (int i = 0; i < 64; i++) {
        uint32_t v = wl_get(i);
        if (v & 0x10000) { if ((v & 0xFFFF) == a) return 1; }
        else if (fr < 0) fr = i;
    }
    if (fr < 0) { printf("whitelist full: %04X not added\n", a); return 0; }
    wl_put(fr, 0x10000 | a);
    printf("whitelist: %s (%04X) added in entry %d\n", name_of(a), a, fr);
    return 1;
}
static void wl_del(uint16_t a)
{
    for (int i = 0; i < 64; i++) { uint32_t v = wl_get(i); if ((v & 0x10000) && (v & 0xFFFF) == a) wl_put(i, 0); }
}
static void members_to_wl(void)                  // at start and every 10 s: atk_wl.sh restore does not know them
{
    if (pl_id < PL_ID_V7) return;
    for (int i = 0; i < nmembers; i++) wl_add(members[i].addr);
}

static int member_count(int t)
{
    int k = 0;
    for (int i = 0; i < nmembers; i++) k += team_of(members[i].addr) == t;
    return k;
}

// number for dev in team t: the wanted one if it is free (or this device's own), else the lowest free one; -1 = full
static int free_number(int t, int want, uint32_t dev)
{
    if (want >= 1 && want <= 99) {
        int m = find_member_addr(0x8000 | t << 8 | want);
        if (m < 0 || members[m].dev_id == dev) return want;
    }
    for (int n = 1; n <= 99; n++) {
        int m = find_member_addr(0x8000 | t << 8 | n);
        if (m < 0 || members[m].dev_id == dev) return n;
    }
    return -1;
}

static void queue_a2(uint32_t dev, uint16_t addr, int team, int num, int result, uint32_t ev_seq)
{
    if (dq_n < 64) dq[dq_n++] = (struct out){ .type = 0xA2, .dst = addr, .dev_id = dev, .team = (uint8_t)team,
                                              .num = (uint8_t)num, .result = (uint8_t)result, .ev_seq = ev_seq };
}

static struct ev *join_event(const struct ev *e)
{
    struct ev j = *e;
    j.type = EV_JOIN; j.seq = 0x20000000u | join_n++;
    return add_event(&j);
}

static struct devlock *find_dlock(uint32_t dev, int create)
{
    for (int i = 0; i < ndlocks; i++) if (dlocks[i].dev_id == dev) return &dlocks[i];
    if (!create) return NULL;
    if (ndlocks == 32) {                         // forget the oldest that is not locked now
        int k = 0;
        for (int i = 0; i < ndlocks; i++) if (dlocks[i].until <= now_s) { k = i; break; }
        dlocks[k] = dlocks[--ndlocks];
    }
    dlocks[ndlocks] = (struct devlock){ dev, 0, 0 };
    return &dlocks[ndlocks++];
}

static int team_locked(int t) { return t >= 1 && t <= TEAMS && teams[t].lock_until > now_s; }
static int dev_locked(uint32_t dev) { struct devlock *d = find_dlock(dev, 0); return d && d->until > now_s; }

static void bad_pin(uint32_t dev, int t, const struct ev *e)
{
    struct devlock *d = find_dlock(dev, 1);
    if (++d->bad >= DEV_BAD_MAX) {
        d->bad = 0; d->until = now_s + LOCK_S;
        struct ev l = *e; l.state = J_DEVLOCK;
        join_event(&l);
        printf("join: dev %08X locked for %d s (%d wrong PINs)\n", dev, LOCK_S, DEV_BAD_MAX);
    }
    struct team *tm = &teams[t];
    tm->bad_t[tm->bad_i++ % TEAM_BAD_MAX] = now_s;
    int n = 0;
    for (int i = 0; i < TEAM_BAD_MAX && i < tm->bad_i; i++) n += now_s - tm->bad_t[i] < LOCK_S;
    if (n >= TEAM_BAD_MAX && !team_locked(t)) {
        tm->lock_until = now_s + LOCK_S; tm->bad_i = 0;
        struct ev l = *e; l.state = J_TEAMLOCK;
        join_event(&l);
        printf("join: team %s locked for %d s (%d wrong PINs in %d s)\n", team_names[t], LOCK_S, TEAM_BAD_MAX, LOCK_S);
    }
}

static struct { uint32_t dev; uint16_t addr; } kicked_devs[32];   // kicked devices (newest last), shown on re-join
static int nkicked;
static int was_kicked(uint32_t dev)              // index or -1
{
    for (int i = nkicked - 1; i >= 0; i--) if (kicked_devs[i].dev == dev) return i;
    return -1;
}

static int find_join_wait(uint32_t dev)
{
    for (int i = 0; i < nhist; i++) if (hist[i].type == EV_JOIN && hist[i].state == J_WAIT && hist[i].dev_id == dev) return i;
    return -1;
}

// a 0xA1 from the FIFO. b = the 17 raw bytes: [5] req_seq, [6..9] dev_id, [10] team, [11] number, [12..13] PIN,
// [14] fw major, [15] fw minor, [16] battery %
static void on_join(const uint8_t *b, int8_t rssi, int8_t snr, uint32_t t)
{
    struct ev e = { 0 };
    e.dev_id = b[6] | b[7] << 8 | b[8] << 16 | (uint32_t)b[9] << 24;
    e.team = b[10]; e.num = b[11]; e.id = b[5]; e.fw_maj = b[14]; e.fw_min = b[15]; e.bat = b[16];
    e.rssi = rssi; e.snr = snr; e.t = t;
    unsigned pin = b[12] | b[13] << 8;
    int tm = e.team, m = find_member(e.dev_id);
    printf("JOIN REQUEST dev %08X as %s-%d PIN %04u fw %u.%u (req_seq %u)\n", e.dev_id,
           tm >= 1 && tm <= TEAMS ? team_names[tm] : "?", e.num, pin, e.fw_maj, e.fw_min, e.id);
    if (dev_locked(e.dev_id) || team_locked(tm)) { j_ignored++; printf("  ignored: locked\n"); return; }
    int w = find_join_wait(e.dev_id);            // the device repeats its request every ~10 s while it waits
    if (w >= 0) {
        struct ev *o = &hist[w];
        if (o->team == e.team && o->num == e.num && o->pin_ok == (tm <= TEAMS && pin == teams[tm].pin)) {
            o->dups++; o->rssi = rssi; o->snr = snr; o->id = e.id;
            return;
        }
        o->state = J_REJ;                        // changed request: the old one is replaced
    }
    if (tm < 1 || tm > TEAMS || !teams[tm].open) {
        e.state = J_CLOSED;
        struct ev *j = join_event(&e);
        queue_a2(e.dev_id, 0, tm, e.num, 2, j->seq);
        return;
    }
    e.pin_ok = pin == teams[tm].pin;
    e.known = m >= 0;
    e.kicked = was_kicked(e.dev_id) >= 0;   // never automatic: not a member any more, the admin decides
    int same = m >= 0 && team_of(members[m].addr) == tm && (!e.num || e.num == (members[m].addr & 0xFF));
    if (!e.pin_ok) {
        bad_pin(e.dev_id, tm, &e);
        if (same) {                              // known device, wrong PIN: the admin decides (it may be a copy)
            e.state = J_WAIT; e.addr = members[m].addr;
            join_event(&e);
            return;
        }
        e.state = J_PIN;
        struct ev *j = join_event(&e);
        queue_a2(e.dev_id, 0, tm, e.num, 1, j->seq);
        return;
    }
    if (same) {                                  // known device, good PIN: its old address again, no admin
        e.state = J_REJOIN; e.addr = members[m].addr;
        struct ev *j = join_event(&e);
        wl_add(e.addr);
        queue_a2(e.dev_id, e.addr, tm, e.addr & 0xFF, 0, j->seq);
        return;
    }
    int n = free_number(tm, e.num, e.dev_id);
    if (n < 0) {
        e.state = J_FULL;
        struct ev *j = join_event(&e);
        queue_a2(e.dev_id, 0, tm, e.num, 3, j->seq);
        return;
    }
    if (e.num && n != e.num) {                   // taken: suggest the lowest free number
        e.state = J_TAKEN; e.addr = 0x8000 | tm << 8 | n;
        struct ev *j = join_event(&e);
        queue_a2(e.dev_id, 0, tm, n, 4, j->seq);
        return;
    }
    e.state = J_WAIT; e.addr = 0x8000 | tm << 8 | n;
    join_event(&e);
}

// Approve / Reject in the join box
static void join_decide(int i, int ok)
{
    struct ev *j = &hist[i];
    if (j->type != EV_JOIN || j->state != J_WAIT) return;
    int tm = j->team;
    if (!ok) { j->state = J_REJ; queue_a2(j->dev_id, 0, tm, j->num, 2, j->seq); return; }
    if (!teams[tm].open) { j->state = J_CLOSED; queue_a2(j->dev_id, 0, tm, j->num, 2, j->seq); return; }
    int n = j->addr & 0xFF;
    int o = find_member_addr(j->addr);
    if (o >= 0 && members[o].dev_id != j->dev_id) {   // taken while it waited
        n = free_number(tm, 0, j->dev_id);
        j->state = n < 0 ? J_FULL : J_TAKEN;
        if (n > 0) j->addr = 0x8000 | tm << 8 | n;
        queue_a2(j->dev_id, 0, tm, n < 0 ? j->num : n, n < 0 ? 3 : 4, j->seq);
        return;
    }
    int m = find_member(j->dev_id);              // a device that changes team / number loses the old address
    if (m >= 0 && members[m].addr != j->addr) { wl_del(members[m].addr); members[m] = members[--nmembers]; m = -1; }
    if (m < 0) {
        if (nmembers == MEMBERS) { printf("join: member list full\n"); return; }
        members[nmembers++] = (struct member){ j->dev_id, j->addr };
    }
    save_teams();
    if (!wl_add(j->addr)) return;                // whitelist full: the device could not send anything
    j->state = J_OK;
    queue_a2(j->dev_id, j->addr, tm, n, 0, j->seq);
}

static void team_new_pin(int t) { teams[t].pin = rand() % 10000; save_teams(); }
static void team_open_next(void)
{
    for (int t = 1; t <= TEAMS; t++)
        if (!teams[t].open) { teams[t].open = 1; teams[t].lock_until = 0; teams[t].bad_i = 0; team_new_pin(t); return; }
}

#ifdef SIM
static void sim_tbl_delete(uint16_t a);
#endif
static void tbl_delete(uint16_t a)               // the node leaves the PL location table (and so the 0xD1 table)
{
#ifdef SIM
    sim_tbl_delete(a);
#else
    if (pl_id >= PL_ID_V8) R(0x084) = a;          // TBL_DELETE exists from v8 on
#endif
    printf("table: %s (%04X) removed\n", name_of(a), a);
}

static void remove_member(int m)
{
    members[m] = members[--nmembers];
    save_teams();
}

// admin kicks a member: off the roster now (no automatic re-join), KICK sent; whitelist + table after its DELIVERED
static void kick(uint16_t a)
{
    int m = find_member_addr(a);
    if (m < 0) return;
    struct ev e = { 0 };
    e.state = J_KICKED; e.t = now_s; e.addr = a; e.dev_id = members[m].dev_id; e.team = team_of(a); e.num = a & 0xFF;
    struct ev *j = join_event(&e);
    if (dq_n < 64) dq[dq_n++] = (struct out){ .type = 0xA3, .dst = a, .dev_id = e.dev_id, .result = 1, .ev_seq = j->seq };
    if (nkicked == 32) memmove(&kicked_devs[0], &kicked_devs[1], --nkicked * sizeof kicked_devs[0]);
    kicked_devs[nkicked].dev = e.dev_id; kicked_devs[nkicked++].addr = a;
    remove_member(m);
    printf("kick: %s (dev %08X)\n", name_of(a), e.dev_id);
}

static void kick_finish(struct sent *s)
{
    s->done = 1;
    if (find_member_addr(s->dst) >= 0) return;   // joined again in the meantime: keep it
    wl_del(s->dst);
    tbl_delete(s->dst);
}

// 0xA4 from a member: it left its team
static void on_leave(uint16_t src, uint32_t dev)
{
    int m = find_member_addr(src);
    printf("LEAVE from %s (dev %08X)%s\n", name_of(src), dev, m < 0 ? ": not a member, ignored" :
           members[m].dev_id != dev ? ": other dev_id, ignored" : "");
    if (m < 0 || members[m].dev_id != dev) return;
    struct ev e = { 0 };
    e.state = J_LEFT; e.t = now_s; e.addr = src; e.dev_id = dev; e.team = team_of(src); e.num = src & 0xFF;
    struct ev *j = join_event(&e);
    remove_member(m);
    wl_del(src);
    tbl_delete(src);
    if (dq_n < 64) dq[dq_n++] = (struct out){ .type = 0xA3, .dst = src, .dev_id = dev, .result = 2, .ev_seq = j->seq };
}

// approve: the marker leaves the map; other pending requests for the same marker are answered by the same broadcast
static void decide(int ri, int decision)
{
    struct ev *r = &hist[ri];
    if (r->type != EV_REQ || r->state != REQ_PENDING) return;
    uint16_t tsrc = r->tsrc;
    uint8_t tid = r->tid;
    r->state = decision;
    queue_decision(r->src, decision, tsrc, tid, r->id);
    if (decision == REQ_APPROVED) {
        int m = find_marker(tsrc, tid);
        if (m >= 0) hist[m].state = 1;
        for (int i = 0; i < nhist; i++)
            if (hist[i].type == EV_REQ && hist[i].state == REQ_PENDING && hist[i].tsrc == tsrc && hist[i].tid == tid)
                hist[i].state = REQ_APPROVED;
    }
}

static void admin_delete(int mi)                  // admin deletes a marker directly: approved, to everybody
{
    struct ev *m = &hist[mi];
    if (m->type != EV_MARK || m->state) return;
    m->state = 1;
    queue_decision(0xFFFF, REQ_APPROVED, m->src, m->id, 0);
    for (int i = 0; i < nhist; i++)
        if (hist[i].type == EV_REQ && hist[i].state == REQ_PENDING && hist[i].tsrc == m->src && hist[i].tid == m->id)
            hist[i].state = REQ_APPROVED;
}

// send the oldest queued admin frame if the PL is free; returns 1 if one went out
static int send_next(void)
{
    if (!dq_n || (R(0x070) & 1)) return 0;
    struct out d = dq[0];
    memmove(&dq[0], &dq[1], --dq_n * sizeof dq[0]);
    if (d.is_raw) {                              // a node's mark, re-broadcast unchanged
        uint8_t *q = d.raw;
        for (int j = 0; j < 4; j++)
            R(0x060 + 4 * j) = q[4 * j] | q[4 * j + 1] << 8 | q[4 * j + 2] << 16 | (j < 3 ? (uint32_t)q[4 * j + 3] << 24 : 0);
        R(0x070) = 1;
        c1_relayed++;
        printf("re-broadcast 0xC1 from %s msg_id %u: %s to %s\n", name_of(q[1] | q[2] << 8), q[5], kind_name(d.kind),
               name_of(d.dst));
        return 1;
    }
    uint8_t id;
    if (d.again) id = d.again_id;
    else { id = admin_id++; save_admin_id(); }
    uint8_t b[16] = { d.type, ADMIN_ADDR & 0xFF, ADMIN_ADDR >> 8, d.dst & 0xFF, d.dst >> 8, id };
    if (d.type == 0xC3) {   // [C3][src FFFE][dst][msg_id][decision][target_src][target_msg_id][request_msg_id][0 x4]
        b[6] = d.decision; b[7] = d.tsrc & 0xFF; b[8] = d.tsrc >> 8; b[9] = d.tid; b[10] = d.rid;
    } else if (d.type == 0xA3) {   // [A3][src FFFE][dst = the node][msg_id][dev_id u32][reason 1 kicked / 2 left][0 x4]
        for (int j = 0; j < 4; j++) b[6 + j] = d.dev_id >> (8 * j);
        b[10] = d.result;
    } else if (d.type == 0xA2) {   // [A2][src FFFE][dst FFFF][msg_id][dev_id u32][address u16][team][number][result]
        b[3] = b[4] = 0xFF;
        for (int j = 0; j < 4; j++) b[6 + j] = d.dev_id >> (8 * j);
        b[10] = d.dst & 0xFF; b[11] = d.dst >> 8; b[12] = d.team; b[13] = d.num; b[14] = d.result;
    } else {                // [C1][src FFFE][dst][msg_id][kind][lat i32][lon i32]
        b[6] = d.kind;
        for (int j = 0; j < 4; j++) { b[7 + j] = (uint32_t)d.lat >> (8 * j); b[11 + j] = (uint32_t)d.lon >> (8 * j); }
    }
    for (int j = 0; j < 4; j++)                  // byte 0 in bits 7..0 of ADMIN_DATA0; b[15] is not sent
        R(0x060 + 4 * j) = b[4 * j] | b[4 * j + 1] << 8 | b[4 * j + 2] << 16 | (uint32_t)b[4 * j + 3] << 24;
    R(0x070) = 1;
    if (d.again) {                               // a re-send: no new event, the command's entry counts it
        struct sent *s = find_sent(id);
        if (s) { s->tries++; s->t_last = now_s; }
        printf("re-sent 0x%02X msg_id %u: %s to %s (no DELIVERED yet, try %d)\n", d.type, id,
               d.type == 0xA2 ? "JOIN ANSWER" : d.type == 0xA3 ? "KICK" : kind_name(d.kind), name_of(d.dst),
               s ? s->tries : 0);
        return 1;
    }
    if (d.type == 0xA3) {                        // kick (tracked until DELIVERED) or "leave confirmed" (once)
        int i = find_seq(d.ev_seq);
        if (i >= 0) hist[i].rid = id;
        if (d.result == 1) {
            if (nsent < 64) nsent++;
            memmove(&sent[1], &sent[0], (nsent - 1) * sizeof sent[0]);
            sent[0] = (struct sent){ .id = id, .kind = KIND_KICK, .dst = d.dst, .t = now_s, .t_last = now_s, .tries = 1,
                                     .ev_seq = d.ev_seq, .dev_id = d.dev_id };
        }
        printf("sent 0xA3 msg_id %u: %s to %s (dev %08X)\n", id, d.result == 1 ? "KICK" : "LEAVE CONFIRMED",
               name_of(d.dst), d.dev_id);
        return 1;
    }
    if (d.type == 0xA2) {                        // no event of its own: the join event shows it
        int i = find_seq(d.ev_seq);
        if (i >= 0) hist[i].rid = id;
        if (d.result == 0) {                     // accepted: re-sent until the DELIVERED from the new address
            if (nsent < 64) nsent++;
            memmove(&sent[1], &sent[0], (nsent - 1) * sizeof sent[0]);
            sent[0] = (struct sent){ .id = id, .kind = KIND_JOIN, .dst = d.dst, .t = now_s, .t_last = now_s, .tries = 1,
                                     .ev_seq = d.ev_seq };
        }
        static const char *res[] = { "ACCEPTED", "WRONG PIN", "REJECTED", "TEAM FULL", "NUMBER TAKEN" };
        printf("sent 0xA2 msg_id %u: %s for dev %08X, %s-%u (address %04X)\n", id, res[d.result % 5], d.dev_id,
               team_names[d.team <= TEAMS ? d.team : 0], d.num, d.dst);
        return 1;
    }
    if (d.type == 0xC1) {                        // remember it for the ACKs
        if (nsent < 64) nsent++;
        memmove(&sent[1], &sent[0], (nsent - 1) * sizeof sent[0]);
        sent[0] = (struct sent){ .id = id, .kind = d.kind, .dst = d.dst, .lat = d.lat, .lon = d.lon, .t = now_s,
                                 .t_last = now_s, .tries = 1, .ev_seq = 0x80000000u | out_count };
    }
    struct ev e = { 0 };
    e.seq = 0x80000000u | out_count++; e.t = now_s; e.src = ADMIN_ADDR; e.dst = d.dst; e.id = id;
    if (d.type == 0xC3) {
        e.type = EV_DEC; e.kind = d.decision; e.tsrc = d.tsrc; e.tid = d.tid; e.rid = d.rid;
        add_event(&e);
        printf("sent 0xC3 msg_id %u: %s %04X#%u to %04X (request %u)\n", id, d.decision == 1 ? "APPROVED" : "REJECTED",
               d.tsrc, d.tid, d.dst, d.rid);
    } else if (d.kind == KIND_GOBACK) {          // counted on the node's LEFT AREA event, not a marker of its own
        struct geo *g = find_geo(d.dst, 0);
        if (g) {
            g->told++;
            int i = find_seq(g->ev_seq);
            if (i >= 0) { hist[i].dups = g->told; hist[i].id = id; }
            sent[0].ev_seq = g->ev_seq;
        }
        printf("sent 0xC1 msg_id %u: GO BACK to %04X (%d, %d)\n", id, d.dst, d.lat, d.lon);
    } else {                                     // an admin marker: on the map like a phone's, can be deleted
        e.type = EV_MARK; e.kind = d.kind; e.lat = d.lat; e.lon = d.lon;
        add_event(&e);
        printf("sent 0xC1 msg_id %u: %s to %04X (%d, %d)\n", id, kind_name(d.kind), d.dst, d.lat, d.lon);
    }
    return 1;
}

// ---------------------------------------------------------------- UI state
static int sel_type, sel_node = -1;              // 1 = node (address), 2 = marker (sequence number)
static uint32_t sel_seq;
static uint32_t confirm_seq;                     // Delete pressed once on this marker: second press deletes
static double confirm_until;
static int hist_scroll;
static int quit;
static double t_now_ms;
static int area_edit, area_menu;                 // drawing a new area / the area box of an existing area is open
static int32_t edit_lat[AREA_MAX], edit_lon[AREA_MAX];
static int edit_n;
static double remove_until;                      // Remove pressed once: a second press within 4 s removes the area
static int sig_open, sig_x, sig_y;               // "send signal" box, opened by a right click at (sig_x, sig_y)
static int32_t sig_lat, sig_lon;
static uint16_t sig_dst;
static int send_pick;                            // Send pressed: the next click on the map opens the signal box
static int teams_box;                            // the teams box is open
static int team_view;                            // 0 = list of teams, else the member list of this team
static uint16_t kick_addr;                       // Kick pressed once on this member: a second press kicks
static double kick_until;

#define UI_BTN_Y 10
#define NODE_Y 54
#define NODE_ROW 22
#define NODE_MAX 6
#define HIST_Y (NODE_Y + 24 + NODE_MAX * NODE_ROW + 12)
#define HIST_ROW 38
#define STAT_Y (H - 98)
#define HIST_ROWS ((STAT_Y - HIST_Y - 28) / HIST_ROW)
#define REQ_X 490
#define REQ_W 460
#define REQ_ROW 60
#define REQ_MAX 4
#define AREA_BTN_Y (UI_BTN_Y + 114)
#define SEND_BTN_Y (AREA_BTN_Y + 38)
#define TEAM_BTN_Y (SEND_BTN_Y + 38)
#define ALARM_X 130
#define ALARM_W 350
#define SIG_W 310
#define SIG_H 160

static void ago(char *s, size_t n, uint32_t sec)
{
    if (sec < 60) snprintf(s, n, "%us ago", sec);
    else if (sec < 3600) snprintf(s, n, "%um ago", sec / 60);
    else snprintf(s, n, "%uh %um ago", sec / 3600, sec / 60 % 60);
}

static void fmt_deg(char *s, size_t n, int32_t v)
{
    int64_t a = v < 0 ? -(int64_t)v : v;
    snprintf(s, n, "%s%d.%05d", v < 0 ? "-" : "", (int)(a / 10000000), (int)(a % 10000000 / 100));
}

static void addr_str(char *s, size_t n, uint16_t a)
{
    if (a == 0xFFFF) snprintf(s, n, "ALL");
    else if (a == ADMIN_ADDR) snprintf(s, n, "ADMIN");
    else snprintf(s, n, "%s", name_of(a));
}

// ---------------------------------------------------------------- markers
static void draw_node_pin(double sx, double sy, uint32_t c, int sel, const char *label)
{
    double hx = sx, hy = sy - 18;
    double tx[3] = { sx - 7, sx + 7, sx }, ty[3] = { hy + 3, hy + 3, sy };
    circle(sx, sy, 3, 0, 0x000000, 60);                       // shadow at the point
    if (sel) circle(hx, hy, 15, 12, C_SEL, 255);
    polygon(tx, ty, 3, C_WHITE, 255);
    circle(hx, hy, 9.5, 0, C_WHITE, 255);
    double ux[3] = { sx - 5.5, sx + 5.5, sx }, uy[3] = { hy + 3, hy + 3, sy - 2 };
    polygon(ux, uy, 3, c, 255);
    circle(hx, hy, 8, 0, c, 255);
    circle(hx, hy, 3, 0, C_WHITE, 255);
    int lw = (int)strlen(label) * font_b.w + 8;
    fill_rect((int)hx + 12, (int)hy - 9, lw, font_b.h + 2, C_BOX, 220);
    text(&font_b, (int)hx + 16, (int)hy - 8, C_TEXT, 255, label);
}

// marker icon centred at (sx, sy); also used (smaller) in the lists
static void draw_cmd_icon(double sx, double sy, int kind, int a, int sel, double s)
{
    uint32_t c = kind_color(kind);
    if (sel) circle(sx, sy, 17 * s, 14 * s, C_SEL, 255);
    if (kind == 2) {                                           // hazard: red triangle with "!"
        double ox[3] = { sx, sx + 12 * s, sx - 12 * s }, oy[3] = { sy - 12 * s, sy + 9 * s, sy + 9 * s };
        polygon(ox, oy, 3, C_WHITE, a);
        double ix[3] = { sx, sx + 9.5 * s, sx - 9.5 * s }, iy[3] = { sy - 8.5 * s, sy + 7.5 * s, sy + 7.5 * s };
        polygon(ix, iy, 3, c, a);
        fill_rect((int)(sx - 1), (int)(sy - 4 * s), 2, (int)(6 * s), C_WHITE, a);
        fill_rect((int)(sx - 1), (int)(sy + 3.5 * s), 2, 2, C_WHITE, a);
    } else if (kind == 3) {                                    // rally: green flag in a white disc
        circle(sx, sy, 11 * s, 0, C_WHITE, a);
        circle(sx, sy, 9.5 * s, 0, c, a);
        fill_rect((int)(sx - 4 * s), (int)(sy - 6 * s), 2, (int)(13 * s), C_WHITE, a);
        double fx[3] = { sx - 3 * s, sx + 6 * s, sx - 3 * s }, fy[3] = { sy - 6 * s, sy - 2.5 * s, sy + 1 * s };
        polygon(fx, fy, 3, C_WHITE, a);
    } else if (kind == 1) {                                    // POI: blue disc with "i"
        circle(sx, sy, 11 * s, 0, C_WHITE, a);
        circle(sx, sy, 9.5 * s, 0, c, a);
        fill_rect((int)(sx - 1), (int)(sy - 2 * s), 2, (int)(8 * s), C_WHITE, a);
        fill_rect((int)(sx - 1), (int)(sy - 6 * s), 2, 2, C_WHITE, a);
    } else {                                                   // commands: orange diamond with a letter
        double ox[4] = { sx, sx + 12 * s, sx, sx - 12 * s }, oy[4] = { sy - 12 * s, sy, sy + 12 * s, sy };
        polygon(ox, oy, 4, C_WHITE, a);
        double ix[4] = { sx, sx + 10 * s, sx, sx - 10 * s }, iy[4] = { sy - 10 * s, sy, sy + 10 * s, sy };
        polygon(ix, iy, 4, c, a);
        char l[2] = { kind == 4 ? 'C' : kind == 5 ? 'H' : kind == 6 ? 'A' : '?', 0 };
        text(&font_b, (int)(sx - font_b.w / 2.0 + 0.5), (int)(sy - font_b.h / 2.0), C_WHITE, a, l);
    }
}

// small round badge with one letter (request / decision rows)
static void badge(double sx, double sy, uint32_t c, char letter)
{
    char l[2] = { letter, 0 };
    circle(sx, sy, 9.5, 0, C_WHITE, 255);
    circle(sx, sy, 8.5, 0, c, 255);
    text(&font_b, (int)(sx - font_b.w / 2.0 + 0.5), (int)(sy - font_b.h / 2.0), C_WHITE, 255, l);
}

// ---------------------------------------------------------------- hit tests on the map
static int node_at(int x, int y)                  // index into nodes[] or -1
{
    for (int i = nnodes - 1; i >= 0; i--) {
        double sx, sy;
        to_screen(nodes[i].lat, nodes[i].lon, &sx, &sy);
        if (hypot(x - sx, y - (sy - 18)) < 13 || hypot(x - sx, y - (sy - 6)) < 7) return i;
    }
    return -1;
}

static int marker_at(int x, int y)                // index into hist[] or -1 (newest drawn on top)
{
    for (int i = 0, shown_n = 0; i < nhist && shown_n < 100; i++) {
        if (hist[i].type != EV_MARK || hist[i].state) continue;
        shown_n++;
        double sx, sy;
        to_screen(hist[i].lat, hist[i].lon, &sx, &sy);
        if (hypot(x - sx, y - sy) < 13) return i;
    }
    return -1;
}

static void fit_nodes(void)
{
    if (!nnodes) return;
    for (zi = nmaps - 1; zi > 0; zi--) {          // highest zoom where all nodes fit with a margin
        double x0 = 1e18, x1 = -1e18, y0 = 1e18, y1 = -1e18;
        for (int i = 0; i < nnodes; i++) {
            double x, y;
            geo2px(nodes[i].lat * 1e-7, nodes[i].lon * 1e-7, maps[zi].z, &x, &y);
            if (x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y < y0) y0 = y;
            if (y > y1) y1 = y;
        }
        if (x1 - x0 < MAPW - 160 && y1 - y0 < H - 200) { cx = (x0 + x1) / 2; cy = (y0 + y1) / 2 - 10; break; }
    }
    if (zi == 0) center_on(nodes[0].lat, nodes[0].lon);
    clamp_view();
}

static void select_marker(int mi, int center)
{
    if (mi < 0) return;
    sel_type = 2;
    sel_seq = hist[mi].seq;
    if (center) center_on(hist[mi].lat, hist[mi].lon);
}

// ---------------------------------------------------------------- screen parts
// "HAZARD by 157C (msg 216)" for marker (src, id); returns the marker index or -1
static int marker_desc(char *s, size_t n, uint16_t src, uint8_t id)
{
    int m = find_marker(src, id);
    if (m >= 0 && src == ADMIN_ADDR) snprintf(s, n, "%s by ADMIN (msg %u)", kind_name(hist[m].kind), id);
    else if (m >= 0) snprintf(s, n, "%s by %04X (msg %u)", kind_name(hist[m].kind), src, id);
    else snprintf(s, n, "marker %04X / msg %u", src, id);
    return m;
}

static int draw_requests(void)                   // returns the y below the box (10 if there is none)
{
    int idx[HIST], n = 0;
    for (int i = nhist - 1; i >= 0; i--)                     // oldest pending first
        if (hist[i].type == EV_REQ && hist[i].state == REQ_PENDING) idx[n++] = i;
    if (!n) return 10;
    int shown_n = n < REQ_MAX ? n : REQ_MAX;
    int h = 28 + shown_n * REQ_ROW + (n > REQ_MAX ? 20 : 0);
    fill_rect(REQ_X, 10, REQ_W, h, C_BOX, 245);
    frame_rect(REQ_X, 10, REQ_W, h, C_WARN, 255);
    frame_rect(REQ_X + 1, 11, REQ_W - 2, h - 2, C_WARN, 255);
    fill_rect(REQ_X, 10, REQ_W, 26, C_WARN, 255);
    textf(&font_b, REQ_X + 10, 15, C_TEXT, "DELETE REQUESTS  (%d waiting)", n);
    for (int k = 0; k < shown_n; k++) {
        struct ev *r = &hist[idx[k]];
        int y = 38 + k * REQ_ROW;
        char d[64], a[32], who[16];
        if (k) fill_rect(REQ_X + 8, y - 2, REQ_W - 16, 1, C_LINE, 255);
        int m = marker_desc(d, sizeof d, r->tsrc, r->tid);
        addr_str(who, sizeof who, r->src);
        if (hover(REQ_X, y, REQ_W - 180, REQ_ROW - 4)) fill_rect(REQ_X + 2, y, REQ_W - 182, REQ_ROW - 4, C_HOVER, 255);
        if (m >= 0) draw_cmd_icon(REQ_X + 20, y + 20, hist[m].kind, hist[m].state ? 110 : 255, 0, 0.85);
        else badge(REQ_X + 20, y + 20, C_DIM, '?');
        textf(&font_b, REQ_X + 38, y + 4, C_TEXT, "%s wants to delete", who);
        ago(a, sizeof a, now_s - r->t);
        text(&font_s, REQ_X + 38 + 21 * font_b.w, y + 5, C_DIM, 255, a);
        text(&font_s, REQ_X + 38, y + 22, C_TEXT, 255, d);
        if (m < 0) text(&font_s, REQ_X + 38, y + 38, C_BAD, 255, "unknown marker (not seen by this GUI)");
        else if (hist[m].state) text(&font_s, REQ_X + 38, y + 38, C_DIM, 255, "marker already deleted");
        else {
            ago(a, sizeof a, now_s - hist[m].t);
            textf(&font_s, REQ_X + 38, y + 38, C_DIM, "placed %s", a);
        }
        if (now_s - r->t >= REQ_TIMEOUT_S) text_right(&font_s, REQ_X + REQ_W - 186, y + 38, C_ORANGE, "phone timed out");
        add_zone(REQ_X, y, REQ_W - 180, REQ_ROW - 4, A_REQ, (int)r->seq);
        button(REQ_X + REQ_W - 172, y + 14, 88, 28, "Approve", C_WHITE, C_OK, 1, A_APPROVE, (int)r->seq);
        button(REQ_X + REQ_W - 78, y + 14, 68, 28, "Reject", C_WHITE, C_BAD, 1, A_REJECT, (int)r->seq);
    }
    if (n > REQ_MAX) textf(&font_s, REQ_X + 38, 38 + REQ_MAX * REQ_ROW, C_DIM, "+ %d more (oldest shown first)", n - REQ_MAX);
    return 10 + h + 8;
}

static void bat_str(char *s, size_t n, uint8_t b)
{
    if (b == 0xFF) snprintf(s, n, "battery ?");
    else snprintf(s, n, "battery %u%%", b);
}

// join requests that wait for the admin (blue box under the delete requests)
static void draw_joins(int y0)
{
    int idx[HIST], n = 0;
    for (int i = nhist - 1; i >= 0; i--) if (hist[i].type == EV_JOIN && hist[i].state == J_WAIT) idx[n++] = i;
    if (!n) return;
    int shown_n = n < JOIN_BOX_MAX ? n : JOIN_BOX_MAX;
    int h = 28 + shown_n * REQ_ROW + (n > JOIN_BOX_MAX ? 20 : 0);
    fill_rect(REQ_X, y0, REQ_W, h, C_BOX, 245);
    frame_rect(REQ_X, y0, REQ_W, h, C_SEL, 255);
    frame_rect(REQ_X + 1, y0 + 1, REQ_W - 2, h - 2, C_SEL, 255);
    fill_rect(REQ_X, y0, REQ_W, 26, C_SEL, 255);
    textf(&font_b, REQ_X + 10, y0 + 5, C_WHITE, "JOIN REQUESTS  (%d waiting)", n);
    add_zone(REQ_X, y0, REQ_W, h, A_BOX, 0);
    for (int k = 0; k < shown_n; k++) {
        struct ev *j = &hist[idx[k]];
        int y = y0 + 28 + k * REQ_ROW;
        char a[32], bt[16];
        if (k) fill_rect(REQ_X + 8, y - 2, REQ_W - 16, 1, C_LINE, 255);
        badge(REQ_X + 20, y + 20, C_SEL, 'J');
        textf(&font_b, REQ_X + 38, y + 4, C_TEXT, "%s", name_of(j->addr));
        textf(&font_s, REQ_X + 38 + ((int)strlen(name_of(j->addr)) + 1) * font_b.w, y + 5, C_DIM, "dev %08X", j->dev_id);
        ago(a, sizeof a, now_s - j->t);
        text_right(&font_s, REQ_X + REQ_W - 186, y + 5, C_DIM, a);
        bat_str(bt, sizeof bt, j->bat);
        textf(&font_s, REQ_X + 38, y + 22, C_DIM, "fw %u.%u  %s  %d dBm%s", j->fw_maj, j->fw_min, bt, j->rssi,
              j->num ? "" : "  (any number)");
        if (j->known && !j->pin_ok) text(&font_s, REQ_X + 38, y + 38, C_BAD, 255, "WRONG PIN - known device re-joining");
        else if (j->known) text(&font_s, REQ_X + 38, y + 38, C_ORANGE, 255, "known device: changes team / number");
        else if (j->kicked) {
            int kk = was_kicked(j->dev_id);
            textf(&font_s, REQ_X + 38, y + 38, C_BAD, "PIN ok - KICKED before (was %s)", kk >= 0 ? name_of(kicked_devs[kk].addr) : "?");
        } else text(&font_s, REQ_X + 38, y + 38, C_OK, 255, "PIN ok - new device");
        button(REQ_X + REQ_W - 172, y + 14, 88, 28, "Approve", C_WHITE, C_OK, 1, A_JOIN_OK, (int)j->seq);
        button(REQ_X + REQ_W - 78, y + 14, 68, 28, "Reject", C_WHITE, C_BAD, 1, A_JOIN_NO, (int)j->seq);
    }
    if (n > JOIN_BOX_MAX) textf(&font_s, REQ_X + 38, y0 + 28 + JOIN_BOX_MAX * REQ_ROW, C_DIM, "+ %d more", n - JOIN_BOX_MAX);
}

// Teams button + box: open teams with their join PIN, members, lock; open the next team
static void draw_teams_box(void)
{
    int lock = 0, open = 0;
    for (int t = 1; t <= TEAMS; t++) { lock |= team_locked(t); open += teams[t].open; }
    button(10, TEAM_BTN_Y, 52, 34, "Teams", teams_box ? C_WHITE : lock ? C_BAD : C_TEXT,
           teams_box ? C_SEL : lock ? C_BAD : C_LINE, teams_box, A_TEAMS, 0);
    if (!teams_box) return;
    if (team_view) {                             // the members of one team, each with Kick
        int t = team_view, idx[MEMBERS], n = 0;
        for (int i = 0; i < nmembers; i++) if (team_of(members[i].addr) == t) idx[n++] = i;
        int rows = n < 8 ? n : 8;
        int x = 70, y = TEAM_BTN_Y, w = 410, h = 30 + (rows ? rows * 30 : 22) + 40;
        fill_rect(x, y, w, h, C_BOX, 245);
        frame_rect(x, y, w, h, C_SEL, 255);
        fill_rect(x, y, 4, h, C_SEL, 255);
        add_zone(x, y, w, h, A_BOX, 0);
        textf(&font_b, x + 12, y + 7, C_TEXT, "%s MEMBERS  (%d)", team_names[t], n);
        for (int r = 0; r < rows; r++) {
            struct member *mb = &members[idx[r]];
            int ry = y + 30 + r * 30, ni = find_node(mb->addr);
            fill_rect(x + 12, ry - 2, w - 24, 1, C_LINE, 255);
            circle(x + 20, ry + 13, 5, 0, ni >= 0 && nodes[ni].fresh ? C_NODE : C_STALE, 255);
            text(&font_b, x + 32, ry + 6, C_TEXT, 255, name_of(mb->addr));
            textf(&font_s, x + 150, ry + 7, C_DIM, "dev %08X  %s", mb->dev_id,
                  ni < 0 ? "offline" : nodes[ni].fresh ? "LIVE" : "STALE");
            int confirm = kick_addr == mb->addr && t_now_ms < kick_until;
            button(x + w - 96, ry + 1, 86, 26, confirm ? "Confirm?" : "Kick", confirm ? C_WHITE : C_BAD, C_BAD, confirm,
                   A_KICK, mb->addr);
        }
        if (!n) text(&font_s, x + 12, y + 34, C_DIM, 255, "no members");
        button(x + 12, y + h - 36, 80, 28, "Back", C_TEXT, C_LINE, 0, A_TEAM_BACK, 0);
        return;
    }
    int rows = open < 8 ? open : 8;
    int x = 70, y = TEAM_BTN_Y, w = 410, h = 30 + (rows ? rows * 30 : 22) + 40;
    fill_rect(x, y, w, h, C_BOX, 245);
    frame_rect(x, y, w, h, C_SEL, 255);
    fill_rect(x, y, 4, h, C_SEL, 255);
    add_zone(x, y, w, h, A_BOX, 0);
    text(&font_b, x + 12, y + 7, C_TEXT, 255, "TEAMS");
    text_right(&font_s, x + w - 10, y + 8, C_DIM, "devices join with team + PIN");
    int r = 0;
    for (int t = 1; t <= TEAMS && r < 8; t++) {
        if (!teams[t].open) continue;
        int ry = y + 30 + r++ * 30;
        char s[32];
        fill_rect(x + 12, ry - 2, w - 24, 1, C_LINE, 255);
        text(&font_b, x + 12, ry + 6, C_TEXT, 255, team_names[t]);
        textf(&font_b, x + 96, ry + 6, C_SEL, "PIN %04u", teams[t].pin);
        if (team_locked(t)) { snprintf(s, sizeof s, "LOCKED %um", (teams[t].lock_until - now_s + 59) / 60); text(&font_s, x + 170, ry + 7, C_BAD, 255, s); }
        else {
            snprintf(s, sizeof s, "%d member%s", member_count(t), member_count(t) == 1 ? "" : "s");
            int hv = hover(x + 166, ry, 84, 26);
            text(&font_s, x + 170, ry + 7, hv ? C_SEL : C_DIM, 255, s);
            fill_rect(x + 170, ry + 22, (int)strlen(s) * font_s.w, 1, hv ? C_SEL : C_LINE, 255);   // looks clickable
            add_zone(x + 166, ry, 84, 26, A_TEAM_MEMBERS, t);
        }
        button(x + w - 148, ry + 1, 76, 26, "New PIN", C_TEXT, C_LINE, 0, A_TEAM_PIN, t);
        button(x + w - 66, ry + 1, 56, 26, "Close", C_BAD, C_BAD, 0, A_TEAM_CLOSE, t);
    }
    if (!open) text(&font_s, x + 12, y + 34, C_DIM, 255, "no team open: no device can join");
    int by = y + h - 36, nt = 0;
    for (int t = 1; t <= TEAMS; t++) if (!teams[t].open) { nt = t; break; }
    if (nt) {
        char l[32];
        snprintf(l, sizeof l, "+ Open %s", team_names[nt]);
        button(x + 12, by, 150, 28, l, C_WHITE, C_SEL, 1, A_TEAM_OPEN, nt);
    }
    textf(&font_s, x + 172, by + 7, C_DIM, "joins %u  ignored (locked) %u", k_joins, j_ignored);
}

// ---------------------------------------------------------------- area and signal boxes
static void draw_area_shape(void)
{
    double sx[AREA_MAX + 1] = { 0 }, sy[AREA_MAX + 1] = { 0 };
    if (area_n && !area_edit) {
        for (int i = 0; i < area_n; i++) to_screen(area_lat[i], area_lon[i], &sx[i], &sy[i]);
        fill_poly(sx, sy, area_n, C_AREA, 40);
        for (int i = 0; i < area_n; i++) line(sx[i], sy[i], sx[(i + 1) % area_n], sy[(i + 1) % area_n], 2.5, C_AREA, 230);
    }
    if (!area_edit) return;
    for (int i = 0; i < edit_n; i++) to_screen(edit_lat[i], edit_lon[i], &sx[i], &sy[i]);
    int n = edit_n;
    if (mx < MAPW && n < AREA_MAX && !sig_open) { sx[n] = mx; sy[n] = my; n++; }   // the next corner follows the mouse
    if (n >= 3) fill_poly(sx, sy, n, C_AREA, 30);
    for (int i = 0; i + 1 < n; i++) line(sx[i], sy[i], sx[i + 1], sy[i + 1], 2.5, C_AREA, i + 1 < edit_n ? 230 : 120);
    if (n >= 3) line(sx[n - 1], sy[n - 1], sx[0], sy[0], 1.5, C_AREA, 110);
    for (int i = 0; i < edit_n; i++) { circle(sx[i], sy[i], 5, 0, C_WHITE, 255); circle(sx[i], sy[i], 3.5, 0, C_AREA, 255); }
}

static int nodes_outside(void)
{
    int k = 0;
    for (int i = 0; i < nnodes; i++) { struct geo *g = find_geo(nodes[i].addr, 0); k += g && g->outside; }
    return k;
}

static void draw_area_box(void)
{
    int filled = area_n && !area_edit;
    button(10, AREA_BTN_Y, 52, 34, "Area", filled ? C_WHITE : C_TEXT, filled ? C_AREA : C_LINE, filled, A_AREA, 0);
    // 2 rows, 410 wide: stays left of the delete request box (x 490)
    int x = 70, y = AREA_BTN_Y - 6, w = 410, h = 68;
    if (!area_edit && !(area_menu && area_n)) return;
    fill_rect(x, y, w, h, C_BOX, 240);
    frame_rect(x, y, w, h, C_AREA, 255);
    fill_rect(x, y, 4, h, C_AREA, 255);
    add_zone(x, y, w, h, A_BOX, 0);
    if (area_edit) {
        textf(&font_b, x + 12, y + 7, C_TEXT, "DRAW AREA   %d / %d", edit_n, AREA_MAX);
        text_right(&font_s, x + w - 10, y + 8, C_DIM, "click map = add corner");
        button(x + 12, y + 32, 64, 28, "Undo", C_TEXT, C_LINE, 0, A_AREA_UNDO, 0);
        if (edit_n >= 3) button(x + 82, y + 32, 64, 28, "Done", C_WHITE, C_OK, 1, A_AREA_DONE, 0);
        else {
            fill_rect(x + 82, y + 32, 64, 28, C_LINE, 255);
            text(&font_b, x + 82 + 16, y + 38, C_WHITE, 255, "Done");
        }
        button(x + 152, y + 32, 82, 28, "Cancel", C_TEXT, C_LINE, 0, A_AREA_CANCEL, 0);
        text(&font_s, x + 246, y + 39, C_DIM, 255, "right click = undo");
    } else {
        int confirm = t_now_ms < remove_until, out = nodes_outside();
        textf(&font_b, x + 12, y + 7, C_TEXT, "AREA   %d corners", area_n);
        textf(&font_s, x + w - 10 - 18 * font_s.w, y + 8, out ? C_BAD : C_DIM, "%d node%s outside", out, out == 1 ? "" : "s");
        button(x + 12, y + 32, 80, 28, "Redraw", C_TEXT, C_LINE, 0, A_AREA_REDRAW, 0);
        button(x + 98, y + 32, 90, 28, confirm ? "Confirm?" : "Remove", confirm ? C_WHITE : C_BAD, C_BAD, confirm,
               A_AREA_REMOVE, 0);
        button(x + 194, y + 32, 66, 28, "Close", C_TEXT, C_LINE, 0, A_AREA_CLOSE, 0);
        textf(&font_s, x + 272, y + 39, C_DIM, "GO BACK every %ds", REMIND_S);
    }
}

// "Send" button (same as a right click on the map, for admins who do not know the right click)
static void draw_send_box(void)
{
    button(10, SEND_BTN_Y, 52, 34, "Send", send_pick ? C_WHITE : C_TEXT, send_pick ? C_CMD : C_LINE, send_pick, A_SEND, 0);
    if (!send_pick) return;
    int x = 70, y = SEND_BTN_Y, w = 410, h = 34;
    fill_rect(x, y, w, h, C_BOX, 240);
    frame_rect(x, y, w, h, C_CMD, 255);
    fill_rect(x, y, 4, h, C_CMD, 255);
    add_zone(x, y, w, h, A_BOX, 0);
    text(&font_b, x + 12, y + 9, C_TEXT, 255, "SEND: click the place on the map");
    button(x + w - 88, y + 3, 82, 28, "Cancel", C_TEXT, C_LINE, 0, A_SEND_CANCEL, 0);
}

// list of the nodes that are outside the area (red box at the top of the map)
static void draw_alarms(void)
{
    int idx[64], n = 0;
    if (!area_n || area_edit) return;
    for (int i = 0; i < nnodes; i++) { struct geo *g = find_geo(nodes[i].addr, 0); if (g && g->outside) idx[n++] = i; }
    if (!n) return;
    int shown_n = n < 3 ? n : 3, h = 30 + shown_n * 24 + 4;      // 3 rows: stays above the area box
    fill_rect(ALARM_X, 10, ALARM_W, h, C_BOX, 245);
    frame_rect(ALARM_X, 10, ALARM_W, h, C_BAD, 255);
    fill_rect(ALARM_X, 10, ALARM_W, 26, C_BAD, 255);
    textf(&font_b, ALARM_X + 10, 15, C_WHITE, "OUT OF AREA  (%d node%s)", n, n > 1 ? "s" : "");
    for (int k = 0; k < shown_n; k++) {
        struct node *nd = &nodes[idx[k]];
        struct geo *g = find_geo(nd->addr, 0);
        int y = 40 + k * 24;
        char a[32];
        if (hover(ALARM_X, y - 2, ALARM_W, 24)) fill_rect(ALARM_X + 2, y - 2, ALARM_W - 4, 24, C_HOVER, 255);
        circle(ALARM_X + 16, y + 9, 5, 0, nd->fresh ? C_BAD : C_STALE, 255);
        textf(&font_b, ALARM_X + 28, y + 1, C_TEXT, "%s", name_of(nd->addr));
        ago(a, sizeof a, now_s - g->t_out);
        textf(&font_s, ALARM_X + 36 + (int)strlen(name_of(nd->addr)) * font_b.w, y + 2, C_DIM, "left %s", a);
        if (!nd->fresh) text_right(&font_s, ALARM_X + ALARM_W - 10, y + 2, C_DIM, "STALE, not told");
        else {
            snprintf(a, sizeof a, "told to go back %dx", g->told);
            text_right(&font_s, ALARM_X + ALARM_W - 10, y + 2, g->told ? C_TEXT : C_ORANGE, a);
        }
        add_zone(ALARM_X, y - 2, ALARM_W, 24, A_NODE, idx[k]);
    }
}

static void draw_signal_box(void)
{
    if (!sig_open) return;
    char la[24], lo[24], to[24];
    int x = sig_x + 12, y = sig_y - 20;
    if (x + SIG_W > MAPW - 4) x = sig_x - 12 - SIG_W;
    if (x < 4) x = 4;
    if (y + SIG_H > H - 4) y = H - 4 - SIG_H;
    if (y < 4) y = 4;
    circle(sig_x, sig_y, 6, 4, C_HEAD, 255);                  // where the signal goes
    circle(sig_x, sig_y, 1.5, 0, C_HEAD, 255);
    fill_rect(x + 3, y + 3, SIG_W, SIG_H, 0x000000, 40);      // shadow
    fill_rect(x, y, SIG_W, SIG_H, C_BOX, 250);
    frame_rect(x, y, SIG_W, SIG_H, C_LINE, 255);
    add_zone(x, y, SIG_W, SIG_H, A_BOX, 0);
    fill_rect(x, y, SIG_W, 28, C_HEAD, 255);
    text(&font_b, x + 10, y + 6, C_WHITE, 255, "SEND SIGNAL");
    button(x + SIG_W - 26, y + 3, 22, 22, "x", C_WHITE, C_HEAD, 1, A_SIG_CLOSE, 0);
    fmt_deg(la, sizeof la, sig_lat);
    fmt_deg(lo, sizeof lo, sig_lon);
    textf(&font_s, x + 10, y + 34, C_DIM, "at %s, %s", la, lo);
    text(&font_b, x + 10, y + 59, C_TEXT, 255, "to");
    if (sig_dst == 0xFFFF) snprintf(to, sizeof to, "ALL NODES");
    else snprintf(to, sizeof to, "%s", name_of(sig_dst));
    button(x + 34, y + 54, 120, 26, to, C_SEL, C_SEL, 0, A_SIG_TO, 0);
    text(&font_s, x + 162, y + 59, C_DIM, 255, "click to change");
    for (int k = 1; k <= 6; k++) {
        int bx = x + 10 + (k - 1) % 3 * 99, by = y + 90 + (k - 1) / 3 * 34;
        button(bx, by, 92, 28, kind_name(k), C_WHITE, kind_color(k), 1, A_SIG_KIND, k);
    }
}

// ---------------------------------------------------------------- ACK display
static void tick(int x, int y, uint32_t c)        // a check mark, 10 x 9 px, top left at (x, y) (line() is map-only)
{
    for (int i = 0; i < 4; i++) fill_rect(x + i, y + 4 + i, 2, 2, c, 255);
    for (int i = 0; i < 7; i++) fill_rect(x + 3 + i, y + 7 - i, 2, 2, c, 255);
}

static struct sent *sent_for(const struct ev *k)  // the admin command a history event stands for, or NULL
{
    if (k->type == EV_MARK && k->src == ADMIN_ADDR) {
        struct sent *s = find_sent(k->id);
        return s && s->ev_seq == k->seq ? s : NULL;
    }
    if (k->type == EV_JOIN && k->state == J_KICKED) {
        struct sent *s = find_sent(k->rid);
        return s && s->kind == KIND_KICK && s->ev_seq == k->seq ? s : NULL;
    }
    if (k->type == EV_JOIN && (k->state == J_OK || k->state == J_REJOIN)) {   // the accepting 0xA2
        struct sent *s = find_sent(k->rid);
        return s && s->kind == KIND_JOIN && s->ev_seq == k->seq ? s : NULL;
    }
    if (k->type == EV_AREA && k->kind == 1 && k->dups) {    // the last GO BACK sent to this node
        struct sent *s = find_sent(k->id);
        return s && s->kind == KIND_GOBACK && s->dst == k->src ? s : NULL;
    }
    return NULL;
}

// right-aligned at xr on line y: ticks + word (to one node), or "N seen" (to all); returns 1 if it drew something
static int draw_ack_status(const struct sent *s, int xr, int y)
{
    char t[24];
    uint32_t c = C_DIM;
    int ticks = 0;
    if (s->dst != 0xFFFF) {
        struct ackn *a = find_ackn((struct sent *)s, s->dst);
        if (a && a->seen) { snprintf(t, sizeof t, "seen"); ticks = 2; c = C_OK; }
        else if (a && a->dlv) { snprintf(t, sizeof t, "delivered"); ticks = 1; c = C_OK; }
        else if (s->tries >= ACK_TRIES && now_s - s->t_last >= ACK_RETRY_S) { snprintf(t, sizeof t, "NO ACK"); c = C_BAD; }
        else if (s->tries > 1) snprintf(t, sizeof t, "retry %d", s->tries - 1);
        else snprintf(t, sizeof t, "waiting");
    } else {
        int n = 0;
        for (int i = 0; i < s->n; i++) n += s->a[i].seen;
        if (!n) return 0;
        snprintf(t, sizeof t, "%d seen", n);
        ticks = 2; c = C_OK;
    }
    text_right(&font_s, xr, y, c, t);
    int x = xr - (int)strlen(t) * font_s.w - 4;
    for (int i = 0; i < ticks; i++) { x -= 11; tick(x, y + 3, c); }
    return 1;
}

// details line for an admin command: per node "157C delivered -55 dBm 12s ago, seen 3s ago"
static void ack_line(const struct sent *s, char *out, size_t n)
{
    size_t k = 0;
    out[0] = 0;
    if (!s->n) {
        snprintf(out, n, s->dst == 0xFFFF ? "no ACK yet (to all: only SEEN comes back)" : "no ACK yet  (sent %dx)", s->tries);
        return;
    }
    for (int i = 0; i < s->n && i < 3 && k < n; i++) {
        const struct ackn *a = &s->a[i];
        char t1[16], t2[16];
        ago(t1, sizeof t1, now_s - a->t_dlv);
        ago(t2, sizeof t2, now_s - a->t_seen);
        if (a->dlv && a->seen) k += snprintf(out + k, n - k, "%s%04X delivered %d dBm %s, SEEN %s", i ? "  |  " : "", a->addr, a->r_dlv, t1, t2);
        else if (a->dlv)       k += snprintf(out + k, n - k, "%s%04X delivered %d dBm %s", i ? "  |  " : "", a->addr, a->r_dlv, t1);
        else                   k += snprintf(out + k, n - k, "%s%04X SEEN %d dBm %s", i ? "  |  " : "", a->addr, a->r_seen, t2);
    }
    if (s->n > 3 && k < n) snprintf(out + k, n - k, "  (+%d)", s->n - 3);
}

static void draw_details(void)
{
    char a[32], la[24], lo[24], to[16], line1[160], line2[160], line3[200] = "";
    uint32_t c3 = C_OK;                          // colour of line 3
    uint32_t c = C_SEL;
    int can_del = 0;                             // a marker that is not deleted is selected
    int can_kick = 0;                            // a joined member is selected
    uint32_t del_seq = 0;                        // its seq (admin markers are >= 0x80000000: not an int)
    if (sel_type == 1) {
        int i = find_node(sel_node);
        if (i < 0) return;
        struct node *n = &nodes[i];
        fmt_deg(la, sizeof la, n->lat);
        fmt_deg(lo, sizeof lo, n->lon);
        ago(a, sizeof a, n->age);
        struct geo *g = area_n ? find_geo(n->addr, 0) : NULL;
        char nm[24];
        if (team_of(n->addr)) snprintf(nm, sizeof nm, "%s (%04X)", name_of(n->addr), n->addr);
        else snprintf(nm, sizeof nm, "NODE %04X", n->addr);
        char q[16] = "";
        if (pl_id >= PL_ID_V10) snprintf(q, sizeof q, "   GW q%d/15", GWQ(n->flags));
        snprintf(line1, sizeof line1, "%s   %s   seq %u   flags %02X%s%s", nm, n->fresh ? "LIVE" : "STALE", n->seq,
                 n->flags, q, !area_n ? "" : g && g->outside ? "   OUT OF AREA" : g && g->seen ? "   in area" : "");
        snprintf(line2, sizeof line2, "%s, %s   heard %s   RSSI %d dBm  SNR %d dB%s", la, lo, a, n->rssi, n->snr,
                 n->via ? " (gateway <- relay)" : "");
        if (n->via && n->rdev)                       // v10: also who it chose
            snprintf(line3, sizeof line3, "via %04X (relay %d dBm / %d dB, gateway %d dBm / %d dB)  chosen %s%s",
                     n->via, n->via_rssi, n->via_snr, n->rssi, n->snr, dev_name(n->rdev),
                     relay_mismatch(n) ? "  DIFFERENT!" : ""), c3 = relay_mismatch(n) ? C_ORANGE : C_SEL;
        else if (n->via)
            snprintf(line3, sizeof line3, "relayed via %04X:  relay link %d dBm / %d dB,  gateway link %d dBm / %d dB",
                     n->via, n->via_rssi, n->via_snr, n->rssi, n->snr), c3 = C_SEL;
        else if (n->rdev)
            snprintf(line3, sizeof line3, "requesting relay, chosen relayer %s (heard directly now)",
                     dev_name(n->rdev)), c3 = C_ORANGE;
        else if (n->flags & FLAG_VIA_RELAY)
            snprintf(line3, sizeof line3, "relayed (relayer unknown: gateway sends no relay info)"), c3 = C_SEL;
        else if (n->flags & FLAG_WANT_RELAY)
            snprintf(line3, sizeof line3, "requesting relay (no direct link to the admin table on its side)"), c3 = C_ORANGE;
        else if (find_member_addr(n->addr) >= 0)
            snprintf(line3, sizeof line3, "joined device %08X (team %s)", members[find_member_addr(n->addr)].dev_id,
                     team_names[team_of(n->addr)]), c3 = C_SEL;
        can_kick = find_member_addr(n->addr) >= 0;
        c = n->fresh ? C_NODE : C_STALE;
    } else if (sel_type == 2) {
        int i = find_seq(sel_seq);
        if (i < 0 || hist[i].type != EV_MARK) return;
        struct ev *k = &hist[i];
        fmt_deg(la, sizeof la, k->lat);
        fmt_deg(lo, sizeof lo, k->lon);
        ago(a, sizeof a, now_s - k->t);
        addr_str(to, sizeof to, k->dst);
        char from[16];
        addr_str(from, sizeof from, k->src);
        snprintf(line1, sizeof line1, "%s   from %s to %s   msg %u%s%s", kind_name(k->kind), from, to, k->id,
                 k->dups ? "   (+ duplicates)" : "", k->state ? "   DELETED" : "");
        if (k->src == ADMIN_ADDR) {
            snprintf(line2, sizeof line2, "%s, %s   %s   sent by this GUI", la, lo, a);
            struct sent *s = sent_for(k);
            if (s) { ack_line(s, line3, sizeof line3); if (line3[0] == 'n') c3 = C_DIM; }
        }
        else snprintf(line2, sizeof line2, "%s, %s   %s   RSSI %d dBm  SNR %d dB", la, lo, a, k->rssi, k->snr);
        c = kind_color(k->kind);
        if (!k->state) { can_del = 1; del_seq = k->seq; }
    } else
        return;
    size_t lw = strlen(line1) > strlen(line2) ? strlen(line1) : strlen(line2);
    if (strlen(line3) > lw) lw = strlen(line3);
    int tw = (int)lw * font_s.w;
    int w = 12 + tw + 12 + (can_del || can_kick ? 100 : 0);
    int bh = line3[0] ? 68 : 50;
    int y = H - 30 - bh;
    fill_rect(10, y, w, bh, C_BOX, 235);
    frame_rect(10, y, w, bh, C_LINE, 255);
    fill_rect(10, y, 4, bh, c, 255);
    text(&font_b, 22, y + 7, C_TEXT, 255, line1);
    text(&font_s, 22, y + 27, C_DIM, 255, line2);
    if (line3[0]) text(&font_s, 22, y + 45, c3, 255, line3);
    if (can_del) {
        int confirm = confirm_seq == del_seq && t_now_ms < confirm_until;
        button(10 + w - 96, y + 11, 86, 28, confirm ? "Confirm?" : "Delete", confirm ? C_WHITE : C_BAD, C_BAD, confirm,
               A_DELETE, (int)del_seq);
    }
    if (can_kick) {
        int confirm = kick_addr == (uint16_t)sel_node && t_now_ms < kick_until;
        button(10 + w - 96, y + 11, 86, 28, confirm ? "Confirm?" : "Kick", confirm ? C_WHITE : C_BAD, C_BAD, confirm,
               A_KICK, sel_node);
    }
}

static void draw_history_row(int i, int y)
{
    struct ev *k = &hist[i];
    char s[64], a[32], who[16], to[16];
    int selected = k->type == EV_AREA ? sel_type == 1 && sel_node == k->src
                   : k->type == EV_JOIN ? sel_type == 1 && k->addr && sel_node == k->addr
                   : sel_type == 2 && (k->type == EV_MARK ? sel_seq == k->seq
                   : (find_marker(k->tsrc, k->tid) >= 0 && sel_seq == hist[find_marker(k->tsrc, k->tid)].seq));
    if (selected) fill_rect(PX + 6, y, W - PX - 12, HIST_ROW - 2, C_SELROW, 255);
    else if (hover(PX, y, W - PX, HIST_ROW)) fill_rect(PX + 6, y, W - PX - 12, HIST_ROW - 2, C_HOVER, 255);
    ago(a, sizeof a, now_s - k->t);
    text_right(&font_s, W - 14, y + 4, C_DIM, a);
    if (k->type == EV_MARK) {
        draw_cmd_icon(PX + 24, y + 18, k->kind, k->state ? 90 : 255, 0, 0.85);
        text(&font_b, PX + 44, y + 3, k->state ? C_DIM : C_TEXT, 255, kind_name(k->kind));
        textf(&font_s, PX + 44 + 11 * font_b.w, y + 4, C_DIM, "msg %u", k->id);
        addr_str(to, sizeof to, k->dst);
        addr_str(who, sizeof who, k->src);
        snprintf(s, sizeof s, "%s -> %s", who, to);
        text(&font_s, PX + 44, y + 20, k->src == ADMIN_ADDR ? C_SEL : C_DIM, 255, s);
        struct sent *sn = sent_for(k);
        if (k->state) text_right(&font_s, W - 14, y + 20, C_BAD, "DELETED");
        else if (sn) draw_ack_status(sn, W - 14, y + 20);
        else if (k->dups) { snprintf(s, sizeof s, "dup %d", k->dups); text_right(&font_s, W - 14, y + 20, C_DIM, s); }
    } else if (k->type == EV_REQ) {
        badge(PX + 24, y + 18, C_WARN, '?');
        text(&font_b, PX + 44, y + 3, C_TEXT, 255, "DELETE REQ");
        textf(&font_s, PX + 44 + 11 * font_b.w, y + 4, C_DIM, "msg %u", k->id);
        addr_str(who, sizeof who, k->src);
        snprintf(s, sizeof s, "%s: %04X#%u", who, k->tsrc, k->tid);
        text(&font_s, PX + 44, y + 20, C_DIM, 255, s);
        text_right(&font_s, W - 14, y + 20, k->state == REQ_PENDING ? C_ORANGE : k->state == REQ_APPROVED ? C_OK : C_BAD,
                   k->state == REQ_PENDING ? "waiting" : k->state == REQ_APPROVED ? "approved" : "rejected");
    } else if (k->type == EV_AREA) {
        int out = k->kind == 1;
        badge(PX + 24, y + 18, out ? C_BAD : C_OK, out ? '!' : 'I');
        text(&font_b, PX + 44, y + 3, out ? C_BAD : C_OK, 255, out ? "LEFT AREA" : "BACK IN AREA");
        if (out && k->dups) snprintf(s, sizeof s, "%s  told %dx (id %u)", name_of(k->src), k->dups, k->id);
        else snprintf(s, sizeof s, "node %s", name_of(k->src));
        text(&font_s, PX + 44, y + 20, C_DIM, 255, s);
        struct sent *sn = sent_for(k);
        if (sn) draw_ack_status(sn, W - 14, y + 20);
    } else if (k->type == EV_JOIN) {
        static const char *st[] = { "waiting", "accepted", "rejected", "wrong PIN", "number taken", "team not open",
                                    "re-joined", "team full", "", "", "kicked", "left" };
        int lockev = k->state == J_TEAMLOCK || k->state == J_DEVLOCK;
        int good = k->state == J_OK || k->state == J_REJOIN;
        uint32_t c = lockev ? C_BAD : k->state == J_WAIT ? C_ORANGE : good ? C_OK : k->state == J_LEFT ? C_DIM : C_BAD;
        const char *tn = k->team >= 1 && k->team <= TEAMS ? team_names[k->team] : "?";
        badge(PX + 24, y + 18, lockev ? C_BAD : C_SEL, lockev ? '!' : 'J');
        if (k->state == J_TEAMLOCK) {
            textf(&font_b, PX + 44, y + 3, C_BAD, "%s LOCKED", tn);
            snprintf(s, sizeof s, "%d wrong PINs: no joins %d min", TEAM_BAD_MAX, LOCK_S / 60);
        } else if (k->state == J_DEVLOCK) {
            text(&font_b, PX + 44, y + 3, C_BAD, 255, "DEVICE LOCKED");
            snprintf(s, sizeof s, "%08X  %d wrong PINs", k->dev_id, DEV_BAD_MAX);
        } else if (k->state == J_KICKED || k->state == J_LEFT) {
            textf(&font_b, PX + 44, y + 3, C_BAD, k->state == J_KICKED ? "KICKED %s" : "%s LEFT", name_of(k->addr));
            snprintf(s, sizeof s, "dev %08X", k->dev_id);
        } else {
            if (k->addr) textf(&font_b, PX + 44, y + 3, C_TEXT, "JOIN %s", name_of(k->addr));
            else if (k->num) textf(&font_b, PX + 44, y + 3, C_TEXT, "JOIN %s-%u", tn, k->num);
            else textf(&font_b, PX + 44, y + 3, C_TEXT, "JOIN %s", tn);
            snprintf(s, sizeof s, "dev %08X", k->dev_id);
        }
        text(&font_s, PX + 44, y + 20, C_DIM, 255, s);
        struct sent *sn = sent_for(k);
        if (sn && ((k->state == J_OK && (sn->n || sn->tries > 1)) || k->state == J_KICKED)) draw_ack_status(sn, W - 14, y + 20);
        else if (!lockev) text_right(&font_s, W - 14, y + 20, c, st[k->state]);
    } else {
        int ok = k->kind == REQ_APPROVED;
        badge(PX + 24, y + 18, ok ? C_OK : C_BAD, ok ? 'A' : 'R');
        text(&font_b, PX + 44, y + 3, ok ? C_OK : C_BAD, 255, ok ? "APPROVED" : "REJECTED");
        textf(&font_s, PX + 44 + 11 * font_b.w, y + 4, C_DIM, "id %u", k->id);
        addr_str(to, sizeof to, k->dst);
        if (k->dst == 0xFFFF) snprintf(s, sizeof s, "%04X#%u  admin delete", k->tsrc, k->tid);
        else snprintf(s, sizeof s, "%04X#%u  -> %s (req %u)", k->tsrc, k->tid, to, k->rid);
        text(&font_s, PX + 44, y + 20, C_DIM, 255, s);
    }
    add_zone(PX, y, W - PX, HIST_ROW, A_EV, (int)k->seq);
}

static void draw_panel(void)
{
    char s[64], a[32];
    fill_rect(PX, 0, W - PX, H, C_PANEL, 255);
    fill_rect(PX, 0, 1, H, C_LINE, 255);

    fill_rect(PX, 0, W - PX, 44, C_HEAD, 255);
    text(&font_l, PX + 14, 11, C_ACC, 255, "A.T.A.K. // C2");
    snprintf(s, sizeof s, "up %u:%02u:%02u", now_s / 3600, now_s / 60 % 60, now_s % 60);
    text_right(&font_s, W - 14, 15, C_DIM, s);

    int live = 0;
    for (int i = 0; i < nnodes; i++) live += nodes[i].fresh;
    textf(&font_b, PX + 14, NODE_Y, C_ACC, "NODES");
    textf(&font_s, PX + 14 + 6 * font_b.w, NODE_Y + 1, C_DIM, "%d live / %d", live, nnodes);
    fill_rect(PX + 14, NODE_Y + 19, W - PX - 28, 1, C_LINE, 255);
    for (int i = 0; i < nnodes && i < NODE_MAX; i++) {
        struct node *n = &nodes[i];
        int y = NODE_Y + 24 + i * NODE_ROW;
        if (sel_type == 1 && sel_node == n->addr) fill_rect(PX + 6, y, W - PX - 12, NODE_ROW, C_SELROW, 255);
        else if (hover(PX, y, W - PX, NODE_ROW)) fill_rect(PX + 6, y, W - PX - 12, NODE_ROW, C_HOVER, 255);
        circle(PX + 20, y + 11, 5, 0, n->fresh ? C_NODE : C_STALE, 255);
        const char *nm = name_of(n->addr);
        int x2 = PX + 32 + ((int)strlen(nm) < 5 ? 5 : (int)strlen(nm) + 1) * font_b.w;   // 4-digit address: as before
        textf(&font_b, PX + 32, y + 3, C_TEXT, "%s", nm);
        text(&font_s, x2, y + 3, n->fresh ? C_OK : C_DIM, 255, n->fresh ? "LIVE" : "STALE");
        ago(a, sizeof a, n->age);
        text(&font_s, x2 + 50, y + 3, C_DIM, 255, a);
        if (pl_id >= PL_ID_V10) {                    // v10: the node's own gateway link, 4 bars (q 1..15)
            int q = GWQ(n->flags);
            for (int b = 0; b < 4; b++)
                fill_rect(W - 124 + 4 * b, y + 15 - (3 + 2 * b), 3, 3 + 2 * b, q > 4 * b ? C_ACC : C_LINE, 255);
        }
        if (n->via) {                                // relayed: who relays it
            snprintf(s, sizeof s, "via %04X%s%s", n->via, (n->flags & FLAG_DIRECT) ? "+D" : "",   // v11: +D = also direct
                     relay_mismatch(n) ? "!" : "");
            text_right(&font_s, W - 14, y + 3, relay_mismatch(n) ? C_ORANGE : C_SEL, s);
        } else if (n->flags & FLAG_VIA_RELAY) {      // relayed, but the old 18-byte frame: relayer unknown
            text_right(&font_s, W - 14, y + 3, C_SEL, "via relay");
        } else if (n->fresh && (n->flags & FLAG_WANT_RELAY)) {
            text_right(&font_s, W - 14, y + 3, C_ORANGE, "needs relay");
        } else {
            snprintf(s, sizeof s, "%d dBm", n->rssi);
            text_right(&font_s, W - 14, y + 3, C_DIM, s);
        }
        add_zone(PX, y, W - PX, NODE_ROW, A_NODE, i);
    }
    if (nnodes > NODE_MAX)
        textf(&font_s, PX + 32, NODE_Y + 24 + NODE_MAX * NODE_ROW - 2, C_DIM, "+ %d more", nnodes - NODE_MAX);
    if (!nnodes) text(&font_s, PX + 20, NODE_Y + 28, C_DIM, 255, "no nodes heard yet");

    textf(&font_b, PX + 14, HIST_Y, C_ACC, "HISTORY");
    textf(&font_s, PX + 14 + 8 * font_b.w, HIST_Y + 1, C_DIM, "%d", nhist);
    fill_rect(PX + 14, HIST_Y + 19, W - PX - 28, 1, C_LINE, 255);
    if (hist_scroll > nhist - HIST_ROWS) hist_scroll = nhist - HIST_ROWS;
    if (hist_scroll < 0) hist_scroll = 0;
    for (int r = 0; r < HIST_ROWS && r + hist_scroll < nhist; r++)
        draw_history_row(r + hist_scroll, HIST_Y + 24 + r * HIST_ROW);
    if (!nhist) text(&font_s, PX + 20, HIST_Y + 28, C_DIM, 255, "no markers yet");
    if (nhist > HIST_ROWS) {                       // scroll bar
        int th = STAT_Y - HIST_Y - 34, bh = th * HIST_ROWS / nhist;
        int by = HIST_Y + 24 + (th - bh) * hist_scroll / (nhist - HIST_ROWS);
        fill_rect(W - 6, by, 3, bh, C_LINE, 255);
    }

    fill_rect(PX, STAT_Y, W - PX, H - STAT_Y, C_STAT, 255);
    fill_rect(PX, STAT_Y, W - PX, 1, C_LINE, 255);
    textf(&font_s, PX + 14, STAT_Y + 8, C_DIM, "cmds %u rej %u dup %u acks %u joins %u", k_ok, k_drop, k_dups, a_ok,
          k_joins);
    textf(&font_s, PX + 14, STAT_Y + 25, (c_crc | c_len | c_frm | c_tmo) ? C_ORANGE : C_DIM,
          "positions ok %u  rejected %u  err %u", c_ok, c_addr, c_crc + c_len + c_frm + c_tmo);
    textf(&font_s, PX + 14, STAT_Y + 42, k_ovf ? C_HAZARD : C_DIM, "ovf %u  downl %u  relayed %u  stale %us",
          k_ovf, c_sent, c_relays, stale_s);
    textf(&font_s, PX + 14, STAT_Y + 59, dq_n ? C_ORANGE : C_DIM, "admin frames %u  queued %d  next id %u",
          adm_sent, dq_n, admin_id);
    if (pl_id >= PL_ID_V9) {                       // v9: secure ok / MIC wrong / replays, and the two switches
        textf(&font_s, PX + 14, STAT_Y + 78, (s_mic | s_rpl) ? C_ORANGE : C_DIM, "sec %u mic %u rpl %u pl %u up %u",
              s_ok, s_mic, s_rpl, (sec_ctrl & 2) ? s_pdrop : s_pok, s_upg);
        button(W - 110, STAT_Y + 74, 40, 20, "TX", (sec_ctrl & 1) ? C_WHITE : C_DIM, C_OK, sec_ctrl & 1, A_SEC_TX, 0);
        button(W - 64, STAT_Y + 74, 50, 20, "ONLY", (sec_ctrl & 2) ? C_WHITE : C_DIM, C_OK, (sec_ctrl >> 1) & 1,
               A_SEC_ONLY, 0);
    } else
        text(&font_s, PX + 14, STAT_Y + 78, C_DIM, 255, "no security in this PL (before v9)");
}

static void draw_cursor(void)
{
    static const char *arrow[] = {
        "X", "XX", "X.X", "X..X", "X...X", "X....X", "X.....X", "X......X", "X.......X", "X........X", "X.....XXXXX",
        "X..X..X", "X.X X..X", "XX  X..X", "X    X..X", "     X..X", "      XX",
    };
    for (int j = 0; j < 17; j++)
        for (int i = 0; arrow[j][i]; i++) {
            int x = mx + i, y = my + j;
            if (x >= W || y >= H || arrow[j][i] == ' ') continue;
            tgt[y * W + x] = arrow[j][i] == 'X' ? 0x000000 : C_WHITE;
        }
}

static void draw_all(void)
{
    char s[64];
    nzones = 0;
    draw_map();
    draw_area_shape();
    // markers (not deleted): oldest first so the newest is on top; older than 10 minutes faded
    int list[100], nl = 0;
    for (int i = 0; i < nhist && nl < 100; i++)
        if (hist[i].type == EV_MARK && !hist[i].state) list[nl++] = i;
    for (int j = nl - 1; j >= 0; j--) {
        struct ev *k = &hist[list[j]];
        double sx, sy;
        to_screen(k->lat, k->lon, &sx, &sy);
        if (sx < -20 || sx > MAPW + 20 || sy < -20 || sy > H + 20) continue;
        draw_cmd_icon(sx, sy, k->kind, now_s - k->t > 600 ? 110 : 255, sel_type == 2 && sel_seq == k->seq, 1.0);
    }
    for (int i = 0; i < nnodes; i++) {               // relayed node -> its relayer: dashed line
        int j = nodes[i].via ? find_node(nodes[i].via) : -1;
        if (j < 0) continue;
        double ax, ay, bx, by;
        to_screen(nodes[i].lat, nodes[i].lon, &ax, &ay);
        to_screen(nodes[j].lat, nodes[j].lon, &bx, &by);
        ay -= 18; by -= 18;                           // pin heads
        double len = hypot(bx - ax, by - ay);
        uint32_t c = nodes[i].fresh ? C_SEL : C_STALE;
        for (double t = 0; t < len; t += 14) {
            double t1 = t + 8 < len ? t + 8 : len;
            line(ax + (bx - ax) * t / len, ay + (by - ay) * t / len, ax + (bx - ax) * t1 / len, ay + (by - ay) * t1 / len,
                 2.5, c, 230);
        }
    }
    for (int i = 0; i < nnodes; i++) {
        double sx, sy;
        char l[16];
        to_screen(nodes[i].lat, nodes[i].lon, &sx, &sy);
        if (sx < -40 || sx > MAPW + 40 || sy < -20 || sy > H + 40) continue;
        snprintf(l, sizeof l, "%s", name_of(nodes[i].addr));
        struct geo *g = area_n ? find_geo(nodes[i].addr, 0) : NULL;
        if (g && g->outside) { circle(sx, sy - 18, 19, 15.5, C_BAD, 255); circle(sx, sy - 18, 15.5, 0, C_BAD, 50); }
        draw_node_pin(sx, sy, nodes[i].fresh ? C_NODE : C_STALE, sel_type == 1 && sel_node == nodes[i].addr, l);
    }
    button(10, UI_BTN_Y, 34, 34, "+", C_TEXT, C_LINE, 0, A_ZOOM_IN, 0);
    button(10, UI_BTN_Y + 38, 34, 34, "-", C_TEXT, C_LINE, 0, A_ZOOM_OUT, 0);
    button(10, UI_BTN_Y + 76, 34, 34, "Fit", C_TEXT, C_LINE, 0, A_FIT, 0);
    button(10, TEAM_BTN_Y + 38, 52, 34, night ? "NGT" : "DAY", night ? C_ACC : C_TEXT, C_LINE, 0, A_NIGHT, 0);
    draw_scale();
    snprintf(s, sizeof s, "zoom %d", maps[zi].z);
    fill_rect(50, UI_BTN_Y + 9, 7 * font_s.w + 8, font_s.h + 2, C_BOX, 200);
    text(&font_s, 54, UI_BTN_Y + 10, C_TEXT, 255, s);
    draw_area_box();
    draw_send_box();
    draw_teams_box();
    draw_details();
    const char *attr = "\xA9 OpenStreetMap contributors";
    int aw = (int)strlen(attr) * font_s.w + 10;
    fill_rect(MAPW - aw, H - font_s.h - 4, aw, font_s.h + 4, C_BOX, 190);
    text(&font_s, MAPW - aw + 5, H - font_s.h - 2, C_TEXT, 255, attr);
    draw_joins(draw_requests());
    draw_alarms();
    draw_signal_box();
    draw_panel();
}

// ---------------------------------------------------------------- overlay: cursor + coordinate readout
// The overlay is drawn on top of the scene into ob. When only the mouse moves (and not onto another button), just
// the overlay rectangles are refreshed: a few hundred pixels instead of the whole screen.
struct rect { int x, y, w, h; };
static struct rect ov[2];            // overlay rectangles now on the screen: [0] cursor, [1] readout (w 0 = none)
#define RD_X 200                     // coordinate readout, bottom left of the map (right of the scale bar)
#define RD_W 250

static void overlay_rects(struct rect *r)
{
    r[0] = (struct rect){ mx, my, 12, 17 };
    r[1] = mx < MAPW ? (struct rect){ RD_X, H - 26, RD_W, 20 } : (struct rect){ 0, 0, 0, 0 };
}

static void draw_overlay(void)       // into ob
{
    tgt = ob;
    if (mx < MAPW) {
        int32_t la, lo;
        char s[48];
        to_geo(mx, my, &la, &lo);
        snprintf(s, sizeof s, "+ %.5f%c %.5f%c", fabs(la * 1e-7), la < 0 ? 'S' : 'N', fabs(lo * 1e-7), lo < 0 ? 'W' : 'E');
        fill_rect(RD_X, H - 26, RD_W, 20, C_BOX, 210);
        text(&font_s, RD_X + 6, H - 23, C_ACC, 255, s);
    }
    draw_cursor();
    tgt = bb;
}

static void copy_rect(uint32_t *d, const uint32_t *s_, struct rect r)
{
    if (r.w <= 0) return;
    int x0 = r.x < 0 ? 0 : r.x, x1 = r.x + r.w > W ? W : r.x + r.w;
    for (int y = r.y < 0 ? 0 : r.y; y < r.y + r.h && y < H; y++)
        if (x1 > x0) memcpy(d + y * W + x0, s_ + y * W + x0, (size_t)(x1 - x0) * 4);
}

// copy the changed 32-pixel blocks of rows y0..y1-1, columns x0..x1-1 (rounded to blocks) from ob to the screen
static void present_area(int x0, int y0, int x1, int y1)
{
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > W) x1 = W;
    if (y1 > H) y1 = H;
    x0 &= ~31;
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x += 32) {
            int o = y * W + x;
            if (!memcmp(&ob[o], &shown[o], 32 * 4)) continue;
            memcpy(&shown[o], &ob[o], 32 * 4);
            memcpy((uint32_t *)&fb[o], &ob[o], 32 * 4);
        }
}

static void present(void) { present_area(0, 0, W, H); }

static void frame_full(void)         // scene (already in bb) + overlay -> screen
{
    memcpy(ob, bb, sizeof ob);
    draw_overlay();
    overlay_rects(ov);
    present();
}

static void frame_overlay(void)      // only the mouse moved: restore the old overlay areas, draw the new overlay
{
    struct rect nw[2];
    overlay_rects(nw);
    for (int i = 0; i < 2; i++) { copy_rect(ob, bb, ov[i]); copy_rect(ob, bb, nw[i]); }
    draw_overlay();
    for (int i = 0; i < 2; i++) {
        struct rect r[2] = { ov[i], nw[i] };
        for (int j = 0; j < 2; j++)
            if (r[j].w > 0) present_area(r[j].x, r[j].y, r[j].x + r[j].w, r[j].y + r[j].h);
    }
    ov[0] = nw[0]; ov[1] = nw[1];
}

static int zone_under_mouse(void)    // topmost click zone under the mouse (action << 24 ^ arg), -1 = none
{
    for (int z = nzones - 1; z >= 0; z--)
        if (hover(zones[z].x, zones[z].y, zones[z].w, zones[z].h)) return zones[z].action << 24 ^ zones[z].arg;
    return -1;
}


// ---------------------------------------------------------------- input
static void right_click(int x, int y);

static void click(int x, int y)
{
    for (int z = nzones - 1; z >= 0; z--) {       // the last drawn zone is on top
        struct zone *q = &zones[z];
        if (x < q->x || x >= q->x + q->w || y < q->y || y >= q->y + q->h) continue;
        int e = find_seq((uint32_t)q->arg);          // event index for the event actions
        if ((q->action == A_APPROVE || q->action == A_REJECT || q->action == A_REQ || q->action == A_EV) && e < 0) return;
        if (q->action != A_BOX && q->action < A_SIG_TO) sig_open = 0;  // any other button closes the signal box
        switch (q->action) {
        case A_BOX: break;                       // a click on a box background does nothing
        case A_SEND:
            if (area_edit) break;                 // finish the area first
            send_pick = !send_pick;
            area_menu = 0; teams_box = 0;
            break;
        case A_NIGHT: night = !night; break;
        case A_SEC_TX:
        case A_SEC_ONLY: {
            uint32_t m = sec_ctrl ^ (q->action == A_SEC_TX ? 1u : 2u);
            if ((m & 1) && !(sec_ctrl & 1) && access(sec_key_file, R_OK) != 0) {
                printf("SECURE_TX not switched on: no key (%s); make one with atk_sec.sh genkey, then reboot\n",
                       sec_key_file);
                break;
            }
            R(0x088) = m;
            sec_ctrl = m;
            FILE *f = fopen(sec_mode_file, "w");
            if (f) { fprintf(f, "%u\n", m); fflush(f); fsync(fileno(f)); fclose(f); }
            printf("security mode: SECURE_TX %u SECURE_ONLY %u (saved)\n", m & 1, (m >> 1) & 1);
            break;
        }
        case A_TEAMS:
            if (area_edit) break;
            teams_box = !teams_box;
            team_view = 0;
            area_menu = 0; send_pick = 0;
            break;
        case A_TEAM_OPEN:  team_open_next(); break;
        case A_TEAM_MEMBERS: team_view = q->arg; break;
        case A_TEAM_BACK:  team_view = 0; break;
        case A_KICK:
            if (kick_addr == (uint16_t)q->arg && t_now_ms < kick_until) { kick((uint16_t)q->arg); kick_addr = 0; }
            else { kick_addr = (uint16_t)q->arg; kick_until = t_now_ms + 4000; }
            break;
        case A_TEAM_PIN:   team_new_pin(q->arg); break;
        case A_TEAM_CLOSE: teams[q->arg].open = 0; save_teams(); break;
        case A_JOIN_OK: case A_JOIN_NO: {
            int j = find_seq((uint32_t)q->arg);
            if (j >= 0) join_decide(j, q->action == A_JOIN_OK);
            break;
        }
        case A_SEND_CANCEL: send_pick = 0; break;
        case A_AREA:
            send_pick = 0; teams_box = 0;
            if (area_edit) break;
            if (area_n) area_menu = !area_menu;
            else { area_edit = 1; edit_n = 0; }
            break;
        case A_AREA_UNDO:   if (edit_n) edit_n--; break;
        case A_AREA_DONE:
            if (edit_n >= 3) { set_area(edit_lat, edit_lon, edit_n); area_edit = 0; }
            break;
        case A_AREA_CANCEL: area_edit = 0; break;
        case A_AREA_REDRAW: area_menu = 0; area_edit = 1; edit_n = 0; break;
        case A_AREA_REMOVE:
            if (t_now_ms < remove_until) { set_area(NULL, NULL, 0); area_menu = 0; remove_until = 0; }
            else remove_until = t_now_ms + 4000;
            break;
        case A_AREA_CLOSE:  area_menu = 0; break;
        case A_SIG_TO: {                         // ALL -> each node in the table -> ALL
            int i = sig_dst == 0xFFFF ? -1 : find_node(sig_dst);
            sig_dst = i + 1 < nnodes ? nodes[i + 1].addr : 0xFFFF;
            break;
        }
        case A_SIG_KIND:
            queue_signal(sig_dst, (uint8_t)q->arg, sig_lat, sig_lon);
            sig_open = 0;
            break;
        case A_SIG_CLOSE:   sig_open = 0; break;
        case A_ZOOM_IN:  zoom(1, MAPW / 2, H / 2); break;
        case A_ZOOM_OUT: zoom(-1, MAPW / 2, H / 2); break;
        case A_FIT:      fit_nodes(); break;
        case A_APPROVE:  decide(e, REQ_APPROVED); break;
        case A_REJECT:   decide(e, REQ_REJECTED); break;
        case A_REQ:      select_marker(find_marker(hist[e].tsrc, hist[e].tid), 1); break;
        case A_DELETE:
            if (confirm_seq == (uint32_t)q->arg && t_now_ms < confirm_until) {
                if (e >= 0) admin_delete(e);
                confirm_seq = 0;
                sel_type = 0;
            } else {
                confirm_seq = (uint32_t)q->arg;
                confirm_until = t_now_ms + 4000;
            }
            break;
        case A_NODE:
            if (q->arg < nnodes) {
                sel_type = 1; sel_node = nodes[q->arg].addr;
                center_on(nodes[q->arg].lat, nodes[q->arg].lon);
            }
            break;
        case A_EV:
            if (hist[e].type == EV_AREA) {
                int i = find_node(hist[e].src);
                sel_type = 1; sel_node = hist[e].src;
                if (i >= 0) center_on(nodes[i].lat, nodes[i].lon);
            } else if (hist[e].type == EV_JOIN) {
                int i = hist[e].addr ? find_node(hist[e].addr) : -1;
                if (i >= 0) { sel_type = 1; sel_node = nodes[i].addr; center_on(nodes[i].lat, nodes[i].lon); }
            } else
                select_marker(hist[e].type == EV_MARK ? e : find_marker(hist[e].tsrc, hist[e].tid), 1);
            break;
        }
        return;
    }
    if (sig_open) { sig_open = 0; return; }       // a click next to the signal box only closes it
    if (send_pick && x < MAPW) { send_pick = 0; right_click(x, y); return; }
    if (area_edit) {
        if (x < MAPW && edit_n < AREA_MAX) { to_geo(x, y, &edit_lat[edit_n], &edit_lon[edit_n]); edit_n++; }
        return;
    }
    area_menu = 0;
    if (x < MAPW) {
        int n = node_at(x, y), k = marker_at(x, y);
        if (n >= 0) { sel_type = 1; sel_node = nodes[n].addr; }
        else if (k >= 0) select_marker(k, 0);
        else sel_type = 0;
    }
}

// right click on the map: drawing an area = remove the last corner, otherwise open the "send signal" box there
// (to the selected node, or to all nodes if none is selected)
static void right_click(int x, int y)
{
    if (x >= MAPW) return;
    if (area_edit) { if (edit_n) edit_n--; return; }
    area_menu = 0;
    send_pick = 0;
    sig_open = 1; sig_x = x; sig_y = y;
    to_geo(x, y, &sig_lat, &sig_lon);
    sig_dst = sel_type == 1 && find_node(sel_node) >= 0 ? (uint16_t)sel_node : 0xFFFF;
}

static int evfd[16];

static void open_inputs(void)
{
    for (int i = 0; i < 16; i++) {
        if (evfd[i] > 0) continue;
        char p[32];
        snprintf(p, sizeof p, "/dev/input/event%d", i);
        int fd = open(p, O_RDONLY | O_NONBLOCK);
        if (fd > 0) { evfd[i] = fd; printf("input: %s\n", p); }
    }
}

static int down, dragging, down_x, down_y;
static double down_cx, down_cy;

static void key(int code)
{
    switch (code) {
    case KEY_LEFT:  cx -= 100; break;
    case KEY_RIGHT: cx += 100; break;
    case KEY_UP:    cy -= 100; break;
    case KEY_DOWN:  cy += 100; break;
    case KEY_KPPLUS: case KEY_EQUAL: zoom(1, MAPW / 2, H / 2); break;
    case KEY_KPMINUS: case KEY_MINUS: zoom(-1, MAPW / 2, H / 2); break;
    case KEY_F:     fit_nodes(); break;
    case KEY_N:     night = !night; break;
    case KEY_ESC:                                 // close the innermost thing that is open
        if (sig_open) sig_open = 0;
        else if (send_pick) send_pick = 0;
        else if (teams_box) teams_box = 0;
        else if (area_edit) area_edit = 0;
        else if (area_menu) area_menu = 0;
        else { sel_type = 0; confirm_seq = 0; }
        break;
    case KEY_BACKSPACE: if (area_edit && edit_n) edit_n--; break;
    case KEY_ENTER: case KEY_KPENTER:
        if (area_edit && edit_n >= 3) { set_area(edit_lat, edit_lon, edit_n); area_edit = 0; }
        break;
    case KEY_Q:     quit = 1; break;
    }
    clamp_view();
}

static int read_inputs(void)                      // 0 nothing, bit 0: the mouse moved, bit 1: anything else
{
    int changed = 0;
    struct input_event ev;
    for (int i = 0; i < 16; i++) {
        if (evfd[i] <= 0) continue;
        for (;;) {
            ssize_t r = read(evfd[i], &ev, sizeof ev);
            if (r != sizeof ev) {
                if (r < 0 && errno != EAGAIN) { close(evfd[i]); evfd[i] = 0; }   // unplugged
                break;
            }
            if (ev.type == EV_SYN) continue;
            changed |= (ev.type == EV_REL && (ev.code == REL_X || ev.code == REL_Y) && !down) ? 1 : 2;
            if (ev.type == EV_REL) {
                if (ev.code == REL_X) mx += ev.value;
                else if (ev.code == REL_Y) my += ev.value;
                else if (ev.code == REL_WHEEL) {
                    if (mx < MAPW) zoom(ev.value > 0 ? 1 : -1, mx, my);
                    else hist_scroll -= ev.value * 2;
                }
                if (mx < 0) mx = 0;
                if (mx >= W) mx = W - 1;
                if (my < 0) my = 0;
                if (my >= H) my = H - 1;
                if (down && mx < MAPW) {
                    if (!dragging && (abs(mx - down_x) > 4 || abs(my - down_y) > 4)) dragging = 1;
                    if (dragging) { cx = down_cx - (mx - down_x); cy = down_cy - (my - down_y); clamp_view(); }
                }
            } else if (ev.type == EV_KEY) {
                if (ev.code == BTN_LEFT) {
                    if (ev.value == 1) { down = 1; dragging = 0; down_x = mx; down_y = my; down_cx = cx; down_cy = cy; }
                    else if (ev.value == 0) { if (down && !dragging) click(mx, my); down = 0; dragging = 0; }
                } else if (ev.code == BTN_RIGHT) {
                    if (ev.value == 1) right_click(mx, my);
                } else if (ev.value == 1 || ev.value == 2)
                    key(ev.code);
            }
        }
    }
    return changed;
}

static void on_signal(int s) { (void)s; quit = 1; }

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

#ifdef SIM
// ---------------------------------------------------------------- PC simulation: fake PL registers
static uint32_t sim_regs[1024];
static void sim_fifo(int k, uint8_t type, uint16_t src, uint16_t dst, uint8_t id, const uint8_t *rest10, uint32_t t)
{
    uint8_t b[16] = { type, src & 0xFF, src >> 8, dst & 0xFF, dst >> 8, id };
    memcpy(&b[6], rest10, 9);
    uint32_t *w = &sim_regs[(0x800 + 32 * k) / 4];
    for (int j = 0; j < 4; j++) w[j] = b[4 * j] | b[4 * j + 1] << 8 | b[4 * j + 2] << 16 | (uint32_t)b[4 * j + 3] << 24;
    w[4] = (uint8_t)-60 | (9u << 8);
    w[5] = t; w[6] = k;
}
static void sim_mark(int k, uint16_t src, uint16_t dst, uint8_t id, uint8_t kind, int32_t la, int32_t lo, uint32_t t)
{
    uint8_t r[9] = { kind, la & 0xFF, la >> 8 & 0xFF, la >> 16 & 0xFF, (uint32_t)la >> 24, lo & 0xFF, lo >> 8 & 0xFF,
                     lo >> 16 & 0xFF, (uint32_t)lo >> 24 & 0xFF };
    sim_fifo(k, 0xC1, src, dst, id, r, t);
}
static void sim_req(int k, uint16_t src, uint8_t id, uint16_t tsrc, uint8_t tid, uint32_t t)
{
    uint8_t r[9] = { 0, tsrc & 0xFF, tsrc >> 8, tid, 0, 0, 0, 0, 0 };
    sim_fifo(k, 0xC2, src, ADMIN_ADDR, id, r, t);
}
static void sim_fill(void)
{
    static const struct { uint16_t a; int32_t la, lo; int8_t rssi, snr; uint16_t age; } n[] = {
        { 0x157C, 409846150, 288538200, -29, 13, 3 }, { 0x157E, 409846150, 288562200, -31, 12, 3 },
        { 0x157D, 409832150, 288550200, -44, 9, 1 },  { 0x1580, 409861000, 288521000, -90, -4, 312 },
    };
    sim_regs[0] = PL_ID; sim_regs[0x038 / 4] = 1000; sim_regs[0x03C / 4] = 60;
    pl_id = PL_ID;
    sim_regs[0x008 / 4] = 4; sim_regs[0x048 / 4] = 0x7;
    sim_regs[0x00C / 4] = 812; sim_regs[0x010 / 4] = 4; sim_regs[0x028 / 4] = 95;
    for (int i = 0; i < 4; i++) {
        uint32_t la = n[i].la, lo = n[i].lo, *w = &sim_regs[(0x100 + 16 * i) / 4];
        w[0] = n[i].a | (35u << 16) | (la << 24);
        w[1] = (la >> 8) | (lo << 24);
        static const uint8_t q[4] = { 13, 9, 6, 0 };   // v10 GW quality in flags bits 3..6
        w[2] = (lo >> 8) | ((uint32_t)(q[i] << 3) << 24);
        w[3] = (uint8_t)n[i].rssi | ((uint8_t)n[i].snr << 8) | ((uint32_t)n[i].age << 16);
    }
    int k = 0;
    sim_mark(k++, 0x157C, 0xFFFF, 213, 4, 409836724, 288538925, 400);
    sim_mark(k++, 0x157C, 0xFFFF, 215, 5, 409835636, 288543729, 930);
    sim_mark(k++, 0x157C, 0xFFFF, 216, 2, 409834337, 288551936, 975);
    sim_mark(k++, 0x157D, 0xFFFF, 40, 1, 409852000, 288572000, 980);
    sim_mark(k++, 0x157E, 0x157D, 9, 3, 409822000, 288528000, 990);
    sim_req(k++, 0x157D, 41, 0x157C, 216, 992);        // 157D wants to delete 157C's hazard
    sim_mark(k++, 0x157E, 0xFFFF, 10, 6, 409841000, 288580000, 995);
    sim_req(k++, 0x157E, 11, 0x1580, 77, 998);          // a marker this GUI never saw
    sim_regs[0x04C / 4] = k; sim_regs[0x058 / 4] = k; sim_regs[0x05C / 4] = 1;
}
static void sim_next_reports(void)               // every node sends a new position report (seq + 1)
{
    for (int i = 0; i < 4; i++) sim_regs[(0x100 + 16 * i) / 4] += 1u << 16;
    sim_regs[0x038 / 4] += 5;
}
static void sim_a1(int k, uint32_t dev, int team, int num, int pin, int rs, uint32_t t)   // a 0xA1 in FIFO slot k
{
    uint8_t b[17] = { 0xA1, 0, 0, 0xFE, 0xFF, (uint8_t)rs, dev & 0xFF, (dev >> 8) & 0xFF, (dev >> 16) & 0xFF, dev >> 24,
                      (uint8_t)team, (uint8_t)num, pin & 0xFF, (pin >> 8) & 0xFF, 1, 14, 0xFF };
    uint32_t *w = &sim_regs[(0x800 + 32 * k) / 4];
    for (int j = 0; j < 4; j++) w[j] = b[4 * j] | b[4 * j + 1] << 8 | b[4 * j + 2] << 16 | (uint32_t)b[4 * j + 3] << 24;
    w[4] = (uint8_t)-52 | (11u << 8);
    w[5] = t; w[6] = k; w[7] = b[16];
}
static void sim_tbl_delete(uint16_t a)          // what TBL_DELETE does in the PL: the last entry fills the gap
{
    uint32_t n = sim_regs[0x008 / 4];
    for (uint32_t i = 0; i < n; i++)
        if ((sim_regs[(0x100 + 16 * i) / 4] & 0xFFFF) == a) {
            for (int j = 0; j < 4; j++) sim_regs[(0x100 + 16 * i) / 4 + j] = sim_regs[(0x100 + 16 * (n - 1)) / 4 + j];
            sim_regs[(0x200 + 4 * i) / 4] = sim_regs[(0x200 + 4 * (n - 1)) / 4];
            sim_regs[0x008 / 4] = n - 1;
            sim_regs[0x048 / 4] &= ~(1u << (n - 1));
            return;
        }
}
static void sim_click_action(int action, int arg)
{
    draw_all();
    for (int z = 0; z < nzones; z++)
        if (zones[z].action == action && (arg < 0 || zones[z].arg == arg)) { click(zones[z].x + 2, zones[z].y + 2); return; }
    printf("SIM: no zone for action %d\n", action);
}
static void sim_send(void)                       // the PL is free at once in the simulation: send + print the payload
{
    sim_regs[0x070 / 4] = 0;
    if (!send_next()) { printf("SIM: nothing sent\n"); return; }
    uint8_t b[16];
    for (int j = 0; j < 16; j++) b[j] = sim_regs[0x060 / 4 + j / 4] >> (8 * (j % 4));
    printf("admin frame payload:");
    for (int j = 0; j < 15; j++) printf(" %02X", b[j]);
    printf("\n");
}
#endif

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : "/mnt/sd/map";
    load_maps(dir);
    if (!nmaps) { fprintf(stderr, "no map_z*.bin found in %s\n", dir); return 1; }
    zi = nmaps > 1 ? 1 : 0;
    night_lut();
    if (getenv("ATAK_DAY")) night = 0;               // start with the day map

#ifdef SIM
    static uint32_t sim_fb[W * H];
    int scene = argc > 2 ? atoi(argv[2]) : 0;
    admin_id_file = "sim_admin_msg_id";
    area_file = "sim_area.txt";
    teams_file = "sim_teams.txt";
    fb = sim_fb;
    pl = sim_regs;
    sim_fill();
    load_admin_id();
    area_n = 0;                                     // scenes start without an area
    poll_pl();
    fit_nodes();
    mx = 700; my = 300;
    if (argc > 3) zoom(atoi(argv[3]), MAPW / 2, H / 2);
    if (scene == 1) select_marker(find_marker(0x157C, 216), 0);
    if (scene == 2) {                               // press Approve on the oldest request, then Delete twice on POI
        sim_click_action(A_APPROVE, -1);
        sim_send();
        select_marker(find_marker(0x157D, 40), 0);
        sim_click_action(A_DELETE, -1);
        sim_click_action(A_DELETE, -1);
        sim_send();
    }
    if (scene >= 3) {                               // draw an area around 157C / 157E with the mouse (157D outside)
        static const int32_t la[5] = { 409853000, 409853000, 409840000, 409843500, 409840000 };
        static const int32_t lo[5] = { 288530000, 288570000, 288570000, 288550000, 288530000 };
        sim_click_action(A_AREA, -1);
        for (int i = 0; i < 5; i++) {
            double sx, sy;
            to_screen(la[i], lo[i], &sx, &sy);
            click((int)lround(sx), (int)lround(sy));
        }
        if (scene == 3) { mx = 640; my = 520; }     // still drawing: the 6th corner follows the mouse
        else {
            sim_click_action(A_AREA_DONE, -1);
            for (int r = 0; r < AREA_REPORTS; r++) { sim_next_reports(); poll_pl(); check_area(); }
            sim_send();                             // GO BACK to 157D
            printf("157D in area: %d, 157C in area: %d\n", in_area(409832150, 288550200), in_area(409846150, 288538200));
        }
    }
    if (scene == 5) {                               // right click next to 157C (selected): signal box
        sel_type = 1; sel_node = 0x157C;
        double sx, sy;
        to_screen(409848000, 288545000, &sx, &sy);
        right_click((int)sx, (int)sy);
        mx = (int)sx + 60; my = (int)sy + 95;
    }
    if (scene == 7) {                               // Send button, then a click next to 157E: signal box to ALL
        sim_click_action(A_SEND, -1);
        draw_all();
        mx = 300; my = 160;
        double sx, sy;
        to_screen(409845000, 288562000, &sx, &sy);
        click((int)sx, (int)sy);
        sim_click_action(A_SIG_KIND, 4);
        sim_send();
        sim_click_action(A_SEND, -1);
        mx = 400; my = 600;
    }
    if (scene == 8) {                               // admin sends a HAZARD, then deletes it (Delete, Confirm?)
        double sx, sy;
        to_screen(409848000, 288545000, &sx, &sy);
        right_click((int)sx, (int)sy);
        sim_click_action(A_SIG_KIND, 2);
        sim_send();
        click((int)sx, (int)sy);                    // select it on the map
        sim_click_action(A_DELETE, -1);
        sim_click_action(A_DELETE, -1);
        sim_send();
    }
    if (scene == 9) {                               // ACKs: HAZARD to 157C, RALLY to all, HOLD HERE to 157D (no answer)
        double sx, sy;
        uint8_t id_c, id_all, id_d;
        sel_type = 1; sel_node = 0x157C;
        to_screen(409848000, 288545000, &sx, &sy);
        right_click((int)sx, (int)sy);
        sim_click_action(A_SIG_KIND, 2);
        id_c = admin_id; sim_send();
        sel_type = 0;
        to_screen(409838000, 288556000, &sx, &sy);
        right_click((int)sx, (int)sy);
        sim_click_action(A_SIG_KIND, 3);
        id_all = admin_id; sim_send();
        sel_type = 1; sel_node = 0x157D;
        to_screen(409828000, 288548000, &sx, &sy);
        right_click((int)sx, (int)sy);
        sim_click_action(A_SIG_KIND, 5);
        id_d = admin_id; sim_send();
        int k = sim_regs[0x04C / 4];                // the nodes answer (3 DELIVERED copies from 157C: 2 duplicates)
        uint8_t dl[9] = { 1, 0xFE, 0xFF, id_c }, sn[9] = { 2, 0xFE, 0xFF, id_c }, sa[9] = { 2, 0xFE, 0xFF, id_all };
        for (int c = 0; c < 3; c++) sim_fifo(k++, 0xC5, 0x157C, ADMIN_ADDR, (uint8_t)c, dl, 1001);
        sim_fifo(k++, 0xC5, 0x157C, ADMIN_ADDR, 3, sn, 1003);
        sim_fifo(k++, 0xC5, 0x157C, ADMIN_ADDR, 4, sa, 1003);
        sim_fifo(k++, 0xC5, 0x157E, ADMIN_ADDR, 7, sa, 1004);
        sim_regs[0x04C / 4] = k;
        poll_pl();
        for (int r = 0; r < 3; r++) {               // 157D never answers: 2 re-sends 5 s apart, then NO ACK
            sim_regs[0x038 / 4] += ACK_RETRY_S;
            poll_pl(); check_acks();
            if (dq_n) sim_send();
        }
        sim_regs[0x038 / 4] += ACK_RETRY_S;
        poll_pl();
        struct sent *sd = find_sent(id_d);
        printf("157D before its late SEEN: %s\n", sd->tries >= ACK_TRIES && now_s - sd->t_last >= ACK_RETRY_S ? "NO ACK" : "?");
        uint8_t sd_seen[9] = { 2, 0xFE, 0xFF, id_d };  // only SEEN comes, 3 copies (DELIVERED lost), after NO ACK
        for (int c = 0; c < 3; c++) sim_fifo(k++, 0xC5, 0x157D, ADMIN_ADDR, (uint8_t)(10 + c), sd_seen, 1020);
        sim_regs[0x04C / 4] = k;
        poll_pl();
        struct ackn *ad = find_ackn(sd, 0x157D);
        printf("157D after: delivered %d seen %d\n", ad ? ad->dlv : 0, ad ? ad->seen : 0);
        printf("acks ok %u dup %u unknown %u; sent ids 157C %u, all %u, 157D %u\n", a_ok, a_dup, a_unknown, id_c, id_all, id_d);
        select_marker(find_marker(ADMIN_ADDR, id_c), 0);
    }
    if (scene == 10) {                              // mesh: 0F53 relayed by 157C; 157E heard directly but asks for a relay
        uint32_t la = 409839350, lo = 288537600, *w = &sim_regs[(0x100 + 16 * 4) / 4];
        w[0] = 0x0F53 | (5u << 16) | (la << 24);
        w[1] = (la >> 8) | (lo << 24);
        w[2] = (lo >> 8) | (0x02u << 24);           // flags bit 1: wants a relay
        w[3] = (uint8_t)-46 | (12u << 8) | (2u << 16);
        sim_regs[(0x200 + 4 * 4) / 4] = 0x0DCF157C; // via 157C, relay RSSI -49, SNR 13
        sim_regs[(0x240 + 4 * 4) / 4] = 0x7C150001; // v10: the relayer it chose (not a member: shown as dev_id)
        w[2] |= 0x84u << 24;                        // via relay + a direct copy too (v11 merge: "+D")
        sim_regs[(0x100 + 16 * 1 + 8) / 4] |= 0x02u << 24;
        sim_regs[0x008 / 4] = 5; sim_regs[0x048 / 4] = 0x17; sim_regs[0x078 / 4] = 7;
        poll_pl();
        sel_type = 1; sel_node = 0x0F53;
    }
    if (scene == 6) {                               // send a HAZARD to all from the signal box, then open the area box
        double sx, sy;
        to_screen(409848000, 288545000, &sx, &sy);
        right_click((int)sx, (int)sy);
        sim_click_action(A_SIG_KIND, 2);
        sim_send();
        sim_click_action(A_AREA, -1);
    }
    if (scene >= 11 && scene <= 15) {               // teams + join requests (Aykut's golden frames); 13 kick, 14 leave
        sim_click_action(A_TEAMS, -1);
        sim_click_action(A_TEAM_OPEN, -1);          // ALPHA
        sim_click_action(A_TEAM_OPEN, -1);          // BRAVO
        teams[1].pin = 1234; teams[2].pin = 5678;
        int k = sim_regs[0x04C / 4];
        sim_a1(k++, 0x9B9D0B15, 1, 2, 1234, 0, 1001);   // ALPHA-2, good PIN: waits for the admin
        sim_a1(k++, 0x9B9D0B15, 1, 2, 1234, 1, 1011);   // its repeat 10 s later: the same request
        sim_a1(k++, 0x11223344, 2, 0, 1111, 0, 1012);   // BRAVO, wrong PIN: answered at once
        sim_a1(k++, 0x55667788, 3, 1, 0, 0, 1013);      // CHARLIE is not open
        sim_a1(k++, 0x0BADF00D, 2, 1, 5678, 0, 1014);   // BRAVO-1, good PIN: waits
        sim_regs[0x04C / 4] = k; sim_regs[0x038 / 4] = 1015;
        poll_pl();
        while (dq_n) sim_send();
        if (scene >= 12) {
            static const uint8_t gold[15] = { 0xA2, 0xFE, 0xFF, 0xFF, 0xFF, 0x30, 0x15, 0x0B, 0x9D, 0x9B, 0x02, 0x81, 0x01, 0x02, 0x00 };
            admin_id = 0x30;
            sim_click_action(A_JOIN_OK, -1);        // the oldest waiting: ALPHA-2
            int wl_before = 0;
            for (int i = 0; i < 64; i++) wl_before |= (sim_wl[i] & 0x1FFFF) == 0x18102;
            sim_send();
            uint8_t b[15];
            for (int j = 0; j < 15; j++) b[j] = sim_regs[0x060 / 4 + j / 4] >> (8 * (j % 4));
            printf("A2 = golden frame payload: %s; 8102 in the whitelist before the A2 went out: %d\n",
                   memcmp(b, gold, 15) ? "NO" : "yes", wl_before);
            uint8_t dv[9] = { 1, 0xFE, 0xFF, 0x30 };
            sim_fifo(k++, 0xC5, 0x8102, ADMIN_ADDR, 0, dv, 1016);   // DELIVERED from the new address
            uint32_t la = 409840150, lo = 288545200, *w = &sim_regs[(0x100 + 16 * 4) / 4];
            w[0] = 0x8102 | (1u << 16) | (la << 24); w[1] = (la >> 8) | (lo << 24); w[2] = lo >> 8;
            w[3] = (uint8_t)-52 | (11u << 8) | (2u << 16);
            sim_regs[0x008 / 4] = 5; sim_regs[0x048 / 4] |= 1u << 4;
            sim_a1(k++, 0x9B9D0B15, 1, 2, 1234, 7, 1020);           // re-join (flash erased), good PIN: automatic
            for (int r = 0; r < 3; r++) sim_a1(k++, 0xDEAD0001, 2, 3, 1000 + r, r, 1021 + r);   // 3 wrong: dev locked
            sim_a1(k++, 0xDEAD0001, 2, 3, 5678, 3, 1024);           // even the right PIN: ignored while locked
            sim_a1(k++, 0xDEAD0002, 2, 3, 2000, 0, 1025);           // 5th wrong PIN for BRAVO: team locked
            sim_a1(k++, 0x0BADF00E, 2, 4, 5678, 0, 1026);           // good PIN, but BRAVO is locked: ignored
            sim_regs[0x04C / 4] = k; sim_regs[0x038 / 4] = 1030;
            poll_pl();
            while (dq_n) sim_send();
            printf("members %d, ignored %u, BRAVO locked %d, dev DEAD0001 locked %d\n", nmembers, j_ignored,
                   team_locked(2), dev_locked(0xDEAD0001));
            sel_type = 1; sel_node = 0x8102;
            if (scene == 12) team_view = 1;         // ALPHA's member list (Kick)
        }
        if (scene == 13) {                          // the admin kicks ALPHA-2 from its details box
            int k = sim_regs[0x04C / 4];
            draw_all();
            sim_click_action(A_KICK, 0x8102);
            sim_click_action(A_KICK, 0x8102);       // Confirm?
            while (dq_n) sim_send();
            struct sent *s = find_sent(admin_id - 1);
            int wl = 0;
            for (int i = 0; i < 64; i++) wl |= (sim_wl[i] & 0x1FFFF) == 0x18102;
            printf("after Kick: member %d, in whitelist %d, in table %d\n", find_member_addr(0x8102) >= 0, wl,
                   find_node(0x8102) >= 0);
            uint8_t dv[9] = { 1, 0xFE, 0xFF, s ? s->id : 0 };
            sim_fifo(k++, 0xC5, 0x8102, ADMIN_ADDR, 0, dv, 1031);   // the node's DELIVERED for the KICK
            sim_regs[0x04C / 4] = k; sim_regs[0x038 / 4] = 1032;
            poll_pl(); check_acks(); poll_pl();
            wl = 0;
            for (int i = 0; i < 64; i++) wl |= (sim_wl[i] & 0x1FFFF) == 0x18102;
            printf("after its DELIVERED: in whitelist %d, in table %d, nodes %d\n", wl, find_node(0x8102) >= 0, nnodes);
            sel_type = 0;
        }
        if (scene == 14) {                          // ALPHA-2 leaves by itself (0xA4); the team's member list is open
            int k = sim_regs[0x04C / 4];
            uint8_t lv[9] = { 0x15, 0x0B, 0x9D, 0x9B };              // dev_id 9B9D0B15
            sim_fifo(k++, 0xA4, 0x8102, ADMIN_ADDR, 9, lv, 1031);
            sim_regs[0x04C / 4] = k; sim_regs[0x038 / 4] = 1032;
            poll_pl();
            while (dq_n) sim_send();
            poll_pl();
            int wl = 0;
            for (int i = 0; i < 64; i++) wl |= (sim_wl[i] & 0x1FFFF) == 0x18102;
            printf("after LEAVE: member %d, in whitelist %d, in table %d, nodes %d\n", find_member_addr(0x8102) >= 0, wl,
                   find_node(0x8102) >= 0, nnodes);
            sel_type = 0;
            team_view = 1;
        }
        if (scene == 15) {                          // kick a node that never answers (dead), then it tries to join again
            int k = sim_regs[0x04C / 4];
            draw_all();
            sim_click_action(A_KICK, 0x8102);
            sim_click_action(A_KICK, 0x8102);
            while (dq_n) sim_send();
            for (int s = 0; s < 4; s++) {           // 5 s steps, no DELIVERED ever
                sim_regs[0x038 / 4] += ACK_RETRY_S;
                poll_pl(); check_acks();
                while (dq_n) sim_send();
                int wl = 0;
                for (int i = 0; i < 64; i++) wl |= (sim_wl[i] & 0x1FFFF) == 0x18102;
                poll_pl();
                printf("t+%ds: in whitelist %d, in table %d\n", 5 * (s + 1), wl, find_node(0x8102) >= 0);
            }
            sim_a1(k++, 0x9B9D0B15, 1, 2, 1234, 9, sim_regs[0x038 / 4]);   // the kicked device, right PIN
            sim_regs[0x04C / 4] = k;
            poll_pl();
            while (dq_n) sim_send();
            int w = find_join_wait(0x9B9D0B15);
            printf("kicked device joins again: %s, member %d\n", w >= 0 ? "waits for the admin" : "NOT waiting",
                   find_member(0x9B9D0B15) >= 0);
            sel_type = 0;
        }
    }
    if (scene == 16) {                              // v9 security: SECURE_TX on, a node mark + its relayed copy
        sim_regs[0x088 / 4] = 1;
        sim_regs[0x0A0 / 4] = 523; sim_regs[0x0AC / 4] = 2; sim_regs[0x0B0 / 4] = 1; sim_regs[0x0A4 / 4] = 0;
        uint32_t k = sim_regs[0x04C / 4];
        sim_mark(k % 64, 0x8102, 0xFFFF, 9, 2, 409840000, 288545000, 1000); k++;
        sim_mark(k % 64, 0x8102, 0xFFFF, 9, 2, 409840000, 288545000, 1001); k++;   // the same mark again
        sim_regs[0x04C / 4] = k;
        poll_pl();
        printf("queued after a new mark + its duplicate: %d\n", dq_n);
        while (dq_n) sim_send();
        printf("re-broadcasts %u, next admin msg_id still %u\n", c1_relayed, admin_id);
    }
    draw_all();
    frame_full();
    FILE *f = fopen("sim_screen.raw", "wb");
    fwrite(sim_fb, 4, W * H, f);
    fclose(f);
    printf("wrote sim_screen.raw (1280x720 BGRX)\n");
    return 0;
#else
    if (argc > 2) admin_id_file = argv[2];
    if (argc > 3) area_file = argv[3];
    if (argc > 4) teams_file = argv[4];
    int mem = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem < 0) { perror("/dev/mem (run as root)"); return 1; }
    fb = mmap(NULL, W * H * 4, PROT_READ | PROT_WRITE, MAP_SHARED, mem, FB_BASE);
    vdma = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, mem, VDMA_BASE);
    pl = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, mem, PL_BASE);
    if (fb == MAP_FAILED || vdma == MAP_FAILED || pl == MAP_FAILED) { perror("mmap"); return 1; }
    pl_id = pl[0];
    if (pl_id != PL_ID && pl_id != PL_ID_V11 && pl_id != PL_ID_V10 && pl_id != PL_ID_V9 && pl_id != PL_ID_V8 && pl_id != PL_ID_V7 &&
        pl_id != PL_ID_V6 && pl_id != PL_ID_V5 && pl_id != PL_ID_V4) {
        fprintf(stderr, "atk_axi v4..v11 not found (ID %08X)\n", pl_id);
        return 1;
    }
    if (pl_id == PL_ID_V4) printf("atk_axi v4: no 0xC5 ACKs from this PL (commands are still retried)\n");
    if (pl_id < PL_ID_V6) printf("atk_axi before v6: no relay info (relayed nodes look like direct ones)\n");
    if (pl_id < PL_ID_V7) printf("atk_axi before v7: no join requests (devices cannot join)\n");
    if (pl_id < PL_ID_V8) printf("atk_axi before v8: kicked / leaving nodes stay in the table until stale\n");
    if (pl_id < PL_ID_V9) printf("atk_axi before v9: no security (plain frames only)\n");
    if (pl_id < PL_ID_V10) printf("atk_axi before v10: no chosen relayer, via-relay bit not set by the PL\n");
    if (pl_id < PL_ID_V11) printf("atk_axi before v11: no copy merge (flags bit 7 \"direct copy\" not set)\n");
    srand(time(NULL) ^ getpid());
    load_admin_id();
    load_area();
    load_teams();
    members_to_wl();

    for (int i = 0; i < W * H; i++) fb[i] = shown[i] = C_BG;
    vdma[0x00 / 4] = 0x4;                // MM2S_VDMACR: reset
    usleep(1000);
    vdma[0x00 / 4] = 0x3;                // run + circular
    vdma[0x5C / 4] = FB_BASE;            // MM2S_START_ADDRESS1
    vdma[0x58 / 4] = W * 4;              // stride
    vdma[0x54 / 4] = W * 4;              // HSIZE
    vdma[0x50 / 4] = H;                  // VSIZE: starts

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    open_inputs();
    poll_pl();
    fit_nodes();
    double t_poll = 0, t_scan = now_ms(), t_draw = 0, t_send = 0, t_wl = now_ms();
    int dirty = 1, moved = 0, hz = -1;                 // hz: the click zone under the mouse at the last full redraw
    while (!quit) {
        struct pollfd p[16];
        int np = 0;
        for (int i = 0; i < 16; i++) if (evfd[i] > 0) { p[np].fd = evfd[i]; p[np].events = POLLIN; np++; }
        poll(p, np, 50);
        t_now_ms = now_ms();
        int in = read_inputs();
        if (in & 2) dirty = 1;
        if (in & 1) { moved = 1; if (zone_under_mouse() != hz) dirty = 1; }   // onto another button: redraw
        double t = now_ms();
        if (t - t_poll >= 250) { poll_pl(); check_area(); check_acks(); t_poll = t; }
        if (dq_n && t - t_send >= SEND_GAP_MS && send_next()) { t_send = t; dirty = 1; }
        if (t - t_scan >= 2000) { open_inputs(); t_scan = t; }
        if (t - t_wl >= 10000) { members_to_wl(); t_wl = t; }
        if ((dirty && t - t_draw >= 33) || t - t_draw >= 1000) {   // at most 30 full redraws / s, at least 1 / s
            draw_all();
            frame_full();
            hz = zone_under_mouse();
            t_draw = t;
            dirty = moved = 0;
        } else if (moved) {
            frame_overlay();
            moved = 0;
        }
    }
    for (int i = 0; i < W * H; i++) bb[i] = C_BG;
    text(&font_l, 40, 40, C_TEXT, 255, "A.T.A.K. GUI stopped");
    memcpy(ob, bb, sizeof ob);
    present();
    return 0;
#endif
}
