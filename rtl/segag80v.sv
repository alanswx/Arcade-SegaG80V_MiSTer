//============================================================================
//  Sega G-80 X-Y game module
//
//  Ties the CPU board, the X-Y boards and Videodr0me's vector renderer
//  together. This is the equivalent of starwars.sv / tempest_sw.sv in the cores
//  this one is grafted onto.
//
//  Clocking
//    Everything game-side lives in one 12 MHz domain, which is what vfb_top
//    expects for its vector input and phosphor timing. The two real clocks are
//    derived from it as fractional enables off the 15.46848 MHz master:
//        Z80   15468480 / 4 = 3.86712 MHz
//        VCL   15468480 / 6 = 2.57808 MHz   (vector generator steps)
//    A fractional enable keeps vfb_top's 12 MHz-based phosphor constants valid
//    without a second PLL.
//
//  Frame pacing
//    No present gate. derpyder's Tempest core needs one because Tempest redraws
//    its list ~250x/sec and the framebuffer would cut lists mid-draw. Sega walks
//    the whole display list exactly once per 40 Hz EDGINT and raises DRAW for
//    the duration, so there is precisely one complete list per frame — the same
//    shape as Star Wars and Asteroids, which feed FRAME_DONE straight in.
//
//  This program is free software under the GNU General Public License v3.
//============================================================================

`default_nettype none

module segag80v #(
	parameter int PHASE_CLKS  = 16,
	parameter int WAIT_STATES = 2
) (
	input  wire        clk_sys,      // 50 MHz, DDRAM domain
	input  wire        clk_12,       // 12 MHz, vector + CPU domain
	input  wire        reset,

	// ---- MRA configuration ----
	input  wire  [2:0] cfg_chip,     // security chip
	input  wire        cfg_usb,      // Universal Sound Board RAM at $D000
	input  wire  [1:0] cfg_fc,       // 0 = plain, 1 = spinner, 2 = elim4
	input  wire  [2:0] cfg_orient,   // {swap_xy, flip_y, flip_x}, MAME's flags

	// ---- ROM download ----
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [24:0] ioctl_addr,
	input  wire  [7:0] ioctl_dout,
	input  wire  [7:0] ioctl_index,

	// ---- controls ----
	input  wire  [7:0] in_d7d6,
	input  wire  [7:0] in_d5d4,
	input  wire  [7:0] in_d3d2,
	input  wire  [7:0] in_d1d0,
	input  wire  [7:0] in_fc,
	input  wire  [7:0] in_coins,
	input  wire signed [7:0] spin_delta,
	input  wire        spin_stb,
	input  wire        coin_a,
	input  wire        coin_b,
	input  wire        service,

	// ---- DDRAM (vector framebuffer) ----
	output wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,

	// ---- SDRAM (halo alignment delay) ----
	input  wire [15:0] SDRAM_DQ_IN,
	output wire [15:0] SDRAM_DQ_OUT,
	output wire        SDRAM_DQ_OE,
	output wire        SDRAM_CKE,
	output wire        SDRAM_nCS,
	output wire        SDRAM_nRAS,
	output wire        SDRAM_nCAS,
	output wire        SDRAM_nWE,
	output wire  [1:0] SDRAM_DQM,
	output wire [12:0] SDRAM_A,
	output wire  [1:0] SDRAM_BA,

	// ---- video out ----
	output wire  [7:0] VGA_R,
	output wire  [7:0] VGA_G,
	output wire  [7:0] VGA_B,
	output wire        VGA_HS,
	output wire        VGA_VS,
	output wire        VGA_HBLANK,
	output wire        VGA_VBLANK,
	input  wire [10:0] h_cnt,
	input  wire [10:0] v_cnt,
	input  wire        ce_pix,
	input  wire        hsync,
	input  wire        vsync,
	input  wire        hblank,
	input  wire        vblank,
	output wire [11:0] render_width,
	output wire [11:0] render_height,

	// ---- OSD (CRT pipeline) ----
	input  wire  [7:0] osd_flash_param,
	input  wire        osd_120hz,
	input  wire  [1:0] osd_buffer_mode,
	input  wire  [2:0] osd_dot_mode,
	input  wire  [2:0] osd_bloom_width,
	input  wire  [2:0] osd_bloom_curve,
	input  wire  [2:0] osd_halo_filter,
	input  wire  [1:0] osd_phosphor_mode,
	input  wire  [1:0] osd_inter_frame_phosphor_mode,
	input  wire  [1:0] osd_halo_spread,
	input  wire        osd_color_space,
	input  wire  [2:0] osd_presentation_color,
	input  wire        osd_slot_mask,
	input  wire        osd_slot_mask_rows,
	input  wire        osd_full_bypass,

	// ---- sound board strobes (audio not implemented yet) ----
	output wire        snd_wr,
	output wire  [1:0] snd_sel,
	output wire        ay_wr,
	output wire        speech_data_wr,
	output wire        speech_ctrl_wr,
	output wire        usb_data_wr,
	output wire  [7:0] snd_data,

	output wire        fifo_full_led
);

	// ------------------------------------------------------------------
	// Fractional clock enables off the 15.46848 MHz master.
	//
	//   ce_cpu : 3.86712 MHz = 12e6 * 3.86712/12  -> step 3867120, mod 12000000
	//   ce_vcl : 2.57808 MHz                      -> step 2578080, mod 12000000
	// ------------------------------------------------------------------
	localparam int CE_MOD     = 12_000_000;
	localparam int CE_CPU_INC =  3_867_120;
	localparam int CE_VCL_INC =  2_578_080;

	logic [23:0] acc_cpu, acc_vcl;
	logic        ce_cpu, ce_vcl;

	always_ff @(posedge clk_12) begin
		if (reset) begin
			acc_cpu <= 24'd0; ce_cpu <= 1'b0;
			acc_vcl <= 24'd0; ce_vcl <= 1'b0;
		end else begin
			if (acc_cpu + CE_CPU_INC >= CE_MOD) begin
				acc_cpu <= acc_cpu + CE_CPU_INC - CE_MOD;
				ce_cpu  <= 1'b1;
			end else begin
				acc_cpu <= acc_cpu + CE_CPU_INC;
				ce_cpu  <= 1'b0;
			end

			if (acc_vcl + CE_VCL_INC >= CE_MOD) begin
				acc_vcl <= acc_vcl + CE_VCL_INC - CE_MOD;
				ce_vcl  <= 1'b1;
			end else begin
				acc_vcl <= acc_vcl + CE_VCL_INC;
				ce_vcl  <= 1'b0;
			end
		end
	end

	// ------------------------------------------------------------------
	// EDGINT: 15468480 / 3 / 0x1F788 = exactly 40.0 Hz.
	// Counted in VCL ticks: VCL is master/6, so the divider is 0x1F788 / 2.
	// ------------------------------------------------------------------
	localparam int EDGINT_DIV = 32'h1F788 / 2;   // 64452 VCL ticks per frame

	// sega_xy only looks at frame_start on a ce tick, so EDGINT must be high
	// *during* one — a registered pulse lands in the gap between ce ticks and
	// is never seen.
	logic [16:0] edgint_cnt;
	wire         edgint = ce_vcl && (edgint_cnt == 17'(EDGINT_DIV - 1));

	always_ff @(posedge clk_12) begin
		if (reset)        edgint_cnt <= 17'd0;
		else if (ce_vcl)  edgint_cnt <= edgint ? 17'd0 : (edgint_cnt + 17'd1);
	end

	// ------------------------------------------------------------------
	// Program ROM, $0000-$BFFF (48K) in block RAM, loaded from the MRA stream.
	// The sin/cos PROM follows it; ioctl_index 0 carries the whole image.
	// ------------------------------------------------------------------
	localparam int PROM_BASE = 32'hC000;   // s-c.xyt-u39 offset in the MRA image

	wire [15:0] rom_addr;
	logic [7:0] rom_data;

	(* ramstyle = "M10K" *) logic [7:0] prog_rom [0:49151];

	wire rom_wr_prog = ioctl_download && ioctl_wr && (ioctl_index == 8'd0)
	                && (ioctl_addr < PROM_BASE);
	wire rom_wr_sin  = ioctl_download && ioctl_wr && (ioctl_index == 8'd0)
	                && (ioctl_addr >= PROM_BASE) && (ioctl_addr < PROM_BASE + 1024);

	always_ff @(posedge clk_sys) begin
		if (rom_wr_prog) prog_rom[ioctl_addr[15:0]] <= ioctl_dout;
	end
	always_ff @(posedge clk_12) begin
		rom_data <= prog_rom[rom_addr];
	end

	// ------------------------------------------------------------------
	// CPU board
	// ------------------------------------------------------------------
	wire [11:0] vram_addr, usb_addr;
	wire  [7:0] vram_din,  usb_din;
	wire        vram_wr,   usb_wr;
	wire  [7:0] vram_dout;
	wire        drawing;

	segag80v_cpu #(.WAIT_STATES(WAIT_STATES)) cpu (
		.clk        (clk_12),
		.ce_cpu     (ce_cpu),
		.reset      (reset),
		.cfg_chip   (cfg_chip),
		.cfg_usb    (cfg_usb),
		.cfg_fc     (cfg_fc),
		.rom_addr   (rom_addr),
		.rom_data   (rom_data),
		.vram_addr  (vram_addr),
		.vram_din   (vram_din),
		.vram_wr    (vram_wr),
		.vram_dout  (vram_dout),
		.usb_addr   (usb_addr),
		.usb_din    (usb_din),
		.usb_wr     (usb_wr),
		.usb_dout   (8'hFF),
		.in_d7d6    (in_d7d6),
		.in_d5d4    (in_d5d4),
		.in_d3d2    (in_d3d2),
		.in_d1d0    (in_d1d0),
		.in_fc      (in_fc),
		.in_coins   (in_coins),
		.spin_delta (spin_delta),
		.spin_stb   (spin_stb),
		.draw_flag  (drawing),
		.edgint     (edgint),
		.coin_a     (coin_a),
		.coin_b     (coin_b),
		.service    (service),
		.snd_wr     (snd_wr),
		.snd_sel    (snd_sel),
		.ay_wr      (ay_wr),
		.speech_data_wr (speech_data_wr),
		.speech_ctrl_wr (speech_ctrl_wr),
		.usb_data_wr    (usb_data_wr),
		.usb_status     (8'hFF),
		.io_dout    (),
		.coin_counter ()
	);

	assign snd_data = usb_din;   // the sound latches all sit on the CPU data bus

	// ------------------------------------------------------------------
	// X-Y boards
	// ------------------------------------------------------------------
	wire [9:0] vec_x, vec_y;
	wire [5:0] vec_colour;
	wire       vec_beam, vec_valid, vec_frame_done;

	sega_xy_top #(
		.PHASE_CLKS (PHASE_CLKS)
	) xy (
		.clk         (clk_12),
		.ce          (ce_vcl),
		.reset       (reset),
		.frame_start (edgint),
		.cpu_addr    (vram_addr),
		.cpu_din     (vram_din),
		.cpu_wr      (vram_wr),
		.cpu_dout    (vram_dout),
		.rom_wr      (rom_wr_sin),
		.rom_addr    (ioctl_addr[9:0]),
		.rom_data    (ioctl_dout),
		.out_x       (vec_x),
		.out_y       (vec_y),
		.out_colour  (vec_colour),
		.out_beam    (vec_beam),
		.out_valid   (vec_valid),
		.drawing     (drawing),
		.frame_done  (vec_frame_done)
	);

	// ------------------------------------------------------------------
	// Coordinate map and renderer feed
	// ------------------------------------------------------------------
	wire [10:0] rast_x, rast_y;
	wire        rast_in_bounds;

	sega_geometry geom (
		.src_x       (vec_x),
		.src_y       (vec_y),
		.orientation (cfg_orient),
		.raster_x    (rast_x),
		.raster_y    (rast_y),
		.in_bounds   (rast_in_bounds)
	);

	assign render_width  = cfg_orient[2] ? 12'd832  : 12'd1024;
	assign render_height = cfg_orient[2] ? 12'd1024 : 12'd832;

	// vfb_top samples continuously in clk_12, so hold the last sample between
	// VCL ticks and only assert the beam on the tick that produced it.
	logic [10:0] fb_x, fb_y;
	logic  [5:0] fb_c;
	logic        fb_beam;
	logic        fb_frame_done;

	always_ff @(posedge clk_12) begin
		if (reset) begin
			fb_x <= 11'd0; fb_y <= 11'd0; fb_c <= 6'd0;
			fb_beam <= 1'b0; fb_frame_done <= 1'b0;
		end else begin
			fb_frame_done <= ce_vcl && vec_frame_done;
			if (ce_vcl && vec_valid) begin
				fb_x    <= rast_x;
				fb_y    <= rast_y;
				fb_c    <= vec_colour;
				fb_beam <= vec_beam && rast_in_bounds;
			end else begin
				fb_beam <= 1'b0;
			end
		end
	end

	// Sega's beam is either fully on or off — there is no Z-axis intensity
	// channel like Atari's AVG, so full scale is the only meaningful value.
	wire [7:0] fb_z = 8'hFF;

	vfb_top renderer (
		.clk_sys             (clk_sys),
		.clk_12              (clk_12),
		.reset               (reset),
		.video_timing_reset  (1'b0),

		.X_VECTOR            (fb_x),
		.Y_VECTOR            (fb_y),
		.Z_VECTOR            (fb_z),
		.COLOR               (fb_c),
		.IS_DOT              (1'b0),
		.BEAM_ON             (fb_beam),

		.DDRAM_CLK           (DDRAM_CLK),
		.DDRAM_BUSY          (DDRAM_BUSY),
		.DDRAM_BURSTCNT      (DDRAM_BURSTCNT),
		.DDRAM_ADDR          (DDRAM_ADDR),
		.DDRAM_DOUT          (DDRAM_DOUT),
		.DDRAM_DOUT_READY    (DDRAM_DOUT_READY),
		.DDRAM_RD            (DDRAM_RD),
		.DDRAM_DIN           (DDRAM_DIN),
		.DDRAM_BE            (DDRAM_BE),
		.DDRAM_WE            (DDRAM_WE),

		.SDRAM_DQ_IN         (SDRAM_DQ_IN),
		.SDRAM_DQ_OUT        (SDRAM_DQ_OUT),
		.SDRAM_DQ_OE         (SDRAM_DQ_OE),
		.SDRAM_CKE           (SDRAM_CKE),
		.SDRAM_nCS           (SDRAM_nCS),
		.SDRAM_nRAS          (SDRAM_nRAS),
		.SDRAM_nCAS          (SDRAM_nCAS),
		.SDRAM_nWE           (SDRAM_nWE),
		.SDRAM_DQM           (SDRAM_DQM),
		.SDRAM_A             (SDRAM_A),
		.SDRAM_BA            (SDRAM_BA),

		.RENDER_WIDTH        (render_width),
		.RENDER_HEIGHT       (render_height),

		.VGA_R               (VGA_R),
		.VGA_G               (VGA_G),
		.VGA_B               (VGA_B),
		.VGA_HS              (VGA_HS),
		.VGA_VS              (VGA_VS),
		.VGA_HBLANK          (VGA_HBLANK),
		.VGA_VBLANK          (VGA_VBLANK),

		.h_cnt               (h_cnt),
		.v_cnt               (v_cnt),
		.ce_pix              (ce_pix),
		.hsync               (hsync),
		.vsync               (vsync),
		.hblank              (hblank),
		.vblank              (vblank),

		.FLASH_PARAM         (osd_flash_param),
		.OSD_120HZ           (osd_120hz),
		.FRAME_DONE          (fb_frame_done),
		.BUFFER_MODE         (osd_buffer_mode),
		.DOT_MODE            (osd_dot_mode),
		.FIFO_FULL_LED       (fifo_full_led),

		.osd_bloom_width     (osd_bloom_width),
		.osd_bloom_curve     (osd_bloom_curve),
		.osd_halo_filter     (osd_halo_filter),
		.osd_phosphor_mode   (osd_phosphor_mode),
		.osd_inter_frame_phosphor_mode (osd_inter_frame_phosphor_mode),
		.osd_halo_spread     (osd_halo_spread),
		.osd_color_space     (osd_color_space),
		.osd_presentation_color (osd_presentation_color),
		.osd_slot_mask       (osd_slot_mask),
		.osd_slot_mask_rows  (osd_slot_mask_rows),
		.osd_full_bypass     (osd_full_bypass),

		.arbiter_reset_busy  ()
	);

endmodule

`default_nettype wire
