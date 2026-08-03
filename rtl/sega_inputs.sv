//============================================================================
//  Sega G-80 X-Y control panel wiring
//
//  Builds the four source bytes the LS253 matrix reads, plus the FC port, from
//  MiSTer joystick bits. Bit positions come from the INPUT_PORTS blocks in
//  refs/mame/segag80v.cpp. Every switch is active low except where MAME marks
//  a bit IP_ACTIVE_HIGH (the FC port on Eliminator).
//
//  Eliminator is fully mapped and is the bring-up target. The other games use
//  the generic layout plus their spinner; their panel-specific bits still need
//  checking against MAME game by game — see the notes on each branch.
//
//  This program is free software under the GNU General Public License v3.
//============================================================================

`default_nettype none

module sega_inputs (
	input  wire  [2:0] game,        // see sega_game_pkg
	input  wire [31:0] joy1,
	input  wire [31:0] joy2,
	input  wire  [7:0] dsw1,        // SW1, read through D3D2
	input  wire  [7:0] dsw2,        // SW2, read through D1D0

	output logic [7:0] in_d7d6,
	output logic [7:0] in_d5d4,
	output logic [7:0] in_d3d2,
	output logic [7:0] in_d1d0,
	output logic [7:0] in_fc,
	output logic [7:0] in_coins,
	output wire        coin_a,
	output wire        coin_b,
	output wire        service
);

	// MiSTer joystick bit assignment used by the OSD string below:
	//   0 right  1 left  2 down  3 up
	//   4 fire1  5 fire2  6 fire3
	//   7 start1 8 start2 9 coin1 10 pause 11 coin2/service
	wire p1_right = joy1[0], p1_left = joy1[1];
	wire p1_b1    = joy1[4], p1_b2   = joy1[5];
	wire p2_right = joy2[0], p2_left = joy2[1];
	wire p2_b1    = joy2[4], p2_b2   = joy2[5];
	wire start1   = joy1[7] | joy2[7];
	wire start2   = joy1[8] | joy2[8];

	assign coin_a  = ~(joy1[9]  | joy2[9]);    // active low
	assign coin_b  = ~(joy1[11] | joy2[11]);
	assign service = 1'b1;                      // not exposed on the OSD yet

	always_comb begin
		// Generic panel: everything released, DIPs straight through.
		// Bits the CPU merges itself (COIN1/COIN2/DRAW in D7D6, SERVICE in
		// D5D4 bit 0) are left high here.
		in_d7d6  = 8'hFF;
		in_d5d4  = 8'hFF;
		in_d3d2  = dsw1;
		in_d1d0  = dsw2;
		in_fc    = 8'h00;      // FC is active high on the games that use it
		in_coins = 8'hFF;

		in_d5d4[1] = ~start1;
		in_d5d4[5] = ~start2;

		unique case (game)
		sega_game_pkg::GAME_ELIM2, sega_game_pkg::GAME_ELIM4: begin
			// D7D6: bit 6 = P1 LEFT
			in_d7d6[6] = ~p1_left;
			// D5D4: 2 = P1 RIGHT, 3 = P1 BUTTON1, 6 = P1 BUTTON2, 7 = P2 LEFT
			in_d5d4[2] = ~p1_right;
			in_d5d4[3] = ~p1_b1;
			in_d5d4[6] = ~p1_b2;
			in_d5d4[7] = ~p2_left;
			// FC is ACTIVE HIGH here: P2 button1, button2, right
			in_fc      = { 5'b00000, p2_right, p2_b2, p2_b1 };
			// Eliminator 4-player reads the four coin inputs through the
			// demux; only two are wired to the OSD.
			in_coins   = { 4'hF, 2'b11, ~coin_b, ~coin_a };
		end

		sega_game_pkg::GAME_SPACFURY: begin
			// TODO: verify against INPUT_PORTS_START(spacfury). Joystick plus
			// two buttons on the generic bits is a placeholder.
			in_d5d4[2] = ~p1_right;
			in_d5d4[3] = ~p1_b1;
			in_d5d4[6] = ~p1_b2;
			in_d7d6[6] = ~p1_left;
		end

		sega_game_pkg::GAME_ZEKTOR,
		sega_game_pkg::GAME_TACSCAN,
		sega_game_pkg::GAME_STARTREK: begin
			// Spinner games: the spinner arrives through segag80v's spin_delta
			// and is read at $FC, so FC carries only the panel buttons here.
			// TODO: verify each game's button bits against MAME.
			in_d5d4[3] = ~p1_b1;
			in_d5d4[6] = ~p1_b2;
		end

		default: ;
		endcase
	end

endmodule

`default_nettype wire
