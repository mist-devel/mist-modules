`timescale 1ns/10ps

// VGA Timing generator
// Copyright (c) 2021 by Alastair M. Robinson

// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.

module video_timings
#(
	parameter clkdivBits = 4,
	parameter hFramingBits=12,
	parameter vFramingBits=12
)
(
	input wire clk,
	input wire reset_n,
		
	// Sync / blanking
	output wire pixel_stb,
	output 	reg hsync_n,
	output 	reg vsync_n,
	output 	wire hblank_n,
	output 	wire vblank_n,
	output 	reg hblank_stb,
	output 	reg vblank_stb,
	output 	reg frame_stb,
		
	// Pixel positions
	output wire [hFramingBits-1:0] xpos,
	output wire [vFramingBits-1:0] ypos,

	input screenmode_timings timings
);

reg [clkdivBits-1:0] clkdivCnt;
reg [hFramingBits-1:0] hcounter;
reg [vFramingBits-1:0] vcounter;
reg pixel_stb_r;
reg hb_internal;
reg vb_internal;
reg [1:0] reset_n_d;
wire reset_s;


assign pixel_stb =pixel_stb_r;
assign hblank_n = hb_internal;
assign vblank_n = vb_internal;
assign xpos = hb_internal ? hcounter : -1;
assign ypos = vb_internal ? vcounter : -1;

always @(posedge clk)
	reset_n_d <= {reset_n_d[0],reset_n};
assign reset_s = reset_n_d[1];

always @(posedge clk) begin
	if(!reset_s) begin
		clkdivCnt<=0;
		hcounter<=timings.hsstop;
		vcounter<=timings.vbstart;
		hsync_n<=1'b1;
		vsync_n<=1'b1;
		hb_internal<=1'b1;
		vb_internal<=1'b1;
	end else begin
		hblank_stb<=1'b0;
		vblank_stb<=1'b0;
		frame_stb<=1'b0;
		pixel_stb_r<=1'b0;
		clkdivCnt<=clkdivCnt+1;

		if (clkdivCnt==timings.clkdiv) begin // new pixel
			pixel_stb_r<=1'b1;
			
			// Horizontal counters
			
			hcounter<=hcounter+1;

			if (hcounter==timings.hbstart) begin
				hblank_stb<=1'b1;
				hb_internal<=1'b0;
			end
			
			if (hcounter==timings.hsstart)
				hsync_n<=timings.hpolarity;
			
			if (hcounter==timings.hsstop) begin
				hsync_n<=~timings.hpolarity;
				vcounter<=vcounter+1;			
			end

			if (hcounter==timings.htotal) begin // New row
				hb_internal<=1'b1;
				hcounter<=1;
			end
			
			// Vertical counters

			if (hcounter==timings.hsstop && vcounter==timings.vbstart) begin
				vblank_stb<=1'b1;
				vb_internal<=1'b0;
			end
			
			if (vcounter==timings.vsstart) begin
				vsync_n<=timings.vpolarity;
			end
			
			if (vcounter==timings.vsstop)
				vsync_n<=~timings.vpolarity;
			
			if (hcounter==timings.hsstop && vcounter==timings.vtotal) begin // New frame
				vb_internal<=1'b1;
				vcounter<=1;
				frame_stb<=1'b1; // A new frame is imminent.
			end
			
			clkdivCnt<=0;
		end
	end
end

endmodule

