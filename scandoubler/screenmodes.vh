typedef struct packed {
	logic [11:0] hbstart;
	logic [11:0] hsstart;
	logic [11:0] hsstop;
	logic [11:0] htotal;
	logic [11:0] vbstart;
	logic [11:0] vsstart;
	logic [11:0] vsstop;
	logic [11:0] vtotal;
	logic hpolarity;
	logic vpolarity;
	logic [3:0] clkdiv;
} screenmode_timings;

`define   SCREENMODE_640_480_60 { 12'd__640, 12'd__656, 12'd__752, 12'd__800, 12'd__480, 12'd__500, 12'd__502, 12'd__525, 1'b0, 1'b0, 4'd_2}

`define   SCREENMODE_768_576_60 { 12'd__768, 12'd__792, 12'd__872, 12'd__976, 12'd__576, 12'd__577, 12'd__580, 12'd__597, 1'b0, 1'b1, 4'd_1}

`define   SCREENMODE_800_600_56 { 12'd__800, 12'd__824, 12'd__896, 12'd_1024, 12'd__600, 12'd__601, 12'd__603, 12'd__625, 1'b1, 1'b1, 4'd_1}

`define   SCREENMODE_800_600_72 { 12'd__800, 12'd__856, 12'd__976, 12'd_1040, 12'd__600, 12'd__637, 12'd__643, 12'd__666, 1'b1, 1'b1, 4'd_0}

`define  SCREENMODE_1024_768_70 { 12'd_1024, 12'd_1048, 12'd_1184, 12'd_1328, 12'd__768, 12'd__771, 12'd__777, 12'd__806, 1'b0, 1'b0, 4'd_0}

`define  SCREENMODE_1280_720_60 { 12'd_1280, 12'd_1390, 12'd_1430, 12'd_1650, 12'd__720, 12'd__725, 12'd__730, 12'd__750, 1'b1, 1'b1, 4'd_0}

`define SCREENMODE_1920_1080_30 { 12'd_1920, 12'd_2008, 12'd_2052, 12'd_2200, 12'd_1080, 12'd_1084, 12'd_1089, 12'd_1125, 1'b1, 1'b1, 4'd_0}

