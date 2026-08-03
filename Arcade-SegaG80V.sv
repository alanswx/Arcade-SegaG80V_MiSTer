//============================================================================
//  Sega G-80 X-Y (vector) arcade hardware for MiSTer FPGA
//
//  Eliminator, Space Fury, Zektor, Tac/Scan, Star Trek.
//  Original hardware by Sega/Gremlin, 1981-1982.
//
//  Vector renderer and CRT pipeline by Videodr0me (videodr0me_fb, from
//  Arcade-Asteroids_MiSTer). This top level follows that core's structure.
//
//  This program is free software under the GNU General Public License v3.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

	`include "build_id.v"

	logic [127:0] status;
	logic  [31:0] joystick_0;
	logic  [31:0] joystick_1;
	logic  [15:0] analog_0;
	logic   [1:0] buttons;
	logic         direct_video;
	wire   [21:0] gamma_bus;

	logic         ioctl_download;
	logic         ioctl_wr;
	logic  [26:0] ioctl_addr;
	logic   [7:0] ioctl_dout;
	logic  [15:0] ioctl_index;

	logic clk_12;
	logic clk_125;
	logic pll_locked;

	logic         video_is_720p;
	logic   [7:0] game_id = 8'd0;

	//============================================================
	// OSD
	//============================================================
	localparam CONF_STR = {
		"SegaG80V;;",
		"-;",
		"P1,Video Options;",
		"P1-;",
		"P1O[15:14],Aspect ratio,Optimized,Stretched,Pixel Perfect;",
		"D0P1O[25],120Hz (720p only),Off,On;",
		"P1O[40:39],Buffer Mode,EOF + VBL,VBL,EOF;",
		"P1O[30:28],Dot Scale,2x,2.5x,3x,1x;",
		"P1-;",
		"P1O[43:41],Bloom Width,Off,1,2,3,4,5,6,7;",
		"P1O[46:44],Bloom Curve,0,1,2,3,4,5,6,7;",
		"P1O[49:47],Halo Filter,Off,1,2,3,4,5,6,7;",
		"P1O[51:50],Halo Spread,Original,Wide,Wider,Widest;",
		"P1-;",
		"P1O[53:52],Phosphor Decay,Off,LUT A,LUT B,LUT C;",
		"P1O[55:54],Inter-frame Phosphor,Off,LUT A,LUT B,LUT C;",
		"P1O[56],Colour Space,Off,Amplifone;",
		"P1O[59:57],Presentation Colour,Normal,1,2,3,4,5,6,7;",
		"P1O[60],Slot Mask,Off,On;",
		"P1O[61],Slot Mask Rows,Off,On;",
		"P1O[62],Bypass CRT Pipeline,Off,On;",
		"-;",
		"P2,Pause Options;",
		"P2-;",
		"P2O[116],Pause when OSD is open,Off,On;",
		"P2O[117],Dim video after 10s,On,Off;",
		"-;",
		"P3,Core Info;",
		"P3-;",
		"P3-,Sega G-80 X-Y vector core;",
		"P3-;",
		"P3-,Vector renderer and CRT;",
		"P3-,pipeline by Videodr0me.;",
		"P3-;",
		"P3-,Hardware analysis from;",
		"P3-,MAME (Aaron Giles).;",
		"-;",
		"R[0],Reset;",
		"J1,Fire,Thrust,Start 1,Start 2,Coin,Pause,Coin 2;",
		"jn,A,B,Start,Select,R,L,Y;",
		"V,v0.1.", `BUILD_DATE
	};

	hps_io #(.CONF_STR(CONF_STR)) hps_io_inst (
		.clk_sys(clk_12),
		.HPS_BUS(HPS_BUS),
		.joystick_0(joystick_0),
		.joystick_1(joystick_1),
		.joystick_l_analog_0(analog_0),
		.buttons(buttons),
		.forced_scandoubler(),
		.direct_video(direct_video),
		.gamma_bus(gamma_bus),
		.status(status),
		.status_menumask({15'd0, !video_is_720p}),
		.ioctl_download(ioctl_download),
		.ioctl_wr(ioctl_wr),
		.ioctl_addr(ioctl_addr),
		.ioctl_dout(ioctl_dout),
		.ioctl_index(ioctl_index)
	);

	pll pll (
		.refclk(CLK_50M),
		.rst(1'b0),
		.outclk_0(),
		.outclk_1(clk_12),
		.outclk_2(),
		.outclk_3(clk_125),
		.locked(pll_locked)
	);

	//============================================================
	// MRA payload
	//   index 0   : ROM image, $0000-$BFFF program + $C000-$C3FF sin/cos PROM
	//   index 1   : one game-identifier byte
	//   index 254 : DIP switches
	//============================================================
	logic [7:0] dip_switch [0:7];
	initial begin
		dip_switch[0] = 8'hFF;   // SW1
		dip_switch[1] = 8'h33;   // SW2: 1 coin / 1 credit
		dip_switch[2] = 8'hFF;
		dip_switch[3] = 8'hFF;
		dip_switch[4] = 8'hFF;
		dip_switch[5] = 8'hFF;
		dip_switch[6] = 8'hFF;
		dip_switch[7] = 8'hFF;
	end

	always @(posedge clk_12) begin
		if (ioctl_wr && (ioctl_index == 16'd1))
			game_id <= ioctl_dout;
		if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[26:3])
			dip_switch[ioctl_addr[2:0]] <= ioctl_dout;
	end

	wire rom_download     = ioctl_download && (ioctl_index == 16'd0);
	wire variant_download = ioctl_download && (ioctl_index == 16'd1);
	wire machine_reset    = RESET || status[0] || buttons[1] ||
	                        rom_download || variant_download || !pll_locked;

	//============================================================
	// Machine
	//============================================================
	wire [2:0] game = game_id[2:0];
	wire [2:0] cfg_chip;
	wire       cfg_usb;
	wire [1:0] cfg_fc;
	wire [2:0] cfg_orient;

	sega_game_cfg gamecfg (
		.game(game), .cfg_chip(cfg_chip), .cfg_usb(cfg_usb),
		.cfg_fc(cfg_fc), .cfg_orient(cfg_orient)
	);

	wire [7:0] in_d7d6, in_d5d4, in_d3d2, in_d1d0, in_fc, in_coins;
	wire       coin_a, coin_b, service;

	sega_inputs inputs (
		.game(game),
		.joy1(joystick_0), .joy2(joystick_1),
		.dsw1(dip_switch[0]), .dsw2(dip_switch[1]),
		.in_d7d6(in_d7d6), .in_d5d4(in_d5d4),
		.in_d3d2(in_d3d2), .in_d1d0(in_d1d0),
		.in_fc(in_fc), .in_coins(in_coins),
		.coin_a(coin_a), .coin_b(coin_b), .service(service)
	);

	// Spinner from the analog stick; the port returns a monotonically
	// increasing count with direction in bit 0, so only the delta matters.
	logic signed [7:0] spin_delta;
	logic              spin_stb;
	logic       [11:0] spin_div;

	always_ff @(posedge clk_12) begin
		spin_stb <= 1'b0;
		spin_div <= spin_div + 12'd1;
		if (spin_div == 12'd0) begin
			spin_delta <= $signed(analog_0[7:0]) >>> 3;
			spin_stb   <= 1'b1;
		end
	end

	logic pause_cpu;
	logic [23:0] paused_rgb;
	wire  [7:0] raw_video_r, raw_video_g, raw_video_b;

	pause #(8, 8, 8, 12) pause_inst (
		.clk_sys(clk_12),
		.reset(machine_reset),
		.user_button(joystick_0[10] | joystick_1[10]),
		.pause_request(1'b0),
		.options({~status[117], status[116]}),
		.OSD_STATUS(OSD_STATUS),
		.r(raw_video_r), .g(raw_video_g), .b(raw_video_b),
		.pause_cpu(pause_cpu),
		.rgb_out(paused_rgb)
	);

	wire [9:0] vec_x, vec_y;
	wire [5:0] vec_colour;
	wire       vec_beam, vec_valid, vec_frame_done, drawing;

	segag80v machine (
		.clk_12(clk_12),
		.reset(machine_reset),
		.pause(pause_cpu),
		.cfg_chip(cfg_chip), .cfg_usb(cfg_usb), .cfg_fc(cfg_fc),
		.rom_wr(ioctl_wr && rom_download),
		.rom_addr(ioctl_addr[15:0]),
		.rom_data(ioctl_dout),
		.in_d7d6(in_d7d6), .in_d5d4(in_d5d4),
		.in_d3d2(in_d3d2), .in_d1d0(in_d1d0),
		.in_fc(in_fc), .in_coins(in_coins),
		.spin_delta(spin_delta), .spin_stb(spin_stb),
		.coin_a(coin_a), .coin_b(coin_b), .service(service),
		.vec_x(vec_x), .vec_y(vec_y), .vec_colour(vec_colour),
		.vec_beam(vec_beam), .vec_valid(vec_valid),
		.drawing(drawing), .frame_done(vec_frame_done),
		.snd_wr(), .snd_sel(), .ay_wr(),
		.speech_data_wr(), .speech_ctrl_wr(), .usb_data_wr(), .snd_data()
	);

	//============================================================
	// Video
	//============================================================
	logic sdram_data_oe;
	logic [15:0] sdram_data_out;
	logic  [1:0] sdram_dqm;
	logic video_hblank, video_vblank;
	logic fifo_full;

	assign SDRAM_CLK  = ~clk_125;
	assign SDRAM_DQ   = sdram_data_oe ? sdram_data_out : 16'hzzzz;
	assign SDRAM_DQML = sdram_dqm[0];
	assign SDRAM_DQMH = sdram_dqm[1];

	sega_video video (
		.clk_12(clk_12),
		.clk_125(clk_125),
		.reset(machine_reset),
		.hdmi_height(HDMI_HEIGHT),
		.aspect_ratio(status[15:14]),
		.orientation(cfg_orient),

		.vec_x(vec_x), .vec_y(vec_y), .vec_colour(vec_colour),
		.vec_beam(vec_beam), .vec_valid(vec_valid),
		.frame_done(vec_frame_done),

		.osd_flash_param(8'd0),
		.osd_120hz(status[25]),
		.osd_buffer_mode(status[40:39]),
		.osd_dot_mode(status[30:28]),
		.osd_bloom_width(status[43:41]),
		.osd_bloom_curve(status[46:44]),
		.osd_halo_filter(status[49:47]),
		.osd_phosphor_mode(status[53:52]),
		.osd_inter_frame_phosphor_mode(status[55:54]),
		.osd_halo_spread(status[51:50]),
		.osd_color_space(status[56]),
		.osd_presentation_color(status[59:57]),
		.osd_slot_mask(status[60]),
		.osd_slot_mask_rows(status[61]),
		.osd_full_bypass(status[62]),

		.video_arx(VIDEO_ARX), .video_ary(VIDEO_ARY),
		.ce_pixel(CE_PIXEL),
		.hblank(video_hblank), .vblank(video_vblank),
		.video_r(raw_video_r), .video_g(raw_video_g), .video_b(raw_video_b),
		.hsync(VGA_HS), .vsync(VGA_VS),
		.mode_is_720p(video_is_720p),
		.fifo_full(fifo_full),

		.ddram_clk(DDRAM_CLK),
		.ddram_busy(DDRAM_BUSY),
		.ddram_burst_count(DDRAM_BURSTCNT),
		.ddram_address(DDRAM_ADDR),
		.ddram_data_out(DDRAM_DOUT),
		.ddram_data_ready(DDRAM_DOUT_READY),
		.ddram_read(DDRAM_RD),
		.ddram_data_in(DDRAM_DIN),
		.ddram_byte_enable(DDRAM_BE),
		.ddram_write(DDRAM_WE),

		.sdram_data_in(SDRAM_DQ),
		.sdram_data_out(sdram_data_out),
		.sdram_data_oe(sdram_data_oe),
		.sdram_cke(SDRAM_CKE),
		.sdram_ncs(SDRAM_nCS),
		.sdram_nras(SDRAM_nRAS),
		.sdram_ncas(SDRAM_nCAS),
		.sdram_nwe(SDRAM_nWE),
		.sdram_dqm(sdram_dqm),
		.sdram_address(SDRAM_A),
		.sdram_bank(SDRAM_BA)
	);

	assign CLK_VIDEO = clk_125;
	assign VGA_R = paused_rgb[23:16];
	assign VGA_G = paused_rgb[15:8];
	assign VGA_B = paused_rgb[7:0];
	assign VGA_DE = !(video_hblank || video_vblank);
	assign VGA_F1 = 1'b0;
	assign VGA_SL = 2'b00;
	assign VGA_SCALER = 1'b0;
	assign VGA_DISABLE = 1'b0;
	assign HDMI_FREEZE = 1'b0;
	assign HDMI_BLACKOUT = 1'b0;
	assign HDMI_BOB_DEINT = 1'b0;

	// Audio is not implemented yet: the sound, speech and USB boards are the
	// remaining work. The strobes exist on segag80v and are left unconnected.
	assign AUDIO_L = 16'd0;
	assign AUDIO_R = 16'd0;
	assign AUDIO_S = 1'b1;
	assign AUDIO_MIX = 2'b00;

	assign LED_USER  = fifo_full || ioctl_download;
	assign LED_DISK  = 2'b00;
	assign LED_POWER = 2'b00;
	assign BUTTONS   = 2'b00;

	assign ADC_BUS = 4'bzzzz;
	assign USER_OUT = 7'h7f;
	assign {UART_RTS, UART_TXD, UART_DTR} = 3'b000;
	assign {SD_SCK, SD_MOSI, SD_CS} = 3'bzzz;

`ifdef MISTER_FB
	assign FB_EN = 1'b0;
	assign FB_FORMAT = 5'd0;
	assign FB_WIDTH = 12'd0;
	assign FB_HEIGHT = 12'd0;
	assign FB_BASE = 32'd0;
	assign FB_STRIDE = 14'd0;
	assign FB_FORCE_BLANK = 1'b0;
`ifdef MISTER_FB_PALETTE
	assign FB_PAL_CLK = 1'b0;
	assign FB_PAL_ADDR = 8'd0;
	assign FB_PAL_DOUT = 24'd0;
	assign FB_PAL_WR = 1'b0;
`endif
`endif

`ifdef MISTER_DUAL_SDRAM
	assign SDRAM2_CLK = 1'bz;
	assign SDRAM2_A = 13'hzzz;
	assign SDRAM2_BA = 2'bzz;
	assign SDRAM2_DQ = 16'hzzzz;
	assign {SDRAM2_nCS, SDRAM2_nCAS, SDRAM2_nRAS, SDRAM2_nWE} = 4'hf;
`endif

endmodule
