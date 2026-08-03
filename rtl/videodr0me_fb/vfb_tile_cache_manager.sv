// ============================================================================
// Tile cache manager for sparse vector pixel writes.
// written 2026 by Videodr0me
//
// Stores 8x8 tiles with an RGB mask, 4-bit draw-time phase, and 9-bit intensity.
// Associative cache slots are flushed and filled in DDRAM bursts.
// Clean tilemaps allow background clears without rewriting the framebuffer.
// First writes to clean cached pixels bypass the repeated-pixel RMW pipeline.
// ============================================================================

module vfb_tile_cache_manager #(
	parameter TILE_SIZE = 8,
	parameter CACHE_COUNT = 4,
	parameter integer BUFFER_COUNT = 5,
	parameter integer BUF_IDX_W = 3
) (
	input  logic clk_sys,
	input  logic reset,

	input  logic [11:0] FB_WIDTH,
	input  logic [11:0] FB_HEIGHT,

	// Rasterizer Interface
	input  logic        pixel_valid,
	output logic        pixel_ready,
	input  logic [15:0] pixel_tile_id,
	input  logic [5:0]  pixel_offset, // 64 pixels per tile
	input  logic [15:0] pixel_data,   // RGB[15:13], draw_idx[12:9], intensity[8:0]

	input  logic        eof_token,
	input  logic [15:0] eof_completed_frame_tick_clks,
	input  logic        fifo_empty,

	// Buffer Controller Interface
	output logic        eof_token_popped,
	output logic [15:0] eof_frame_tick_clks_popped,
	output logic [15:0] eof_elapsed_frame_tick_clks_popped,
	input  logic        flush_req,
	output logic        flush_done,
	input  logic        clear_req,
	input  logic [BUF_IDX_W-1:0] clear_buf_idx,
	output logic        clear_done,
	input  logic [BUF_IDX_W-1:0] buf_draw,
	input  logic [BUF_IDX_W-1:0] buf_display,
	input  logic        display_valid,
	input  logic        has_draw_buf,

	// Arbiter Interface
	// Cache Fill (Read)
	output logic        fill_ready,
	input  logic        fill_grant,
	output logic [28:0] fill_addr,
	output logic [7:0]  fill_burstcnt,
	input  logic [63:0] fill_data,
	input  logic        fill_data_valid,

	// Cache Flush (Write)
	output logic        flush_ready,
	input  logic        flush_grant,
	input  logic        flush_done_in,
	output logic [28:0] flush_addr,
	output logic [7:0]  flush_burstcnt,
	output logic [63:0] flush_din,         // Current beat data
	output logic [7:0]  flush_be,          // Current beat byte enables
	input  logic        flush_advance,     // Beat accepted, present next

	// Readout Interface (Dirty Map Query)
	input  logic [14:0] display_tile_addr,
	output logic        display_tile_dirty,

	// Compositor tilemap port. All maps are read in parallel; only the
	// composing destination map may be written through this port.
	input  logic [14:0] compose_tilemap_addr,
	input  logic        compose_tilemap_we,
	input  logic [BUF_IDX_W-1:0] compose_tilemap_buf,
	input  logic        compose_tilemap_din,
	output logic [BUFFER_COUNT-1:0] compose_tilemap_dout,

	input  logic        arbiter_idle
);

	// Buffer Base Addresses
	wire [28:0] buf_base [0:BUFFER_COUNT-1];
	assign buf_base[0] = 29'h06000000;
	assign buf_base[1] = 29'h06110000;
	assign buf_base[2] = 29'h06220000;
	assign buf_base[3] = 29'h06330000;
	assign buf_base[4] = 29'h06440000;

	// Reset Extension (CDC)
	logic [1:0] rst_sync = 2'b11;
	always_ff @(posedge clk_sys) rst_sync <= {rst_sync[0], reset};
	wire rst_sys = rst_sync[1];

	localparam TILEMAP_STRIDE = 192;
	localparam TILEMAP_ADDR_W = 15;
	localparam TILEMAP_DEPTH = 1 << TILEMAP_ADDR_W;

	function [TILEMAP_ADDR_W-1:0] linear_tile_addr(input [15:0] tile_id);
		logic [15:0] row_base;
		begin
			row_base = ({8'd0, tile_id[15:8]} << 7)
			         + ({8'd0, tile_id[15:8]} << 6);
			linear_tile_addr = row_base[TILEMAP_ADDR_W-1:0]
			                 + {{(TILEMAP_ADDR_W-8){1'b0}}, tile_id[7:0]};
		end
	endfunction

	// Skid Buffer (Decouples Rasterizer from Cache Manager)
	logic [54:0] s_data;
	assign s_data = {eof_token, eof_completed_frame_tick_clks,
	                 pixel_data, pixel_offset, pixel_tile_id};

	logic r_valid=0, r_valid_buf=0;
	logic [54:0] r_data, r_data_buf;
	logic [3:0]  r_offset_word, r_offset_word_buf;
	logic [1:0]  r_offset_byte, r_offset_byte_buf;
	logic [63:0] r_offset_mask, r_offset_mask_buf;
	logic [TILEMAP_ADDR_W-1:0] r_tilemap_addr, r_tilemap_addr_buf;
	logic [7:0]  r_hit_hot;
	logic        r_hit_valid;

	logic s0_ready; // Driven by Cache Manager FSM

	logic load_primary, load_buffer, unload_buffer;
	assign load_primary  = pixel_ready && pixel_valid && (!r_valid || s0_ready) && !r_valid_buf;
	assign load_buffer   = pixel_ready && pixel_valid && r_valid && !s0_ready;
	assign unload_buffer = s0_ready && r_valid_buf;

	// Backpressure to rasterizer
	assign pixel_ready = !r_valid_buf;

	always_ff @(posedge clk_sys) begin
		if (rst_sys) begin
			r_valid <= 0;
			r_valid_buf <= 0;
		end else begin
			if (load_primary || unload_buffer) r_valid <= 1;
			else if (s0_ready)               r_valid <= 0;

			if (load_buffer)   r_valid_buf <= 1;
			else if (unload_buffer) r_valid_buf <= 0;

			if (load_buffer) begin
				r_data_buf <= s_data;
				r_offset_word_buf <= pixel_offset[5:2];
				r_offset_byte_buf <= pixel_offset[1:0];
				r_offset_mask_buf <= 64'd1 << pixel_offset;
				r_tilemap_addr_buf <= linear_tile_addr(pixel_tile_id);
			end
			if (load_primary) begin
				r_data <= s_data;
				r_offset_word <= pixel_offset[5:2];
				r_offset_byte <= pixel_offset[1:0];
				r_offset_mask <= 64'd1 << pixel_offset;
				r_tilemap_addr <= linear_tile_addr(pixel_tile_id);
			end else if (unload_buffer) begin
				r_data <= r_data_buf;
				r_offset_word <= r_offset_word_buf;
				r_offset_byte <= r_offset_byte_buf;
				r_offset_mask <= r_offset_mask_buf;
				r_tilemap_addr <= r_tilemap_addr_buf;
			end
		end
	end

	logic        s0_valid;
	logic        s0_eof;
	logic [15:0] s0_completed_frame_tick_clks;
	logic [15:0] s0_pixel_data;
	logic [3:0]  s0_offset_word;
	logic [1:0]  s0_offset_byte;
	logic [63:0] s0_offset_mask;
	logic [15:0] s0_tile_id;
	logic [TILEMAP_ADDR_W-1:0] s0_tilemap_addr;

	assign s0_valid = r_valid;
	assign s0_eof = r_data[54];
	assign s0_completed_frame_tick_clks = r_data[53:38];
	assign s0_pixel_data = r_data[37:22];
	assign s0_tile_id = r_data[15:0];
	assign s0_offset_word = r_offset_word;
	assign s0_offset_byte = r_offset_byte;
	assign s0_offset_mask = r_offset_mask;
	assign s0_tilemap_addr = r_tilemap_addr;

	// RMW State Machine Definition
	typedef enum logic [3:0] {
		RMW_IDLE,
		RMW_READ,
		RMW_READ2,
		RMW_BLEND,
		RMW_WAIT_FILL,
		RMW_WAIT_FILL_FINISH,
		RMW_MODIFY,
		RMW_WAIT_DIRTY_BIT,
		RMW_FLUSH_ALL,
		RMW_WAIT_FLUSH_REQ_LOW
	} rmw_state_t;
	rmw_state_t rmw_state;




	wire [28:0] draw_buf_base = buf_base[buf_draw];

	// Local cache slots: CACHE_COUNT x 16 x 64-bit register-array entries.
	// Registered reads feed the RMW and flush paths.
	logic [3:0]  s1_offset_word;
	logic [1:0]  s1_offset_byte;
	logic [2:0]  s1_cache_idx;
	logic [2:0]  hit_idx;
	logic [63:0] rmw_read_word;

	logic flush_active = 0;
	logic [2:0] flush_active_idx;
	logic flush_active_is_eof = 0; // Tracks if the active flush is an EOF flush
	logic flush_contaminated = 0; // Tracks if the current flush burst had a concurrent write

	// Shared registered write port. All cache writes queue parameters here;
	// cache_ram updates one cycle later.
	logic        cache_wr_en [0:CACHE_COUNT-1];
	logic        cache_wr_full [0:CACHE_COUNT-1];     // 1 = 64-bit full write (fill), 0 = 16-bit partial
	logic [3:0]  cache_wr_word [0:CACHE_COUNT-1];
	logic [1:0]  cache_wr_byte [0:CACHE_COUNT-1];     // which 16-bit slice (partial only)
	logic [15:0] cache_wr_data_16_q;                  // shared partial write data
	logic [63:0] cache_wr_data_64 [0:CACHE_COUNT-1];  // full write data (fill)

	// Port A Address generation
	logic [3:0] port_a_addr;

	// Port A: Registered read output (one per slot, all read same word address)
	logic [63:0] cache_ram_out [0:CACHE_COUNT-1];

	(* ramstyle = "logic" *) logic [63:0] cache_ram [0:CACHE_COUNT-1][0:15];

	// Cache RAM: CACHE_COUNT slots x 16 words x 64 bits.
	always_ff @(posedge clk_sys) begin
		for(int i=0; i<CACHE_COUNT; i++) begin
			if (cache_wr_en[i]) begin
				if (cache_wr_full[i]) begin
					cache_ram[i][cache_wr_word[i]] <= cache_wr_data_64[i];
				end else begin
					if (cache_wr_byte[i] == 2'd0) cache_ram[i][cache_wr_word[i]][15:0] <= cache_wr_data_16_q;
					if (cache_wr_byte[i] == 2'd1) cache_ram[i][cache_wr_word[i]][31:16] <= cache_wr_data_16_q;
					if (cache_wr_byte[i] == 2'd2) cache_ram[i][cache_wr_word[i]][47:32] <= cache_wr_data_16_q;
					if (cache_wr_byte[i] == 2'd3) cache_ram[i][cache_wr_word[i]][63:48] <= cache_wr_data_16_q;
				end
			end
		end

		// Port A Registered Read (Unconditional for all blocks)
		for (int i=0; i<CACHE_COUNT; i++) begin
			cache_ram_out[i] <= cache_ram[i][port_a_addr];
		end
	end

	logic        cache_valid [0:CACHE_COUNT-1];
	logic        cache_dirty [0:CACHE_COUNT-1];
	logic [15:0] cache_tile_id [0:CACHE_COUNT-1];
	logic [63:0] cache_bitmap [0:CACHE_COUNT-1];

	// Hit/Miss Resolution
	logic [7:0] cache_hit_hot;
	logic       cache_hit;
	logic       dirty_hit;

	logic [7:0] slot_dirty_hit;
	always_comb begin
		hit_idx = 0;
		slot_dirty_hit = 8'd0;
		for (int i=0; i<CACHE_COUNT; i++) begin
			if (cache_hit_hot[i]) hit_idx = i[2:0];
			slot_dirty_hit[i] = |(cache_bitmap[i] & s0_offset_mask);
		end
		cache_hit = |cache_hit_hot;

		// The pixel offset is predecoded into a registered one-hot mask and
		// tested against every slot bitmap in parallel.
		dirty_hit = |(cache_hit_hot & slot_dirty_hit);
	end

	assign cache_hit_hot = r_hit_hot;

	// PLRU Logic (Pseudo-LRU)
	logic [6:0] plru_state = 7'b0;
	wire        sel_right_half = plru_state[0];
	wire        sel_qtr = sel_right_half ? plru_state[2] : plru_state[1];
	wire        sel_leaf = sel_right_half ?
	                      (sel_qtr ? plru_state[6] : plru_state[5]) :
	                      (sel_qtr ? plru_state[4] : plru_state[3]);
	wire [2:0]  plru_victim_way = (CACHE_COUNT == 8) ? {sel_right_half, sel_qtr, sel_leaf} : {1'b0, sel_right_half, sel_qtr};

	// Priority encoders for allocation and eviction

	// Stage 1: registered slot status vectors for eviction
	logic [CACHE_COUNT-1:0] slot_dirty;

	always_ff @(posedge clk_sys) begin
		for (int i=0; i<CACHE_COUNT; i++) begin
			slot_dirty[i] <= cache_valid[i] && cache_dirty[i];
		end
	end

	// Register the allocation candidate before it reaches cache and tilemap
	// write control.
	logic [CACHE_COUNT-1:0] slot_avail_d;
	logic [2:0] free_idx_d;
	logic       has_free_d;
	logic [2:0] free_idx_q;
	logic       has_free_q;

	always_comb begin
		for (int i=0; i<CACHE_COUNT; i++) begin
			slot_avail_d[i] = (!cache_valid[i] || !cache_dirty[i]);
		end

		has_free_d = |slot_avail_d;
		free_idx_d = plru_victim_way;

		if (!slot_avail_d[plru_victim_way]) begin
			if (CACHE_COUNT == 8) begin
				if      (slot_avail_d[plru_victim_way + 3'd1]) free_idx_d = plru_victim_way + 3'd1;
				else if (slot_avail_d[plru_victim_way + 3'd2]) free_idx_d = plru_victim_way + 3'd2;
				else if (slot_avail_d[plru_victim_way + 3'd3]) free_idx_d = plru_victim_way + 3'd3;
				else if (slot_avail_d[plru_victim_way + 3'd4]) free_idx_d = plru_victim_way + 3'd4;
				else if (slot_avail_d[plru_victim_way + 3'd5]) free_idx_d = plru_victim_way + 3'd5;
				else if (slot_avail_d[plru_victim_way + 3'd6]) free_idx_d = plru_victim_way + 3'd6;
				else                                           free_idx_d = plru_victim_way + 3'd7;
			end else begin // CACHE_COUNT == 4
				if      (slot_avail_d[(plru_victim_way + 3'd1) & 3'd3]) free_idx_d = (plru_victim_way + 3'd1) & 3'd3;
				else if (slot_avail_d[(plru_victim_way + 3'd2) & 3'd3]) free_idx_d = (plru_victim_way + 3'd2) & 3'd3;
				else                                                    free_idx_d = (plru_victim_way + 3'd3) & 3'd3;
			end
		end
	end

	// Stage 2: Registered priority encoder outputs (Eviction)
	logic [2:0] lru_dirty_idx;
	logic       has_lru_dirty;

	always_ff @(posedge clk_sys) begin
		has_lru_dirty <= |slot_dirty;
		lru_dirty_idx <= plru_victim_way;

		// If the PLRU victim is not dirty, pick the next dirty slot around
		// the same position.
		if (!slot_dirty[plru_victim_way]) begin
			if (CACHE_COUNT == 8) begin
				if      (slot_dirty[plru_victim_way + 3'd1]) lru_dirty_idx <= plru_victim_way + 3'd1;
				else if (slot_dirty[plru_victim_way + 3'd2]) lru_dirty_idx <= plru_victim_way + 3'd2;
				else if (slot_dirty[plru_victim_way + 3'd3]) lru_dirty_idx <= plru_victim_way + 3'd3;
				else if (slot_dirty[plru_victim_way + 3'd4]) lru_dirty_idx <= plru_victim_way + 3'd4;
				else if (slot_dirty[plru_victim_way + 3'd5]) lru_dirty_idx <= plru_victim_way + 3'd5;
				else if (slot_dirty[plru_victim_way + 3'd6]) lru_dirty_idx <= plru_victim_way + 3'd6;
				else                                         lru_dirty_idx <= plru_victim_way + 3'd7;
			end else begin // CACHE_COUNT == 4
				if      (slot_dirty[(plru_victim_way + 3'd1) & 3'd3]) lru_dirty_idx <= (plru_victim_way + 3'd1) & 3'd3;
				else if (slot_dirty[(plru_victim_way + 3'd2) & 3'd3]) lru_dirty_idx <= (plru_victim_way + 3'd2) & 3'd3;
				else                                                  lru_dirty_idx <= (plru_victim_way + 3'd3) & 3'd3;
			end
		end
	end

	// Tile Dirty Background Map (one per framebuffer)
	// The largest mode is 184 x 135 tiles. A fixed 192-tile stride provides
	// cheap shift/add addressing and fits each map in 32K entries.
	logic [TILEMAP_ADDR_W-1:0] buf_tilemap_addr [0:BUFFER_COUNT-1];
	logic        buf_tilemap_we [0:BUFFER_COUNT-1];
	logic        buf_tilemap_din [0:BUFFER_COUNT-1];
	logic        buf_tilemap_dout [0:BUFFER_COUNT-1];

	genvar g;
	generate
		for (g = 0; g < BUFFER_COUNT; g++) begin : gen_dirty_ram
			(* ramstyle = "no_rw_check, M10K" *) logic buf_tilemap [0:TILEMAP_DEPTH-1];
			wire compose_write = compose_tilemap_we &&
			                     (compose_tilemap_buf == BUF_IDX_W'(g));
			wire tilemap_port_a_we = compose_write || buf_tilemap_we[g];
			wire [TILEMAP_ADDR_W-1:0] tilemap_port_a_addr =
				compose_write ? compose_tilemap_addr : buf_tilemap_addr[g];
			wire tilemap_port_a_din =
				compose_write ? compose_tilemap_din : buf_tilemap_din[g];

			always_ff @(posedge clk_sys) begin
				if (tilemap_port_a_we) begin
					buf_tilemap[tilemap_port_a_addr] <= tilemap_port_a_din;
				end
				buf_tilemap_dout[g] <= buf_tilemap[tilemap_port_a_addr];
				compose_tilemap_dout[g] <= buf_tilemap[compose_tilemap_addr];
			end
		end
	endgenerate

	// Clearer state
	logic [TILEMAP_ADDR_W-1:0] bg_clear_tile;
	logic [BUF_IDX_W-1:0] active_clear_buf;

	typedef enum logic [1:0] {
		CLEAR_INIT,
		CLEAR_IDLE,
		CLEAR_PROCESS,
		CLEAR_WAIT_FINISH
	} clear_state_t;
	clear_state_t clear_state = CLEAR_INIT;

	logic clearer_init_done = 0;
	always_ff @(posedge clk_sys) begin
		if (rst_sys) clearer_init_done <= 0;
		else if (!clearer_init_done && clear_state != CLEAR_INIT)
			clearer_init_done <= 1;
	end

	// Mode-dependent clear limit. FB_HEIGHT changes only as part of a
	// framebuffer mode reset.
	localparam [8:0]  TILE_ROWS_DEFAULT      = 9'd60;     // 480p
	localparam [15:0] TILEMAP_ENTRIES_DEFAULT = 16'd11520; // 60 * 192
	localparam [TILEMAP_ADDR_W-1:0] TILEMAP_MAX_DEFAULT = 15'd11519;

	logic [8:0] tile_rows_r = TILE_ROWS_DEFAULT;
	logic [15:0] tilemap_entries_r = TILEMAP_ENTRIES_DEFAULT;
	logic [TILEMAP_ADDR_W-1:0] tilemap_max = TILEMAP_MAX_DEFAULT;

	always_ff @(posedge clk_sys) begin
		if (rst_sys) begin
			tile_rows_r       <= TILE_ROWS_DEFAULT;
			tilemap_entries_r <= TILEMAP_ENTRIES_DEFAULT;
			tilemap_max       <= TILEMAP_MAX_DEFAULT;
		end else begin
			tile_rows_r       <= 9'((FB_HEIGHT + 12'd7) >> 3);
			tilemap_entries_r <= ({7'd0, tile_rows_r} << 7)
			                   + ({7'd0, tile_rows_r} << 6);
			tilemap_max       <= tilemap_entries_r[TILEMAP_ADDR_W-1:0] - 1'b1;
		end
	end

	logic [15:0] s1_pixel_data;
	logic [15:0] s1_tile_id;
	logic [2:0]  s1_alloc_idx;
	logic [63:0] s1_offset_mask_reg;

	// Latch eviction target index so invalidation uses a
	// stable index even if lru_dirty_idx changes before flush_grant.
	logic [2:0]  flush_evict_idx;

	// Pipelined LRU Update Stage
	logic       s1_lru_en = 0;
	logic [2:0] s1_lru_idx = 0;

	always_ff @(posedge clk_sys) begin
		if (rst_sys) begin
			plru_state <= 7'b0;
		end else if (s1_lru_en) begin
			if (CACHE_COUNT == 8) begin
				plru_state[0] <= ~s1_lru_idx[2];
				if (s1_lru_idx[2] == 1'b0) begin
					plru_state[1] <= ~s1_lru_idx[1];
					if (s1_lru_idx[1] == 1'b0) plru_state[3] <= ~s1_lru_idx[0];
					else                       plru_state[4] <= ~s1_lru_idx[0];
				end else begin
					plru_state[2] <= ~s1_lru_idx[1];
					if (s1_lru_idx[1] == 1'b0) plru_state[5] <= ~s1_lru_idx[0];
					else                       plru_state[6] <= ~s1_lru_idx[0];
				end
			end else begin // CACHE_COUNT == 4
				plru_state[0] <= ~s1_lru_idx[1];
				if (s1_lru_idx[1] == 1'b0) plru_state[1] <= ~s1_lru_idx[0];
				else                       plru_state[2] <= ~s1_lru_idx[0];
			end
		end
	end


	// S2 pipeline: cached pixel extraction, registered in RMW_READ2.
	logic [15:0] s2_cached_pixel;
	always_ff @(posedge clk_sys) begin
		if (rmw_state == RMW_READ2) begin
			case (s1_offset_byte)
				2'b00: s2_cached_pixel <= cache_ram_out[s1_cache_idx][15:0];
				2'b01: s2_cached_pixel <= cache_ram_out[s1_cache_idx][31:16];
				2'b10: s2_cached_pixel <= cache_ram_out[s1_cache_idx][47:32];
				2'b11: s2_cached_pixel <= cache_ram_out[s1_cache_idx][63:48];
			endcase
		end
	end

	// First blend stage: resolve per-channel crossing energy.
	wire [2:0] c_old = s2_cached_pixel[15:13];
	wire [2:0] c_new = s1_pixel_data[15:13];
	wire [8:0] z_old = s2_cached_pixel[8:0];
	wire [8:0] z_new = s1_pixel_data[8:0];
	wire [8:0] z_hi  = (z_old >= z_new) ? z_old : z_new;
	wire [8:0] z_lo  = (z_old >= z_new) ? z_new : z_old;
	wire [9:0] z_soft_overlap = {1'b0, z_hi} + {3'b000, z_lo[8:2]};

	function automatic logic [9:0] soft_cross_channel(
		input logic       old_en,
		input logic       new_en,
		input logic [8:0] old_z_in,
		input logic [8:0] new_z_in,
		input logic [9:0] overlap_z
	);
		begin
			if (old_en && new_en) begin
				soft_cross_channel = overlap_z;
			end else if (old_en) begin
				soft_cross_channel = {1'b0, old_z_in};
			end else if (new_en) begin
				soft_cross_channel = {1'b0, new_z_in};
			end else begin
				soft_cross_channel = 10'd0;
			end
		end
	endfunction

	logic [9:0] r_sum, g_sum, b_sum;
	assign r_sum = soft_cross_channel(c_old[2], c_new[2], z_old, z_new, z_soft_overlap);
	assign g_sum = soft_cross_channel(c_old[1], c_new[1], z_old, z_new, z_soft_overlap);
	assign b_sum = soft_cross_channel(c_old[0], c_new[0], z_old, z_new, z_soft_overlap);

	logic [9:0] blend_r_sum_q;
	logic [9:0] blend_g_sum_q;
	logic [9:0] blend_b_sum_q;
	logic [2:0] blend_color_q;
	logic [3:0] blend_draw_idx_q;

	// Second blend stage: normalize total energy across the active channels.
	logic [11:0] total_energy;
	assign total_energy = blend_r_sum_q + blend_g_sum_q + blend_b_sum_q;

	logic [11:0] z_out_full;
	always_comb begin
		case (blend_color_q)
			3'b001, 3'b010, 3'b100: z_out_full = total_energy;
			3'b011, 3'b101, 3'b110: z_out_full = total_energy >> 1;
			3'b111: z_out_full = (total_energy + (total_energy >> 2)) >> 2; // 5/16 approximation to one-third.
			default: z_out_full = 12'd0;
		endcase
	end

	logic [8:0] final_z;
	assign final_z = (z_out_full > 11'd511) ? 9'd511 : z_out_full[8:0];

	logic [15:0] blended_pixel;
	assign blended_pixel = {blend_color_q, blend_draw_idx_q, final_z};

	// Controller Flush Signals
	logic flush_all = 0;
	logic [2:0] eof_flush_idx = 0;
	logic flush_done_out = 0;
	assign flush_done = flush_done_out;
	wire normal_flush_releases_slot =
		flush_done_in && !flush_all && !flush_contaminated &&
		!cache_wr_en[flush_active_idx];

	always_ff @(posedge clk_sys) begin
		if (rst_sys) begin
			has_free_q <= 1'b0;
			free_idx_q <= 3'd0;
		end else if (normal_flush_releases_slot) begin
			// Make the released slot visible without issuing another eviction
			// while the registered metadata catches up.
			has_free_q <= 1'b1;
			free_idx_q <= flush_active_idx;
		end else begin
			has_free_q <= has_free_d;
			free_idx_q <= free_idx_d;
		end
	end

	// Flush beat counter owned by cache manager, advanced by arbiter.
	logic [3:0] flush_beat_int = 0;

	// Flush Read Index Selection
	wire [2:0] flush_read_idx = flush_active ? flush_active_idx :
	                            flush_all ? eof_flush_idx : flush_evict_idx;

	// Flush data path:
	// Pre-read both current beat and next beat into registers every cycle.
	// A registered prev_advance flag selects which one to present.
	logic [63:0] flush_data_cur;    // Registered: cache_ram[idx][flush_beat_int]
	logic [63:0] flush_data_nxt;    // Registered: cache_ram[idx][flush_beat_int + 1]
	logic [3:0]  flush_beat_pipe;   // Registered: flush_beat_int
	logic        prev_advance = 0;  // Registered: flush_advance from previous cycle

	always_ff @(posedge clk_sys) begin
		flush_data_cur  <= cache_ram[flush_read_idx][flush_beat_int];
		flush_data_nxt  <= cache_ram[flush_read_idx][flush_beat_int + 4'd1];
		flush_beat_pipe <= flush_beat_int;
		prev_advance    <= flush_advance;
	end

	// If we advanced last cycle, the current register is stale; use pre-read next.
	wire [63:0] unmasked_flush_data = prev_advance ? flush_data_nxt : flush_data_cur;
	wire [3:0]  active_flush_beat   = prev_advance ? (flush_beat_pipe + 4'd1) : flush_beat_pipe;

	logic [63:0] flush_bitmap_reg;

	// Flush masking initializes unwritten pixels to zero.
	assign flush_din = {
		flush_bitmap_reg[{active_flush_beat, 2'd3}] ? unmasked_flush_data[63:48] : 16'd0,
		flush_bitmap_reg[{active_flush_beat, 2'd2}] ? unmasked_flush_data[47:32] : 16'd0,
		flush_bitmap_reg[{active_flush_beat, 2'd1}] ? unmasked_flush_data[31:16] : 16'd0,
		flush_bitmap_reg[{active_flush_beat, 2'd0}] ? unmasked_flush_data[15:0]  : 16'd0
	};

	// Flush Burst Count: always 16 beats per tile
	assign flush_burstcnt = 8'd16;

	// Flush BE: ALWAYS write full 64-bit words (0xFF) to ensure initialization
	assign flush_be = 8'hFF;

	// Fill Beat Counter: owned by cache manager
	logic [3:0] fill_beat_int = 0;
	assign fill_burstcnt = 8'd16;

	// Port A Address generation
	always_comb begin
		if (rmw_state == RMW_IDLE) port_a_addr = s0_offset_word;
		else port_a_addr = s1_offset_word;
	end

	// Port A: Registered read output (one per slot, all read same word address)
	// S1 pipeline: draw-buffer dirty bit
	// buf_tilemap_dout is synchronous, so s1_dirty_valid makes the FSM wait one
	// cycle before predecoding the requested tile's clean/dirty state.
	logic s1_dirty_valid = 0;
	logic s1_tile_clean = 0;

	// Pipeline buf_display to match the 1-cycle latency of the M10K BRAMs
	logic [BUF_IDX_W-1:0] buf_display_d1;
	always_ff @(posedge clk_sys) begin
		buf_display_d1 <= buf_display;
	end

	// Force clean during CLEAR_INIT
	assign display_tile_dirty = (clearer_init_done && display_valid) ? buf_tilemap_dout[buf_display_d1] : 1'b0;

	logic [TILEMAP_ADDR_W-1:0] s1_tilemap_addr;
	logic [TILEMAP_ADDR_W-1:0] draw_tilemap_addr;
	logic        draw_we;
	logic        draw_din;
	logic [TILEMAP_ADDR_W-1:0] rmw_tilemap_addr_q;
	logic        rmw_tilemap_mark_q;

	always_comb begin
		draw_tilemap_addr = s0_tilemap_addr;
		draw_we = 0;
		draw_din = 0;

		if (rmw_tilemap_mark_q) begin
			draw_tilemap_addr = rmw_tilemap_addr_q;
			draw_we = 1;
			draw_din = 1;
		end else if (rmw_state == RMW_WAIT_DIRTY_BIT && s1_dirty_valid && has_free_q && s1_tile_clean) begin
			draw_tilemap_addr = s1_tilemap_addr;
			draw_we = 1;
			draw_din = 1;
		end else if (rmw_state == RMW_IDLE && s0_valid) begin
			// Present the candidate tile to the dirty map so a miss can sample
			// the existing dirty bit. Do not write on cache hits here: fast misses
			// mark the tile dirty after the existing bit is consumed, and dirty/RMW
			// paths mark it in RMW_MODIFY.
			draw_tilemap_addr = s0_tilemap_addr;
		end else if (rmw_state == RMW_WAIT_DIRTY_BIT) begin
			draw_tilemap_addr = s1_tilemap_addr;
		end
	end

	logic [7:0] tilemap_collision_cnt = 0;
	always_ff @(posedge clk_sys) begin
		if (rst_sys) tilemap_collision_cnt <= 0;
		else begin
			if (clearer_init_done) begin
				if ((buf_display == active_clear_buf && clear_state == CLEAR_PROCESS) ||
					(buf_display == buf_draw && has_draw_buf) ||
					(active_clear_buf == buf_draw && clear_state == CLEAR_PROCESS && has_draw_buf)) begin
					tilemap_collision_cnt <= tilemap_collision_cnt + 1'b1;
				end
			end
		end
	end

	always_comb begin
		for (int i=0; i<BUFFER_COUNT; i++) begin
			buf_tilemap_we[i] = 0;
			buf_tilemap_addr[i] = 0;
			buf_tilemap_din[i] = 0;
		end

		if (!clearer_init_done) begin
			for (int i=0; i<BUFFER_COUNT; i++) begin
				buf_tilemap_addr[i] = bg_clear_tile;
				buf_tilemap_din[i] = 0;
				buf_tilemap_we[i] = 1;
			end
		end else begin
			for (int i=0; i<BUFFER_COUNT; i++) begin
				automatic logic is_display = display_valid && (buf_display == BUF_IDX_W'(i));
				automatic logic is_clear   = (clear_state == CLEAR_PROCESS && active_clear_buf == BUF_IDX_W'(i));
				automatic logic is_draw    = has_draw_buf && (buf_draw == BUF_IDX_W'(i));

				if (is_display) begin
					buf_tilemap_addr[i] = display_tile_addr;
				end else if (is_clear) begin
					buf_tilemap_addr[i] = bg_clear_tile;
					if (clear_state == CLEAR_PROCESS) begin
						buf_tilemap_we[i] = 1;
						buf_tilemap_din[i] = 0;
					end
				end else if (is_draw) begin
					buf_tilemap_addr[i] = draw_tilemap_addr;
					if (has_draw_buf) begin
						buf_tilemap_we[i] = draw_we;
						buf_tilemap_din[i] = draw_din;
					end
				end
			end
		end
	end

	// Clear buf_tilemap FSM
	always_ff @(posedge clk_sys) begin
		if (rst_sys) begin
			clear_state <= CLEAR_INIT;
			bg_clear_tile <= 0;
			clear_done <= 0;
			active_clear_buf <= '0;
		end else begin
			case (clear_state)
				CLEAR_INIT: begin
					if (bg_clear_tile == TILEMAP_ADDR_W'(TILEMAP_DEPTH-1)) begin
						clear_state <= CLEAR_IDLE;
						bg_clear_tile <= 0;
					end else begin
						bg_clear_tile <= bg_clear_tile + 1'b1;
					end
				end

				CLEAR_IDLE: begin
					if (clear_req) begin
						bg_clear_tile <= 0;
						active_clear_buf <= clear_buf_idx;  // Latch: stable for entire sweep
						clear_state <= CLEAR_PROCESS;
					end
				end

				CLEAR_PROCESS: begin
					if (bg_clear_tile >= tilemap_max) clear_state <= CLEAR_WAIT_FINISH;
					else bg_clear_tile <= bg_clear_tile + 1'b1;
				end

				CLEAR_WAIT_FINISH: begin
					// 4-phase handshake: keep clear_done HIGH until the
					// Buffer Controller acknowledges by dropping clear_req.
					if (!clear_req) begin
						clear_done  <= 0;
						clear_state <= CLEAR_IDLE;
					end else begin
						clear_done <= 1;
					end
				end
			endcase
		end
	end

	// RMW pipeline control signals
	// Cache tag matches travel with the primary skid-buffer entry. Buffered
	// entries are matched when promoted so they always see the current tags.
	logic [15:0] tag_match_tile_id;
	logic [7:0]  tag_match_hot;
	always_comb begin
		if (load_primary)
			tag_match_tile_id = pixel_tile_id;
		else if (unload_buffer)
			tag_match_tile_id = r_data_buf[15:0];
		else
			tag_match_tile_id = s0_tile_id;

		tag_match_hot = 8'd0;
		for (int i=0; i<CACHE_COUNT; i++) begin
			tag_match_hot[i] =
				cache_valid[i] && (cache_tile_id[i] == tag_match_tile_id);
		end
	end

	wire fast_tag_allocation =
		(rmw_state == RMW_WAIT_DIRTY_BIT) && s1_dirty_valid &&
		has_free_q && s1_tile_clean;
	wire fill_tag_allocation =
		(rmw_state == RMW_WAIT_FILL) && fill_data_valid &&
		(fill_beat_int == 4'd15);
	wire tag_map_unstable =
		(rmw_state == RMW_FLUSH_ALL) ||
		fast_tag_allocation || fill_tag_allocation;

	// In IDLE, accept pixels when initialized and no flush request is active.
	logic manager_ready = 0;
	always_ff @(posedge clk_sys) begin
		manager_ready <= has_draw_buf && clearer_init_done;
	end

	assign s0_ready = (rmw_state == RMW_IDLE) && manager_ready &&
		!flush_req && (!s0_valid || r_hit_valid);

	always_ff @(posedge clk_sys) begin
		if (rst_sys) begin
			r_hit_hot <= 8'd0;
			r_hit_valid <= 1'b0;
		end else if (tag_map_unstable) begin
			r_hit_valid <= 1'b0;
		end else if (load_primary || unload_buffer ||
		             (r_valid && !r_hit_valid)) begin
			r_hit_hot <= tag_match_hot;
			r_hit_valid <= 1'b1;
		end else if (s0_ready && r_valid) begin
			r_hit_valid <= 1'b0;
		end
	end

	// RMW + Flush + Fill FSM
	always_ff @(posedge clk_sys) begin
		if (rst_sys) begin
			rmw_state <= RMW_IDLE;
			fill_ready <= 0; flush_ready <= 0; flush_active <= 0;
			flush_all <= 0; flush_done_out <= 0; eof_token_popped <= 0;
			eof_frame_tick_clks_popped <= 16'd0;
			eof_elapsed_frame_tick_clks_popped <= 16'd0;
			flush_beat_int <= 0; fill_beat_int <= 0;
			s1_dirty_valid <= 1'b0;
			s1_tile_clean <= 1'b0;
			s1_tilemap_addr <= '0;
			rmw_tilemap_addr_q <= '0;
			rmw_tilemap_mark_q <= 1'b0;
			for(int i=0; i<CACHE_COUNT; i++) begin
				cache_valid[i] <= 0;
				cache_dirty[i] <= 0;
				cache_bitmap[i] <= 0;
				cache_wr_en[i] <= 0;
			end
		end else begin

			eof_token_popped <= 0;
			eof_frame_tick_clks_popped <= s0_pixel_data;
			eof_elapsed_frame_tick_clks_popped <= s0_completed_frame_tick_clks;
			flush_done_out <= 0;

			for (int i=0; i<CACHE_COUNT; i++) cache_wr_en[i] <= 0; // Default-clear: one-shot pulse per write
			s1_lru_en <= 0;   // Default-clear pipeline trigger
			rmw_tilemap_mark_q <= 1'b0;

			// Universal Arbiter Grant/Complete Handlers
			// The arbiter's grant and done signals are 1-cycle pulses.

			// Flush complete: clear dirty only if this flush was not contaminated.
			if (flush_done_in) begin
				flush_active <= 0;
				flush_contaminated <= 0;

				if (normal_flush_releases_slot) begin
					cache_dirty[flush_active_idx] <= 0;
				end
			end

			// Flush grant: snapshot bitmap at grant, not request.
			if (flush_ready && flush_grant) begin
				flush_ready <= 0;
				flush_active <= 1;
				flush_active_idx <= flush_evict_idx;
				flush_active_is_eof <= flush_all;
				flush_bitmap_reg <= cache_bitmap[flush_evict_idx];

				// cache_wr_en here means a queued write is committing on this edge.
				// If it targets the granted slot, the flush pre-read may see stale data.
				flush_contaminated <= cache_wr_en[flush_evict_idx];

			end else if (flush_active && cache_wr_en[flush_active_idx]) begin
				// Any write committing while the burst is active means DDR may receive stale data.
				flush_contaminated <= 1;
			end

			// Fill grant: clear fill_ready (already handled in-state, but
			// add safety catch here for the same reason)
			if (fill_ready && fill_grant) begin
				fill_ready <= 0;
			end

			if (flush_advance) flush_beat_int <= flush_beat_int + 1'b1;
			if (fill_data_valid) fill_beat_int <= fill_beat_int + 1'b1;

		case (rmw_state)
				RMW_IDLE: begin
					if (flush_req || flush_all) begin
						flush_all <= 1;
						eof_flush_idx <= 0;
						rmw_state <= RMW_FLUSH_ALL;
					end else if (s0_valid && s0_ready) begin
						if (s0_eof) begin
							// EOF token reached the front of the skid buffer.
							eof_token_popped <= 1;
						end else begin
							s1_pixel_data <= s0_pixel_data;
							s1_tile_id <= s0_tile_id;
							s1_tilemap_addr <= s0_tilemap_addr;
							s1_offset_word <= s0_offset_word;
							s1_offset_byte <= s0_offset_byte;
							s1_offset_mask_reg <= s0_offset_mask;

							// 1. Independent write dispatch for clean hits.
							cache_wr_data_16_q <= s0_pixel_data;
							for (int i=0; i<CACHE_COUNT; i++) begin
								cache_wr_full[i] <= 0;
								cache_wr_word[i] <= s0_offset_word;
								cache_wr_byte[i] <= s0_offset_byte;
							end

							for (int i=0; i<CACHE_COUNT; i++) begin
								if (cache_hit_hot[i]) begin
									cache_dirty[i] <= 1'b1;
									if (!slot_dirty_hit[i]) begin
										cache_wr_en[i]   <= 1;
										cache_bitmap[i] <= cache_bitmap[i] | s0_offset_mask;
									end
								end
							end

							// 2. FSM state transitions
							if (cache_hit) begin
								s1_lru_en <= 1;
								s1_lru_idx <= hit_idx;

								// Latch selected slot for any later RMW path.
								s1_cache_idx <= hit_idx;

								if (dirty_hit) begin
									// Dirty hit: stall for RMW blending.
									rmw_state <= RMW_READ;
								end
							end else begin
								// Miss: sample the dirty bit.
								s1_dirty_valid <= 0;
								rmw_state <= RMW_WAIT_DIRTY_BIT;
							end
						end
					end
				end

				RMW_WAIT_DIRTY_BIT: begin
					if (!s1_dirty_valid) begin
						// Wait one cycle for buf_tilemap_dout, then predecode the
						// clean-miss decision into a register before allocation.
						s1_dirty_valid <= 1;
						s1_tile_clean <= !buf_tilemap_dout[buf_draw];
					end else begin
						if (has_free_q) begin
							if (s1_tile_clean) begin
								// Fast miss: tile is clean. Allocate and write directly.
								cache_valid[free_idx_q] <= 1;
								cache_tile_id[free_idx_q] <= s1_tile_id;
								cache_dirty[free_idx_q] <= 1;
								cache_bitmap[free_idx_q] <= s1_offset_mask_reg;

								s1_lru_en <= 1;
								s1_lru_idx <= free_idx_q;

								// Direct write to cache RAM.
								cache_wr_en[free_idx_q] <= 1;
								cache_wr_full[free_idx_q] <= 0;
								cache_wr_word[free_idx_q] <= s1_offset_word;
								cache_wr_byte[free_idx_q] <= s1_offset_byte;
								cache_wr_data_16_q <= s1_pixel_data;

								rmw_state <= RMW_IDLE;
							end else begin
								// Dirty miss: fetch tile contents from DDR.
								fill_ready <= 1;
								fill_beat_int <= 0;
								fill_addr <= draw_buf_base + ({13'd0, s1_tile_id} << 4);
								s1_alloc_idx <= free_idx_q;
								rmw_state <= RMW_WAIT_FILL;
							end
						end else begin
							// All slots are dirty; flush an LRU dirty slot before retrying.
							if (has_lru_dirty && !flush_ready && !flush_active) begin
								flush_ready <= 1;
								flush_beat_int <= 0;
								flush_evict_idx <= lru_dirty_idx;
								flush_addr <= draw_buf_base + ({13'd0, cache_tile_id[lru_dirty_idx]} << 4);
								flush_bitmap_reg <= cache_bitmap[lru_dirty_idx];
							end
							// Stay here until the registered allocation candidate becomes valid.
						end
					end
				end

				RMW_FLUSH_ALL: begin
					if (cache_valid[eof_flush_idx] && cache_dirty[eof_flush_idx]) begin
						if (!flush_ready && !flush_active) begin
							flush_ready <= 1;
							flush_beat_int <= 0;
							flush_evict_idx <= eof_flush_idx; // Select slot for flush pre-read.
							flush_addr <= draw_buf_base + ({13'd0, cache_tile_id[eof_flush_idx]} << 4);
							flush_bitmap_reg <= cache_bitmap[eof_flush_idx];
						end else if (flush_active && flush_active_idx == eof_flush_idx) begin
							// Grant already handled by universal handler.
							// Wait for flush_done_in to advance.
						end
					end

					if ((cache_valid[eof_flush_idx] && cache_dirty[eof_flush_idx] && flush_active && flush_active_idx == eof_flush_idx && flush_done_in && flush_active_is_eof) ||
					    !(cache_valid[eof_flush_idx] && cache_dirty[eof_flush_idx])) begin

						if (eof_flush_idx == (CACHE_COUNT - 1)) begin
							flush_all <= 0;
							rmw_state <= RMW_WAIT_FLUSH_REQ_LOW;
							flush_done_out <= 1;
							for (int i=0; i<CACHE_COUNT; i++) begin
								cache_valid[i] <= 0;
								cache_dirty[i] <= 0;
								cache_bitmap[i] <= 0;
							end
						end else begin
							eof_flush_idx <= eof_flush_idx + 3'd1;
						end
					end
				end

				RMW_WAIT_FILL: begin
					if (fill_grant) fill_ready <= 0;
					if (fill_data_valid) begin
						cache_wr_en[s1_alloc_idx]      <= 1;
						cache_wr_full[s1_alloc_idx]    <= 1;
						cache_wr_word[s1_alloc_idx]    <= fill_beat_int;
						cache_wr_data_64[s1_alloc_idx] <= fill_data;
					end
					if (fill_data_valid && fill_beat_int == 4'd15) begin
						cache_valid[s1_alloc_idx] <= 1;
						cache_tile_id[s1_alloc_idx] <= s1_tile_id;
						// Complete dirty-miss fill.
						cache_bitmap[s1_alloc_idx] <= 64'hFFFFFFFFFFFFFFFF;
						cache_dirty[s1_alloc_idx] <= 0;

						s1_lru_en <= 1;
						s1_lru_idx <= s1_alloc_idx;
						s1_cache_idx <= s1_alloc_idx;

						rmw_state <= RMW_WAIT_FILL_FINISH;
					end
				end

				RMW_WAIT_FILL_FINISH: begin
					rmw_state <= RMW_READ;
				end

				RMW_READ: begin
					// Registered cache-row data is available in cache_ram_out.
					rmw_state <= RMW_READ2;
				end
				RMW_READ2: begin
					// Select the requested slot and pixel into s2_cached_pixel.
					rmw_state <= RMW_BLEND;
				end

				RMW_BLEND: begin
					blend_r_sum_q <= r_sum;
					blend_g_sum_q <= g_sum;
					blend_b_sum_q <= b_sum;
					blend_color_q <= c_old | c_new;
					blend_draw_idx_q <= s1_pixel_data[12:9];

					rmw_tilemap_addr_q <= s1_tilemap_addr;
					rmw_tilemap_mark_q <= 1'b1;
					rmw_state <= RMW_MODIFY;
				end

				RMW_MODIFY: begin
					// Queue write via registered write port (commits next cycle)
					cache_wr_en[s1_cache_idx] <= 1;
					cache_wr_full[s1_cache_idx] <= 0;
					cache_wr_word[s1_cache_idx] <= s1_offset_word;
					cache_wr_byte[s1_cache_idx] <= s1_offset_byte;
					cache_wr_data_16_q <= blended_pixel;

					cache_bitmap[s1_cache_idx] <=
						cache_bitmap[s1_cache_idx] | s1_offset_mask_reg;
					cache_dirty[s1_cache_idx] <= 1'b1;
					rmw_state <= RMW_IDLE;
				end

				RMW_WAIT_FLUSH_REQ_LOW: begin
					if (!flush_req) begin
						rmw_state <= RMW_IDLE;
						flush_done_out <= 0;
					end else begin
						flush_done_out <= 1;
					end
				end
			endcase
		end
	end
endmodule
