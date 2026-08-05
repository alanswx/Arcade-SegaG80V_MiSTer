# Hardware verification checklist

For whoever takes this to the DE10-Nano. Everything in `sim/` is verified
against MAME in simulation; this file lists only what **cannot** be checked
without real hardware, plus what is known good so you don't re-test it.

Run `cd sim && make all` first — 17/17 should pass before a build is worth
doing. If any of those fail, fix that before touching Quartus.

---

## Confirmed working on hardware

Do not re-verify unless something regressed.

| Date | What |
|---|---|
| 2026-08-03 | All five games boot, render attract screens, DE10-Nano |
| 2026-08-04 | Havoc renderer migration, 125 MHz PLL, new clock topology |

### Resource note

The Universal Sound Board adds a second 8035 (`tv48`), 4K of shared program RAM
and 1K of work RAM. If the fit gets tight, that is the newest thing in the
build. `usb_filter.sv` is deliberately multiplier-free apart from three shared
envelope DAC gains, so it should cost logic rather than DSPs.

---

## Open — needs eyes on a screen

### 1. `READ_ADVANCE` — one-pixel alignment

`rtl/videodr0me_fb/vfb_readout.sv` sets `READ_ADVANCE = 10` where Major Havoc
uses 9. The Sega colour path is one register deeper than Havoc's (the shoulder
add is registered ahead of the per-gun ladder), and `READ_ADVANCE` sizes the
sync/blank shift register to match the datapath depth.

Reasoned from the stage count, never seen. **Check:** the picture should not be
shifted one pixel horizontally relative to its blanking, and the leftmost
column should not show the previous line's last pixel. If it looks worse than
with 9, revert it and say so.

### 2. Colour — the whole point of the 6-bit work

Sega drives each gun from a 2-bit ladder; `vfb_dac_ladder.sv` implements
0 / ⅓ / ⅔ / full. Verified numerically, never seen.

**Check:** Eliminator should show a distinct **orange** (`R3 G1 B0`) — 8% of
all its beam-on samples, and the single colour that motivated this work. If it
looks red or yellow rather than orange, the ladder or the colour field is
wrong. Space Fury and Star Trek use nearly the whole 64-colour palette, so
banding or wrong hues there are also a tell.

### 3. `PHASE_CLKS` — the one unresolved hardware question

`rtl/xy/sega_xy.sv` parameter, currently **16** (MAME's value). MAME's own
header says *"the games seem to run too fast"*. Reading U51/U50 on
`XY_Timing_800-0161` sheet 7/7 suggests it may be 1.

Both values pass the golden-model tests, so only hardware can settle it.
**Check:** does attract-mode animation and object motion run at a plausible
speed? If everything looks too fast or too slow, rebuild with `PHASE_CLKS = 1`
and compare. Whichever looks right, record it here.

### 4. Controls

Transcribed from MAME's `INPUT_PORTS_START` blocks but only Eliminator has ever
been played. **Check per game:** buttons do what the label says, both players
work, and for Eliminator 4-player that players 3 and 4 respond (they come
through a demux on the `$F8` select latch, which is the fiddliest part).

### 5. Spinner — never exercised at all

Zektor, Tac/Scan and Star Trek. Uses `hps_io` `spinner_0/1` (toggle strobe with
a signed delta), with the d-pad as a fallback.

**Check:** a real spinner or mouse rotates the ship smoothly in both
directions, and the self-test's spinner reading counts *upward* whichever way
you turn (that is deliberate — the port returns a monotonic count with
direction in bit 0). Sensitivity may well need tuning; the divider is in
`Arcade-SegaG80V.sv`.

### 6. Tac/Scan orientation

The only game with swapped axes (`SWAP_XY | FLIP_X | FLIP_Y`), rendered into a
portrait 832×1024 target. **Check:** it is rotated the right way and fills the
screen sensibly at 720p and 1080p.

### 7. Audio — nothing has ever been heard

Implemented and verified in simulation, **never played through a speaker**:

| Board | Games | Verification |
|---|---|---|
| AY-3-8912 | Zektor | jt49, standard part |
| Speech board (8035 + SP0250) | Space Fury, Zektor, Star Trek | SP0250 bit-exact vs MAME |
| Universal Sound Board (8035 + 3× 8253) | Tac/Scan, Star Trek | 8253 and MM5837 bit-exact; analog chain correlates 1.00000 with MAME |

**Not** implemented: the discrete sound boards (Eliminator, Space Fury, Zektor),
so silence from those is expected rather than a bug.

**Check:**
- Zektor makes music and effects.
- **Space Fury speaks.** The SP0250 is bit-exact against MAME in simulation but
  the 8035 has never been seen executing the speech program. The attract line
  is *"So, a creature for my amusement. Prepare for battle!"*.
- Star Trek and Zektor also speak.
- **Tac/Scan makes music.** This is the Universal Sound Board's only outing
  where nothing else can mask it — Star Trek has the speech board too.
- Nothing clicks, buzzes or clips.

If speech is silent, the likely suspects in order: the `$38`/`$3B` write
strobes, the T0/INT handshake off the latch's bit 7, and the speech-data ROM
paging through P2. If it is present but garbled, suspect the ROM layout or the
data-ROM bank rather than the SP0250 itself.

If the **USB** is silent, note that the boot bench already proves a lot of the
chain: Tac/Scan writes all 4096 bytes of the 8035 program through the scrambled
`$D000` window, `/LOAD` releases the 8035, and the board produces audio. So
suspect the *level*, not the plumbing — `usb_filter.sv` deliberately carries
12 dB of headroom (MAME's nominal 1.0 maps to a quarter of full scale, because
MAME's own value for this chain peaks at 3.26), and `Arcade-SegaG80V.sv` halves
it again in the mix. If it is present but too quiet, raise it there rather than
inside the filter.

**Level balance between boards is a guess and needs an ear.** The mix in
`Arcade-SegaG80V.sv` is `audio_ay + (audio_speech >>> 1) + (audio_usb >>> 1)`.
Nothing in simulation can tell you whether those relative weights are right.

**MRAs must be regenerated** for this — the ROM image grew from 0xC400 to
0x10C00 bytes to carry the speech ROMs. Old MRAs will load a truncated image.

---

## Timing

`SEED 2` in the `.qsf` and `Arcade-SegaG80V.sdc` follow `MajorHavoc.sdc`.

If it stops closing, check the timing report for **unconstrained clocks** first
— particularly `emu_clk_vec`, which comes from the standalone `sega_clocks`
PLL outside the framework hierarchy and needs its own asynchronous groups
against `FPGA_CLK1_50`, `pll_audio` and `pll_hdmi`. Those groups are already in
the SDC; if the instance path changes they will silently match nothing.

## Requirements

- Quartus 17.0.x Lite
- **32 MB SDRAM module** in addition to DDR3 — `videodr0me_fb` keeps its
  halo-alignment delay line in SDRAM
- ROMs are not included; MRAs are in `mra/`

## Reporting back

Anything that needs changing: note the game, the video mode, and what you saw.
For colour and geometry a photo is worth more than a description — the
simulation can reproduce the display list exactly (`sim/tools/render.cpp`), so
a picture makes it possible to tell a rendering bug from a machine bug.
