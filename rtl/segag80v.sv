//============================================================================
//  Sega G-80 X-Y machine: CPU board + EPROM board + X-Y boards
//
//  The equivalent of asteroids_core.sv in the core this one is grafted onto:
//  everything behind the beam, with no video timing or renderer. Video lives in
//  sega_video.sv.
//
//  Clocking
//    One 12 MHz domain (the clock vfb_top expects for its vector input and
//    phosphor timing). The two real clocks are fractional enables off the
//    15.46848 MHz master:
//        Z80   15468480 / 4 = 3.86712 MHz
//        VCL   15468480 / 6 = 2.57808 MHz   (vector generator steps)
//
//  Frame pacing
//    No present gate. Tempest needs one because it redraws its list ~250x/sec
//    and the framebuffer would cut lists mid-draw. Sega walks the whole display
//    list exactly once per 40 Hz EDGINT with DRAW asserted throughout — the
//    same shape as Star Wars and Asteroids, which feed FRAME_DONE straight in.
//
//  This program is free software under the GNU General Public License v3.
//============================================================================

`default_nettype none

module segag80v #(
	parameter int PHASE_CLKS  = 16,
	parameter int WAIT_STATES = 2,
	// clk_vec is 12.096 MHz on the MiSTer PLL, not a round 12
	parameter int CLK_HZ      = 12_096_000
) (
	input  wire        clk_vec,
	input  wire        reset,
	input  wire        pause,

	// ---- MRA configuration ----
	input  wire  [2:0] cfg_chip,     // security chip, see sega_security_pkg
	input  wire        cfg_usb,      // Universal Sound Board RAM at $D000
	input  wire  [1:0] cfg_fc,       // 0 = plain, 1 = spinner, 2 = elim4

	// ---- ROM download ($0000-$BFFF program, $C000-$C3FF sin/cos PROM) ----
	input  wire        rom_wr,
	input  wire [15:0] rom_addr,
	input  wire  [7:0] rom_data,

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

	// ---- beam output ----
	output wire  [9:0] vec_x,
	output wire  [9:0] vec_y,
	output wire  [5:0] vec_colour,
	output wire        vec_beam,
	output wire        vec_valid,
	output wire        drawing,
	output wire        frame_done,
	output wire        vec_tick,    // VCL step enable, paces the renderer

	// ---- sound board strobes (audio not implemented yet) ----
	output wire        snd_wr,
	output wire  [1:0] snd_sel,
	output wire        ay_wr,
	output wire        ay_port,
	output wire        speech_data_wr,
	output wire        speech_ctrl_wr,
	output wire        usb_data_wr,
	output wire  [7:0] snd_data,

	// ---- audio ----
	output wire [10:0] audio_ay      // Zektor AY-3-8912
);

	// ------------------------------------------------------------------
	// Fractional clock enables off the 15.46848 MHz master
	// ------------------------------------------------------------------
	localparam int CE_CPU_INC = 3_867_120;   // 15468480 / 4
	localparam int CE_VCL_INC = 2_578_080;   // 15468480 / 6

	logic [24:0] acc_cpu, acc_vcl;
	logic        ce_cpu, ce_vcl;

	always_ff @(posedge clk_vec) begin
		if (reset) begin
			acc_cpu <= '0; ce_cpu <= 1'b0;
			acc_vcl <= '0; ce_vcl <= 1'b0;
		end else begin
			if (acc_cpu + CE_CPU_INC >= CLK_HZ) begin
				acc_cpu <= acc_cpu + CE_CPU_INC - CLK_HZ; ce_cpu <= ~pause;
			end else begin
				acc_cpu <= acc_cpu + CE_CPU_INC;          ce_cpu <= 1'b0;
			end
			if (acc_vcl + CE_VCL_INC >= CLK_HZ) begin
				acc_vcl <= acc_vcl + CE_VCL_INC - CLK_HZ; ce_vcl <= 1'b1;
			end else begin
				acc_vcl <= acc_vcl + CE_VCL_INC;          ce_vcl <= 1'b0;
			end
		end
	end

	// ------------------------------------------------------------------
	// EDGINT: 15468480 / 3 / 0x1F788 = exactly 40.0 Hz. Counted in VCL ticks,
	// and VCL is master/6, so the divider is 0x1F788 / 2.
	//
	// It must be high *during* a ce tick: sega_xy only samples frame_start
	// then, and a registered pulse lands in the gap and is never seen.
	// ------------------------------------------------------------------
	localparam int EDGINT_DIV = 32'h1F788 / 2;   // 64452 VCL ticks per frame

	logic [16:0] edgint_cnt;
	wire         edgint = ce_vcl && (edgint_cnt == 17'(EDGINT_DIV - 1));

	always_ff @(posedge clk_vec) begin
		if (reset)       edgint_cnt <= 17'd0;
		else if (ce_vcl) edgint_cnt <= edgint ? 17'd0 : (edgint_cnt + 17'd1);
	end

	// ------------------------------------------------------------------
	// Program ROM, $0000-$BFFF (48K) in block RAM
	// ------------------------------------------------------------------
	localparam [15:0] PROM_BASE = 16'hC000;  // sin/cos PROM offset in the image

	wire [15:0] cpu_rom_addr;
	logic [7:0] cpu_rom_data;

	(* ramstyle = "M10K" *) logic [7:0] prog_rom [0:49151];

	wire rom_wr_prog = rom_wr && (rom_addr < PROM_BASE);
	wire rom_wr_sin  = rom_wr && (rom_addr >= PROM_BASE)
	                          && (rom_addr < PROM_BASE + 16'd1024);

	always_ff @(posedge clk_vec) begin
		if (rom_wr_prog) prog_rom[rom_addr] <= rom_data;
		cpu_rom_data <= prog_rom[cpu_rom_addr];
	end

	// ------------------------------------------------------------------
	// CPU board
	// ------------------------------------------------------------------
	wire [11:0] vram_addr, usb_addr;
	wire  [7:0] vram_din,  usb_din;
	wire        vram_wr,   usb_wr;
	wire  [7:0] vram_dout;

	segag80v_cpu #(.WAIT_STATES(WAIT_STATES)) cpu (
		.clk        (clk_vec),
		.ce_cpu     (ce_cpu),
		.reset      (reset),
		.cfg_chip   (cfg_chip),
		.cfg_usb    (cfg_usb),
		.cfg_fc     (cfg_fc),
		.rom_addr   (cpu_rom_addr),
		.rom_data   (cpu_rom_data),
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
		.ay_port    (ay_port),
		.speech_data_wr (speech_data_wr),
		.speech_ctrl_wr (speech_ctrl_wr),
		.usb_data_wr    (usb_data_wr),
		.usb_status     (8'hFF),
		.io_dout    (),
		.coin_counter (),
		.dbg_op_addr  ()
	);

	// videodr0me_fb measures the EOF period in source ticks, so it self-
	// calibrates to the 40 Hz redraw rate from this.
	assign vec_tick = ce_vcl;

	// the sound latches all sit on the CPU data bus
	assign snd_data = usb_din;

	// ------------------------------------------------------------------
	// Zektor AY-3-8912 at $3C/$3D. The other games have no PSG; jt49 is small
	// enough that it is left instantiated and simply never written.
	// ------------------------------------------------------------------
	sega_ay #(.CLK_HZ(CLK_HZ)) ay (
		.clk      (clk_vec),
		.reset    (reset),
		.wr       (ay_wr_stb),
		.addr_sel (ay_port_sel),
		.din      (snd_data),
		.audio    (audio_ay)
	);

	// ay_wr is a level held for the whole I/O cycle, so strobe once at its end
	// (the same treatment the CPU multiplier needs).
	logic ay_wr_d;
	logic ay_port_sel;
	always_ff @(posedge clk_vec) begin
		if (reset) begin
			ay_wr_d     <= 1'b0;
			ay_port_sel <= 1'b0;
		end else begin
			ay_wr_d <= ay_wr;
			if (ay_wr) ay_port_sel <= ay_port;
		end
	end
	wire ay_wr_stb = ~ay_wr && ay_wr_d;

	// ------------------------------------------------------------------
	// X-Y boards
	// ------------------------------------------------------------------
	sega_xy_top #(
		.PHASE_CLKS (PHASE_CLKS)
	) xy (
		.clk         (clk_vec),
		.ce          (ce_vcl),
		.reset       (reset),
		.frame_start (edgint),
		.cpu_addr    (vram_addr),
		.cpu_din     (vram_din),
		.cpu_wr      (vram_wr),
		.cpu_dout    (vram_dout),
		.rom_wr      (rom_wr_sin),
		.rom_addr    (rom_addr[9:0]),
		.rom_data    (rom_data),
		.out_x       (vec_x),
		.out_y       (vec_y),
		.out_colour  (vec_colour),
		.out_beam    (vec_beam),
		.out_valid   (vec_valid),
		.drawing     (drawing),
		.frame_done  (frame_done)
	);

endmodule

`default_nettype wire
