# Audio implementation plan

Four independent subsystems, sequenced by impact per unit of work. The standard
to hold to is the one the rest of this core is built on and that Videodr0me set
for his own audio: **model the hardware, verify against MAME, don't approximate
where the real thing is knowable.**

| # | Subsystem | Games | Status |
|---|---|---|---|
| 1 | AY-3-8912 | Zektor | **done** |
| 2 | Speech board (8035 + SP0250) | Space Fury, Zektor, Star Trek | next |
| 3 | Universal Sound Board (8035 + 3× 8253) | Tac/Scan, Star Trek | after |
| 4 | Discrete boards | Eliminator, Space Fury, Zektor | last, open-ended |

---

## 1. AY-3-8912 — done

`rtl/sound/sega_ay.sv`. Zektor is the only X-Y game with a PSG.

- `AY8912` at `VIDEO_CLOCK/4/2` = 15468480/8 = 1.93356 MHz, from a fractional
  enable off `clk_12`.
- `$3C` latches the register address, `$3D` writes it — MAME's `write_ay()`
  calls `address_data_w(offset, data)`, where offset 0 is the address latch.
- `jt49` (vendored, GPL-3.0) provides the PSG.
- MAME sets `AY8910_RESISTOR_OUTPUT` with equal 10k loads on all three
  channels, so the per-channel linearised outputs are summed passively rather
  than using jt49's pre-mixed `sound`.

The `$3C/$3D` strobe is taken on the **falling** edge of the I/O cycle. `io_wr`
is a level held for the whole cycle and `ce_cpu` pulses several times inside
one; strobing per enable writes the register repeatedly. This is the same trap
the `$BD/$BE` multiplier hit — see `rtl/segag80v_cpu.sv`.

## 2. Speech board — next

**Hardware:** 8035 @ 3.12 MHz + **SP0250** LPC synthesiser, drawing 800-0294
(`refs/schematics/Speech_Board_800-0294_sheet5of5.png`). Reached at `$38`
(data) and `$3B` (control), both already decoded by `segag80v_cpu`.

**ROM:** `speech:cpu` 2 KB, `speech:data` up to 12 KB, plus a 32-byte 6331
addressing PROM. Present in `spacfury.zip`, `zektor.zip` and `startrek.zip`;
the MRA and `build_rom.py` both need extending to place them.

**What exists:** `rtl/i8035/i8035.v` is already vendored from
`Arcade-SegaVICZ80_MiSTer`. The SP0250 needs writing.

**References for the SP0250:**
- MAME `src/devices/sound/sp0250.cpp` — the authoritative decoder.
- `refs/cores/sega-vector/tools/wav2lpc.py` — a genuine SP0250 LPC **encoder**
  written from the SP0250 Applications Manual, with the real filter
  coefficient tables. Being able to encode as well as decode makes this
  testable end to end.

**Verification plan**, mirroring how the vector generator was done:
1. Port MAME's `sp0250.cpp` to a standalone C++ golden model.
2. Write `rtl/sound/sp0250.sv` and diff its sample stream against the golden
   model, driven by the real LPC data from the ROMs.
3. Boot-level: run `spacfury` under the existing `tb_boot` harness with the
   speech board attached and confirm the 8035 fetches and the `$38/$3B`
   handshake match MAME's.

**Note:** MAME's `segag80v.h` still `#include`s `tms5110.h`, which is
misleading — the real part is the SP0250 (`segaspeech.cpp` includes
`sound/sp0250.h`). Only the Italian *Advisor* bootleg uses a TMS5100, and it is
unimplemented in MAME too.

## 3. Universal Sound Board — after

**Hardware:** 8035 @ 6 MHz, three 8253 PITs, DACs, an MM5837 noise source and
analog filters. Drawing 800-0377, three sheets, in `refs/schematics/`.

**No ROM of its own** — the main Z80 downloads the program into the shared RAM
window at `$D000-$DFFF`, which is why that window goes through the security
scrambler. It is already wired in `segag80v_cpu`; the `usb_*` ports are
currently stubbed off in `segag80v.sv`.

**What's needed:** an 8253 PIT (none exists in any core checked; it is small),
the DAC/mixer chain, and the MM5837 LFSR. MAME's model is `segausb.cpp` (850
lines) plus `nl_segausb.cpp` (545 lines of netlist for the analog side).

Clocks from MAME: `USB_MASTER_CLOCK` 6 MHz, `USB_2MHZ_CLOCK` = /3,
`USB_PCS_CLOCK` = /2 again, `USB_GOS_CLOCK` = /16/4, `MM5837_CLOCK` 100 kHz.

**Verification:** the 8253 is exactly specifiable, so unit-test it against a C
model of all six modes the way `sega_ports` was done. The analog chain is
better judged by ear against MAME.

## 4. Discrete boards — last

Eliminator, Space Fury and Zektor each have an analog sound board driven by
latches at `$3E/$3F`. MAME models them as netlists: `nl_elim.cpp` is 1227 lines
(and also carries Zektor's), `nl_spacfury.cpp` 1106.

The trigger lines are named in the netlists, so the scope is known exactly:

**Eliminator** — 7 lines at `$3E`, 8 at `$3F`:

| Line | Sound | | Line | Sound |
|---|---|---|---|---|
| LO D1 | Fireball | | HI D0 | Thrust low |
| LO D2 | Explosion 1 | | HI D1 | Thrust high |
| LO D3 | Explosion 2 | | HI D2 | Thrust level LSB |
| LO D4 | Explosion 3 | | HI D3 | Thrust level MSB |
| LO D5 | Bounce | | HI D4 | Skitter |
| LO D6 | Torpedo 1 | | HI D5 | Enemy ship |
| LO D7 | Torpedo 2 | | HI D6/D7 | Background level |

**Space Fury** — 5 at `$3E`, 6 at `$3F`: crafts scale, moving, thrust, star
spin, partial warship, crafts joining, shoot, fireball, small explosion, large
explosion, docking bang.

So roughly 9 one-shots plus two 2-bit **level** controls (thrust, background)
for Eliminator, and 11 lines for Space Fury.

### Two routes

**(a) RTL analog modelling**, the way Videodr0me did `asteroids_cabinet_audio.sv`.
Highest fidelity and consistent with the rest of this core. These are 555
timers, op-amp filters and noise sources — tractable, but 2300 lines of netlist
is real work.

**(b) Samples** via `wave_sound.sv` from `Arcade-SegaVICZ80_MiSTer`. Much
faster, with two problems:
- MAME no longer ships sample sets for these games (it moved to netlists), so
  samples would have to be rendered from the netlist or recorded from real
  hardware.
- The continuous, parameterised sounds — thrust and background, each with a
  2-bit level — do not map onto one-shot playback.

**Recommendation: (a).** Route (b) cannot represent the level-controlled
sounds, which are a large part of what Eliminator sounds like, and "quality
first" was the explicit brief. Route (b) is a reasonable *interim* if we want
audible sound early, but it should not be the destination.

### SDRAM constraint if (b) is ever used

`wave_sound` is SDRAM-backed, but `videodr0me_fb` already owns SDRAM for its
halo-alignment delay and keeps all four banks' rows open
(`vfb_sdram_core.sv`). Samples would have to live in DDR3 instead, or share
under a carefully arbitrated scheme. Settle this before committing.

---

## Mixing

`AUDIO_L/R` currently carry only the AY, scaled with headroom. As each board
lands, mix per MAME's `add_route` weights:

- Eliminator: discrete only, output scale 0.15
- Space Fury: discrete (scale 2.0) into the speech board, then to the speaker
- Zektor: discrete (0.15) + AY (routed through the same netlist) into speech
- Tac/Scan: USB only
- Star Trek: USB into the speech board

Note that on Space Fury, Zektor and Star Trek the sound board feeds *through*
the speech board rather than mixing beside it, so the speech board's analog
stage colours the whole mix. `nl_segaspeech.cpp` (120 lines) is the filter.
