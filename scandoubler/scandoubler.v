//
// scandoubler.v
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

// AMR - generates and output a pixel clock with a reliable phase relationship with
// with the scandoubled hsync pulse.  Allows the incoming data to be sampled more
// sparsely, reducing block RAM usage.  ce_x1/x2 are replaced with a ce_divider
// which is the largest value the counter will reach before resetting - so 3'111 to
// divide clk_sys by 8, 3'011 to divide by 4, 3'101 to divide by six.

// Also now has a bypass mode, in which the incoming data will be scaled to the output
// width but otherwise unmodified.  Simplifies the rest of the video chain.


module scandoubler
(
	// system interface
	input            clk_sys,

	input            bypass,
	input            rotateonly,

	// Pixelclock
	input      [3:0] ce_divider, // 0 - clk_sys/4, 1 - clk_sys/2, 2 - clk_sys/3, 3 - clk_sys/4, etc.
	output           pixel_ena_x1,
	output           pixel_ena_x2,
	output           pixel_ena,

	// scanlines (00-none 01-25% 10-50% 11-75%)
	input      [1:0] scanlines,

	input      [1:0] rotation, // 0 - no rotation, 1 - anticlockwise, 2 - clockwise
	input            hfilter,
	input            vfilter,

	// shifter video interface
	input            hb_in,
	input            vb_in,
	input            hs_in,
	input            vs_in,
	input      [COLOR_DEPTH-1:0] r_in,
	input      [COLOR_DEPTH-1:0] g_in,
	input      [COLOR_DEPTH-1:0] b_in,

	// output interface
	output       hb_out,
	output       vb_out,
	output       hs_out,
	output       vs_out,
	output [OUT_COLOR_DEPTH-1:0] r_out,
	output [OUT_COLOR_DEPTH-1:0] g_out,
	output [OUT_COLOR_DEPTH-1:0] b_out,
	
	// Memory interface - to RAM (for rotation).  Operates on 16-word bursts
	output wire         vidin_req,    // High at start of row, remains high until burst of 16 pixels has been delivered
	output wire [1:0]   vidin_frame,  // Odd or even frame for double-buffering
	output wire [10:0]  vidin_row,    // Y position of current row.
	output wire [10:0]  vidin_col,    // X position of current burst.
	output wire [15:0]  vidin_d,      // Incoming video data
	input wire          vidin_ack,    // Request next word from host
	
	// Memory interface - from RAM (for rotation).  Operates on 8-word bursts
	output wire         vidout_req,   // High at start of row, remains high until entire row has been delivered
	output wire [1:0]   vidout_frame, // Odd or even frame for double-buffering
	output wire [10:0]  vidout_row,   // Y position of current row.  (Controller maintains X counter)
	output wire [10:0]  vidout_col,   // Y position of current row.  (Controller maintains X counter)
	input wire [15:0]   vidout_d,     // Outgoing video data
	input wire          vidout_ack    // Valid data available.
);

parameter HCNT_WIDTH = 10; // Resolution of scandoubler buffer
parameter COLOR_DEPTH = 6; // Bits per colour to be stored in the buffer
parameter HSCNT_WIDTH = 12; // Resolution of hsync counters
parameter OUT_COLOR_DEPTH = 6; // Bits per color outputted

// --------------------- create output signals -----------------

wire [OUT_COLOR_DEPTH-1:0] r;
wire [OUT_COLOR_DEPTH-1:0] g;
wire [OUT_COLOR_DEPTH-1:0] b;

wire [OUT_COLOR_DEPTH-1:0] r_ld;
wire [OUT_COLOR_DEPTH-1:0] g_ld;
wire [OUT_COLOR_DEPTH-1:0] b_ld;

wire [OUT_COLOR_DEPTH-1:0] r_rot;
wire [OUT_COLOR_DEPTH-1:0] g_rot;
wire [OUT_COLOR_DEPTH-1:0] b_rot;

reg hs_o, vs_o;
reg hb_o, vb_o;

always @(posedge clk_sys) begin
	if(pe_out) begin
		hs_o <= hs_sd;
		vs_o <= vs_sd;
		hb_o <= hb_sd;
		vb_o <= vb_sd;
	end
end

// Output multiplexing
wire   blank_out = hb_out | vb_out;
assign r_out = blank_out ? {OUT_COLOR_DEPTH{1'b0}} : r;
assign g_out = blank_out ? {OUT_COLOR_DEPTH{1'b0}} : g;
assign b_out = blank_out ? {OUT_COLOR_DEPTH{1'b0}} : b;
assign hb_out = (bypass | rotateonly) ? hb_in : hb_o;
assign vb_out = (bypass | rotateonly) ? vb_in : vb_o;
assign hs_out = (bypass | rotateonly) ? hs_in : hs_o;
assign vs_out = (bypass | rotateonly) ? vs_in : vs_o;


wire pe_in; // Pixel enable for input signal
wire pe_out; // Pixel enable for output signal

wire [HCNT_WIDTH-1:0] hcnt;
wire [HCNT_WIDTH-1:0] sd_hcnt;
wire vb_sd;
wire hb_sd;
wire hs_sd;
wire vs_sd;


// Linedoubler

scandoubler_linedouble#(
	.HCNT_WIDTH(HCNT_WIDTH),
	.COLOR_DEPTH(COLOR_DEPTH),
	.HSCNT_WIDTH(HSCNT_WIDTH),
	.OUT_COLOR_DEPTH(OUT_COLOR_DEPTH)
) linedoubler (
	.clk_sys(clk_sys),
	.bypass(bypass),
	.scanlines(scanlines),
	.pe_in(pe_in),
	.pe_out(pe_out),
	.hcnt(hcnt),
	.sd_hcnt(sd_hcnt),
	.line_toggle(line_toggle),
	.hs_sd(hs_sd),
	.vs_in(vs_in),
	.r_in(r_in),
	.g_in(g_in),
	.b_in(b_in),
	
	.r_out(r_ld),
	.g_out(g_ld),
	.b_out(b_ld)
);

// Rotation

scandoubler_rotate #(
	.HCNT_WIDTH(HCNT_WIDTH),
	.COLOR_DEPTH(COLOR_DEPTH),
	.OUT_COLOR_DEPTH(OUT_COLOR_DEPTH)
) rotate (
	.clk_sys(clk_sys),
	.rotation(rotation),
	.rotateonly(rotateonly),
	.hfilter(hfilter),
	.vfilter(vfilter),
	
	.pe_in(pe_in),
	.ppe_out(ppe_out),

	.hs_in(hs_in),
	.vs_in(vs_in),
	.hb_in(hb_in),
	.vb_in(vb_in),
	.r_in(r_in),
	.g_in(g_in),
	.b_in(b_in),

	.hb_sd(rotateonly ? hb_in : hb_sd),
	.vb_sd(rotateonly ? vb_in : vb_sd),
	.vs_sd(rotateonly ? vs_in : vs_sd),
	.r_out(r_rot),
	.g_out(g_rot),
	.b_out(b_rot),

	.vidin_req(vidin_req),
	.vidin_d(vidin_d),
	.vidin_ack(vidin_ack),
	.vidin_frame(vidin_frame),
	.vidin_row(vidin_row),
	.vidin_col(vidin_col),

	.vidout_req(vidout_req),
	.vidout_d(vidout_d),
	.vidout_ack(vidout_ack),
	.vidout_frame(vidout_frame),
	.vidout_row(vidout_row),
	.vidout_col(vidout_col)
);

assign r = (rotation==2'b00 || (bypass & !rotateonly)) ? r_ld : r_rot;
assign g = (rotation==2'b00 || (bypass & !rotateonly)) ? g_ld : g_rot;
assign b = (rotation==2'b00 || (bypass & !rotateonly)) ? b_ld : b_rot;

assign pixel_ena_x2=ppe_out;
assign pixel_ena_x1=pe_in;
assign pixel_ena = bypass ? pe_in : ppe_out;

wire ppe_out;
wire line_toggle;

// Factor out the scandoubler framing
scandoubler_framing #(
	.HCNT_WIDTH(HCNT_WIDTH),
	.HSCNT_WIDTH(HSCNT_WIDTH)
) framing (
	.clk_sys(clk_sys),
	.ce_divider(ce_divider),

	.hb_in(hb_in),
	.vb_in(vb_in),
	.hs_in(hs_in),
	.vs_in(vs_in),
	.pe_in(pe_in),

	.hcnt_in(hcnt),

	// output interface
	.hb_out(hb_sd),
	.vb_out(vb_sd),
	.hs_out(hs_sd),
	.vs_out(vs_sd),
	.pe_out(pe_out),
	
	.ppe_out(ppe_out),

	.hcnt_out(sd_hcnt),
	.line_out(line_toggle)	
);

endmodule

