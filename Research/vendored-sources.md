# Vendored sources — pinned commits

Vendored on 2026-08-03. Do not edit vendored trees in place unless the change is
listed under "Local modifications" below, so upstream updates can be rebased.

| Path in this repo | Upstream | Commit |
|---|---|---|
| `rtl/videodr0me_fb/` | [Videodr0me/Arcade-Asteroids_MiSTer](https://github.com/Videodr0me/Arcade-Asteroids_MiSTer) `rtl/videodr0me_fb/` | `ebfd5d89605b4ec1f48932f68955ebed90256513` |
| `sys/` | [Videodr0me/Arcade-StarWars_MiSTer](https://github.com/Videodr0me/Arcade-StarWars_MiSTer) `sys/` | `5270c74394c3828500543845f76011f88226dbff` |
| `rtl/present_gate.sv` | [derpyder/Arcade-Tempest_MiSTer](https://github.com/derpyder/Arcade-Tempest_MiSTer) `rtl/present_gate.sv` | `92711125331383ffec7d4c3b053ed4b5dd232411` |
| `rtl/tv80/` | [MiSTer-devel/Arcade-SegaVICZ80_MiSTer](https://github.com/MiSTer-devel/Arcade-SegaVICZ80_MiSTer) `rtl/tv80/` | `16386ffec0bf548520d174538190c09ffa426368` |
| `rtl/i8035/i8035.v` | same | same |
| `rtl/jt49/` | same | same |

Licences: the Videodr0me cores are GPL-3.0 / GPL-2.0+; `tv80` is MIT; `jt49` is
GPL-3.0. This core is therefore GPL-3.0.

## Renderer interface as vendored (Asteroids revision)

`vfb_top` vector inputs:

```
input  [10:0] X_VECTOR, Y_VECTOR
input  [7:0]  Z_VECTOR
input  [3:0]  COLOR        // Asteroids passes {Rhi, Rlo, G, B}
input         IS_DOT, BEAM_ON
input         FRAME_DONE
input  [11:0] RENDER_WIDTH, RENDER_HEIGHT
```

Framebuffer pixel packing (`vfb_rasterizer.sv` → `vfb_readout.sv`):

```
pixel_data[15:0] = { rgb[2:0], draw_idx[3:0], 1'b0, z[7:0] }
```

One spare bit at [8]. Sega needs 6-bit colour (2 bits/gun). See
`docs/02-mister-core-plan.md` §3 for the repack, and Phase 0 for the census that
decides whether the repack is needed at all.

## Local modifications

**6-bit colour repack** (2026-08-03). Mandated by the Phase 0 census — see
`colour-census.md`: 42 of the 64 Sega colours cannot be expressed as hue x
brightness and they cover 22% of all beam-on samples, so the stock 3-bit RGB
path would visibly wreck the picture.

Stored pixel layouts, both still exactly 16 bits:

```
rasterised  { rgb[5:0], draw_idx[3:0], z[7:2] }      (was { rgb[2:0], draw_idx[3:0], 1'b0, z[7:0] })
composed    { rgb[5:0], fresh,         energy[8:0] } (was { rgb[2:0], fresh, 3'd0, energy[8:0] })
```

Sega's intensity is binary, so the two low bits of Z are the cheapest thing to
surrender; `vfb_readout` replicates the top two bits back into the low end on
read, so 63 restores to 255 exactly.

| File | Change |
|---|---|
| `vfb_top.sv` | `COLOR` 4 -> 6 bits |
| `vfb_rasterizer.sv` | `COLOR` 4 -> 6; FIFO word 36 -> 38 bits; `a_c`/`s2_out_c`/`dot_base_c`/`pending_sub_c` widened; `pixel_data` repacked |
| `vfb_readout.sv` | decode `rgb` from `[15:10]`, `draw_idx` from `[9:6]`, Z expanded from `[5:0]`; colour resolution moved into the new `vfb_color6` |
| `vfb_phosphor_compositor.sv` | rgb registers 3 -> 6 bits; colour combine changed from bitwise OR to **per-channel max** (OR-ing 2-bit levels invents colours neither source had); channel-present tests become `\|level`; energy normalisation keyed off a lit-channel count; `stored_pixel` repacked |
| `vfb_color6.sv` | **new** — 2-bit-per-gun ladder (0, 1/3, 2/3, 1 of full scale, matching the 6.2K/12K network on X-Y Control sheet 6/6) plus the stock overflow-spill behaviour |

Verified by `make color6`: all 64 colours x all 512 intensities against a C
model of the ladder, plus the Z round-trip. The whole renderer still lints with
zero errors and no new warnings.

If upstream `videodr0me_fb` moves, rebase these five files; nothing else in the
renderer was touched.
