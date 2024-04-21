//
// scandoubler_double.v
// 
// Copyright (c) 2015 Till Harbaum <till@harbaum.org> 
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//
// Straightforward linedoubling of input signal, but includes scaling of
// incoming signal to OUT_COLOUR_DEPTH. Refactored into a separate module
// by AMR.

module scandoubler_linedouble
(
	// system interface
	input            clk_sys,

	input            bypass,

	// Pixelclock
	input            pe_in,
	input            pe_out,
	
	// Framing
	input [HCNT_WIDTH-1:0] hcnt,
	input [HCNT_WIDTH-1:0] sd_hcnt,
	input line_toggle,

	// scanlines (00-none 01-25% 10-50% 11-75%)
	input      [1:0] scanlines,

	// shifter video interface
	input            hs_sd,
	input            vs_in,
	input      [COLOR_DEPTH-1:0] r_in,
	input      [COLOR_DEPTH-1:0] g_in,
	input      [COLOR_DEPTH-1:0] b_in,

	// output interface
	output [OUT_COLOR_DEPTH-1:0] r_out,
	output [OUT_COLOR_DEPTH-1:0] g_out,
	output [OUT_COLOR_DEPTH-1:0] b_out
);

parameter HCNT_WIDTH = 10; // Resolution of scandoubler buffer
parameter COLOR_DEPTH = 6; // Bits per colour to be stored in the buffer
parameter HSCNT_WIDTH = 12; // Resolution of hsync counters
parameter OUT_COLOR_DEPTH = 6; // Bits per color outputted

// --------------------- create output signals -----------------
// latch everything once more to make it glitch free and apply scanline effect
reg scanline;
wire [OUT_COLOR_DEPTH-1:0] r;
wire [OUT_COLOR_DEPTH-1:0] g;
wire [OUT_COLOR_DEPTH-1:0] b;

wire [COLOR_DEPTH*3-1:0] sd_mux = bypass ? {r_in, g_in, b_in} : sd_out[COLOR_DEPTH*3-1:0];

scandoubler_scaledepth #(.IN_DEPTH(COLOR_DEPTH),.OUT_DEPTH(OUT_COLOR_DEPTH)) scalein_b (.d(sd_mux[COLOR_DEPTH*3-1:COLOR_DEPTH*2]),.q(r));
scandoubler_scaledepth #(.IN_DEPTH(COLOR_DEPTH),.OUT_DEPTH(OUT_COLOR_DEPTH)) scalein_g (.d(sd_mux[COLOR_DEPTH*2-1:COLOR_DEPTH]),.q(g));
scandoubler_scaledepth #(.IN_DEPTH(COLOR_DEPTH),.OUT_DEPTH(OUT_COLOR_DEPTH)) scalein_r (.d(sd_mux[COLOR_DEPTH-1:0]),.q(b));

reg [OUT_COLOR_DEPTH+6:0] r_mul;
reg [OUT_COLOR_DEPTH+6:0] g_mul;
reg [OUT_COLOR_DEPTH+6:0] b_mul;

wire scanline_bypass = (!scanline) | (!(|scanlines)) | bypass;

// More subtle variant of the scanlines effect.
// 0 00 -> 1000000 0x40	 -  bypass / inert mode
// 1 01 -> 0111010 0x3a  -  25%
// 2 10 -> 0101110 0x2e  -  50%
// 3 11 -> 0011010 0x1a  -  75%

wire [6:0] scanline_coeff = scanline_bypass ?
                            7'b1000000 : {1'b0,~(&scanlines),scanlines[0],1'b1,~scanlines[0],2'b10};

reg vs_o;
reg hs_o;

always @(posedge clk_sys) begin
	if(pe_out) begin
		vs_o <= vs_in;
		hs_o <= hs_sd;

		// reset scanlines at every new screen
		if(vs_o != vs_in) scanline <= 0;

		// toggle scanlines at begin of every hsync
		if(hs_o && !hs_sd) scanline <= !scanline;

		r_mul<=r*scanline_coeff;
		g_mul<=g*scanline_coeff;
		b_mul<=b*scanline_coeff;
	end
end

wire [OUT_COLOR_DEPTH-1:0] r_o = r_mul[OUT_COLOR_DEPTH+5 -:OUT_COLOR_DEPTH];
wire [OUT_COLOR_DEPTH-1:0] g_o = g_mul[OUT_COLOR_DEPTH+5 -:OUT_COLOR_DEPTH];
wire [OUT_COLOR_DEPTH-1:0] b_o = b_mul[OUT_COLOR_DEPTH+5 -:OUT_COLOR_DEPTH];

// Output multiplexing
assign r_out = bypass ? r : r_o;
assign g_out = bypass ? g : g_o;
assign b_out = bypass ? b : b_o;


// scan doubler output register
reg [COLOR_DEPTH*3-1:0] sd_out;

// Scandoubler read and write processes

// 2 lines of 2**HCNT_WIDTH pixels 3*COLOR_DEPTH bit RGB
(* ramstyle = "no_rw_check" *) reg [COLOR_DEPTH*3-1:0] sd_buffer[2*2**HCNT_WIDTH];

always @(posedge clk_sys) begin
	// Pixel logic on x1 clkena
	if(pe_in)
		sd_buffer[{line_toggle, hcnt}] <= {r_in, g_in, b_in};
end

always @(posedge clk_sys) begin
	if(pe_out)
		sd_out <= sd_buffer[{~line_toggle, sd_hcnt}];
end

endmodule

