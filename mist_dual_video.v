// A video pipeline for MiST. Just insert between the core video output and the VGA pins
// Provides an optional scandoubler, a rotateable OSD and (optional) RGb->YPbPr conversion

module mist_dual_video
(
	// master clock
	// it should be 4x (or 2x) pixel clock for the scandoubler
	input        clk_sys,

	// OSD SPI interface
	input        SPI_SCK,
	input        SPI_SS3,
	input        SPI_DI,

	// scanlines (00-none 01-25% 10-50% 11-75%)
	input  [1:0] scanlines,

	// non-scandoubled pixel clock divider:
	// 0 - clk_sys/4, 1 - clk_sys/2, 2 - clk_sys/3, 3 - clk_sys/4, etc
	input  [3:0] ce_divider,

	// 0 = HVSync 31KHz, 1 = CSync 15KHz
	input        scandoubler_disable,
	input        rotateonly,
	// disable csync without scandoubler
	input        no_csync,
	// YPbPr always uses composite sync
	input        ypbpr,
	// Rotate OSD [0] - rotate [1] - left or right
	input  [1:0] rotate,
	// Rotate screen (needs SDRAM connection)
	input  [1:0] rotate_screen,
	// filters for rotation
	input        rotate_hfilter,
	input        rotate_vfilter,
	// composite-like blending
	input        blend,

	// video in
	input  [COLOR_DEPTH-1:0] R,
	input  [COLOR_DEPTH-1:0] G,
	input  [COLOR_DEPTH-1:0] B,

	input        HBlank,
	input        VBlank,
	input        HSync,
	input        VSync,

	// MiST video output signals
	output reg [OUT_COLOR_DEPTH-1:0] VGA_R,
	output reg [OUT_COLOR_DEPTH-1:0] VGA_G,
	output reg [OUT_COLOR_DEPTH-1:0] VGA_B,
	output reg       VGA_VS,
	output reg       VGA_HS,
	output reg       VGA_HB,
	output reg       VGA_VB,
	output reg       VGA_DE,

	output reg [7:0] HDMI_R,
	output reg [7:0] HDMI_G,
	output reg [7:0] HDMI_B,
	output reg       HDMI_VS,
	output reg       HDMI_HS,
	output reg       HDMI_DE,

	// SDRAM signals for screen rotation/basic ROM access
	input    [15:0]  ram_din,        // data input from chipset/cpu
	output   [15:0]  ram_dout,
	input    [22:0]  ram_addr,       // 23 bit word address
	input    [1:0]   ram_ds,         // upper/lower data strobe
	input            ram_req,        // cpu/chipset requests read/write (level toggle)
	input            ram_we,         // cpu/chipset requests write
	output           ram_ack,
	input            rom_oe,
	input    [22:0]  rom_addr,
	output   [15:0]  rom_dout,

	input            clk_sdram,
	input            sdram_init,
	output    [12:0] SDRAM_A,
	inout     [15:0] SDRAM_DQ,
	output           SDRAM_DQML,
	output           SDRAM_DQMH,
	output           SDRAM_nWE,
	output           SDRAM_nCAS,
	output           SDRAM_nRAS,
	output           SDRAM_nCS,
	output     [1:0] SDRAM_BA
);

parameter OSD_COLOR    = 3'd4;
parameter OSD_X_OFFSET = 10'd0;
parameter OSD_Y_OFFSET = 10'd0;
parameter SD_HCNT_WIDTH = 9;
parameter COLOR_DEPTH = 6;      // 1-8
parameter OSD_AUTO_CE = 1'b1;
parameter SYNC_AND = 1'b0;      // 0 - XOR, 1 - AND
parameter USE_BLANKS = 1'b0;    // Honor H/VBlank signals?
parameter SD_HSCNT_WIDTH = 12;
parameter OUT_COLOR_DEPTH = 6;  // 1-8
parameter BIG_OSD = 1'b0;       // 16 line OSD
parameter VIDEO_CLEANER = 1'b0; // Align VSync/VBlank to HSync/HBlank edges. HDMI usually needs it.

wire  [7:0] SD_R_O;
wire  [7:0] SD_G_O;
wire  [7:0] SD_B_O;
wire        SD_HS_O;
wire        SD_VS_O;
wire        SD_HB_O;
wire        SD_VB_O;

wire        pixel_ena_x1;
wire        pixel_ena_x2;

wire        vidin_req;
wire        vidin_ack;
wire [10:0] vidin_row;
wire [10:0] vidin_col;
wire [15:0] vidin_d;
wire  [1:0] vidin_frame;

wire        vidout_req;
wire        vidout_ack;
wire [10:0] vidout_row;
wire [10:0] vidout_col;
wire [15:0] vidout_d;
wire  [1:0] vidout_frame;

scandoubler #(SD_HCNT_WIDTH, COLOR_DEPTH, SD_HSCNT_WIDTH, 8) scandoubler
(
	.clk_sys    ( clk_sys    ),
	.bypass     ( rotateonly ),
	.rotateonly ( rotateonly ),
	.ce_divider ( ce_divider ),
	.scanlines  ( scanlines  ),
	.rotation   ( rotate_screen  ),
	.hfilter    ( rotate_hfilter ),
	.vfilter    ( rotate_vfilter ),
	.pixel_ena_x1 ( pixel_ena_x1 ),
	.pixel_ena_x2 ( pixel_ena_x2 ),
	.hb_in      ( HBlank     ),
	.vb_in      ( VBlank     ),
	.hs_in      ( HSync      ),
	.vs_in      ( VSync      ),
	.r_in       ( R          ),
	.g_in       ( G          ),
	.b_in       ( B          ),
	.hb_out     ( SD_HB_O    ),
	.vb_out     ( SD_VB_O    ),
	.hs_out     ( SD_HS_O    ),
	.vs_out     ( SD_VS_O    ),
	.r_out      ( SD_R_O     ),
	.g_out      ( SD_G_O     ),
	.b_out      ( SD_B_O     ),

	// SDRAM interface for rotation
	.vidin_req  ( vidin_req  ),
	.vidin_d    ( vidin_d    ),
	.vidin_ack  ( vidin_ack  ),
	.vidin_frame(vidin_frame ),
	.vidin_row  ( vidin_row  ),
	.vidin_col  ( vidin_col  ),

	.vidout_req( vidout_req  ),
	.vidout_d  ( vidout_d    ),
	.vidout_ack( vidout_ack  ),
	.vidout_frame( vidout_frame),
	.vidout_row( vidout_row  ),
	.vidout_col( vidout_col  )
);

// SDRAM controller for screen rotation
scandoubler_sdram sdram_ctrl (
	.sd_data(SDRAM_DQ),  // 16 bit bidirectional data bus
	.sd_addr(SDRAM_A),   // 13 bit multiplexed address bus
	.sd_dqm({SDRAM_DQMH,SDRAM_DQML}), // two byte masks
	.sd_ba(SDRAM_BA),    // two banks
	.sd_cs(SDRAM_nCS),   // a single chip select
	.sd_we(SDRAM_nWE),   // write enable
	.sd_ras(SDRAM_nRAS), // row address select
	.sd_cas(SDRAM_nCAS), // columns address select

	.clk_96(clk_sdram),
	.init(sdram_init),
	.ready(),

	.ram_din(ram_din),
	.ram_dout(ram_dout),
	.ram_addr(ram_addr),
	.ram_ds(ram_ds),     // upper/lower data strobe
	.ram_req(ram_req),   // cpu/chipset requests read/write
	.ram_we(ram_we),     // cpu/chipset requests write
	.ram_ack(ram_ack),

	.rom_oe(rom_oe),
	.rom_addr(rom_addr),
	.rom_dout(rom_dout),

	.vidin_req(vidin_req),
	.vidin_d(vidin_d),
	.vidin_ack(vidin_ack),
	.vidin_frame(vidin_frame),
	.vidin_row(vidin_row),
	.vidin_col(vidin_col),

	.vidout_req(vidout_req),
	.vidout_row(vidout_row),
	.vidout_col(vidout_col),
	.vidout_frame(vidout_frame),
	.vidout_q(vidout_d),
	.vidout_ack(vidout_ack)
);

////////////////////////// VGA OUTPUT  ///////////////////////////

wire [OUT_COLOR_DEPTH-1:0] SD_SCALED_R_O;
wire [OUT_COLOR_DEPTH-1:0] SD_SCALED_G_O;
wire [OUT_COLOR_DEPTH-1:0] SD_SCALED_B_O;

wire [OUT_COLOR_DEPTH-1:0] SCALED_R_O;
wire [OUT_COLOR_DEPTH-1:0] SCALED_G_O;
wire [OUT_COLOR_DEPTH-1:0] SCALED_B_O;

scandoubler_scaledepth #(8, OUT_COLOR_DEPTH) vga_scaledepth_sd_r(SD_R_O, SD_SCALED_R_O);
scandoubler_scaledepth #(8, OUT_COLOR_DEPTH) vga_scaledepth_sd_g(SD_G_O, SD_SCALED_G_O);
scandoubler_scaledepth #(8, OUT_COLOR_DEPTH) vga_scaledepth_sd_b(SD_B_O, SD_SCALED_B_O);

scandoubler_scaledepth #(COLOR_DEPTH, OUT_COLOR_DEPTH) vga_scaledepth_r(R, SCALED_R_O);
scandoubler_scaledepth #(COLOR_DEPTH, OUT_COLOR_DEPTH) vga_scaledepth_g(G, SCALED_G_O);
scandoubler_scaledepth #(COLOR_DEPTH, OUT_COLOR_DEPTH) vga_scaledepth_b(B, SCALED_B_O);

wire use_sd = !scandoubler_disable | (rotate_screen != 0 & rotateonly);
wire blank_in = HBlank | VBlank;
wire [OUT_COLOR_DEPTH-1:0] vga_r_in = !use_sd ? (blank_in ? {OUT_COLOR_DEPTH{1'b0}} : SCALED_R_O) : SD_SCALED_R_O;
wire [OUT_COLOR_DEPTH-1:0] vga_g_in = !use_sd ? (blank_in ? {OUT_COLOR_DEPTH{1'b0}} : SCALED_G_O) : SD_SCALED_G_O;
wire [OUT_COLOR_DEPTH-1:0] vga_b_in = !use_sd ? (blank_in ? {OUT_COLOR_DEPTH{1'b0}} : SCALED_B_O) : SD_SCALED_B_O;
wire vga_hs_in = !use_sd ? HSync  : SD_HS_O;
wire vga_vs_in = !use_sd ? VSync  : SD_VS_O;
wire vga_hb_in = !use_sd ? HBlank : SD_HB_O;
wire vga_vb_in = !use_sd ? VBlank : SD_VB_O;
wire vga_pixel_ena = use_sd ? pixel_ena_x2 : pixel_ena_x1;

wire [OUT_COLOR_DEPTH-1:0] vga_osd_r_o;
wire [OUT_COLOR_DEPTH-1:0] vga_osd_g_o;
wire [OUT_COLOR_DEPTH-1:0] vga_osd_b_o;

osd #(OSD_X_OFFSET, OSD_Y_OFFSET, OSD_COLOR, OSD_AUTO_CE, USE_BLANKS, OUT_COLOR_DEPTH, BIG_OSD) vga_osd
(
	.clk_sys ( clk_sys     ),
	.rotate  ( rotate      ),
	.ce      ( vga_pixel_ena ),
	.SPI_DI  ( SPI_DI      ),
	.SPI_SCK ( SPI_SCK     ),
	.SPI_SS3 ( SPI_SS3     ),
	.R_in    ( vga_r_in    ),
	.G_in    ( vga_g_in    ),
	.B_in    ( vga_b_in    ),
	.HBlank  ( vga_hb_in   ),
	.VBlank  ( vga_vb_in   ),
	.HSync   ( vga_hs_in   ),
	.VSync   ( vga_vs_in   ),
	.R_out   ( vga_osd_r_o ),
	.G_out   ( vga_osd_g_o ),
	.B_out   ( vga_osd_b_o )
);

wire [OUT_COLOR_DEPTH-1:0] vga_cofi_r, vga_cofi_g, vga_cofi_b;
wire       vga_cofi_hs, vga_cofi_vs;
wire       vga_cofi_hb, vga_cofi_vb;
wire       vga_cofi_pixel_ena;

cofi #(OUT_COLOR_DEPTH) vga_cofi (
	.clk     ( clk_sys     ),
	.pix_ce  ( vga_pixel_ena ),
	.enable  ( blend       ),
	.hblank  ( USE_BLANKS ? vga_hb_in : ~vga_hs_in ),
	.vblank  ( vga_vb_in   ),
	.hs      ( vga_hs_in   ),
	.vs      ( vga_vs_in   ),
	.red     ( vga_osd_r_o ),
	.green   ( vga_osd_g_o ),
	.blue    ( vga_osd_b_o ),
	.hs_out  ( vga_cofi_hs ),
	.vs_out  ( vga_cofi_vs ),
	.hblank_out( vga_cofi_hb ),
	.vblank_out( vga_cofi_vb ),
	.red_out ( vga_cofi_r    ),
	.green_out( vga_cofi_g   ),
	.blue_out( vga_cofi_b    ),
	.pix_ce_out(vga_cofi_pixel_ena)
);

wire       hs, vs, cs;
wire       hb, vb;
wire [OUT_COLOR_DEPTH-1:0] r,g,b;

RGBtoYPbPr #(OUT_COLOR_DEPTH) rgb2ypbpr
(
	.clk       ( clk_sys ),
	.ena       ( ypbpr   ),

	.red_in    ( vga_cofi_r   ),
	.green_in  ( vga_cofi_g   ),
	.blue_in   ( vga_cofi_b   ),
	.hs_in     ( vga_cofi_hs  ),
	.vs_in     ( vga_cofi_vs  ),
	.cs_in     ( SYNC_AND ? (vga_cofi_hs & vga_cofi_vs) : ~(vga_cofi_hs ^ vga_cofi_vs) ),
	.hb_in     ( vga_cofi_hb  ),
	.vb_in     ( vga_cofi_vb  ),
	.red_out   ( r            ),
	.green_out ( g            ),
	.blue_out  ( b            ),
	.hs_out    ( hs           ),
	.vs_out    ( vs           ),
	.cs_out    ( cs           ),
	.hb_out    ( hb           ),
	.vb_out    ( vb           )
);

always @(posedge clk_sys) begin

	VGA_R  <= r;
	VGA_G  <= g;
	VGA_B  <= b;
	// a minimig vga->scart cable expects a composite sync signal on the VGA_HS output.
	// and VCC on VGA_VS (to switch into rgb mode)
	VGA_HS <= ((~no_csync & scandoubler_disable) || ypbpr)? cs : hs;
	VGA_VS <= ((~no_csync & scandoubler_disable) || ypbpr)? 1'b1 : vs;

	VGA_HB <= hb;
	VGA_VB <= vb;
	VGA_DE <= ~(hb | vb);
end

/////////////////////////// HDMI OUTPUT ///////////////////////////
wire [7:0] hdmi_osd_r_o;
wire [7:0] hdmi_osd_g_o;
wire [7:0] hdmi_osd_b_o;

osd #(OSD_X_OFFSET, OSD_Y_OFFSET, OSD_COLOR, OSD_AUTO_CE, USE_BLANKS, 8, BIG_OSD) hdmi_osd
(
	.clk_sys ( clk_sys      ),
	.rotate  ( rotate       ),
	.ce      ( pixel_ena_x2 ),
	.SPI_DI  ( SPI_DI       ),
	.SPI_SCK ( SPI_SCK      ),
	.SPI_SS3 ( SPI_SS3      ),
	.R_in    ( SD_R_O       ),
	.G_in    ( SD_G_O       ),
	.B_in    ( SD_B_O       ),
	.HBlank  ( SD_HB_O      ),
	.VBlank  ( SD_VB_O      ),
	.HSync   ( SD_HS_O      ),
	.VSync   ( SD_VS_O      ),
	.R_out   ( hdmi_osd_r_o ),
	.G_out   ( hdmi_osd_g_o ),
	.B_out   ( hdmi_osd_b_o )
);

wire [7:0] hdmi_cofi_r, hdmi_cofi_g, hdmi_cofi_b;
wire       hdmi_cofi_hs, hdmi_cofi_vs;
wire       hdmi_cofi_hb, hdmi_cofi_vb;
wire       hdmi_cofi_pixel_ena;

cofi #(8) hdmi_cofi (
	.clk     ( clk_sys        ),
	.pix_ce  ( pixel_ena_x2   ),
	.enable  ( blend          ),
	.hblank  ( USE_BLANKS ? SD_HB_O : ~SD_HS_O ),
	.vblank  ( SD_VB_O        ),
	.hs      ( SD_HS_O        ),
	.vs      ( SD_VS_O        ),
	.red     ( hdmi_osd_r_o   ),
	.green   ( hdmi_osd_g_o   ),
	.blue    ( hdmi_osd_b_o   ),
	.hs_out  ( hdmi_cofi_hs   ),
	.vs_out  ( hdmi_cofi_vs   ),
	.hblank_out( hdmi_cofi_hb ),
	.vblank_out( hdmi_cofi_vb ),
	.red_out ( hdmi_cofi_r    ),
	.green_out( hdmi_cofi_g   ),
	.blue_out( hdmi_cofi_b    ),
	.pix_ce_out(hdmi_cofi_pixel_ena)
);

wire [7:0] cleaner_r_o;
wire [7:0] cleaner_g_o;
wire [7:0] cleaner_b_o;
wire cleaner_hs_o, cleaner_vs_o, cleaner_hb_o, cleaner_vb_o;

video_cleaner #(8) video_cleaner(
	.clk_vid    ( clk_sys          ),
	.ce_pix     ( hdmi_cofi_pixel_ena ),
	.enable     ( VIDEO_CLEANER ),

	.R          ( hdmi_cofi_r  ),
	.G          ( hdmi_cofi_g  ),
	.B          ( hdmi_cofi_b  ),

	.HSync      ( hdmi_cofi_hs ),
	.VSync      ( hdmi_cofi_vs ),
	.HBlank     ( hdmi_cofi_hb ),
	.VBlank     ( hdmi_cofi_vb ),

	.VGA_R      ( cleaner_r_o  ),
	.VGA_G      ( cleaner_g_o  ),
	.VGA_B      ( cleaner_b_o  ),
	.VGA_VS     ( cleaner_vs_o ),
	.VGA_HS     ( cleaner_hs_o ),
	.HBlank_out ( cleaner_hb_o ),
	.VBlank_out ( cleaner_vb_o )
);


always @(posedge clk_sys) begin
	HDMI_R  <= cleaner_r_o;
	HDMI_G  <= cleaner_g_o;
	HDMI_B  <= cleaner_b_o;
	HDMI_HS <= cleaner_hs_o;
	HDMI_VS <= cleaner_vs_o;
	HDMI_DE <= ~(cleaner_hb_o | cleaner_vb_o);
end

endmodule
