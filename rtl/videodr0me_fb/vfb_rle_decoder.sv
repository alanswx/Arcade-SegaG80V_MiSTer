// ============================================================================
// Decoder for the line-local RLE16 word format.
// written 2026 by Videodr0me
//
// Implemented RLE16 control table:
//   0x0: full RGB literal, word0 [11:4]=R [3:0]=count-1,
//        word1 [15:8]=G [7:0]=B
//   0x1..0x7: masked intensity run, opcode bits are {R,G,B} mask,
//        [11:4]=intensity [3:0]=count-1
//   0x8: repeat previous decoded RGB, [11:0]=count-1
//   0x9..0xE: main-ceiling spill run for masks 001..110:
//        channels selected by opcode bits [2:0] decode to 232,
//        remaining channels decode to [11:4] spill intensity,
//        [3:0]=count-1. Examples:
//        mask 110, spill 49 => RGB=(232,232,49)
//        mask 001, spill 129 => RGB=(129,129,232)
//   0xF: black run, [11:0]=count-1. Odd SDR packer filler words are excluded
//        by the descriptor word count before they reach the decoder.
//
// Compressed words are parsed into a small run FIFO ahead of the pixel
// consumer. This keeps two-word full-RGB literals away from the pixel edge:
// rgb_out is always the current head pixel before advance is asserted.
// ============================================================================

module vfb_rle_decoder (
	input  logic        clk_sys,
	input  logic        reset,

	input  logic        token_valid,
	output logic        token_ready,
	input  logic [15:0] token_data,
	input  logic        token_eol,

	input  logic        advance,
	output logic [23:0] rgb_out,
	output logic        pixel_valid,
	output logic        line_done,
	output logic        underflow
);

	localparam integer RUN_FIFO_DEPTH = 16;
	localparam integer RUN_FIFO_AW = 4;
	localparam logic [7:0] SPILL_MAIN_CEIL = 8'd232;

	typedef enum logic {
		PARSE_WORD,
		PARSE_LITERAL1
	} parse_state_t;

	parse_state_t parse_state;
	logic [7:0] literal_r;
	logic [3:0] literal_count_m1;
	logic literal_first_eol;
	logic [23:0] previous_rgb;

	logic [23:0] fifo_rgb [0:RUN_FIFO_DEPTH-1];
	logic [12:0] fifo_count [0:RUN_FIFO_DEPTH-1];
	logic fifo_eol [0:RUN_FIFO_DEPTH-1];
	logic [RUN_FIFO_AW-1:0] fifo_wr_ptr;
	logic [RUN_FIFO_AW-1:0] fifo_rd_ptr;
	logic [RUN_FIFO_AW:0] fifo_used;

	logic [23:0] run_rgb;
	logic [12:0] run_remaining;
	logic run_eol;

	function automatic [23:0] masked_rgb(
		input logic [2:0] mask,
		input logic [7:0] intensity
	);
		begin
			masked_rgb = {
				mask[2] ? intensity : 8'd0,
				mask[1] ? intensity : 8'd0,
				mask[0] ? intensity : 8'd0
			};
		end
	endfunction

	function automatic [23:0] spill_rgb(
		input logic [2:0] mask,
		input logic [7:0] spill
	);
		begin
			spill_rgb = {
				mask[2] ? SPILL_MAIN_CEIL : spill,
				mask[1] ? SPILL_MAIN_CEIL : spill,
				mask[0] ? SPILL_MAIN_CEIL : spill
			};
		end
	endfunction

	function automatic [12:0] count_short(input logic [3:0] count_m1);
		count_short = {9'd0, count_m1} + 13'd1;
	endfunction

	function automatic [12:0] count_long(input logic [11:0] count_m1);
		count_long = {1'b0, count_m1} + 13'd1;
	endfunction

	wire fifo_full = (fifo_used == RUN_FIFO_DEPTH);
	wire fifo_empty = (fifo_used == 0);
	wire consume_current = advance && (run_remaining != 0);
	wire consume_fifo = advance && (run_remaining == 0) && !fifo_empty;
	wire fifo_pop = consume_fifo;
	logic fifo_push;
	logic [23:0] fifo_push_rgb;
	logic [12:0] fifo_push_count;
	logic fifo_push_eol;

	// Holding the outer FIFO head for one cycle when this queue is full keeps
	// pixel advance out of the upstream FIFO pointer path. When an advance
	// consumes the FIFO head, token intake resumes on the following clock.
	assign token_ready = !fifo_full;

	always_comb begin
		fifo_push = 1'b0;
		fifo_push_rgb = 24'd0;
		fifo_push_count = 13'd0;
		fifo_push_eol = 1'b0;

		if (token_valid && token_ready) begin
			case (parse_state)
				PARSE_WORD: begin
					case (token_data[15:12])
						4'h0: begin
							// First half of a full RGB literal.
						end
						4'h1, 4'h2, 4'h3, 4'h4,
						4'h5, 4'h6, 4'h7: begin
							fifo_push = 1'b1;
							fifo_push_rgb =
								masked_rgb(token_data[14:12],
								           token_data[11:4]);
							fifo_push_count =
								count_short(token_data[3:0]);
							fifo_push_eol = token_eol;
						end
						4'h8: begin
							fifo_push = 1'b1;
							fifo_push_rgb = previous_rgb;
							fifo_push_count =
								count_long(token_data[11:0]);
							fifo_push_eol = token_eol;
						end
						4'h9, 4'ha, 4'hb, 4'hc,
						4'hd, 4'he: begin
							fifo_push = 1'b1;
							fifo_push_rgb =
								spill_rgb(token_data[14:12],
								          token_data[11:4]);
							fifo_push_count =
								count_short(token_data[3:0]);
							fifo_push_eol = token_eol;
						end
						4'hf: begin
							fifo_push = 1'b1;
							fifo_push_rgb = 24'd0;
							fifo_push_count =
								count_long(token_data[11:0]);
							fifo_push_eol = token_eol;
						end
						default: begin
						end
					endcase
				end

				PARSE_LITERAL1: begin
					fifo_push = 1'b1;
					fifo_push_rgb = {literal_r, token_data[15:8],
					                 token_data[7:0]};
					fifo_push_count = count_short(literal_count_m1);
					fifo_push_eol = token_eol || literal_first_eol;
				end
			endcase
		end
	end

	always_comb begin
		if (run_remaining != 0)
			rgb_out = run_rgb;
		else if (!fifo_empty)
			rgb_out = fifo_rgb[fifo_rd_ptr];
		else
			rgb_out = 24'd0;
	end

	always_ff @(posedge clk_sys) begin
		if (reset) begin
			parse_state <= PARSE_WORD;
			literal_r <= 8'd0;
			literal_count_m1 <= 4'd0;
			literal_first_eol <= 1'b0;
			previous_rgb <= 24'd0;
			fifo_wr_ptr <= '0;
			fifo_rd_ptr <= '0;
			fifo_used <= '0;
			run_rgb <= 24'd0;
			run_remaining <= 13'd0;
			run_eol <= 1'b0;
			pixel_valid <= 1'b0;
			line_done <= 1'b0;
			underflow <= 1'b0;
		end else begin
			pixel_valid <= 1'b0;
			line_done <= 1'b0;

			if (token_valid && token_ready) begin
				if (parse_state == PARSE_WORD &&
				    token_data[15:12] == 4'h0) begin
					parse_state <= PARSE_LITERAL1;
					literal_r <= token_data[11:4];
					literal_count_m1 <= token_data[3:0];
					literal_first_eol <= token_eol;
				end else begin
					parse_state <= PARSE_WORD;
				end

				if (fifo_push) begin
					fifo_rgb[fifo_wr_ptr] <= fifo_push_rgb;
					fifo_count[fifo_wr_ptr] <= fifo_push_count;
					fifo_eol[fifo_wr_ptr] <= fifo_push_eol;
					fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
					if (fifo_push_eol)
						previous_rgb <= 24'd0;
					else
						previous_rgb <= fifo_push_rgb;
				end
			end

			if (consume_current) begin
				pixel_valid <= 1'b1;
				if (run_remaining == 13'd1) begin
					if (run_eol)
						line_done <= 1'b1;
					run_remaining <= 13'd0;
				end else begin
					run_remaining <= run_remaining - 13'd1;
				end
			end else if (consume_fifo) begin
				pixel_valid <= 1'b1;
				run_rgb <= fifo_rgb[fifo_rd_ptr];
				run_eol <= fifo_eol[fifo_rd_ptr];
				if (fifo_count[fifo_rd_ptr] == 13'd1) begin
					run_remaining <= 13'd0;
					if (fifo_eol[fifo_rd_ptr])
						line_done <= 1'b1;
				end else begin
					run_remaining <= fifo_count[fifo_rd_ptr] - 13'd1;
				end
				fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
			end else if (advance) begin
				underflow <= 1'b1;
			end

			case ({fifo_push, fifo_pop})
				2'b10: fifo_used <= fifo_used + 1'b1;
				2'b01: fifo_used <= fifo_used - 1'b1;
				default: fifo_used <= fifo_used;
			endcase
		end
	end

endmodule
