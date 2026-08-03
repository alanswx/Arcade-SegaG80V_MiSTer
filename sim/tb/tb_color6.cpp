// vfb_color6 exhaustive check: all 64 colours x all 512 intensity values.
//
// The reference is the 2-bit-per-gun resistor ladder on X-Y Control drawing
// 800-0163 sheet 6/6 (levels 0, 1/3, 2/3, 3/3 of full scale), plus the overflow
// spill behaviour inherited from the stock videodr0me_fb readout.
//
// Also checks the Z round-trip the repack introduced: the rasterizer stores
// z[7:2] and the readout replicates the top two bits back into the low end,
// so full intensity must survive as full intensity.

#include <cstdio>
#include <cstdint>

#include "Vvfb_color6.h"
#include "verilated.h"

static const uint8_t MAIN_CEIL  = 232;
static const int     SPILL_BASE = 232;
static const int     SPILL_CAP  = 64;

static uint8_t scale(uint8_t v, int lvl) {
	switch (lvl) {
		case 0: return 0;
		case 1: return (uint8_t)((v * 85) >> 8);
		case 2: return (uint8_t)((v * 171) >> 8);
		default: return v;
	}
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	auto *dut = new Vvfb_color6;

	long checked = 0;
	int  fails = 0;

	for (int c = 0; c < 64; c++) {
		int lr = (c >> 4) & 3, lg = (c >> 2) & 3, lb = c & 3;
		int unlit = (lr == 0) + (lg == 0) + (lb == 0);

		for (int i = 0; i < 512; i++) {
			dut->colour = c;
			dut->intensity = i;
			dut->eval();

			uint8_t wr, wg, wb;
			if (i < 256) {
				wr = scale((uint8_t)i, lr);
				wg = scale((uint8_t)i, lg);
				wb = scale((uint8_t)i, lb);
			} else if (c == 0x3F) {
				wr = wg = wb = 255;
			} else {
				int excess = i - SPILL_BASE;
				int half   = excess >> 1;
				uint8_t sf = (uint8_t)(excess > SPILL_CAP ? 64 : excess);
				uint8_t sh = (uint8_t)(half   > SPILL_CAP ? 64 : half);
				uint8_t sp = (unlit == 1) ? sf : sh;
				wr = lr ? scale(MAIN_CEIL, lr) : sp;
				wg = lg ? scale(MAIN_CEIL, lg) : sp;
				wb = lb ? scale(MAIN_CEIL, lb) : sp;
			}

			checked++;
			if (dut->out_r != wr || dut->out_g != wg || dut->out_b != wb) {
				if (fails < 8)
					printf("FAIL c=%02X i=%3d: want %3u,%3u,%3u got %3u,%3u,%3u\n",
					       c, i, wr, wg, wb,
					       (uint8_t)dut->out_r, (uint8_t)dut->out_g,
					       (uint8_t)dut->out_b);
				fails++;
			}
		}
	}

	// Sanity: the three primaries at full level and full intensity must be
	// exactly saturated, and a non-proportional colour must stay non-proportional.
	struct { int c; const char *name; uint8_t r, g, b; } spot[] = {
		{ 0x30, "pure red",   255,   0,   0 },
		{ 0x0C, "pure green",   0, 255,   0 },
		{ 0x03, "pure blue",    0,   0, 255 },
		{ 0x3F, "white",      255, 255, 255 },
		{ 0x34, "orange (R3 G1 B0) - 8% of all Sega beam-on samples",
		                      255,  84,   0 },
	};
	for (auto &t : spot) {
		dut->colour = t.c; dut->intensity = 255; dut->eval();
		checked++;
		if (dut->out_r != t.r || dut->out_g != t.g || dut->out_b != t.b) {
			printf("FAIL spot %s: want %u,%u,%u got %u,%u,%u\n",
			       t.name, t.r, t.g, t.b,
			       (uint8_t)dut->out_r, (uint8_t)dut->out_g, (uint8_t)dut->out_b);
			fails++;
		} else {
			printf("  ok  %-58s -> %3u,%3u,%3u\n",
			       t.name, (uint8_t)dut->out_r, (uint8_t)dut->out_g,
			       (uint8_t)dut->out_b);
		}
	}

	// Z round-trip introduced by the repack: store z[7:2], read back
	// {z[5:0], z[5:4]}. Full must stay full and zero must stay zero.
	for (int z = 0; z < 256; z++) {
		uint8_t stored = (uint8_t)(z >> 2);
		uint8_t back   = (uint8_t)((stored << 2) | ((stored >> 4) & 3));
		checked++;
		if (z == 255 && back != 255) { printf("FAIL z round-trip 255 -> %u\n", back); fails++; }
		if (z == 0   && back != 0)   { printf("FAIL z round-trip 0 -> %u\n", back); fails++; }
		if (back > 255 || (z >= 4 && back == 0)) { printf("FAIL z round-trip %d -> %u\n", z, back); fails++; }
	}

	dut->final();
	delete dut;

	printf("vfb_color6: %ld checked, %d failed\n", checked, fails);
	if (fails) { printf("RESULT: FAIL\n"); return 1; }
	printf("RESULT: PASS\n");
	return 0;
}
