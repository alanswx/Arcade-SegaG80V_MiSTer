// ============================================================================
// present_gate.sv -- Tempest vector present-gate (phosphor-persistence emulation).
//
// THE PROBLEM (and why the obvious fix is wrong)
//   The Tempest AVG redraws its whole display list ~200-250x/sec (the CPU kicks
//   vggo/$4800 once per ~250 Hz IRQ -> one complete list every ~4 ms).  On a real
//   tube the PHOSPHOR INTEGRATES those ~200 redraws/frame: any single redraw that
//   is missing a beam is refilled by the next one, and moving objects leave a soft
//   trail.  That integration is WHY a real Tempest never flickers.
//   A DDR framebuffer has no phosphor.  If you present exactly ONE redraw per
//   displayed frame (the "clean" approach), every contention-dropped beam shows for
//   a whole frame with nothing to refill it (-> intermittent dropped beams), and a
//   list cut mid-draw drops its tail (-> projectiles flash when firing).
//
// THE FIX -- accumulate N COMPLETE lists per displayed buffer (emulate persistence)
//   The framebuffer only CLEARS the draw buffer on EOF.  So if we hold the beam ON
//   across N complete lists and emit EOF only after the Nth, those N redraws pile
//   into one buffer with NO clear between them = a union of N redraws == a crude
//   phosphor.  A beam dropped in redraw #2 is still present from #1/#3 (-> no
//   dropped-beam flicker).  Each list is bounded vggo->vggo so the Nth is COMPLETE
//   (-> projectile tail never cut, no firing flash).  N is the persistence amount,
//   exposed as a live OSD knob.  (This is what the good "_n" build did by accident
//   with a ~12 ms time window -- ~3 redraws -- except it cut the list on a timer,
//   which is what made it flash when firing grew the list.  Here the cut is always
//   on a list boundary.)
//
// DISPLAY IS DECOUPLED (so the beam-off clear window is invisible)
//   The framebuffer swaps ready->display on its OWN scan-out vblank and shows the
//   last completed buffer steadily between EOFs.  So while this gate is blanked for
//   the clear, or mid-accumulation, the screen keeps showing the previous N-redraw
//   union -- no dark flash.  The displayed image updates once per EOF (~30 Hz),
//   each update a full N-redraw accumulation held rock-steady until the next.
//
// WHY vggo (not avg_halted)
//   vggo is the CPU's deliberate once-per-list $4800 strobe.  avg_halted has a
//   ~sub-ms idle and prior HW builds that gated on its edge caught partial frames.
//   We count vggo only.
//
// HW-SAFE DEGRADE
//   If vggo never arrives (timing/CDC pathology), ARMED_TIMEOUT/CAP_TIMEOUT fire and
//   the gate becomes a plain time-window accumulator -- never black, never worse
//   than "_n".  Free-running (no vblank lock): the displayed content is identical
//   frame-to-frame (a stable union), so there is no beat against scan-out to see.
//
//   All I/O is in the clk_12 (vector-generator) domain -- no new CDC.
// ============================================================================

module present_gate #(
	// One blank window per EOF covers the DDR buffer-clear (row-range clear ~7.5 ms;
	// ~10 ms is safe).  Beam is off during it, but the screen still shows the prior
	// completed buffer (display is decoupled), so it is not a visible blank.
	parameter [19:0] BLANK_CYC     = 20'd120000,  // ~10 ms @12 MHz: beam-off for the clear
	// Degrade timeouts must EXCEED the real cadence so they ONLY fire when vggo is dead.
	parameter [19:0] ARMED_TIMEOUT = 20'd144000,  // ~12 ms: no list start -> open anyway
	parameter [21:0] CAP_TIMEOUT   = 22'd720000   // ~60 ms: no list progress -> EOF anyway
)(
	input        clk,          // clk_12 (vector-generator clock)
	input        reset,
	input        vggo_rise,    // avg_go rising edge, 1 per list start (clk domain)
	input  [1:0] persist,      // persistence: lists accumulated per displayed buffer
	                           //   0 -> 3 (default, ~"_n"),  1 -> 4,  2 -> 6,  3 -> 2

	output       beam_window,  // 1 while accumulating (gate rast_beam with this)
	output reg   eof,          // 1-cycle pulse after the Nth list -> FB FRAME_DONE (swap+clear)
	output reg   frame_start   // 1-cycle pulse at accumulation open -> FB START_FRAME
);

	// persistence -> N complete lists per displayed buffer.  Default (persist=0,
	// the power-on/OSD default) = 3, reproducing the known-good "_n" accumulation.
	reg [3:0] nlists;
	always @* begin
		case (persist)
			2'd0:    nlists = 4'd3;   // default
			2'd1:    nlists = 4'd4;
			2'd2:    nlists = 4'd6;
			default: nlists = 4'd2;
		endcase
	end

	localparam [1:0] S_BLANK = 2'd0,   // beam off: the FB clears the new draw buffer
	                 S_ARM   = 2'd1,   // beam off: align to a true list start (vggo)
	                 S_CAP   = 2'd2;   // beam ON : accumulate N complete lists

	reg [1:0]  st  = S_BLANK;
	reg [21:0] tmr = 22'd0;            // dual-use: blank timer / degrade timeout
	reg [3:0]  lcount = 4'd0;          // complete lists accumulated since open

	always @(posedge clk) begin
		eof         <= 1'b0;
		frame_start <= 1'b0;

		if (reset) begin
			st     <= S_BLANK;
			tmr    <= 22'd0;
			lcount <= 4'd0;
		end else begin
			case (st)
				// ----- beam off while the framebuffer clears the recycled buffer -----
				S_BLANK: begin
					tmr <= tmr + 22'd1;
					if (tmr >= BLANK_CYC) begin st <= S_ARM; tmr <= 22'd0; end
				end

				// ----- beam off; open accumulation on the next list start (vggo) -----
				S_ARM: begin
					tmr <= tmr + 22'd1;
					if (vggo_rise || (tmr >= ARMED_TIMEOUT)) begin
						st          <= S_CAP;
						tmr         <= 22'd0;
						lcount      <= 4'd0;
						frame_start <= 1'b1;
					end
				end

				// ----- beam ON; each later vggo = one more COMPLETE list accumulated -----
				S_CAP: begin
					tmr <= tmr + 22'd1;
					if (vggo_rise) begin
						// this vggo closes the list that was being drawn
						if (lcount + 4'd1 >= nlists) begin
							st  <= S_BLANK;       // N complete lists in the buffer -> present
							tmr <= 22'd0;
							eof <= 1'b1;
						end else begin
							lcount <= lcount + 4'd1;
						end
					end else if (tmr >= CAP_TIMEOUT) begin
						st  <= S_BLANK;           // vggo dead -> degrade: present what we have
						tmr <= 22'd0;
						eof <= 1'b1;
					end
				end

				default: st <= S_BLANK;
			endcase
		end
	end

	assign beam_window = (st == S_CAP);

endmodule
