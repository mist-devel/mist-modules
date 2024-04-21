//
// scandoubler_framing.v
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
// which is the largest value the counter will reach before resetting - so 4'b0111 to
// divide clk_sys by 8, 4'0011 to divide by 4, 4'0101 to divide by six.

module scandoubler_framing
(
	// system interface
	input        clk_sys,

	// Pixelclock
	input [3:0]	 ce_divider, // 0 - clk_sys/4, 1 - clk_sys/2, 2 - clk_sys/3, 3 - clk_sys/4, etc.

	// incoming video interface
	input        hb_in,
	input        vb_in,
	input        hs_in,
	input        vs_in,
	output       pe_in,	// Pixel enable at input rate

	output [HCNT_WIDTH-1:0] hcnt_in,

	// output interface
	output	     hb_out,
	output	     vb_out,
	output	     hs_out,
	output	     vs_out,
	output       pe_out, // Pixel enable at output rate
	
	output       ppe_out, // Pixel enable at output or double rate for post-processing

	output [HCNT_WIDTH-1:0] hcnt_out,
	output       line_out
	
);

parameter HCNT_WIDTH = 10; // Resolution of scandoubler buffer
parameter HSCNT_WIDTH = 12; // Resolution of hsync counters

// use alternating sd_buffers when storing/reading data   
reg        line_toggle;

// total hsync time (in 16MHz cycles), hs_total reaches 1024
reg  [HCNT_WIDTH-1:0] hcnt;
reg  [HSCNT_WIDTH:0] hs_max;
reg  [HSCNT_WIDTH:0] hs_rise;
reg  [HCNT_WIDTH:0] hb_fall[2];
reg  [HCNT_WIDTH:0] hb_rise[2];
reg  [HCNT_WIDTH+1:0] vb_event[2];
reg  [HCNT_WIDTH+1:0] vs_event[2];
reg  [HSCNT_WIDTH:0] synccnt;

// Input pixel clock, aligned with input sync:
wire[3:0] ce_divider_adj = |ce_divider ? ce_divider : 4'd3; // 0 = clk/4 for compatiblity
reg [3:0] ce_divider_in;
reg [3:0] ce_divider_out;

reg [3:0] i_div;
wire ce_x1 = (i_div == ce_divider_in);

always @(posedge clk_sys) begin
	reg hsD, vsD;
	reg vbD;
	reg hbD;

	// Pixel logic on x1 clkena
	if(ce_x1) begin
		hcnt <= hcnt + 1'd1;
		vsD <= vs_in;
		vbD <= vb_in;

		if (vbD ^ vb_in) vb_event[line_toggle] <= {1'b1, vb_in, hcnt};
		if (vsD ^ vs_in) vs_event[line_toggle] <= {1'b1, vs_in, hcnt};
		// save position of hblank
		hbD <= hb_in;
		if(!hbD &&  hb_in) hb_rise[line_toggle] <= {1'b1, hcnt};
		if( hbD && !hb_in) hb_fall[line_toggle] <= {1'b1, hcnt};
	end

	// Generate pixel clock
	i_div <= i_div + 1'd1;

	if (i_div==ce_divider_adj) i_div <= 4'b0000;

	synccnt <= synccnt + 1'd1;
	hsD <= hs_in;
	if(hsD && !hs_in) begin
		// At hsync latch the ce_divider counter limit for the input clock
		// and pass the previous input clock limit to the output stage.
		// This should give correct output if the pixel clock changes mid-screen.
		ce_divider_out <= ce_divider_in;
		ce_divider_in <= ce_divider_adj;
		hs_max <= {1'b0,synccnt[HSCNT_WIDTH:1]};
		hcnt <= 0;
		synccnt <= 0;
		i_div <= 4'b0000;
	end

	// save position of hsync rising edge
	if(!hsD && hs_in) hs_rise <= {1'b0,synccnt[HSCNT_WIDTH:1]};

	// begin of incoming hsync
	if(hsD && !hs_in) begin
		line_toggle <= !line_toggle;
		vb_event[!line_toggle] <= 0;
		vs_event[!line_toggle] <= 0;
		hb_rise[!line_toggle][HCNT_WIDTH] <= 0;
		hb_fall[!line_toggle][HCNT_WIDTH] <= 0;
	end

end

assign pe_in = ce_x1;

// ==================================================================
// ==================== output timing generation ====================
// ==================================================================

reg  [HSCNT_WIDTH:0] sd_synccnt;
reg  [HCNT_WIDTH-1:0] sd_hcnt;
reg vb_sd = 0;
reg hb_sd = 0;
reg hs_sd = 0;
reg vs_sd = 0;

// Output pixel clock, aligned with output sync:
reg [3:0] sd_i_div;

always @(posedge clk_sys) begin
	reg hsD;

	// Output logic on x2 clkena
	if(ce_x2) begin
		// output counter synchronous to input and at twice the rate
		sd_hcnt <= sd_hcnt + 1'd1;

		// Handle VBlank event
		if(vb_event[~line_toggle][HCNT_WIDTH+1] && sd_hcnt == vb_event[~line_toggle][HCNT_WIDTH-1:0]) vb_sd <= vb_event[~line_toggle][HCNT_WIDTH];
		// Handle VSync event
		if(vs_event[~line_toggle][HCNT_WIDTH+1] && sd_hcnt == vs_event[~line_toggle][HCNT_WIDTH-1:0]) vs_sd <= vs_event[~line_toggle][HCNT_WIDTH];
		// Handle HBlank events
		if(hb_rise[~line_toggle][HCNT_WIDTH] && sd_hcnt == hb_rise[~line_toggle][HCNT_WIDTH-1:0]) hb_sd <= 1;
		if(hb_fall[~line_toggle][HCNT_WIDTH] && sd_hcnt == hb_fall[~line_toggle][HCNT_WIDTH-1:0]) hb_sd <= 0;
	end

	sd_i_div <= sd_i_div + 1'd1;
	if (sd_i_div==ce_divider_adj) sd_i_div <= 4'b0000;

	//  Framing logic on sysclk
	sd_synccnt <= sd_synccnt + 1'd1;
	hsD <= hs_in;

	if(sd_synccnt == hs_max || (hsD && !hs_in)) begin
		sd_synccnt <= 0;
		sd_hcnt <= 0;
		hs_sd <= 0;
		sd_i_div <= 4'b0000;
	end

	if(sd_synccnt == hs_rise) hs_sd <= 1;

end

reg [3:0] x4_limit;
always @(posedge clk_sys)
	x4_limit <= 4'b1 + {1'b0,ce_divider_out[3:1]} + {2'b00,ce_divider_out[3:2]};

wire ce_x2 = (sd_i_div == ce_divider_out) | (sd_i_div == {1'b0,ce_divider_out[3:1]});
wire ce_x4 = (sd_i_div == {2'b00,ce_divider_out[3:2]}) | (sd_i_div==x4_limit) | ce_x2;

assign pe_out = ce_x2 ;
assign ppe_out = ce_divider_out > 4'd5 ? ce_x4 : ce_x2 ;

assign hb_out = hb_sd;
assign vb_out = vb_sd;
assign hs_out = hs_sd;
assign vs_out = vs_sd;

assign line_out = line_toggle;
assign hcnt_out = sd_hcnt;
assign hcnt_in = hcnt;

endmodule

