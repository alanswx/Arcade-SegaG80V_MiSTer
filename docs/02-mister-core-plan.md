# Plan: `Arcade-SegaG80V_MiSTer`

> **Note on `refs/` paths.** This document cites local research material
> — scanned Gremlin schematics, game manuals and MAME driver sources —
> that is not redistributed here. See
> [`docs/00-research-summary.md`](00-research-summary.md) for where each
> item came from, and `sim/tools/` for the scripts that regenerate the
> ROM-derived artefacts locally.


A MiSTer FPGA core for the Sega/Gremlin G80 X-Y (vector) board set — Eliminator,
Space Fury, Zektor, Tac/Scan, Star Trek — built by grafting a new Sega game module
onto **Videodr0me's `videodr0me_fb` vector renderer**, following the pattern
derpyder used for Tempest.

Read `01-hardware-reference.md` first; this plan assumes it.

---

## 0. Strategy in one paragraph

One core, five games, selected by MRA. The Z80, the security scrambler, the X-Y
Control board and the X-Y Timing board are common to all five and are written once.
Only the sound board differs per game, so audio is where the per-game work lives and
it is deliberately pushed to the back of the schedule. The vector generator is
transcribed from `refs/mame/segag80v_v.cpp` — which is already a phase-by-phase
gate-level description — and cross-checked against
`refs/schematics/XY_*.png`. The renderer is taken from
`Arcade-MajorHavoc_MiSTer/rtl/videodr0me_fb/` and adapted only where
the Sega 6-bit colour path and timing require it.

**Target:** DE10-Nano, 32 MB SDRAM module (the renderer's halo delay needs SDRAM in
addition to DDR3). Quartus project cloned from the Star Wars core, since that is the
most-integrated example of `vfb_top` in use.

## 1. Repository layout

```
Arcade-SegaG80V_MiSTer/
├── Arcade-SegaG80V.{qpf,qsf,sdc,sv}   # top level, cloned from Star Wars
├── files.qip
├── rtl/
│   ├── segag80v.sv          # game module: instantiates everything below + vfb_top
│   ├── segag80v_cpu.sv      # Z80 + memory map + I/O map + wait states + IRQ chain
│   ├── sega_security.sv     # 315-0064/0070/0076/0082 RAM-write address scrambler
│   ├── xy/
│   │   ├── xy_control.sv    # 800-0163: vector RAM, display-list address gen,
│   │   │                    #           length multiplier, attribute latch
│   │   ├── xy_timing.sv     # 800-0161: 16-phase generator, angle maths,
│   │   │                    #           sin PROM, position counters, clipping
│   │   └── sin_prom.sv      # s-c.xyt-u39, loaded from ROM
│   ├── sound/
│   │   ├── sega_speech.sv   # 8035 + SP0250          (spacfury, zektor, startrek)
│   │   ├── sega_usb.sv      # 8035 + 3x 8253 + DACs  (tacscan, startrek)
│   │   ├── sp0250.sv
│   │   ├── i8253.sv
│   │   └── g80_analog_*.sv  # discrete boards: elim / zektor / spacfury
│   ├── i8035.v              # from Arcade-SegaVICZ80_MiSTer
│   ├── tv80/                # from Arcade-SegaVICZ80_MiSTer
│   ├── jt49/                # from Arcade-SegaVICZ80_MiSTer  (Zektor AY-3-8912)
│   ├── videodr0me_fb/       # from Arcade-MajorHavoc_MiSTer
│   └── pll/
├── sim/                     # Verilator/ModelSim benches (see §7)
├── mra/                     # one MRA per romset
└── Research/
    └── xy_schematic_reference.txt   # transcription notes, Videodr0me style
```

## 2. Phase plan

### Phase 0 — Decide the colour question (do this first, ~1 day)

The only invasive change in the whole project is widening the renderer's colour
path from 3 to 6 bits. Find out whether it is actually needed before writing any
RTL.

Patch MAME's `segag80v_v.cpp` to log every distinct `(attrib >> 1) & 0x3f` value
each game emits, run all five through attract mode and a few levels, and count.

- If the games only use colours whose R:G:B levels are proportional (pure hues at
  varying brightness), map Sega's 2:2:2 onto the existing `RGB[2:0]` hue +
  `Z_VECTOR[7:0]` brightness and **change nothing in the renderer**.
- If they use genuinely non-proportional colours (e.g. `R=3, G=1, B=0`), do the
  repack in §3.

Record the answer in `Research/`. This decision gates the rest.

### Phase 1 — Chassis boots (1 week)

Clone the Star Wars Quartus project, strip the Atari game module, drop in
`videodr0me_fb` from Asteroids, and wire a stub generator that draws a static test
pattern (a box, a colour ramp, a rotating line) at 40 Hz into `vfb_top`.

**Exit:** a bitstream that boots on hardware and shows the test pattern with the CRT
pipeline and OSD working. This de-risks the renderer, the PLLs, DDR3/SDRAM, and the
video modes before any Sega logic exists.

### Phase 2 — CPU subsystem (1–2 weeks)

`segag80v_cpu.sv`: `tv80` at 15468480/4 with **2 wait states on every access**, the
memory map and I/O map from `01-hardware-reference.md` §3, the mangled input matrix,
the coin/service/EDGINT interrupt flip-flops with `INTCL` clear on interrupt ack,
the NMI-on-service pulse, and the CPU-visible multiplier at `$BD/$BE`.

`sega_security.sv`: latch the PC at every opcode fetch; when the fetched opcode is
`$32`, scramble the low byte of the next write address using the permutation
selected by the configured chip and the latched PC bits. Four combinational
permutations, selector per §3 of the hardware reference. MRA supplies the chip ID.

ROM loading via `ioctl_download` + an MRA-driven `games.v`-style splitter, modelled
on `Arcade-SegaVICZ80_MiSTer`.

**Exit:** in simulation, all five games reach their self-test and write plausible
data into vector RAM. Compare a vector-RAM dump against MAME's at the same frame.

### Phase 3 — Vector generator (2–4 weeks — the core of the project)

This is a direct transcription of `refs/mame/segag80v_v.cpp`, which walks the
16-phase state machine naming a schematic sheet and chip for every step.

`xy_control.sv`
- 4K×8 vector RAM as dual-port block RAM: CPU port at `$E000-$EFFF` (through the
  security scrambler), generator port for the display-list walk. The real board
  time-multiplexes one RAM and stalls the CPU via `MUX`/`WAIT`; dual-port plus the
  fixed 2 wait states reproduces the CPU-visible behaviour without the arbitration.
- Symbol-list pointer and vector-list address counters (U10/U11/U12).
- 25LS14 length × scale multiplier (U8) → 9-bit length counter.
- Attribute latch (U2) → `beam_on`, `rgb[5:0]`, `end_of_symbol`.

`xy_timing.sv`
- LS161/LS154 phase generator (U51/U50), preload to 0 or 10 from U52 per attribute
  bit 7 / draw-flag bit 7.
- Symbol and vector angle latches; 10-bit adder.
- `sin_prom.sv` — the 1 KB `s-c.xyt-u39` table, A0 grounded, indexed
  `angle<<1` and `(angle+0x100)<<1`.
- The DDA: 8-bit X and Y accumulators with the `+(delta>>7)` round-in carry,
  carry-out clocking 12-bit up/down position counters, direction from bit 9 of the
  angle sum.
- Clipping (`^0x200`, the `0x600` window test, saturate to `0x000`/`0x3FF`) driving
  the `BOS` blank while the accumulators keep running.
- `DRAW` and `EDGINT` generation.

Emit `{X[10:0], Y[10:0], Z, COLOR, BEAM_ON}` one sample per `clk_12` and
`FRAME_DONE` when the display list ends.

**Resolve the phase-clock ambiguity here** (hardware reference §2): does U51 clock
at VCL, or at VCL/16 as MAME's time accounting implies? Trace U51 pin 2 on
`XY_Timing_800-0161_sheet7of7.png`. Make it a parameter so both can be measured
against the games' behaviour before freezing.

**Exit:** `sega-xy-diagnostic` (in `refs/cores/`) passes, and a frame captured from
the RTL matches a frame captured from instrumented MAME point-for-point.

### Phase 4 — Presentation (3–5 days)

Coordinate map from the 1024×1024 vector field (visible window 1025×833) into the
render target; per-game orientation — Tac/Scan is `FLIP_X ^ ROT270`, the others
`FLIP_Y`.

Use the Major Havoc `vfb_buffer_controller` and `vfb_phosphor_compositor` directly.
Its sparse inter-frame decay preserves completed frames and decays them at display
boundaries; do not insert the Tempest list-accumulating `present_gate.sv` in front
of it. Sega already emits one complete list per 40 Hz `FRAME_DONE`.

**Exit:** all five games look right on hardware at 720p and 1080p, no flicker, no
dropped beams.

### Phase 5 — Controls, DIPs, MRAs (3–5 days)

Spinner emulation for Zektor / Tac/Scan / Star Trek: the monotonically-increasing
count with direction in bit 0 (`~((count<<1)|sign)`), fed from analog stick, mouse
and USB spinner — copy the input handling from the Tempest core, which solved the
same problem. Eliminator 4-player demux. DIP switches through the mangled matrix.
One MRA per romset with the security chip ID, orientation and sound board as
parameters.

**Exit:** every romset in `01-hardware-reference.md` §8 boots and is playable, with
correct DIP behaviour in service mode.

### Phase 6 — Audio, easiest first (3–6 weeks)

1. **Zektor's AY-3-8912** — drop in `jt49`. Immediate partial audio.
2. **Speech board** (Space Fury, Zektor, Star Trek) — `i8035.v` + a new `sp0250.sv`.
   Port MAME's `sound/sp0250.cpp` LPC synthesiser; it is compact and well-defined.
3. **Universal Sound Board** (Tac/Scan, Star Trek) — `i8035.v` at 6 MHz, three
   8253 PITs, the DAC/mixer chain, MM5837 noise, and the shared program RAM window
   at `$D000-$DFFF`. `refs/mame/segausb.cpp` plus
   `Universal_Sound_Board_800-0377_sheet{6,7,8}of8.png` are the spec.
4. **Discrete boards** (Eliminator, Space Fury, Zektor) — MAME models these as
   netlists (`nl_elim.cpp`, `nl_spacfury.cpp`). Options in increasing fidelity:
   samples triggered by the `$3E/$3F` latches; hand-written oscillator/filter
   models; a real analog model in the style of `asteroids_cabinet_audio.sv`.
   Start with samples so the games ship with sound, then improve.

### Phase 7 — Polish

Hiscore save (`hiscore.v`), pause, OSD CRT-profile presets tuned for the
Electrohome G08 rather than the Amplifone, README, MRAs, release.

## 3. The colour repack (only if Phase 0 says so)

Current framebuffer pixel, identical in the Star Wars and Asteroids copies
(`vfb_rasterizer.sv`, decoded in `vfb_readout.sv`):

```
pixel_data[15:0] = { rgb[2:0], draw_idx[3:0], 1'b0, z[7:0] }
                     15:13      12:9          8      7:0
```

One spare bit; 6-bit colour needs three more. Since Sega's intensity is binary,
take them from Z:

```
pixel_data[15:0] = { rgb[5:0], draw_idx[3:0], z[5:0] }
                     15:10      9:6           5:0
```

Files touched: `vfb_rasterizer.sv` (FIFO width 35→38, pack), `vfb_readout.sv`
(`pixel_rgb_comb`, `pixel_int_comb` slicing), and wherever the 3-bit mask is turned
into RGB in `vfb_final_present.sv` / `vfb_profile_resolver.sv` — the 2-bit-per-gun
levels need a small weighting table matching the 6.2 K/12 K ladder on
`XY_Control_800-0163_sheet6of6`.

Keep this on a branch and keep the unmodified renderer buildable, so a renderer
update from upstream can be rebased.

## 4. Effort and risk

| Phase | Estimate | Risk |
|---|---|---|
| 0 colour decision | 1 day | low |
| 1 chassis boots | 1 wk | low — proven path |
| 2 CPU subsystem | 1–2 wk | low — MAME driver is complete |
| 3 vector generator | 2–4 wk | **medium** — the phase-clock ambiguity is the one genuine unknown |
| 4 presentation | 3–5 d | low — Tempest solved it |
| 5 controls/DIPs/MRA | 3–5 d | low |
| 6 audio | 3–6 wk | **medium-high** — SP0250 and the USB are each a subsystem; discrete boards are open-ended |
| 7 polish | 1 wk | low |

**Roughly 2–3 months** to a playable five-game core with partial audio; audio
fidelity is the long tail. A "video-complete, sound via samples" release is a
reasonable milestone at the ~6 week mark.

Principal risks:

1. **Phase-generator timing.** MAME charges 16 VCL clocks per phase and still
   carries a "games run too fast" note. Getting this wrong changes how much of the
   display list fits in a 40 Hz frame and how the `DRAW` flag behaves — games poll
   it. Mitigate by parameterising it and validating against MAME frame captures.
2. **Colour width.** Contained, and Phase 0 may eliminate it.
3. **Discrete audio.** Unbounded if you chase netlist fidelity. Bound it: samples
   first, ship, improve later.
4. **Renderer drift.** `videodr0me_fb` is actively developed. Vendor it at a pinned
   commit; keep any modification isolated.

## 5. Upstreaming

The Videodr0me cores are GPL-3.0 / GPL-2.0+; the derived work must be GPL too.
Credit Videodr0me for the renderer, Aaron Giles / MAME for the hardware analysis,
JimmyStones for `i8035`, and derpyder for the graft pattern. Since Sega G80 vector
has no core on MiSTer main, this is a candidate for `MiSTer-devel` — but talk to
Videodr0me early, both as a courtesy and because any colour-path change is much
better landed upstream than carried as a fork.

## 6. First concrete steps

1. Run the Phase 0 colour census in MAME.
2. `git init` the core repo from a copy of `Arcade-StarWars_MiSTer`, vendor
   `videodr0me_fb` from `Arcade-MajorHavoc_MiSTer` at a pinned commit.
3. Trace U51's clock on `XY_Timing_800-0161_sheet7of7.png` and write the finding
   into `Research/xy_schematic_reference.txt`.
4. Build the Verilator bench in §7 before writing `xy_timing.sv`.

## 7. Test strategy

- **Golden vectors from MAME.** Add a hook to `sega_generate_vector_list()` that
  dumps every `add_point(x, y, color, intensity)` for a frame. Replay the same
  vector-RAM contents through the RTL in Verilator and diff. This gives a
  point-exact regression test for the hardest module, independent of video output.
- **Diagnostic ROM.** `refs/cores/sega-xy-diagnostic` exercises the X-Y boards
  without a game booting — the first thing to make pass.
- **Homebrew display lists.** `refs/cores/sega-vector` contains small known-good
  games; their vector RAM makes compact, hand-checkable simulation stimulus.
- **Per-game frame captures** at fixed frame numbers, compared to MAME screenshots.
