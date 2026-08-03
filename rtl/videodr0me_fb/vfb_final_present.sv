// ============================================================================
// Final CRT presentation stage.
// written 2026 by Videodr0me
//
// This stage runs after the primary/bloom/halo/phosphor composite. It is a
// late presentation transform only; it intentionally does not feed back into
// bloom, halo, RLE compression, or cache behavior.
//
// Pipeline:
//   C1: optional Amplifone-to-Rec.709 color-space lift, R/G += floor(B/7)
//   C2: presentation color transform
//   C3: orientation-aware slot mask with bright-pixel gap closure
//   C4: final VGA-facing packet register
//
// RGB and sync/blank always travel as one packet.
// ============================================================================

module vfb_final_present (
	input  logic        clk_sys,
	input  logic        reset,
	input  logic        ce_pix,

	input  logic        color_space_amp709,
	input  logic [2:0]  presentation_color,
	input  logic        slot_mask_enable,
	input  logic        slot_mask_rows,

	input  logic [7:0]  VGA_R_IN,
	input  logic [7:0]  VGA_G_IN,
	input  logic [7:0]  VGA_B_IN,
	input  logic        VGA_HS_IN,
	input  logic        VGA_VS_IN,
	input  logic        VGA_HBLANK_IN,
	input  logic        VGA_VBLANK_IN,

	output logic [7:0]  VGA_R_OUT,
	output logic [7:0]  VGA_G_OUT,
	output logic [7:0]  VGA_B_OUT,
	output logic        VGA_HS_OUT,
	output logic        VGA_VS_OUT,
	output logic        VGA_HBLANK_OUT,
	output logic        VGA_VBLANK_OUT
);
	localparam logic [2:0] COLOR_WHITE      = 3'd0;
	localparam logic [2:0] COLOR_RED        = 3'd1;
	localparam logic [2:0] COLOR_LUNAR      = 3'd2;
	localparam logic [2:0] COLOR_DELUXE     = 3'd3;
	localparam logic [2:0] COLOR_CYAN       = 3'd4;
	localparam logic [2:0] COLOR_PURPLE     = 3'd5;
	localparam logic [2:0] COLOR_YELLOW     = 3'd6;
	localparam logic [2:0] COLOR_PURPLE_ALT = 3'd7;

	function automatic [5:0] div7_u8(input logic [7:0] value);
		logic [16:0] product_293;
		begin
			// Exact floor(value / 7) for every 8-bit input:
			// floor(n/7) == (n * 293) >> 11, for n=0..255.
			// 293 = 256 + 32 + 4 + 1, implemented as shift-add.
			product_293 =
				({9'd0, value} << 8) +
				({9'd0, value} << 5) +
				({9'd0, value} << 2) +
				{9'd0, value};
			div7_u8 = product_293[16:11];
		end
	endfunction

	function automatic [7:0] clamp_add_lift(
		input logic [7:0] channel,
		input logic [5:0] lift
	);
		logic [8:0] sum;
		begin
			sum = {1'b0, channel} + {3'b000, lift};
			clamp_add_lift = sum[8] ? 8'hff : sum[7:0];
		end
	endfunction

	function automatic [7:0] scale_14_16(input logic [7:0] channel);
		logic [10:0] scaled;
		begin
			// Exact round(channel * 14 / 16), reduced to
			// floor((channel * 7 + 4) / 8).
			scaled = ({3'd0, channel} << 3) -
			         {3'd0, channel} +
			         11'd4;
			scale_14_16 = scaled[10:3];
		end
	endfunction

	function automatic [7:0] scale_deluxe_red(input logic [7:0] channel);
		logic [16:0] scaled;
		begin
			// 273/512 produces the same rounded 8-bit values as
			// MAME's Asteroids Deluxe 0.5333 red multiplier.
			scaled =
				({9'd0, channel} << 8) +
				({9'd0, channel} << 4) +
				{9'd0, channel} +
				17'd256;
			scale_deluxe_red = scaled[16:9];
		end
	endfunction

	function automatic [7:0] scale_lunar_blue(input logic [7:0] channel);
		logic [8:0] scaled;
		logic [8:0] quotient;
		begin
			// The 519 nm comparison target is RGB(0, 255, 170).
			scaled = {channel, 1'b0} + 9'd1;
			quotient = scaled / 9'd3;
			scale_lunar_blue = quotient[7:0];
		end
	endfunction

	function automatic [7:0] max3_u8(
		input logic [7:0] a,
		input logic [7:0] b,
		input logic [7:0] c
	);
		logic [7:0] ab;
		begin
			ab = (a > b) ? a : b;
			max3_u8 = (ab > c) ? ab : c;
		end
	endfunction

	logic [7:0] cs_r;
	logic [7:0] cs_g;
	logic [7:0] cs_b;
	logic cs_hs;
	logic cs_vs;
	logic cs_hblank;
	logic cs_vblank;

	logic [7:0] ch_r;
	logic [7:0] ch_g;
	logic [7:0] ch_b;
	logic ch_hs;
	logic ch_vs;
	logic ch_hblank;
	logic ch_vblank;

	logic [7:0] selected_r;
	logic [7:0] selected_g;
	logic [7:0] selected_b;
	logic selected_hs;
	logic selected_vs;
	logic selected_hblank;
	logic selected_vblank;

	logic slot_column_parity;
	logic slot_row_parity;
	logic slot_line_active;

	always_ff @(posedge clk_sys) begin
		if (reset) begin
			cs_r <= 8'd0;
			cs_g <= 8'd0;
			cs_b <= 8'd0;
			cs_hs <= 1'b1;
			cs_vs <= 1'b1;
			cs_hblank <= 1'b1;
			cs_vblank <= 1'b1;
		end else if (ce_pix) begin
			logic [5:0] blue_lift;

			cs_hs <= VGA_HS_IN;
			cs_vs <= VGA_VS_IN;
			cs_hblank <= VGA_HBLANK_IN;
			cs_vblank <= VGA_VBLANK_IN;
			if (VGA_HBLANK_IN || VGA_VBLANK_IN) begin
				cs_r <= 8'd0;
				cs_g <= 8'd0;
				cs_b <= 8'd0;
			end else if (color_space_amp709) begin
				blue_lift = div7_u8(VGA_B_IN);
				cs_r <= clamp_add_lift(VGA_R_IN, blue_lift);
				cs_g <= clamp_add_lift(VGA_G_IN, blue_lift);
				cs_b <= VGA_B_IN;
			end else begin
				cs_r <= VGA_R_IN;
				cs_g <= VGA_G_IN;
				cs_b <= VGA_B_IN;
			end
		end
	end

	always_ff @(posedge clk_sys) begin
		if (reset) begin
			ch_r <= 8'd0;
			ch_g <= 8'd0;
			ch_b <= 8'd0;
			ch_hs <= 1'b1;
			ch_vs <= 1'b1;
			ch_hblank <= 1'b1;
			ch_vblank <= 1'b1;
		end else if (ce_pix) begin
			ch_hs <= cs_hs;
			ch_vs <= cs_vs;
			ch_hblank <= cs_hblank;
			ch_vblank <= cs_vblank;

			case (presentation_color)
				COLOR_WHITE: begin ch_r <= cs_r; ch_g <= cs_g; ch_b <= cs_b; end
				COLOR_RED: begin ch_r <= cs_r; ch_g <= 8'd0; ch_b <= 8'd0; end
				COLOR_LUNAR: begin
					ch_r <= 8'd0;
					ch_g <= cs_g;
					ch_b <= scale_lunar_blue(cs_b);
				end
				COLOR_DELUXE: begin
					ch_r <= scale_deluxe_red(cs_r);
					ch_g <= cs_g;
					ch_b <= cs_b;
				end
				COLOR_CYAN: begin ch_r <= 8'd0; ch_g <= cs_g; ch_b <= cs_b; end
				COLOR_PURPLE,
				COLOR_PURPLE_ALT: begin ch_r <= cs_r; ch_g <= 8'd0; ch_b <= cs_b; end
				COLOR_YELLOW: begin ch_r <= cs_r; ch_g <= cs_g; ch_b <= 8'd0; end
			endcase
		end
	end

	always_ff @(posedge clk_sys) begin
		if (reset) begin
			selected_r <= 8'd0;
			selected_g <= 8'd0;
			selected_b <= 8'd0;
			selected_hs <= 1'b1;
			selected_vs <= 1'b1;
			selected_hblank <= 1'b1;
			selected_vblank <= 1'b1;
			slot_column_parity <= 1'b0;
			slot_row_parity <= 1'b0;
			slot_line_active <= 1'b0;
		end else if (ce_pix) begin
			logic gap_position;
			logic close_gap;

			selected_hs <= ch_hs;
			selected_vs <= ch_vs;
			selected_hblank <= ch_hblank;
			selected_vblank <= ch_vblank;

			gap_position = slot_mask_enable &&
			               (slot_mask_rows ? slot_row_parity :
			                                 slot_column_parity);
			close_gap = (max3_u8(ch_r, ch_g, ch_b) >= 8'd200);

			if (ch_hblank || ch_vblank) begin
				selected_r <= 8'd0;
				selected_g <= 8'd0;
				selected_b <= 8'd0;
				slot_column_parity <= 1'b0;
				if (ch_vblank) begin
					slot_row_parity <= 1'b0;
					slot_line_active <= 1'b0;
				end else begin
					if (slot_line_active)
						slot_row_parity <= ~slot_row_parity;
					slot_line_active <= 1'b0;
				end
			end else begin
				if (gap_position && !close_gap) begin
					selected_r <= scale_14_16(ch_r);
					selected_g <= scale_14_16(ch_g);
					selected_b <= scale_14_16(ch_b);
				end else begin
					selected_r <= ch_r;
					selected_g <= ch_g;
					selected_b <= ch_b;
				end
				slot_column_parity <= ~slot_column_parity;
				slot_line_active <= 1'b1;
			end
		end
	end

	always_ff @(posedge clk_sys) begin
		if (reset) begin
			VGA_R_OUT <= 8'd0;
			VGA_G_OUT <= 8'd0;
			VGA_B_OUT <= 8'd0;
			VGA_HS_OUT <= 1'b1;
			VGA_VS_OUT <= 1'b1;
			VGA_HBLANK_OUT <= 1'b1;
			VGA_VBLANK_OUT <= 1'b1;
		end else if (ce_pix) begin
			VGA_R_OUT <= selected_r;
			VGA_G_OUT <= selected_g;
			VGA_B_OUT <= selected_b;
			VGA_HS_OUT <= selected_hs;
			VGA_VS_OUT <= selected_vs;
			VGA_HBLANK_OUT <= selected_hblank;
			VGA_VBLANK_OUT <= selected_vblank;
		end
	end

endmodule
