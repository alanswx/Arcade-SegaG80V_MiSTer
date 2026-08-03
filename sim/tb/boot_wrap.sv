// Boot harness: the CPU board plus the X-Y boards, without the renderer.
//
// Lets a real game ROM run in Verilator so the whole game side can be checked
// end to end — ROM fetch, wait states, the security chip, the interrupt chain,
// the display list the game builds, and the beam path the X-Y boards walk from
// it — without needing DDRAM and SDRAM models.

`default_nettype none

module boot_wrap #(
	parameter int PHASE_CLKS  = 16,
	parameter int WAIT_STATES = 2
) (
	input  wire        clk,
	input  wire        reset,

	input  wire  [2:0] cfg_chip,
	input  wire        cfg_usb,
	input  wire  [1:0] cfg_fc,

	// program ROM, driven by the testbench
	output wire [15:0] rom_addr,
	input  wire  [7:0] rom_data,

	// sin/cos PROM load
	input  wire        prom_wr,
	input  wire  [9:0] prom_addr,
	input  wire  [7:0] prom_data,

	input  wire  [7:0] in_d7d6,
	input  wire  [7:0] in_d5d4,
	input  wire  [7:0] in_d3d2,
	input  wire  [7:0] in_d1d0,
	input  wire  [7:0] in_fc,
	input  wire  [7:0] in_coins,
	input  wire        coin_a,
	input  wire        coin_b,
	input  wire        service,

	// observation
	output wire        ce_cpu_o,
	output wire        ce_vcl_o,
	output wire        edgint_o,
	output wire        drawing_o,
	output wire [11:0] vram_addr_o,
	output wire  [7:0] vram_din_o,
	output wire        vram_wr_o,
	output wire  [9:0] vec_x_o,
	output wire  [9:0] vec_y_o,
	output wire  [5:0] vec_colour_o,
	output wire        vec_beam_o,
	output wire        vec_valid_o,
	output wire        frame_done_o,
	output wire [15:0] dbg_op_addr
);

	// Same fractional enables as segag80v.sv
	localparam int CE_MOD     = 12_000_000;
	localparam int CE_CPU_INC =  3_867_120;
	localparam int CE_VCL_INC =  2_578_080;

	logic [23:0] acc_cpu, acc_vcl;
	logic        ce_cpu, ce_vcl;

	always_ff @(posedge clk) begin
		if (reset) begin
			acc_cpu <= 24'd0; ce_cpu <= 1'b0;
			acc_vcl <= 24'd0; ce_vcl <= 1'b0;
		end else begin
			if (acc_cpu + CE_CPU_INC >= CE_MOD) begin
				acc_cpu <= acc_cpu + CE_CPU_INC - CE_MOD; ce_cpu <= 1'b1;
			end else begin
				acc_cpu <= acc_cpu + CE_CPU_INC;          ce_cpu <= 1'b0;
			end
			if (acc_vcl + CE_VCL_INC >= CE_MOD) begin
				acc_vcl <= acc_vcl + CE_VCL_INC - CE_MOD; ce_vcl <= 1'b1;
			end else begin
				acc_vcl <= acc_vcl + CE_VCL_INC;          ce_vcl <= 1'b0;
			end
		end
	end

	localparam int EDGINT_DIV = 32'h1F788 / 2;
	// EDGINT must be high *during* a ce tick — sega_xy only samples
	// frame_start then. See rtl/segag80v.sv.
	logic [16:0] edgint_cnt;
	wire         edgint = ce_vcl && (edgint_cnt == 17'(EDGINT_DIV - 1));

	always_ff @(posedge clk) begin
		if (reset)       edgint_cnt <= 17'd0;
		else if (ce_vcl) edgint_cnt <= edgint ? 17'd0 : (edgint_cnt + 17'd1);
	end

	wire [11:0] vram_addr;
	wire  [7:0] vram_din;
	wire        vram_wr;
	wire  [7:0] vram_dout;
	wire        drawing;

	segag80v_cpu #(.WAIT_STATES(WAIT_STATES)) cpu (
		.clk(clk), .ce_cpu(ce_cpu), .reset(reset),
		.cfg_chip(cfg_chip), .cfg_usb(cfg_usb), .cfg_fc(cfg_fc),
		.rom_addr(rom_addr), .rom_data(rom_data),
		.vram_addr(vram_addr), .vram_din(vram_din), .vram_wr(vram_wr),
		.vram_dout(vram_dout),
		.usb_addr(), .usb_din(), .usb_wr(), .usb_dout(8'hFF),
		.in_d7d6(in_d7d6), .in_d5d4(in_d5d4),
		.in_d3d2(in_d3d2), .in_d1d0(in_d1d0),
		.in_fc(in_fc), .in_coins(in_coins),
		.spin_delta(8'sd0), .spin_stb(1'b0),
		.draw_flag(drawing), .edgint(edgint),
		.coin_a(coin_a), .coin_b(coin_b), .service(service),
		.snd_wr(), .snd_sel(), .ay_wr(),
		.speech_data_wr(), .speech_ctrl_wr(), .usb_data_wr(),
		.usb_status(8'hFF), .io_dout(), .coin_counter(),
		.dbg_op_addr(dbg_op_addr)
	);

	sega_xy_top #(.PHASE_CLKS(PHASE_CLKS)) xy (
		.clk(clk), .ce(ce_vcl), .reset(reset),
		.frame_start(edgint),
		.cpu_addr(vram_addr), .cpu_din(vram_din), .cpu_wr(vram_wr),
		.cpu_dout(vram_dout),
		.rom_wr(prom_wr), .rom_addr(prom_addr), .rom_data(prom_data),
		.out_x(vec_x_o), .out_y(vec_y_o), .out_colour(vec_colour_o),
		.out_beam(vec_beam_o), .out_valid(vec_valid_o),
		.drawing(drawing), .frame_done(frame_done_o)
	);

	assign ce_cpu_o    = ce_cpu;
	assign ce_vcl_o    = ce_vcl;
	assign edgint_o    = edgint;
	assign drawing_o   = drawing;
	assign vram_addr_o = vram_addr;
	assign vram_din_o  = vram_din;
	assign vram_wr_o   = vram_wr;

endmodule

`default_nettype wire
