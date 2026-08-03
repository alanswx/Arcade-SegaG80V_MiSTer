derive_pll_clocks
derive_clock_uncertainty

# Counter indices match Arcade-Asteroids_MiSTer: same PLL IP, same outclk
# wiring (outclk_1 -> clk_12, outclk_3 -> clk_125), so the synthesised
# counter names are the same.
#
# The control, machine and renderer domains are asynchronous at their
# boundaries; explicit synchronizers and asynchronous FIFOs implement the CDC.
set emu_clk_50  [get_clocks {FPGA_CLK2_50}]
set emu_clk_12  [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set emu_clk_125 [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]

set_clock_groups -asynchronous \
	-group $emu_clk_50 \
	-group $emu_clk_12 \
	-group $emu_clk_125
