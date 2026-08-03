//============================================================================
//  Vector intensity conditioning and tone mapping
//
//  Written 2026 by Videodr0me
//============================================================================

module vfb_tone_mapper
(
	input  logic       clk_source,
	input  logic       reset,
	input  logic       beam_on,
	input  logic [7:0] raw_intensity,
	input  logic [1:0] tone_mapping,
	output logic [7:0] mapped_intensity
);

	logic beam_on_q = 1'b0;

(* romstyle = "logic" *) reg [7:0] z_lut[0:255] = '{default:0};
initial begin
	z_lut[0] = 8'd0; z_lut[1] = 8'd2; z_lut[2] = 8'd3; z_lut[3] = 8'd5; z_lut[4] = 8'd7;
	z_lut[5] = 8'd9; z_lut[6] = 8'd10; z_lut[7] = 8'd12; z_lut[8] = 8'd14; z_lut[9] = 8'd15;
	z_lut[10] = 8'd17; z_lut[11] = 8'd19; z_lut[12] = 8'd21; z_lut[13] = 8'd22; z_lut[14] = 8'd24;
	z_lut[15] = 8'd26; z_lut[16] = 8'd27; z_lut[17] = 8'd29; z_lut[18] = 8'd31; z_lut[19] = 8'd33;
	z_lut[20] = 8'd34; z_lut[21] = 8'd36; z_lut[22] = 8'd38; z_lut[23] = 8'd39; z_lut[24] = 8'd41;
	z_lut[25] = 8'd43; z_lut[26] = 8'd45; z_lut[27] = 8'd46; z_lut[28] = 8'd48; z_lut[29] = 8'd50;
	z_lut[30] = 8'd52; z_lut[31] = 8'd54; z_lut[32] = 8'd56; z_lut[33] = 8'd58; z_lut[34] = 8'd60;
	z_lut[35] = 8'd62; z_lut[36] = 8'd64; z_lut[37] = 8'd66; z_lut[38] = 8'd68; z_lut[39] = 8'd70;
	z_lut[40] = 8'd72; z_lut[41] = 8'd74; z_lut[42] = 8'd76; z_lut[43] = 8'd78; z_lut[44] = 8'd80;
	z_lut[45] = 8'd82; z_lut[46] = 8'd84; z_lut[47] = 8'd86; z_lut[48] = 8'd88; z_lut[49] = 8'd90;
	z_lut[50] = 8'd92; z_lut[51] = 8'd94; z_lut[52] = 8'd96; z_lut[53] = 8'd98; z_lut[54] = 8'd100;
	z_lut[55] = 8'd102; z_lut[56] = 8'd104; z_lut[57] = 8'd106; z_lut[58] = 8'd108; z_lut[59] = 8'd110;
	z_lut[60] = 8'd112; z_lut[61] = 8'd114; z_lut[62] = 8'd116; z_lut[63] = 8'd118; z_lut[64] = 8'd120;
	z_lut[65] = 8'd122; z_lut[66] = 8'd124; z_lut[67] = 8'd126; z_lut[68] = 8'd128; z_lut[69] = 8'd130;
	z_lut[70] = 8'd132; z_lut[71] = 8'd134; z_lut[72] = 8'd136; z_lut[73] = 8'd138; z_lut[74] = 8'd140;
	z_lut[75] = 8'd142; z_lut[76] = 8'd144; z_lut[77] = 8'd146; z_lut[78] = 8'd148; z_lut[79] = 8'd150;
	z_lut[80] = 8'd152; z_lut[81] = 8'd154; z_lut[82] = 8'd156; z_lut[83] = 8'd158; z_lut[84] = 8'd160;
	z_lut[85] = 8'd162; z_lut[86] = 8'd164; z_lut[87] = 8'd166; z_lut[88] = 8'd168; z_lut[89] = 8'd170;
	z_lut[90] = 8'd172; z_lut[91] = 8'd174; z_lut[92] = 8'd176; z_lut[93] = 8'd178; z_lut[94] = 8'd180;
	z_lut[95] = 8'd182; z_lut[96] = 8'd184; z_lut[97] = 8'd186; z_lut[98] = 8'd188; z_lut[99] = 8'd190;
	z_lut[100] = 8'd192; z_lut[101] = 8'd194; z_lut[102] = 8'd196; z_lut[103] = 8'd198; z_lut[104] = 8'd200;
	z_lut[105] = 8'd202; z_lut[106] = 8'd204; z_lut[107] = 8'd206; z_lut[108] = 8'd208; z_lut[109] = 8'd210;
	z_lut[110] = 8'd212; z_lut[111] = 8'd214; z_lut[112] = 8'd216; z_lut[113] = 8'd216; z_lut[114] = 8'd217;
	z_lut[115] = 8'd217; z_lut[116] = 8'd217; z_lut[117] = 8'd217; z_lut[118] = 8'd218; z_lut[119] = 8'd218;
	z_lut[120] = 8'd218; z_lut[121] = 8'd219; z_lut[122] = 8'd219; z_lut[123] = 8'd219; z_lut[124] = 8'd219;
	z_lut[125] = 8'd220; z_lut[126] = 8'd220; z_lut[127] = 8'd220; z_lut[128] = 8'd221; z_lut[129] = 8'd221;
	z_lut[130] = 8'd221; z_lut[131] = 8'd221; z_lut[132] = 8'd222; z_lut[133] = 8'd222; z_lut[134] = 8'd222;
	z_lut[135] = 8'd223; z_lut[136] = 8'd223; z_lut[137] = 8'd223; z_lut[138] = 8'd223; z_lut[139] = 8'd224;
	z_lut[140] = 8'd224; z_lut[141] = 8'd224; z_lut[142] = 8'd225; z_lut[143] = 8'd225; z_lut[144] = 8'd225;
	z_lut[145] = 8'd225; z_lut[146] = 8'd226; z_lut[147] = 8'd226; z_lut[148] = 8'd226; z_lut[149] = 8'd227;
	z_lut[150] = 8'd227; z_lut[151] = 8'd227; z_lut[152] = 8'd227; z_lut[153] = 8'd228; z_lut[154] = 8'd228;
	z_lut[155] = 8'd228; z_lut[156] = 8'd229; z_lut[157] = 8'd229; z_lut[158] = 8'd229; z_lut[159] = 8'd229;
	z_lut[160] = 8'd230; z_lut[161] = 8'd230; z_lut[162] = 8'd230; z_lut[163] = 8'd231; z_lut[164] = 8'd231;
	z_lut[165] = 8'd231; z_lut[166] = 8'd231; z_lut[167] = 8'd232; z_lut[168] = 8'd232; z_lut[169] = 8'd233;
	z_lut[170] = 8'd233; z_lut[171] = 8'd234; z_lut[172] = 8'd234; z_lut[173] = 8'd235; z_lut[174] = 8'd235;
	z_lut[175] = 8'd236; z_lut[176] = 8'd236; z_lut[177] = 8'd237; z_lut[178] = 8'd237; z_lut[179] = 8'd238;
	z_lut[180] = 8'd239; z_lut[181] = 8'd239; z_lut[182] = 8'd240; z_lut[183] = 8'd240; z_lut[184] = 8'd241;
	z_lut[185] = 8'd241; z_lut[186] = 8'd242; z_lut[187] = 8'd242; z_lut[188] = 8'd243; z_lut[189] = 8'd244;
	z_lut[190] = 8'd244; z_lut[191] = 8'd245; z_lut[192] = 8'd245; z_lut[193] = 8'd246; z_lut[194] = 8'd246;
	z_lut[195] = 8'd247; z_lut[196] = 8'd247; z_lut[197] = 8'd248; z_lut[198] = 8'd248; z_lut[199] = 8'd249;
	z_lut[200] = 8'd250; z_lut[201] = 8'd250; z_lut[202] = 8'd251; z_lut[203] = 8'd251; z_lut[204] = 8'd252;
	z_lut[205] = 8'd252; z_lut[206] = 8'd253; z_lut[207] = 8'd253; z_lut[208] = 8'd254; z_lut[209] = 8'd254;
	z_lut[210] = 8'd255; z_lut[211] = 8'd255; z_lut[212] = 8'd255; z_lut[213] = 8'd255; z_lut[214] = 8'd255;
	z_lut[215] = 8'd255; z_lut[216] = 8'd255; z_lut[217] = 8'd255; z_lut[218] = 8'd255; z_lut[219] = 8'd255;
	z_lut[220] = 8'd255; z_lut[221] = 8'd255; z_lut[222] = 8'd255; z_lut[223] = 8'd255; z_lut[224] = 8'd255;
	z_lut[225] = 8'd255; z_lut[226] = 8'd255; z_lut[227] = 8'd255; z_lut[228] = 8'd255; z_lut[229] = 8'd255;
	z_lut[230] = 8'd255; z_lut[231] = 8'd255; z_lut[232] = 8'd255; z_lut[233] = 8'd255; z_lut[234] = 8'd255;
	z_lut[235] = 8'd255; z_lut[236] = 8'd255; z_lut[237] = 8'd255; z_lut[238] = 8'd255; z_lut[239] = 8'd255;
	z_lut[240] = 8'd255; z_lut[241] = 8'd255; z_lut[242] = 8'd255; z_lut[243] = 8'd255; z_lut[244] = 8'd255;
	z_lut[245] = 8'd255; z_lut[246] = 8'd255; z_lut[247] = 8'd255; z_lut[248] = 8'd255; z_lut[249] = 8'd255;
	z_lut[250] = 8'd255; z_lut[251] = 8'd255; z_lut[252] = 8'd255; z_lut[253] = 8'd255; z_lut[254] = 8'd255;
	z_lut[255] = 8'd255;
end

	logic [8:0] base_intensity;
	logic [8:0] inertia_intensity;
	logic [7:0] conditioned_intensity;
	logic [16:0] linear_1_product;
	logic [16:0] linear_2_product;
	logic [7:0] linear_1_intensity;
	logic [7:0] linear_2_intensity;

	always_ff @(posedge clk_source) begin
		if (reset)
			beam_on_q <= 1'b0;
		else
			beam_on_q <= beam_on;
	end

	always_comb begin
		base_intensity = {1'b0, raw_intensity};
		inertia_intensity = (beam_on && !beam_on_q) ?
		                    base_intensity + (base_intensity >> 2) :
		                    base_intensity;
		conditioned_intensity = (inertia_intensity > 9'd255) ?
		                        8'd255 : inertia_intensity[7:0];

		linear_1_product = conditioned_intensity * 17'd311;
		linear_2_product = conditioned_intensity * 17'd389;
		linear_1_intensity = (conditioned_intensity >= 8'd210) ?
		                     8'd255 : linear_1_product[15:8];
		linear_2_intensity = (conditioned_intensity >= 8'd168) ?
		                     8'd255 : linear_2_product[15:8];

		case (tone_mapping)
			2'd0: mapped_intensity = linear_1_intensity;
			2'd1: mapped_intensity = linear_2_intensity;
			2'd2: mapped_intensity = z_lut[conditioned_intensity];
			default: mapped_intensity = conditioned_intensity;
		endcase
	end

endmodule
