module cdc_pulse (
	input clk_d,
	input d,
	input clk_q,
	output q
);

reg d_d;
reg d_edge=1'b0;
reg d_q,d_q2,d_q3;

// Invert d_edge every time we see a rising edge on d.
always @(posedge clk_d) begin
	d_d<=d;
	if (d && !d_d)
		d_edge<=~d_edge;
end

// Sync d_edge to clk_q, and emit a pulse any time it changes.
always @(posedge clk_q) begin
	d_q<=d_edge;
	d_q2<=d_q;
	d_q3<=d_q2;
end

assign q = d_q3 ^ d_q2;

endmodule
