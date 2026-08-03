//============================================================================
//  Sega G-80 vector field -> framebuffer coordinate map
//
//  The X-Y boards produce a 1024 x 1024 coordinate space after clipping, but
//  the monitor only shows part of it vertically. MAME's visible area is
//  x 512..1536, y 608..1440 with the transform in adjust_xy() offsetting Y by
//  (min_y - 512) = 96, so the visible field is:
//
//      x  0..1023            full width
//      y  96..927            832 of the 1024 rows
//
//  Orientation uses MAME's own three flags so the MRA can carry the value
//  straight across:
//
//      bit 0  ORIENTATION_FLIP_X
//      bit 1  ORIENTATION_FLIP_Y
//      bit 2  ORIENTATION_SWAP_XY
//
//  Per game (from refs/mame/segag80v.cpp):
//      Eliminator, Space Fury, Zektor, Star Trek   FLIP_Y            = 3'b010
//      Tac/Scan   (FLIP_X ^ ROT270)                SWAP|FLIP_Y|FLIP_X= 3'b111
//
//  First pass: the render target is the native field, 1024 x 832 (or 832 x 1024
//  when the axes are swapped), and MiSTer's scaler handles output scaling.
//  Videodr0me's Asteroids core additionally resizes the framebuffer per video
//  mode to tune the CRT effects; that can be layered on later without changing
//  this module's contract.
//
//  This program is free software under the GNU General Public License v3.
//============================================================================

`default_nettype none

module sega_geometry (
	input  wire  [9:0] src_x,        // 0..1023 from the vector generator
	input  wire  [9:0] src_y,
	input  wire  [2:0] orientation,  // {swap_xy, flip_y, flip_x}

	output wire [10:0] raster_x,
	output wire [10:0] raster_y,
	output wire        in_bounds
);
	localparam int VIS_Y0 = 96;      // first visible row of the 1024-row field
	localparam int VIS_H  = 832;     // visible rows
	localparam int VIS_W  = 1024;

	wire flip_x  = orientation[0];
	wire flip_y  = orientation[1];
	wire swap_xy = orientation[2];

	// Crop vertically. Rows outside the monitor's window are simply not drawn;
	// the vector generator has already blanked anything clipped in X.
	wire signed [11:0] cy = $signed({2'b00, src_y}) - 12'sd96;
	wire               y_visible = (cy >= 0) && (cy < VIS_H);

	wire [10:0] sx = {1'b0, src_x};
	wire [10:0] sy = cy[10:0];

	// Axis assignment, then flips about the centre of each axis.
	wire [10:0] a_raw = swap_xy ? sy : sx;
	wire [10:0] b_raw = swap_xy ? sx : sy;
	wire [10:0] a_max = swap_xy ? 11'(VIS_H - 1) : 11'(VIS_W - 1);
	wire [10:0] b_max = swap_xy ? 11'(VIS_W - 1) : 11'(VIS_H - 1);

	assign raster_x  = flip_x ? (a_max - a_raw) : a_raw;
	assign raster_y  = flip_y ? (b_max - b_raw) : b_raw;
	assign in_bounds = y_visible;

endmodule

`default_nettype wire
