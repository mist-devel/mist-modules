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

`include "screenmodes.vh"

module scandoubler
(
	// system interface
	input            clk_sys,
	input            clk_75,

	input            bypass,

	// Pixelclock
	input      [3:0] ce_divider, // 0 - clk_sys/4, 1 - clk_sys/2, 2 - clk_sys/3, 3 - clk_sys/4, etc.
	output           pixel_ena_x1,
	output           pixel_ena_x2,

	// scanlines (00-none 01-25% 10-50% 11-75%)
	input      [1:0] scanlines,

	input      [1:0] rotation, // 0 - no rotation, 1 - anticlockwise, 2 - clockwise
	input            hfilter,
	input            vfilter,
	
	input      [2:0] screenmode, // Select from a number of preset screenmodes.  0: default (synchronous) mode

	// shifter video interface
	input            hb_in,
	input            vb_in,
	input            hs_in,
	input            vs_in,
	input      [COLOR_DEPTH-1:0] r_in,
	input      [COLOR_DEPTH-1:0] g_in,
	input      [COLOR_DEPTH-1:0] b_in,

	// output interface
	output       clk_out,   // Used for everything beyond the scandoubler; may or may not be the same as clk_sys
	output       hb_out,
	output       vb_out,
	output       hs_out,
	output       vs_out,
	output [OUT_COLOR_DEPTH-1:0] r_out,
	output [OUT_COLOR_DEPTH-1:0] g_out,
	output [OUT_COLOR_DEPTH-1:0] b_out,
	
	// Memory interface - to RAM (for rotation).  Operates on 8-word bursts which may or may not be contiguous
	output wire         vidin_req,    // High at start of burst, remains high until burst of 8 pixels has been delivered
	output wire [1:0]   vidin_frame,  // Frame number for double- or triple-buffering
	output wire [HCNT_WIDTH-1:0]  vidin_x,      // X position of current row.
	output wire [HCNT_WIDTH-1:0]  vidin_y,      // Y position of current burst.
	output wire [15:0]  vidin_d,      // Video data to RAM
	input wire          vidin_ack,    // Request next word from host
	
	// Memory interface - from RAM (for rotation).  Operates on 8-word contiguous bursts
	output wire         vidout_req,   // High at start of row, remains high until entire row has been delivered
	output wire [1:0]   vidout_frame, // Frame number for double- or triple-buffering
	output wire [HCNT_WIDTH-1:0]  vidout_x,     // Y position of current row.
	output wire [HCNT_WIDTH-1:0]  vidout_y,     // Y position of current row.
	input wire [15:0]   vidout_d,     // Video data from RAM
	input wire          vidout_ack    // Valid data available.
);

parameter HCNT_WIDTH = 10; // Resolution of scandoubler buffer
parameter COLOR_DEPTH = 6; // Bits per colour to be stored in the buffer
parameter HSCNT_WIDTH = 12; // Resolution of hsync counters
parameter OUT_COLOR_DEPTH = 6; // Bits per color outputted
parameter USE_SCALER = 1'b0;

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

// Output multiplexing
wire   blank_out = hb_out | vb_out;
assign r_out = blank_out ? {OUT_COLOR_DEPTH{1'b0}} : r;
assign g_out = blank_out ? {OUT_COLOR_DEPTH{1'b0}} : g;
assign b_out = blank_out ? {OUT_COLOR_DEPTH{1'b0}} : b;


wire pe_in; // Pixel enable for input signal
wire pe_out; // Pixel enable for output signal
wire ppe_out; // Pixel enable for postprocessing

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
	.HSCNT_WIDTH(HSCNT_WIDTH),
	.OUT_COLOR_DEPTH(OUT_COLOR_DEPTH)
) rotate (
	.clk_sys(clk_sys),
	.bypass(bypass),
	.rotation(rotation),
	.hfilter(hfilter),
	.vfilter(vfilter),
	
	.pe_in(pe_in),

	.hs_in(hs_in),
	.vs_in(vs_in),
	.hb_in(hb_in),
	.vb_in(vb_in),
	.r_in(r_in),
	.g_in(g_in),
	.b_in(b_in),

	.clk_dst(clk_out),

	.pe_out(pe_out),
	.ppe_out(ppe_out),

	.hb_sd(hb_o),
	.vb_sd(vb_o),
	.vs_sd(vs_inverted),
	.r_out(r_rot),
	.g_out(g_rot),
	.b_out(b_rot),

	.vidin_req(vidin_req),
	.vidin_d(vidin_d),
	.vidin_ack(vidin_ack),
	.vidin_frame(vidin_frame),
	.vidin_x(vidin_x),
	.vidin_y(vidin_y),

	.vidout_req(vidout_req),
	.vidout_d(vidout_d),
	.vidout_ack(vidout_ack),
	.vidout_frame(vidout_frame),
	.vidout_y(vidout_y),
	.vidout_x(vidout_x)
);

wire userotscale = (|rotation || |screenmode);

assign r = userotscale ? r_rot : r_ld;
assign g = userotscale ? g_rot : g_ld;
assign b = userotscale ? b_rot : b_ld;

assign pixel_ena_x1=pe_out;
assign pixel_ena_x2=ppe_out;

wire pe_out_sd;
wire ppe_out_sd;
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
	.pe_out(pe_out_sd),
	
	.ppe_out(ppe_out_sd),

	.hcnt_out(sd_hcnt),
	.line_out(line_toggle)	
);


// Video framing for scaler.

wire hb_sc,vb_sc,hs_sc,vs_sc; 
wire pe_out_sc,ppe_out_sc;

screenmode_timings timings;

always @(posedge clk_out) begin
	case(screenmode) 
		3'b000: timings <= `SCREENMODE_640_480_60;
		3'b001: timings <= `SCREENMODE_640_480_60;
		3'b010: timings <= `SCREENMODE_768_576_60;
		3'b011: timings <= `SCREENMODE_800_600_56;
		3'b100: timings <= `SCREENMODE_800_600_72;
		3'b101: timings <= `SCREENMODE_1024_768_70;
		3'b110: timings <= `SCREENMODE_1280_720_60;
		3'b111: timings <= `SCREENMODE_1920_1080_30;
	endcase
end

video_timings vt (
	.clk(clk_out),
	.reset_n(1'b1),
	.frame_stb(),
	.hsync_n(hs_sc),
	.vsync_n(vs_sc),
	.hblank_n(hb_sc),
	.vblank_n(vb_sc),
	.hblank_stb(),
	.vblank_stb(),
	.pixel_stb(pe_out_sc),
	.xpos(),
	.ypos(),
	.timings(timings)
);

assign ppe_out_sc = pe_out_sc;


reg hs_o, vs_o;
reg hb_o, vb_o;
reg vs_inverted;

always @(posedge clk_out) begin
	if(pe_out) begin
		hs_o <= |screenmode ?  hs_sc : (bypass ? hs_in : hs_sd);
		vs_o <= |screenmode ?  vs_sc : (bypass ? vs_in : vs_sd);
		hb_o <= |screenmode ? ~hb_sc : (bypass ? hb_in : hb_sd);
		vb_o <= |screenmode ? ~vb_sc : (bypass ? vb_in : vb_sd);
	end
end
assign vs_inverted = vs_o ^ (timings.vpolarity & |screenmode);

generate
	if (USE_SCALER ) begin
		wire [1:0] clkselect;
		scandoubler_clkctrl (
			.clkselect(clkselect),
			.inclk0x(1'b0),
			.inclk1x(1'b0),
			.inclk2x(clk_sys),
			.inclk3x(clk_75),
			.outclk(clk_out)
		);

		assign clkselect = |screenmode ? 2'b11 : 2'b10;
	end else begin
		assign clk_out = clk_sys;
	end
endgenerate

assign pe_out =  |screenmode ? pe_out_sc : pe_out_sd;
assign ppe_out = |screenmode ? pe_out_sc : ppe_out_sd;
assign hb_out = (bypass && !(|screenmode)) ? hb_in : hb_o;
assign vb_out = (bypass && !(|screenmode)) ? vb_in : vb_o;
assign hs_out = (bypass && !(|screenmode)) ? hs_in : hs_o;
assign vs_out = (bypass && !(|screenmode)) ? vs_in : vs_o;

endmodule

