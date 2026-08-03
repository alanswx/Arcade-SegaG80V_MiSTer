// ============================================================================
// vfb_color6: 6-bit (2-bit-per-gun) colour resolution
//
// LOCAL MODIFICATION to Videodr0me's videodr0me_fb, added for the Sega G-80
// vector core. Atari's AVG has one bit per gun plus a Z intensity, so the
// stock renderer resolves colour as hue x brightness. Sega's X-Y Control board
// drives each gun from a 2-bit weighted resistor ladder (6.2K/12K + 1N914 per
// gun, drawing 800-0163 sheet 6/6), giving 64 colours where the three guns can
// sit at different levels simultaneously.
//
// A census of 576 real display lists captured from all six games found 42 of
// the 64 colours are non-proportional and account for 22% of all beam-on
// samples — see Research/colour-census.md. Hue x brightness is therefore not a
// usable approximation and the colour path carries all six bits.
//
// Levels map to 0, 1/3, 2/3 and 3/3 of full scale, matching the ladder.
// ============================================================================

`default_nettype none

module vfb_color6 (
	input  wire [5:0] colour,      // RRGGBB, 2 bits per gun
	input  wire [8:0] intensity,   // 0..511; bit 8 set means overflow (bloom)
	output logic [7:0] out_r,
	output logic [7:0] out_g,
	output logic [7:0] out_b
);
	// Overflow behaviour inherited from the stock readout: lit channels clamp
	// and the excess spills into the unlit ones.
	localparam logic [7:0] MAIN_CEIL  = 8'd232;
	localparam logic [8:0] SPILL_BASE = 9'd232;
	localparam logic [8:0] SPILL_CAP  = 9'd64;

	wire [1:0] lvl_r = colour[5:4];
	wire [1:0] lvl_g = colour[3:2];
	wire [1:0] lvl_b = colour[1:0];

	// v * {0, 1/3, 2/3, 1}
	function automatic logic [7:0] scale(input logic [7:0] v, input logic [1:0] lvl);
		logic [15:0] p;
		begin
			unique case (lvl)
				2'd0: scale = 8'd0;
				2'd1: begin p = v * 16'd85;  scale = p[15:8]; end
				2'd2: begin p = v * 16'd171; scale = p[15:8]; end
				2'd3: scale = v;
			endcase
		end
	endfunction

	wire lit_r = (lvl_r != 2'd0);
	wire lit_g = (lvl_g != 2'd0);
	wire lit_b = (lvl_b != 2'd0);
	wire [1:0] n_unlit = {1'b0, ~lit_r} + {1'b0, ~lit_g} + {1'b0, ~lit_b};

	wire [8:0] excess     = intensity[8] ? (intensity - SPILL_BASE) : 9'd0;
	wire [8:0] excess_half = excess >> 1;
	wire [7:0] spill_full = (excess      > SPILL_CAP) ? 8'd64 : excess[7:0];
	wire [7:0] spill_half = (excess_half > SPILL_CAP) ? 8'd64 : excess_half[7:0];
	// one unlit channel takes the whole excess, two share it
	wire [7:0] spill = (n_unlit == 2'd1) ? spill_full : spill_half;

	always_comb begin
		if (!intensity[8]) begin
			out_r = scale(intensity[7:0], lvl_r);
			out_g = scale(intensity[7:0], lvl_g);
			out_b = scale(intensity[7:0], lvl_b);
		end else if (colour == 6'b111111) begin
			// full white stays saturated rather than clamping to the ceiling
			out_r = 8'd255;
			out_g = 8'd255;
			out_b = 8'd255;
		end else begin
			out_r = lit_r ? scale(MAIN_CEIL, lvl_r) : spill;
			out_g = lit_g ? scale(MAIN_CEIL, lvl_g) : spill;
			out_b = lit_b ? scale(MAIN_CEIL, lvl_b) : spill;
		end
	end
endmodule

`default_nettype wire
