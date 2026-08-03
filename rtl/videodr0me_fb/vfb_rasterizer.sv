// ============================================================================
// videodr0me_fb: Rasterizer
// written 2026 by Videodr0me
// Handles dual-clock FIFO decoding and subpixel generation.
// ============================================================================

module vfb_rasterizer #(
	parameter TILE_SIZE = 8,
	parameter FIFO_ADDR_W = 10
) (
	input  logic clk_sys,
	input  logic clk_12,
	input  logic reset,

	// Vector Input Interface (clk_12 from DVG)
	input  logic [10:0] X_VECTOR,
	input  logic [10:0] Y_VECTOR,
	input  logic [7:0]  Z_VECTOR,
	input  logic [5:0]  COLOR,   // LOCAL MOD: 6-bit RRGGBB
	input  logic        IS_DOT,
	input  logic        BEAM_ON,
	input  logic        FRAME_DONE,
	input  logic [2:0]  DOT_MODE,
	input  logic [11:0] FB_WIDTH,
	input  logic [11:0] FB_HEIGHT,

	// Cache Manager Interface (clk_sys)
	output logic        pixel_valid,
	input  logic        pixel_ready,
	output logic [15:0] pixel_tile_id,
	output logic [5:0]  pixel_offset,
	output logic [15:0] pixel_data,
	input  logic [3:0]  draw_idx,         // Pixel draw-time phase
	input  logic [15:0] frame_tick_clks, // Source clocks per draw-index phase
	input  logic [15:0] completed_frame_tick_clks,

	output logic        eof_token,
	output logic [15:0] eof_completed_frame_tick_clks,
	output logic        fifo_full_led,
	output logic        fifo_empty
);

	localparam FIFO_DEPTH = 1 << FIFO_ADDR_W;
	localparam FIFO_PTR_W = FIFO_ADDR_W + 1;
	localparam logic [2:0] DOT_2X  = 3'd0;
	localparam logic [2:0] DOT_25X = 3'd1;
	localparam logic [2:0] DOT_3X  = 3'd2;
	localparam logic [2:0] DOT_1X  = 3'd3;

	function [FIFO_PTR_W-1:0] b2g(input [FIFO_PTR_W-1:0] b);
		b2g = b ^ (b >> 1);
	endfunction

	function [FIFO_PTR_W-1:0] g2b(input [FIFO_PTR_W-1:0] g);
		logic [FIFO_PTR_W-1:0] b;
		begin
			b[FIFO_PTR_W-1] = g[FIFO_PTR_W-1];
			for (int i=FIFO_PTR_W-2; i>=0; i=i-1)
				b[i] = b[i+1] ^ g[i];
			g2b = b;
		end
	endfunction

	// Async FIFO (clk_12 -> clk_sys). The renderer consumer normally drains much
	// faster than the 12 MHz DVG producer; this covers cache and DDR arbitration
	// stalls.
	(* ramstyle = "M10K" *) logic [37:0] fifo_mem [0:FIFO_DEPTH-1];

	logic [FIFO_PTR_W-1:0] wr_ptr = 0;
	logic [FIFO_PTR_W-1:0] wr_ptr_g = 0;
	logic [FIFO_PTR_W-1:0] rd_ptr = 0;
	logic [FIFO_PTR_W-1:0] rd_ptr_g = 0;

	logic [FIFO_PTR_W-1:0] wr_ptr_g_sync1 = 0;
	logic [FIFO_PTR_W-1:0] wr_ptr_g_sync2 = 0;
	logic [FIFO_PTR_W-1:0] rd_ptr_g_sync1_12 = 0;
	logic [FIFO_PTR_W-1:0] rd_ptr_g_sync2_12 = 0;

	// Write side (clk_12)
	logic [10:0] last_x = 0;
	logic [10:0] last_y = 0;
	logic        last_beam_on = 0;
	logic        last_frame_done = 0;

	wire push_eof = (FRAME_DONE && !last_frame_done);
	wire push_pix = (BEAM_ON && (X_VECTOR != last_x || Y_VECTOR != last_y || !last_beam_on));
	wire fifo_we  = push_eof || push_pix;

	// LOCAL MOD: COLOR widened 4 -> 6 bits, so the word grows 36 -> 38.
	wire [37:0] fifo_din = push_eof ? {
		1'b1, 5'd0, completed_frame_tick_clks, frame_tick_clks
	} : {
		1'b0,              // 37
		IS_DOT,            // 36
		COLOR,             // 35:30 = RRGGBB
		Y_VECTOR,          // 29:19
		X_VECTOR,          // 18:8
		Z_VECTOR           // 7:0
	};

	wire [FIFO_PTR_W-1:0] wr_ptr_next = wr_ptr + 1'b1;
	wire [FIFO_PTR_W-1:0] wr_ptr_g_next = b2g(wr_ptr_next);
	wire fifo_full_12 =
		(wr_ptr_g_next ==
		 {~rd_ptr_g_sync2_12[FIFO_PTR_W-1:FIFO_PTR_W-2],
		   rd_ptr_g_sync2_12[FIFO_PTR_W-3:0]});
	logic [1:0] rst_12_sync = 2'b11;
	always_ff @(posedge clk_12) rst_12_sync <= {rst_12_sync[0], reset};
	wire rst_12 = rst_12_sync[1];

	// Synchronize the Gray-coded read pointer back to the write domain so a
	// prolonged DDR/cache stall cannot silently overwrite unread entries.
	always_ff @(posedge clk_12) begin
		if (rst_12) begin
			rd_ptr_g_sync1_12 <= 0;
			rd_ptr_g_sync2_12 <= 0;
		end else begin
			rd_ptr_g_sync1_12 <= rd_ptr_g;
			rd_ptr_g_sync2_12 <= rd_ptr_g_sync1_12;
		end
	end

	always_ff @(posedge clk_12) begin
		last_x <= X_VECTOR;
		last_y <= Y_VECTOR;
		last_beam_on <= BEAM_ON;
		last_frame_done <= FRAME_DONE;

		if (rst_12) begin
			wr_ptr <= 0;
			wr_ptr_g <= 0;
		end else if (fifo_we) begin
			if (!fifo_full_12) begin
				fifo_mem[wr_ptr[FIFO_ADDR_W-1:0]] <= fifo_din;
				wr_ptr <= wr_ptr_next;
				wr_ptr_g <= wr_ptr_g_next;
			end
		end
	end

	// Read side (clk_sys)
	always_ff @(posedge clk_sys) begin
		wr_ptr_g_sync1 <= wr_ptr_g;
		wr_ptr_g_sync2 <= wr_ptr_g_sync1;
	end
	assign fifo_empty = (rd_ptr_g == wr_ptr_g_sync2);

	// FIFO fill level LED with display timer
	wire [FIFO_PTR_W-1:0] wr_ptr_bin = g2b(wr_ptr_g_sync2);
	wire [FIFO_PTR_W-1:0] fifo_used = wr_ptr_bin - rd_ptr;
	wire fifo_full_flag = (fifo_used > FIFO_PTR_W'(128));

	logic [23:0] led_timer = 0;
	always_ff @(posedge clk_sys) begin
		if (fifo_full_flag) led_timer <= 24'd9349794;
		else if (led_timer != 0) led_timer <= led_timer - 1'b1;
	end
	assign fifo_full_led = (led_timer != 0);

	logic [1:0] rst_sys_sync = 2'b11;
	always_ff @(posedge clk_sys) rst_sys_sync <= {rst_sys_sync[0], reset};
	wire rst_sys = rst_sys_sync[1];

	// Pipeline: FIFO -> Stage A (buffer) -> Stage B (process/insert) -> Out
	//
	// Stage A: Single-entry buffer, reads from FIFO when empty or consumed.
	// Stage B: Emits primaries and inserts diagonal fill pixels or dot expansion.
	//   B_IDLE      - Accept pixel from A, emit primary, detect expansions.
	//   B_CHECK_SUB - Select a diagonal fill corner using lookahead, then emit.
	//   B_DOT_SUB   - Emit dot expansion subpixels (stalls A).

	// Stage A
	logic [37:0] a_data;
	logic        a_valid = 0;
	wire         a_ready;

	wire a_fifo_read = !fifo_empty && (!a_valid || a_ready);

	always_ff @(posedge clk_sys) begin
		if (rst_sys) begin
			a_valid <= 0;
			rd_ptr  <= 0;
			rd_ptr_g <= 0;
		end else begin
			if (a_ready && a_valid) a_valid <= 0;
			if (a_fifo_read) begin
				a_data   <= fifo_mem[rd_ptr[FIFO_ADDR_W-1:0]];
				rd_ptr   <= rd_ptr + 1'b1;
				rd_ptr_g <= b2g(rd_ptr + 1'b1);
				a_valid  <= 1;
			end
		end
	end

	wire [10:0] a_x      = a_data[18:8];
	wire [10:0] a_y      = a_data[29:19];
	wire [7:0]  a_z      = a_data[7:0];
	wire [5:0]  a_c      = a_data[35:30];
	wire        a_is_dot = a_data[36];
	wire        a_eof    = a_data[37];
	wire [2:0]  a_dot    = DOT_MODE;

	// Stage B
	typedef enum logic [1:0] {
		B_IDLE,
		B_CHECK_SUB,
		B_DOT_SUB
	} b_state_t;

	b_state_t b_state = B_IDLE;

	logic [10:0] s2_out_x;
	logic [10:0] s2_out_y;
	logic [7:0]  s2_out_z;
	logic [5:0]  s2_out_c;
	logic        s2_out_valid = 0;
	logic [15:0] s2_eof_frame_tick_clks = 0;
	logic [15:0] s2_eof_completed_frame_tick_clks = 0;

	wire b_output_free = pixel_ready || !s2_out_valid;
	assign pixel_valid = s2_out_valid;

	// Preferred and alternate diagonal fill pixels.
	logic [10:0] pending_sub_x;
	logic [10:0] pending_sub_y;
	logic [7:0]  pending_sub_z;
	logic [5:0]  pending_sub_c;
	logic [10:0] pending_alt_x;
	logic [10:0] pending_alt_y;
	logic        pending_is_xdom;

	// 2-deep history for previous step classification
	logic [10:0] hist_x [2];
	logic [10:0] hist_y [2];
	logic [1:0]  hist_count = 0;

	logic [10:0] read_last_x = 0;
	logic [10:0] read_last_y = 0;

	// Dot expansion state
	logic [2:0]  dot_idx;
	logic [2:0]  dot_last_idx;
	logic [2:0]  dot_mode;
	logic [7:0]  dot_base_z;
	logic [5:0]  dot_base_c;
	logic [10:0] dot_x, dot_y;
	logic [11:0] dot_candidate_x;
	logic [11:0] dot_candidate_y;
	logic        dot_candidate_valid;

	always_comb begin
		dot_candidate_x = {1'b0, dot_x};
		dot_candidate_y = {1'b0, dot_y};

		case (dot_mode)
		DOT_2X: begin
			case (dot_idx)
				3'd0: dot_candidate_x = {1'b0, dot_x} + 12'd1;
				3'd1: dot_candidate_y = {1'b0, dot_y} + 12'd1;
				default: begin
					dot_candidate_x = {1'b0, dot_x} + 12'd1;
					dot_candidate_y = {1'b0, dot_y} + 12'd1;
				end
			endcase
		end

		DOT_25X: begin
			case (dot_idx)
				3'd0: dot_candidate_x = {1'b0, dot_x} + 12'd1;
				3'd1: dot_candidate_x = {1'b0, dot_x} + 12'd2;
				3'd2: dot_candidate_y = {1'b0, dot_y} + 12'd1;
				3'd3: begin
					dot_candidate_x = {1'b0, dot_x} + 12'd1;
					dot_candidate_y = {1'b0, dot_y} + 12'd1;
				end
				default: begin
					dot_candidate_x = {1'b0, dot_x} + 12'd2;
					dot_candidate_y = {1'b0, dot_y} + 12'd1;
				end
			endcase
		end

		DOT_3X: begin
			case (dot_idx)
				3'd0: begin
					dot_candidate_x = {1'b0, dot_x} - 12'd1;
					dot_candidate_y = {1'b0, dot_y} - 12'd1;
				end
				3'd1: dot_candidate_y = {1'b0, dot_y} - 12'd1;
				3'd2: begin
					dot_candidate_x = {1'b0, dot_x} + 12'd1;
					dot_candidate_y = {1'b0, dot_y} - 12'd1;
				end
				3'd3: dot_candidate_x = {1'b0, dot_x} - 12'd1;
				3'd4: dot_candidate_x = {1'b0, dot_x} + 12'd1;
				3'd5: begin
					dot_candidate_x = {1'b0, dot_x} - 12'd1;
					dot_candidate_y = {1'b0, dot_y} + 12'd1;
				end
				3'd6: dot_candidate_y = {1'b0, dot_y} + 12'd1;
				default: begin
					dot_candidate_x = {1'b0, dot_x} + 12'd1;
					dot_candidate_y = {1'b0, dot_y} + 12'd1;
				end
			endcase
		end

		default: begin
			dot_candidate_x = {1'b0, dot_x};
			dot_candidate_y = {1'b0, dot_y};
		end
		endcase
	end

	assign dot_candidate_valid = (dot_candidate_x < FB_WIDTH) &&
	                             (dot_candidate_y < FB_HEIGHT);

	// Combinational step classification
	wire [10:0] step_dx = (a_x > read_last_x) ? (a_x - read_last_x)
	                                           : (read_last_x - a_x);
	wire [10:0] step_dy = (a_y > read_last_y) ? (a_y - read_last_y)
	                                           : (read_last_y - a_y);
	// To compile diagonal subpixel insertion out, force this wire to 1'b0.
	wire step_is_diag = (step_dx == 11'd1 && step_dy == 11'd1);
	wire primary_is_dot = a_is_dot && (a_dot < DOT_1X);
	wire is_neighbor  = (step_dx <= 11'd1) && (step_dy <= 11'd1);

	assign a_ready = a_valid && b_output_free && (b_state == B_IDLE);

	always_ff @(posedge clk_sys) begin
		if (rst_sys) begin
			s2_out_valid <= 0;
			eof_token    <= 0;
			s2_eof_frame_tick_clks <= 16'd0;
			s2_eof_completed_frame_tick_clks <= 16'd0;
			b_state      <= B_IDLE;
			hist_count   <= 0;
		end else begin
			if (pixel_ready) begin
				s2_out_valid <= 0;
				eof_token    <= 0;
			end

			case (b_state)
			B_IDLE: begin
				if (a_valid && b_output_free) begin
					if (a_eof) begin
						eof_token    <= 1;
						s2_out_valid <= 1;
						s2_eof_frame_tick_clks <= a_data[15:0];
						s2_eof_completed_frame_tick_clks <= a_data[31:16];
					end else begin
						s2_out_x     <= a_x;
						s2_out_y     <= a_y;
						s2_out_z     <= a_z;
						s2_out_c     <= a_c;
						s2_out_valid <= 1;

						hist_x[1] <= hist_x[0]; hist_y[1] <= hist_y[0];
						hist_x[0] <= a_x;       hist_y[0] <= a_y;
						hist_count <= is_neighbor ? ((hist_count < 2'd2) ? hist_count + 2'd1 : 2'd2) : 2'd1;

						if (primary_is_dot) begin
							b_state      <= B_DOT_SUB;
							dot_mode     <= a_dot;
							dot_idx      <= 3'd0;
							dot_last_idx <= (a_dot == DOT_2X)  ? 3'd2 :
							                (a_dot == DOT_25X) ? 3'd4 : 3'd7;
							dot_base_z   <= a_z;
							dot_base_c   <= a_c;
							dot_x        <= a_x;
							dot_y        <= a_y;
						end else if (step_is_diag) begin
							// Store both fill options for the lookahead stage.
							if (hist_count >= 2'd2 && hist_x[0] == hist_x[1] && hist_y[0] != hist_y[1]) begin
								// Previous step was V: prefer X-dom
								pending_sub_x   <= a_x;
								pending_sub_y   <= read_last_y;
								pending_alt_x   <= read_last_x;
								pending_alt_y   <= a_y;
								pending_is_xdom <= 1;
							end else begin
								// Default: prefer Y-dom
								pending_sub_x   <= read_last_x;
								pending_sub_y   <= a_y;
								pending_alt_x   <= a_x;
								pending_alt_y   <= read_last_y;
								pending_is_xdom <= 0;
							end
							pending_sub_z <= a_z;
							pending_sub_c <= a_c;
							b_state       <= B_CHECK_SUB;
						end

						read_last_x <= a_x;
						read_last_y <= a_y;
					end
				end
			end

			// If the preferred fill aligns with the next primary on the dominant
			// axis, use the alternate corner.
			B_CHECK_SUB: begin
				if (a_valid && b_output_free) begin
					if (!a_eof && (pending_is_xdom ? (a_x == pending_sub_x) : (a_y == pending_sub_y))) begin
						s2_out_x <= pending_alt_x;
						s2_out_y <= pending_alt_y;
					end else begin
						s2_out_x <= pending_sub_x;
						s2_out_y <= pending_sub_y;
					end
					s2_out_z     <= pending_sub_z;
					s2_out_c     <= pending_sub_c;
					s2_out_valid <= 1;
					b_state      <= B_IDLE;
				end
			end

			B_DOT_SUB: begin
				if (b_output_free) begin
					if (dot_candidate_valid) begin
						s2_out_x     <= dot_candidate_x[10:0];
						s2_out_y     <= dot_candidate_y[10:0];
						s2_out_z     <= dot_base_z;
						s2_out_c     <= dot_base_c;
						s2_out_valid <= 1;
					end

					if (dot_idx == dot_last_idx) begin
						b_state <= B_IDLE;
					end else begin
						dot_idx <= dot_idx + 3'd1;
					end
				end
			end
			endcase
		end
	end

	assign pixel_tile_id = {s2_out_y[10:3], s2_out_x[10:3]};
	assign pixel_offset  = {s2_out_y[2:0],  s2_out_x[2:0]};
	// LOCAL MOD: store all six colour bits. Sega's intensity is binary, so the
	// two low bits of Z are the cheapest thing to give up; they are replicated
	// back on read (see vfb_readout).
	//   { rgb[5:0], draw_idx[3:0], z[7:2] }
	assign pixel_data    = eof_token ? s2_eof_frame_tick_clks
	                                 : {s2_out_c, draw_idx, s2_out_z[7:2]};
	assign eof_completed_frame_tick_clks = s2_eof_completed_frame_tick_clks;

endmodule
