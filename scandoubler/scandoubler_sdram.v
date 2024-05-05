`timescale 1ns/10ps
//
// sdram.v
//
// sdram controller implementation for the MiST board
// https://github.com/mist-devel/mist-board
// 
// Copyright (c) 2013 Till Harbaum <till@harbaum.org> 
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

module scandoubler_sdram (
	// interface to the MT48LC16M16 chip
	inout  wire [15:0] sd_data,    // 16 bit bidirectional data bus
	output reg [12:0]  sd_addr,    // 13 bit multiplexed address bus
	output reg [1:0]   sd_dqm,     // two byte masks
	output reg [1:0]   sd_ba,      // two banks
	output wire        sd_cs,      // a single chip select
	output wire        sd_we,      // write enable
	output wire        sd_ras,     // row address select
	output wire        sd_cas,     // columns address select

	// cpu/chipset interface
	input wire         init,       // init signal after FPGA config to initialize RAM
	input wire         clk_96,     // sdram is accessed at 96MHz
	output wire        ready,

	input wire [15:0]  port1_din,        // data input from chipset/cpu
	output reg [15:0]  port1_dout,
	input wire [22:0]  port1_addr,       // 24 bit word address
	input wire [1:0]   port1_ds,         // upper/lower data strobe
	input wire         port1_req,        // cpu/chipset requests read/write (level toggle)
	input wire         port1_we,         // cpu/chipset requests write
	output reg         port1_ack,

	input  wire        rom_oe,
	input  wire[22:0]  rom_addr,
	output reg [15:0]  rom_dout,

	input wire         vidin_req,    // High at start of row, remains high until burst of 16 pixels has been delivered
	input wire [1:0]   vidin_frame,  // Odd or even frame for double-buffering
	input wire [10:0]  vidin_x,      // X position of current row.
	input wire [10:0]  vidin_y,      // Y position of current burst.
	input wire [15:0]  vidin_d,      // Incoming video data
	output wire        vidin_ack,    // Request next word from host
	
	input wire         vidout_req,   // High at start of row, remains high until entire row has been delivered
	input wire [1:0]   vidout_frame, // Odd or even frame for double-buffering
	input wire [10:0]  vidout_x,     // X position of current row
	input wire [10:0]  vidout_y,     // Y position of current row.
	output reg [15:0]  vidout_q,     // Outgoing video data
	output reg         vidout_ack    // Valid data available.
);

`default_nettype none

localparam RASCAS_DELAY   = 3'd2;   // tRCD=20ns -> 2 cycles@96MHz
localparam BURST_LENGTH   = 3'b011; // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE    = 1'b0;   // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2;   // 2/3 allowed
localparam OP_MODE        = 2'b00;  // only 00 (standard operation) allowed
localparam NO_WRITE_BURST = 1'b1;   // 0= write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 


// ---------------------------------------------------------------------
// ------------------------ cycle state machine ------------------------
// ---------------------------------------------------------------------

// The state machine runs at 96Mhz synchronous to the 8 Mhz chipset clock.
// It wraps from T15 to T0 on the rising edge of clk_8

localparam STATE_FIRST     = 5'd0;   // first state in cycle
localparam STATE_CMD_CONT  = STATE_FIRST  + {2'b00,RASCAS_DELAY}; // command can be continued
localparam STATE_READ      = STATE_CMD_CONT + {2'b00,CAS_LATENCY} + 5'd2;
localparam STATE_END       = 5'd7;  // last state in cycle
localparam STATE_VIDREADEND = STATE_CMD_CONT+{2'b00,CAS_LATENCY}+5'd10;
localparam STATE_VIDWRITEEND = STATE_CMD_CONT+5'd11;
reg [4:0] t;


// ---------------------------------------------------------------------
// --------------------------- startup/reset ---------------------------
// ---------------------------------------------------------------------

// wait 1ms (32 8Mhz cycles) after FPGA config is done before going
// into normal operation. Initialize the ram in the last 16 reset cycles (cycles 15-0)
reg [4:0] reset;
always @(posedge clk_96 or posedge init) begin
	if(init)
		reset <= 5'h1f;
	else if((t == STATE_END) && (reset != 0))
		reset <= reset - 5'd1;
end

// ---------------------------------------------------------------------
// ------------------ generate ram control signals ---------------------
// ---------------------------------------------------------------------

// all possible commands
localparam CMD_INHIBIT         = 4'b1111;
localparam CMD_NOP             = 4'b0111;
localparam CMD_ACTIVE          = 4'b0011;
localparam CMD_READ            = 4'b0101;
localparam CMD_WRITE           = 4'b0100;
localparam CMD_BURST_TERMINATE = 4'b0110;
localparam CMD_PRECHARGE       = 4'b0010;
localparam CMD_AUTO_REFRESH    = 4'b0001;
localparam CMD_LOAD_MODE       = 4'b0000;

reg [3:0] sd_cmd;   // current command sent to sd ram
// drive control signals according to current command
assign sd_cs  = sd_cmd[3];
assign sd_ras = sd_cmd[2];
assign sd_cas = sd_cmd[1];
assign sd_we  = sd_cmd[0];

reg [15:0] sd_din;

reg [15:0] sd_data_reg;
reg [15:0] data_latch;
reg [22:0] addr_latch;
reg [15:0] din_latch;
reg        req_latch;
reg        rom_port;
reg        we_latch;
reg        drive_dq;

reg       vidwrite;
reg       vidwrite_next;

reg       vidread;
reg       vidread_extend; // One row contains sixteen pixels, so could extend a burst.

assign vidin_ack = vidwrite_next;

assign sd_data=drive_dq ? sd_data_reg : 16'bZZZZZZZZZZZZZZZZ;

reg clk_8_enD;

assign ready = |reset ? 1'b0 : ~init;

wire rom_req = rom_oe && (addr_latch != rom_addr);

wire portswaiting = rom_req | (port1_req ^ port1_ack) | vidin_req;

always @(posedge clk_96) begin
	// permanently latch ram data to reduce delays
	sd_din <= sd_data;
	drive_dq<=1'b0;
	sd_cmd <= CMD_INHIBIT;  // default: idle

	t<=t+1'd1;

	if (vidwrite) begin
		if (t == STATE_VIDWRITEEND)
			t <= STATE_FIRST;
	end else if (vidread) begin	
		if ((t == STATE_READ+7) && vidread_extend)
			t <= STATE_READ;
		if (t == STATE_VIDREADEND)
			t <= STATE_FIRST;
	end else
		if (t == STATE_END)
			t <= STATE_FIRST;

	if(init) begin
		t<=STATE_FIRST;
		vidwrite<=1'b0;
		req_latch<=1'b0;
	end

	if(init || reset != 0) begin
		// initialization takes place at the end of the reset phase
		if(t == STATE_FIRST) begin

			if(reset == 13) begin
				sd_cmd <= CMD_PRECHARGE;
				sd_addr[10] <= 1'b1;      // precharge all banks
			end

			if(reset == 2) begin
				sd_ba <= 2'b00;
				sd_cmd <= CMD_LOAD_MODE;
				sd_addr <= MODE;
			end

		end
	end else begin
		vidout_ack<=1'b0;
		// normal operation
		if(t == STATE_FIRST) begin
			req_latch <=1'b0;
			vidwrite<=1'b0;
			vidread<=1'b0;
			vidread_extend<=1'b0;
			if (port1_req != port1_ack) begin // Upload gets first priority
				addr_latch <= port1_addr;
				req_latch <= 1;
				din_latch <= port1_din;
				rom_port <= 0;
				we_latch <= port1_we;

				// RAS phase
				sd_cmd <= CMD_ACTIVE;
				sd_addr <= port1_addr[21:9];
				sd_ba <= {1'b0,port1_addr[22]};
			end else if (rom_req) begin // ROM reads are next
				addr_latch <= rom_addr;
				req_latch <= 1;
				rom_port <= 1;
				we_latch <= 1'b0;

				// RAS phase
				sd_cmd <= CMD_ACTIVE;
				sd_addr <= rom_addr[21:9];
				sd_ba <= {1'b0,rom_addr[22]};
			end else if (vidin_req) begin // Then writing to the framebuffer
				vidwrite<=1'b1;
				sd_ba <= 2'b11;
				sd_addr <= {vidin_frame,vidin_y[9:5],vidin_x[9:4]};
//				$display("vidwrite (%t) bank %d, row %h", $time, {1'b1,vidin_y[3]}, {2'b11,vidin_frame,vidin_y[9:4],~vidin_x[9:6]});
				sd_cmd <= CMD_ACTIVE;
			end else if (vidout_req) begin // and finally reading back from the framebuffer
				vidread<=1'b1;
				// ba(0) <= x(3); // Stripe adjacent pixel blocks across banks
				sd_ba <= 2'b11;
				sd_addr <= {vidout_frame,vidout_y[9:5],vidout_x[9:4]};
				sd_cmd <= CMD_ACTIVE;
//				$display("vidread  (%t) read bank %d, row %h", $time, {1'b1,vidout_y[3]}, {2'b11,vidout_frame,vidout_y[9:4],~vidout_x[9:6]});

			end else begin
				req_latch <= 0;
				sd_cmd <= CMD_AUTO_REFRESH;
			end
		end

		// Video write:
		// Address mapping:

		// col(3 downto 0) <= y(3 downto 0); // 4 bits, 16 words
		// col(8 downto 4) <= x(4 downto 0); // 5 bits, 32 words
		// col(9) <= y(10); // On 64 meg chips only
		// row(5 downto 0) <= y(9 downto 4); // 6 bits
		// row(10 downto 6) <= x(9 downto 5); // 5 bits 
		// row(12 downto 11) <= frame;

		vidwrite_next<=1'b0;

		if(vidwrite) begin
			if(t>=(STATE_CMD_CONT-1) && t <STATE_CMD_CONT+7)
				vidwrite_next<=1'b1;

			if(t==STATE_CMD_CONT+1)
				sd_ba <= 2'b11;

			if(t==STATE_CMD_CONT+9)
				sd_ba <= 2'b11;

			if(t>=STATE_CMD_CONT+1 && t<=STATE_CMD_CONT+8) begin
				sd_dqm <= 2'b00;
				sd_data_reg <= vidin_d;
				drive_dq <= 1'b1;

				sd_addr[12:11] <= 2'b00;
				sd_addr[10] <= 1'b0;
				if(t==STATE_CMD_CONT+8)
					sd_addr[10] <= 1'b1;	// Auto precharge
				sd_addr[9:0] <= {vidin_x[10],vidin_y[4:0],vidin_x[3:0]};
				sd_cmd<=CMD_WRITE;
//				$display("vidwrite (%t) bank %d, col %h", $time, sd_ba, {1'b0,vidin_y[2:0],~vidin_x[5:0]});
			end
		end

		// Video read:
		// Address mapping:

		// col(3 downto 0) <= x(3 downto 0);
		// col(8 downto 4) <= y(4 downto 0);
		// col(9) <= x(10; // on 64 meg chips only
		// row(5 downto 0) <= x(9 downto 4);
		// row(10 downto 6) <= y(9 downto 5);
		// row(12 downto 11) <= frame;

		if(vidread) begin
			if(t == STATE_CMD_CONT) begin
				sd_dqm <= 2'b00;
				sd_addr[12:11] <= 2'b00;
				sd_addr[10] <= 1'b0; // Don't auto precharge
				sd_addr[9:0] <= {vidout_x[10],vidout_y[4:0],vidout_x[3],3'b0};
				sd_cmd <= CMD_READ;
				vidread_extend <= ~vidout_x[3]; // Can we extend the transaction if the other ports aren't waiting?
//				$display("vidread  (%t) column %h", $time, {1'b0,vidout_y[2:0],vidout_x[5:0]});
			end

			if(t==STATE_READ+6-{2'b0,CAS_LATENCY}) begin
				sd_addr[10] <= 1'b0;
				
				if(vidout_req && vidread_extend && !portswaiting) begin
					sd_addr[12:11] <= 2'b00;
					sd_addr[10] <= 1'b0; // Don't auto precharge
					sd_addr[9:0] <= {vidout_x[10],vidout_y[4:0],1'b1,3'b0};
					sd_cmd <= CMD_READ;
				end else begin
					vidread_extend<=1'b0;
					sd_cmd <= CMD_PRECHARGE;
				end
			end
			
			if(t==STATE_READ+7)
				vidread_extend<=1'b0;
			
			if(t>=STATE_READ && t<(STATE_READ+8)) begin
				vidout_q<=sd_din;
				vidout_ack <= 1'b1;
			end			
		end


		// -------------------  cpu/chipset read/write ----------------------
		if(req_latch) begin

			// CAS phase 
			if(t == STATE_CMD_CONT) begin
				sd_cmd <= we_latch?CMD_WRITE:CMD_READ;
				if (we_latch) begin
					sd_data_reg <= din_latch;
					drive_dq<=1'b1;
					port1_ack <= port1_req;
				end
				// always return both bytes in a read. The cpu may not
				// need it, but the caches need to be able to store everything
				sd_dqm <= we_latch ? ~port1_ds : 2'b00;

				sd_addr <= { we_latch ? 4'b0010 : 4'b0000, addr_latch[8:0] };  // auto precharge for writes only
			end

			if(t == STATE_CMD_CONT+3) begin
				if(!we_latch) begin
					sd_cmd <= CMD_PRECHARGE;
					sd_addr[10]<=1'b0;
				end
			end

			// read phase
			if(!we_latch || rom_port) begin
				if(t == STATE_READ) begin
					if (rom_port)
						rom_dout <= sd_din;
					else begin
						port1_dout <= sd_din;
						port1_ack <= port1_req;
					end
				end
			end
		end
	end
end

endmodule
