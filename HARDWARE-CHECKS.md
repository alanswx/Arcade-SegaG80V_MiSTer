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

### 7a. FOUND: the t48 core ignored T0 (fixed)

`rtl/tv48/t48_core.v` passed both T0 and T1 into the conditional-branch unit
through a std_logic table lookup that the VHDL-to-Verilog translation gets
wrong. `t1_i` had already been bypassed with a hand edit; `t0_i` had not. The
result was that **`JT0` / `JNT0` never saw the pin**, so `JNT0` took its branch
forever.

That is exactly what the Sega speech board polls to notice a pending word:

```
22E: JT1 239      ; DRQ set -> feed the SP0250 a frame   (worked: T1 was patched)
230: JNT0 22E     ; T0 clear -> keep waiting             (never fell through)
232: IN A,P1      ; T0 set -> read the word number
233: CALL 43B     ; ack: OUTL P1,#7F pulses P1.7 low, clearing T0
```

So the 8035 sat in that four-instruction loop forever, dutifully feeding the
SP0250 silence, which is why the board fed exactly 15 bytes per DRQ and every
byte was 00. With `t0_i` wired directly the program advances: addresses touched
went 166 -> 299 and all three of Space Fury's power-on words are now consumed.

This affects **both** sound boards — they are the only users of `i8035`.

### 7b. Sound status by game (2026-08-05)

All four implemented boards now produce audio from a running game. Measured by
`make audio`, which coins up, starts, and records 30 s at 48 kHz.

| Game | Boards fitted | State | Level |
|---|---|---|---|
| Eliminator 2P/4P | discrete only | **silent — board not implemented** | — |
| Space Fury | speech + discrete | speech **works**; discrete not implemented | speech -6.2 dBFS |
| Zektor | AY-3-8912 + speech + discrete | AY **works**, speech **works**; discrete not implemented | AY -30.1, speech -6.0 dBFS |
| Tac/Scan | Universal Sound Board | **works** | -9.4 dBFS |
| Star Trek | speech + USB (through the speech CD4053) | **works**, both | speech -14.9 dBFS |

The Universal Sound Board's fixed-point analog chain tracks MAME's
double-precision model on real gameplay, not just synthetic stimulus:

```
USB analog chain, RTL vs MAME, on real Tac/Scan gameplay:
  correlation 0.999587   rms ratio 0.9990
```

Two things that took a while to learn and are worth keeping:

- **Coin pulse width matters.** Space Fury's routine counts down from 231
  retries at ~0.67 ms while waiting for release, and rejects the coin if the
  loop runs out (>~155 ms, "stuck coin") or too few retries elapsed (<~21 ms,
  "bounce"). 100 ms works.
- **Start must be pulsed, not held.** The games sample START at specific points
  and want to see it released between presses. `make audio` pulses it at 5 Hz.

### 7c. Known gap: the speech board has no output filter

Comparing `spacfury_speech.wav` against a real cabinet recording shows the core
carrying much more energy above 700 Hz:

```
  band(Hz)    arcade    core
      163     0.133    0.041
      434     0.137    0.108
      903     0.013    0.070
     1880     0.008    0.053
     3066     0.002    0.046
  spectral-shape correlation 0.24
```

The cause is identified: **nothing filters the SP0250 output.** The raw DAC is a
10 kHz sample-and-hold and sounds correspondingly bright. MAME does not filter
it either — `segaspeech.cpp` has `#define ENABLE_NETLIST_FILTERING (0)`, so its
default path routes the SP0250 straight out, which is what this core matches.
The real board has an op-amp filter (R17-R21, C9/C10/C50 in
`refs/mame/nl_segaspeech.cpp`) that MAME only models in the disabled netlist
path.

So the speech *content* is right — the SP0250 is bit-exact against MAME and the
8035 runs the real program — but the *tone* will be brighter than a cabinet
until that filter is added. It is small: five resistors and three caps, the
same shift-add treatment as `usb_filter.sv`. Some of the low-frequency
difference above is also the cabinet speaker and the recording chain, so do not
chase the numbers exactly.

### 7d. Audio — what is still unheard on hardware

**2026-08-04: neither sound board produces audio in the assembled machine.**
Every component passes its bench (17/17, including bit-exact 8253, MM5837 and
SP0250), but `make audio` — which runs a real game through `segag80v` and
records the result — shows silence. That is a component-versus-system gap, and
it is worth stating plainly because the previous version of this file claimed
the audio was verified.

What `make audio` establishes, on Space Fury:

| Observation | Meaning |
|---|---|
| 799 frames drawn in 20 s, 12.8 M beam-on samples | the machine and video are fine |
| Z80 writes `$38` <- 3F, BF, 0F, 8F, 0E, 8E and `$3B` <- 28 | the game *does* ask for three words, and control bit 3 gates speech on |
| speech 8035 executes from 0x000 and its opcodes match the ROM | the 8035 core runs the right program |
| 3540 SP0250 writes / 236 DRQ edges = exactly 15:1 | the frame-feed loop works |
| every byte written to the SP0250 is 00 | it is feeding silence frames |
| T0 rises at t=53.2 ms and stays high | the request handshake reaches the board |
| P1.7 never goes low; **0 MOVX reads of the speech data ROM** | the 8035 never acknowledges and never fetches speech data |

So the speech 8035 sees the pending word and never acts on it. The Universal
Sound Board is the same story from the other end: Tac/Scan issues only 2 `$3F`
commands in 20 s and the recorded output has 42 non-zero samples in 960000 —
isolated clicks, not sound.

Things already ruled out, so nobody repeats them: the T0 rising-edge rule, the
P1 readback (`latch & 0x7F`, bit 7 = 0), the INT polarity and its power-on
state, the INT pulse width (6.78 us against a 4.81 us instruction cycle), the
DIP defaults (SW1 must be 0x8D — bit 1 is Demo Sounds and MAME defaults it
*on*), the 8035 clock (MAME feeds the crystal and divides by 15 internally,
which is what `t48` expects), and the speech ROM contents in the image.

Four real bugs were found and fixed on the way, none of which was the cause:
P2 is now latched at ALE alongside the low address byte (reading it live during
PSEN returns the written P2 register, not PC[11:8]); the write data bus is
sampled during WR rather than at its rising edge; T0 clears on the falling edge
of P1.7 rather than on its level; and the speech latch resets to 0x80 so INT is
not asserted from power-on.

The remaining suspect is the `t48`/`i8035` integration — both boards fail the
same way, and both are the only places this core uses that CPU.

### Previously written, still true as far as it goes

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
