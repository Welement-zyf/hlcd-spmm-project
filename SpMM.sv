`ifndef N
`define N              16
`endif
`define W               8
`define lgN     ($clog2(`N))
`define dbLgN (2*$clog2(`N))

typedef struct packed { logic [`W-1:0] data; } data_t;

module add_(
    input   logic   clock,
    input   data_t  a,
    input   data_t  b,
    output  data_t  out
);
    always_ff @(posedge clock) begin
        out.data <= a.data + b.data;
    end
endmodule

module mul_(
    input   logic   clock,
    input   data_t  a, 
    input   data_t  b,
    output  data_t out
);
    always_ff @(posedge clock) begin
        out.data <= a.data * b.data;
    end
endmodule



module SmallShiftReg #(
    parameter int T = 4 // 假设T>0
)(
    input   logic               clock,
                                reset,
    input   data_t              in,
    output  data_t              out
);
    data_t shift_reg [T-1:0];

    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < T; i = i+1) begin
                shift_reg[i].data <= 0;
            end
        end else begin
            shift_reg[0].data <= in.data;
            for (int i = 1; i < T; i = i+1) begin
                shift_reg[i].data <= shift_reg[i-1].data;
            end
        end
    end
    assign out = shift_reg[T-1];
    
endmodule


module AdderSwitch(
    input   logic               clock,
    input   data_t              a,         // 靠近加法树一端的输入
    input   data_t              b,         // 远离加法树一端的输入
    input   logic               addEn,     // 是否进入加法模式
    input   logic               bypassEn,  // 是否进入绕过模式
    output  data_t              mainOut,   // 加法树的输出路径
    output  data_t              viceOut    // 非加法树的输出路径
);
    always_ff @(posedge clock) begin
        if (addEn) begin
            mainOut.data <= a.data + b.data;
            viceOut.data <= a.data + b.data;
        end else if (bypassEn) begin
            // a和b的区别其实只在bypass的时候用到，而bypass只在第0层adder用到
            mainOut.data <= a.data;
            viceOut.data <= b.data;
        end else begin
            mainOut.data <= 0;
            viceOut.data <= 0;
        end
    end
endmodule


// 生成加法树的层数的组合逻辑
module AdderTreeLevel(
    output  logic [`lgN-1:0]    levels[`N-2:0]
);
    // level就是输入的这个数的二进制表示，末尾连续1的个数
    // 由于N是2的幂次，输入范围为0到N-2，所以level的范围是0到lgN-1
    // 我们使用独热码来表示level
    genvar level, adderIdx;
    generate
        for (level = 0; level < `lgN; level = level + 1) begin : AdderTreeLevel1
            if (level == 0) begin
                for (adderIdx=0; adderIdx<`N-1; adderIdx=adderIdx+2) begin : AdderTreeLevel1_lv0
                    assign levels[adderIdx] = 0;
                end                
            end
            else begin
                for (adderIdx=(1<<level)-1; adderIdx<`N-1; adderIdx=adderIdx+(1<<(level+1))) begin : AdderTreeLevel1_lv234
                    assign levels[adderIdx] = 1<<(level-1);
                end
            end
        end
    endgenerate

endmodule


// 搭建一个有N个输入的FAN模块
// 输入N个数据和每个数据要累加到的vecID
module FAN(
    input   logic               clock,
                                reset,
    input   data_t              vector[`N-1:0],        // 输入的N个数据
    input   logic [`lgN-1:0]    vecID[`N-1:0],         // 每个数据要累加到的vecID，属于哪个部分和
    output  data_t              out_data[`N*3/2-2:0],  // 可能的输出结果的位置
    output  logic [`lgN:0]      out_idx[`N-1:0]        // 这个部分和的结果在哪个adder下面找
);

    // 例化vectorID的shift reg
    genvar vecIDIdx;
    logic [`lgN-1:0] vecIDShiftReg[`lgN:1][`N-1:0]; // 第一个索引是shift reg的层数
    
    always_ff @(posedge clock) begin : vecIDShiftReg111
        if (reset) begin
            for (int i = 1; i < `lgN+1; i = i+1) begin
                for (int j = 0; j < `N; j = j+1) begin
                    vecIDShiftReg[i][j] <= 0;
                end
            end
        end else begin
            for (int i = 1; i < `lgN+1; i = i+1) begin
                for (int j = 0; j < `N; j = j+1) begin
                    if (i == 1) begin
                        vecIDShiftReg[i][j] <= vecID[j];
                    end else begin
                        vecIDShiftReg[i][j] <= vecIDShiftReg[i-1][j];
                    end
                end
            end
        end
    end
    // ------------------------------------------------------
    // 例化adder
    genvar level, adderIdx, jp;

    data_t adders_mainOut_ls [`N-2:0];
    data_t adders_viceOut_ls [`N-2:0];
    // level是从0到lgN-1，表示FAN中adder的层级
    generate 
        for (level = 0; level < `lgN; level = level + 1) begin : FAN1
            if (level == 0) begin: FAN1_lv0
                for (adderIdx=0; adderIdx<`N-1; adderIdx=adderIdx+2) begin 
                    AdderSwitch adderSwitch(
                        .clock(clock),
                        .a(vector[adderIdx+((adderIdx%4==0)?1:0)]),
                        .b(vector[adderIdx+((adderIdx%4==2)?1:0)]),
                        .addEn(vecID[adderIdx] == vecID[adderIdx+1]),
                        .bypassEn(vecID[adderIdx] != vecID[adderIdx+1]),
                        .mainOut(adders_mainOut_ls[adderIdx]),
                        .viceOut(adders_viceOut_ls[adderIdx])
                    );
                end
            end else if (level == 1) begin : FAN1_lv1
                for (adderIdx=1; adderIdx<`N-1; adderIdx=adderIdx+4) begin 
                    AdderSwitch adderSwitch(
                        .clock(clock),
                        .a(adders_mainOut_ls[adderIdx-1]),
                        .b(adders_mainOut_ls[adderIdx+1]),
                        .addEn(vecIDShiftReg[1][adderIdx] == vecIDShiftReg[1][adderIdx+1]),
                        .bypassEn(0),
                        .mainOut(adders_mainOut_ls[adderIdx]),
                        .viceOut(adders_viceOut_ls[adderIdx])
                    );
                end
            end else begin : FAN1_lv234
                for (adderIdx=(1<<level)-1; adderIdx<`N-1; adderIdx=adderIdx+(1<<(level+1))) begin : FAN1_lv234_idx
                    // 左边的mux前面的移位寄存器
                    data_t left_choices[level-2:0]; // 有level-1个选择
                    for (jp = 1; jp < level; jp = jp+1) begin
                        SmallShiftReg #(
                            .T(level-jp)
                        ) vecIDShiftRegReg(
                            .clock(clock),
                            .reset(reset),
                            .in(adders_viceOut_ls[adderIdx-(1<<(jp-1))]),
                            .out(left_choices[jp-1])
                        );
                    end
                    
                    // 左边的mux
                    data_t left;
                    always_comb begin : left_mux
                        left = adders_mainOut_ls[adderIdx-(1<<(level-1))];

                        for (int j = 1; j < level; j = j+1) begin
                            if (vecIDShiftReg[level][adderIdx-(1<<j)] != vecIDShiftReg[level][adderIdx]) begin
                                // left = adders_viceOut_ls[adderIdx-(1<<(j-1))];
                                left = left_choices[j-1];
                                break;
                            end
                        end
                    end

                    // 右边的mux前面的移位寄存器
                    data_t right_choices[level-2:0]; // 有level-1个选择
                    for (jp = 1; jp < level; jp = jp+1) begin
                        SmallShiftReg #(
                            .T(level-jp)
                        ) vecIDShiftRegReg(
                            .clock(clock),
                            .reset(reset),
                            .in(adders_viceOut_ls[adderIdx+(1<<(jp-1))]),
                            .out(right_choices[jp-1])
                        );
                    end

                    // 右边的mux
                    data_t right;
                    always_comb begin : right_mux
                        right = adders_mainOut_ls[adderIdx+(1<<(level-1))];

                        for (int j = 1; j < level; j = j+1) begin
                            if (vecIDShiftReg[level][adderIdx+(1<<j)+1] != vecIDShiftReg[level][adderIdx]) begin
                                // right = adders_viceOut_ls[adderIdx+(1<<(j-1))];
                                right = right_choices[j-1];
                                break;
                            end
                        end
                    end
                    
                    AdderSwitch adderSwitch(
                        .clock(clock),
                        .a(left),
                        .b(right),
                        .addEn(vecIDShiftReg[level][adderIdx] == vecIDShiftReg[level][adderIdx+1]),
                        .bypassEn(0),
                        .mainOut(adders_mainOut_ls[adderIdx]),
                        .viceOut(adders_viceOut_ls[adderIdx])
                    );
                end
            end
        end
    endgenerate


    // 例化adder的small shift reg，这是为了保证所有的adder同步，从而实现pipeline
    data_t adderReg_last_out[`N*3/2-2:0];

    // 我们一共弄3N/2-1个small shift reg (最后一层不需要)
    // 前面的N-1个是所有adder的main输出 (还需要注意最后一个adder不用reg)
    // 后面的N/2个是level 0的adder的vice输出

    assign adderReg_last_out[`N/2-1] = adders_mainOut_ls[`N/2-1];
    assign out_data[`N/2-1] = adderReg_last_out[`N/2-1];

    genvar levelp, adderRegIdx;
    generate
        // 第一部分：adderRegIdx从0到N-2，表示所有adder的main输出
        for (levelp = 0; levelp < `lgN-1; levelp = levelp + 1) begin : FAN2_1
            for (adderRegIdx=(1<<levelp)-1; adderRegIdx<`N-1; adderRegIdx=adderRegIdx+(1<<(levelp+1))) begin : FAN2_1p
                // logic [`lgN-1:0] adderReg_out_ls[`lgN-1:levelp+1];
                // always_ff @(posedge clock) begin
                //     if (reset) begin
                //         for (int i = levelp+1; i < `lgN; i = i+1) begin
                //             adderReg_out_ls[i] <= 0;
                //         end
                //     end else begin
                //         adderReg_out_ls[levelp+1] <= adders_mainOut_ls[adderRegIdx];
                //         for (int i = levelp+2; i < `lgN; i = i+1) begin
                //             adderReg_out_ls[i] <= adderReg_out_ls[i-1];
                //         end
                //     end
                // end
                // assign out_data[adderRegIdx] = adderReg_out_ls[`lgN-1];
                SmallShiftReg #(
                    .T(`lgN-1-levelp)
                ) adderReg(
                    .clock(clock),
                    .reset(reset),
                    .in(adders_mainOut_ls[adderRegIdx]),
                    .out(adderReg_last_out[adderRegIdx])
                );
                assign out_data[adderRegIdx] = adderReg_last_out[adderRegIdx];
            end
        end
    endgenerate
    generate
        // 第二部分：adderRegIdx从N-1到3N/2-1，表示level 0的adder的vice输出，记得要除以2
        for (adderRegIdx=`N-1; adderRegIdx<`N*3/2-1; adderRegIdx=adderRegIdx+1) begin : FAN2_2
            // logic [`lgN-1:0] adderReg_out_ls[`lgN-1:1];
            // always_ff @(posedge clock) begin
            //     if (reset) begin
            //         for (int i = 1; i < `lgN; i = i+1) begin
            //             adderReg_out_ls[i] <= 0;
            //         end
            //     end else begin
            //         adderReg_out_ls[1] <= adders_viceOut_ls[adderRegIdx-(`N-1)];
            //         for (int i = 2; i < `lgN; i = i+1) begin
            //             adderReg_out_ls[i] <= adderReg_out_ls[i-1];
            //         end
            //     end
            // end
            // assign out_data[adderRegIdx] = adderReg_out_ls[`lgN-1];
            SmallShiftReg #(
                .T(`lgN-1)
            ) adderReg(
                .clock(clock),
                .reset(reset),
                .in(adders_viceOut_ls[(adderRegIdx-(`N-1))*2]),
                .out(adderReg_last_out[adderRegIdx])
            );
            assign out_data[adderRegIdx] = adderReg_last_out[adderRegIdx];
        end
    endgenerate

    // 现在，怎么确定部分和结果应该在哪个中找？
    // 这怎么做？
    
    logic [`lgN-1:0] adder_tree_level[`N-2:0];
    AdderTreeLevel adderTreeLevel(.levels(adder_tree_level));

    logic [`lgN-1:0] out_idx_tmp [`N-1:0];
    always_comb begin
        for (int i = 0; i < `N; i = i+1) begin
            out_idx[i] = 0;
            out_idx_tmp[i] = 0;
        end

        for (int i = 0; i < `N; i = i+1) begin
            // 首先是只有一个元素的部分和
            if ((i==0 || vecIDShiftReg[`lgN][i] != vecIDShiftReg[`lgN][i-1]) && (i==`N-1 || vecIDShiftReg[`lgN][i] != vecIDShiftReg[`lgN][i+1])) begin
                if (i % 4 == 0) begin
                    out_idx[vecIDShiftReg[`lgN][i]] = (`N-1) + i/2; // ith vice output
                end
                else if (i % 4 == 1) begin
                    out_idx[vecIDShiftReg[`lgN][i]] = i - 1; // (i-1)th main output
                end
                else if (i % 4 == 2) begin
                    out_idx[vecIDShiftReg[`lgN][i]] = i; // ith main output
                end
                else begin
                    out_idx[vecIDShiftReg[`lgN][i]] = (`N-1)+ (i - 1)/2; // (i-1)th vice output
                end
            end

            // 多个元素的部分和
            else begin
                // if (out_idx[vecIDShiftReg[`lgN][i]] != 0) begin
                //     continue;
                // end
                if (out_idx_tmp[i] != 0) begin
                    continue;
                end
                out_idx_tmp[i] = 0;
                out_idx[vecIDShiftReg[`lgN][i]] = 0;
                for (int j = i+1; j < `N; j = j+1) begin
                    if (vecIDShiftReg[`lgN][j] == vecIDShiftReg[`lgN][i]) begin
                        if (adder_tree_level[j-1] >= adder_tree_level[out_idx_tmp[j-1]]) begin
                            out_idx_tmp[j] = j-1;
                            out_idx[vecIDShiftReg[`lgN][i]] = j-1;
                        end
                        else begin
                            out_idx_tmp[j] = out_idx_tmp[j-1];
                        end
                    end
                    else begin
                        out_idx[vecIDShiftReg[`lgN][i]] = out_idx_tmp[j-1];
                        break;
                    end
                end
            end
        end
    end



endmodule







module RedUnit(
    input   logic               clock,
                                reset,
    input   data_t              data[`N-1:0],
    input   logic               split[`N-1:0],
    input   logic [`lgN-1:0]    out_idx[`N-1:0],
    output  data_t              out_data[`N-1:0],
    // output  logic [`lgN-1:0]    halo_idx,   // halo输出的位置
    output  data_t              halo_data,  // halo输出的数据
    output  int                 delay,
    output  int                 num_el
);
    // num_el 总是赋值为 N
    assign num_el = `N;
    // delay 你需要自己为其赋值，表示电路的延迟
    assign delay = `lgN;

    // out_idx要存下来，因为FAN的输出是有延迟的，所以我们要使用一个small shift reg
    genvar out_idx_RegIdx;
    logic [`lgN-1:0] out_idx_Reg_out[`N-1:0];
    generate
        for (out_idx_RegIdx=0; out_idx_RegIdx<`N; out_idx_RegIdx=out_idx_RegIdx+1) begin : out_idx_Reg
            SmallShiftReg #(
                .T(`lgN)
            ) out_idx_Reg(
                .clock(clock),
                .reset(reset),
                .in(out_idx[out_idx_RegIdx]),
                .out(out_idx_Reg_out[out_idx_RegIdx])
            );
        end
    endgenerate

    // split也要存下来
    genvar split_RegIdx;
    logic split_Reg_out[`N-1:0];
    generate
        for (split_RegIdx=0; split_RegIdx<`N; split_RegIdx=split_RegIdx+1) begin : split_Reg
            SmallShiftReg #(
                .T(`lgN)
            ) split_Reg(
                .clock(clock),
                .reset(reset),
                .in(split[split_RegIdx]),
                .out(split_Reg_out[split_RegIdx])
            );
        end
    endgenerate


    // ------------------------------------------------------
    logic [`lgN-1:0]    FAN_vecID[`N-1:0];
    data_t              FAN_out_data[`N*3/2-2:0];
    logic [`lgN:0]      FAN_out_idx[`N-1:0];

    // 先根据split计算FAN_vecID
    // 第0个的vecID是0，如果split[i]为1，那么vecID[i+1] = vecID[i] + 1
    always_comb begin
        FAN_vecID[0] = 0;
        for (int i = 1; i < `N; i = i+1) begin
            FAN_vecID[i] = FAN_vecID[i-1] + (split[i-1]?1:0);
        end
    end

    logic [`lgN-1:0]    FAN_vecID_late[`N-1:0];
    always_comb begin
        FAN_vecID_late[0] = 0;
        for (int i = 1; i < `N; i = i+1) begin
            FAN_vecID_late[i] = FAN_vecID_late[i-1] + (split_Reg_out[i-1]?1:0);
        end
    end

    FAN fan(
        .clock(clock),
        .reset(reset),
        .vector(data),
        .vecID(FAN_vecID),
        .out_data(FAN_out_data),
        .out_idx(FAN_out_idx)
    );

    

    // 现在，把FAN的输出和RedUnit对应起来
    always_comb begin
        for (int i = 0; i < `N; i = i+1) begin
            if (split_Reg_out[out_idx_Reg_out[i]] == 1) begin
                out_data[i] = FAN_out_data[FAN_out_idx[FAN_vecID_late[out_idx_Reg_out[i]]]];
            end
            else begin
                out_data[i] = 0;
            end
        end
    end

    always_comb begin
        // 最后一段是和之后的结果相加的，部分和结果存储在halo_data里
        if (split_Reg_out[`N-1] == 0) begin
            halo_data = FAN_out_data[FAN_out_idx[FAN_vecID_late[`N-1]]];
        end
        // 最后一段数据已经是正确数据了，不用halo
        else begin
            halo_data = 0;
        end
    end

endmodule






module PE(
    input   logic               clock,
                                reset,
    input   logic               lhs_start,
    input   logic [`dbLgN-1:0]  lhs_ptr [`N-1:0],
    input   logic [`lgN-1:0]    lhs_col [`N-1:0],
    input   data_t              lhs_data[`N-1:0],
    input   data_t              rhs[`N-1:0],
    output  data_t              out[`N-1:0],
    output  int                 delay,
    output  int                 num_el
);
    // num_el 总是赋值为 N
    assign num_el = `N;
    // delay 你需要自己为其赋值，表示电路的延迟
    // assign delay = 0;
    assign delay = `lgN+2;

    // ------------------------------------------------------
    // 计时器
    logic [31:0] counter;
    always_ff @(posedge clock) begin
        if (reset || lhs_start) begin
            counter <= 0;
        end else begin
            counter <= counter + 1;
        end
    end

    logic [31:0] compute_dalay;
    always_ff @(posedge clock) begin
        if (reset) begin
            compute_dalay <= 0;
        end else begin
            if (lhs_start) begin
                compute_dalay <= lhs_ptr[`N-1]/`N + 1;
            end
        end
    end

    // 将lhs_ptr存下来，只有在lhs_start的时候才更新
    logic [`dbLgN-1:0] lhs_ptr_Reg_out[`N-1:0];
    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < `N; i = i+1) begin
                lhs_ptr_Reg_out[i] <= 0;
            end
        end else begin
            if (lhs_start) begin
                for (int i = 0; i < `N; i = i+1) begin
                    lhs_ptr_Reg_out[i] <= lhs_ptr[i];
                end    
            end
            else begin
                for (int i = 0; i < `N; i = i+1) begin
                    lhs_ptr_Reg_out[i] <= lhs_ptr_Reg_out[i];
                end
            end
        end
    end

    // 首先实现XBAR模块
    data_t product_b[`N-1:0];
    // 根据lhs_col在rhs找到对应的数据
    always_comb begin : XBAR
        for (int i = 0; i < `N; i = i+1) begin
            product_b[i] = rhs[lhs_col[i]];
        end
    end

    // 然后实现MUL模块
    genvar mulIdx;
    data_t mul_out[`N-1:0];
    generate
        for (mulIdx=0; mulIdx<`N; mulIdx=mulIdx+1) begin : mul
            mul_ mul(
                .clock(clock),
                .a(lhs_data[mulIdx]),
                .b(product_b[mulIdx]),
                .out(mul_out[mulIdx])
            );
        end
    endgenerate


    // 根据lhs_ptr_Reg_out来计算出split和out_idx
    logic split[`N-1:0];
    logic [`lgN-1:0] out_idx[`N-1:0];
    // logic not_split_index;
    always_comb begin : split_and_out_idx
        // not_split_index = 0;
        for (int i = 0; i < `N; i = i+1) begin
            split[i] = 0;
            out_idx[i] = i;
        end
        for (int i = 0; i < `N; i = i+1) begin
            if (lhs_ptr_Reg_out[i]>=counter*`N && lhs_ptr_Reg_out[i]<(counter+1)*`N && (i==0 || lhs_ptr_Reg_out[i]!=lhs_ptr_Reg_out[i-1])) begin
                split[lhs_ptr_Reg_out[i]- counter*`N] = 1;
            end
        end
        for (int i = 0; i < `N; i = i+1) begin
            if (split[i] == 0) begin
                for (int j = 0; j < `N; j = j+1) begin
                    if (lhs_ptr_Reg_out[j]>=counter*`N && lhs_ptr_Reg_out[j]<(counter+1)*`N && (j==0 || lhs_ptr_Reg_out[j]!=lhs_ptr_Reg_out[j-1])) begin
                    end
                    else begin
                        out_idx[j] = i;
                    end
                end
                // not_split_index = i;
                break;
            end
        end
        for (int i = 0; i < `N; i = i+1) begin
            if (lhs_ptr_Reg_out[i]>=counter*`N && lhs_ptr_Reg_out[i]<(counter+1)*`N && (i==0 || lhs_ptr_Reg_out[i]!=lhs_ptr_Reg_out[i-1])) begin
                out_idx[i] = lhs_ptr_Reg_out[i] - counter*`N;
            end else begin
                // out_idx[i] = not_split_index; // 没用的数据都放在not_split_index里
            end
        end
    end

    logic [`lgN-1:0] halo_idx;
    always_comb begin
        halo_idx = 0;
        for (int i = 0; i < `N; i = i+1) begin
            if (i<`N-1 && lhs_ptr_Reg_out[i]<(counter-`lgN+1)*`N && lhs_ptr_Reg_out[i+1]>=(counter-`lgN+1)*`N) begin
                // halo_idx = lhs_ptr_Reg_out[i+1] - (counter-`lgN+2)*`N;
                halo_idx = i+1;
                break;
            end
        end
    end

    data_t redUnit_out_data [`N-1:0];
    data_t redUnit_halo_data;
    RedUnit redUnit(
        .clock(clock),
        .reset(reset),
        .data(mul_out),
        .split(split),
        .out_idx(out_idx),
        .out_data(redUnit_out_data),
        .halo_data(redUnit_halo_data),
        .delay(),
        .num_el()
    );

    logic halo_valid;
    always_ff @(posedge clock) begin
        if (reset) begin
            halo_valid <= 0;
        end else begin
            if (counter == `lgN-1) begin
                halo_valid <= 1;
            end else begin
                if (counter == `lgN+compute_dalay) begin
                    halo_valid <= 0;
                end
            end
        end
    end

    // 最后，将redUnit的输出赋值给out
    data_t reg_for_out[`N-1:0];
    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < `N; i = i+1) begin
                reg_for_out[i] <= 0;
            end
        end else begin
            for (int i = 0; i < `N; i = i+1) begin
                if (lhs_start) begin
                    reg_for_out[i] <= 0;
                end
                else if (i == halo_idx && halo_idx != 0 && redUnit_halo_data != 0 && halo_valid) begin
                    reg_for_out[i] <= redUnit_halo_data;
                end
                else begin
                    reg_for_out[i] <= redUnit_out_data[i] + reg_for_out[i];
                end
            end
        end
    end

    assign out = reg_for_out;

endmodule

module SpMM(
    input   logic               clock,
                                reset,
    /* 输入在各种情况下是否 ready */
    output  logic               lhs_ready_ns,
                                lhs_ready_ws,
                                lhs_ready_os,
                                lhs_ready_wos,
    input   logic               lhs_start,
    /* 如果是 weight-stationary, 这次使用的 rhs 将保留到下一次 */
                                lhs_ws,
    /* 如果是 output-stationary, 将这次的结果加到上次的 output 里 */
                                lhs_os,
    input   logic [`dbLgN-1:0]  lhs_ptr [`N-1:0],
    input   logic [`lgN-1:0]    lhs_col [`N-1:0],
    input   data_t              lhs_data[`N-1:0],
    output  logic               rhs_ready,
    input   logic               rhs_start,
    input   data_t              rhs_data [3:0][`N-1:0],
    output  logic               out_ready,
    input   logic               out_start,
    output  data_t              out_data [3:0][`N-1:0],
    output  int                 num_el
);
    // num_el 总是赋值为 N
    assign num_el = `N;

    // ------------------------------------------------------
    // rhs的控制逻辑
    logic rhs_buf_not_empty;
    logic rhs_buf_ws_not_empty; // 用于weight stationary，只要有一个rhs就是1
    logic rhs_buf_produce_ptr;
    logic rhs_buf_consume_ptr;
    always_ff @(posedge clock) begin
        if (reset) begin
            rhs_buf_not_empty <= 0;
            rhs_buf_produce_ptr <= 0;
            rhs_buf_consume_ptr <= 0;
            rhs_buf_ws_not_empty <= 0;
        end else begin
            // 输入了一个rhs
            if (`N == 4) begin
                if (rhs_start) begin
                    rhs_buf_produce_ptr <= ~rhs_buf_produce_ptr;
                    rhs_buf_not_empty <= 1;
                    rhs_buf_ws_not_empty <= 1; // 以后不会变成0
                end
            end 
            else if (rhs_reg_move && rhs_input_counter == `N/4-1) begin
                rhs_buf_produce_ptr <= ~rhs_buf_produce_ptr;
                rhs_buf_not_empty <= 1;
                rhs_buf_ws_not_empty <= 1; // 以后不会变成0
            end
            
            // 计算消耗了一个rhs
            if (!lhs_ws && compute_busy && compute_counter == `lgN+compute_dalay) begin
                // 先把上次的rhs标记为使用完了，要是之后有weight stationary再改回去
                rhs_buf_consume_ptr <= ~rhs_buf_consume_ptr;
                // 如果同时还进来一个rhs，那么就不是empty
                if (~rhs_buf_consume_ptr == rhs_buf_produce_ptr && !(rhs_reg_move && rhs_input_counter == `N/4-1)) begin
                    rhs_buf_not_empty <= 0;
                end
            end
        end
    end

    // rhs的buffer中有空位0并且rhs的不是正在输入
    assign rhs_ready = ~rhs_input_busy && (~rhs_buf_not_empty || (rhs_buf_produce_ptr != rhs_buf_consume_ptr));

    logic rhs_input_busy;
    always_ff @(posedge clock) begin
        if (reset) begin
            rhs_input_busy <= 0;
        end
        else if (`N != 4 && rhs_start) begin
            rhs_input_busy <= 1;
        end
        else if (rhs_reg_move && rhs_input_counter == `N/4-1) begin // rhs的输入完成
            rhs_input_busy <= 0;
        end
    end

    logic rhs_reg_move;
    logic [31:0] rhs_input_counter;
    always_ff @(posedge clock) begin
        if (reset) begin
            rhs_reg_move <= 0;
            rhs_input_counter <= 0;
        end else begin
            if (`N != 4 && rhs_start) begin
                rhs_reg_move <= 1;
                rhs_input_counter <= 1;
            end else begin
                if (rhs_reg_move) begin
                    if (rhs_input_counter == `N/4-1) begin
                        rhs_reg_move <= 0;
                    end
                    else begin
                        rhs_input_counter <= rhs_input_counter + 1;
                    end
                end
                else begin
                    rhs_reg_move <= 0;
                    rhs_input_counter <= 0;
                end
            end
        end
    end

    data_t rhs_data_reg[1:0][3:0][`N/4-1:0][`N-1:0];
    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < 4; i = i+1) begin
                for (int j = 0; j < `N/4; j = j+1) begin
                    for (int k = 0; k < `N; k = k+1) begin
                        rhs_data_reg[0][i][j][k] <= 0;
                        rhs_data_reg[1][i][j][k] <= 0;
                    end
                end
            end
        end else begin
            for (int i = 0; i < 4; i = i+1) begin
                if (rhs_start || rhs_reg_move) begin
                    rhs_data_reg[rhs_buf_produce_ptr][i][`N/4-1] <= rhs_data[i];
                    for (int j = 0; j < `N/4-1; j = j+1) begin
                        rhs_data_reg[rhs_buf_produce_ptr][i][j] <= rhs_data_reg[rhs_buf_produce_ptr][i][j+1];
                    end
                end
            end
        end
    end

    // ------------------------------------------------------
    // lhs和compute的控制逻辑
    logic [31:0] compute_dalay;
    always_ff @(posedge clock) begin
        if (reset) begin
            compute_dalay <= 0;
        end else begin
            if (lhs_start) begin
                compute_dalay <= lhs_ptr[`N-1]/`N + 1;
            end
        end
    end

    logic compute_busy;
    always_ff @(posedge clock) begin
        if (reset) begin
            compute_busy <= 0;
        end else begin
            if (lhs_start) begin
                compute_busy <= 1;
            end else begin
                if (compute_counter == `lgN+compute_dalay) begin
                    compute_busy <= 0;
                end
            end
        end
    end

    logic [31:0] compute_counter;
    always_ff @(posedge clock) begin
        if (reset) begin
            compute_counter <= 0;
        end else begin
            if (lhs_start) begin
                compute_counter <= 0;
            end else begin
                if (compute_busy) begin
                    compute_counter <= compute_counter + 1;
                end
            end
        end
    end
    
    assign lhs_ready_ns = ~compute_busy && rhs_buf_not_empty && (~out_buf_not_empty || out_buf_produce_ptr != out_buf_consume_ptr);
    assign lhs_ready_ws = ~compute_busy && rhs_buf_ws_not_empty && (~out_buf_not_empty || out_buf_produce_ptr != out_buf_consume_ptr);
    assign lhs_ready_os = ~compute_busy && rhs_buf_not_empty;
    assign lhs_ready_wos = lhs_ready_ws || lhs_ready_os;

    // ------------------------------------------------------
    // out的控制逻辑
    logic out_buf_not_empty;
    logic out_buf_produce_ptr;
    logic out_buf_consume_ptr;
    always_ff @(posedge clock) begin
        if (reset) begin
            out_buf_not_empty <= 0;
            out_buf_produce_ptr <= 0;
            out_buf_consume_ptr <= 0;
        end else begin
            if (compute_busy && compute_counter == `lgN+compute_dalay) begin
                out_buf_produce_ptr <= ~out_buf_produce_ptr;
                out_buf_not_empty <= 1;
            end

            if (lhs_start && lhs_os) begin // output-stationary
                // 产生指针还得变回去
                out_buf_produce_ptr <= ~out_buf_produce_ptr;
                if (~out_buf_consume_ptr == out_buf_produce_ptr) begin
                    out_buf_not_empty <= 0;
                end
                // out_buf_not_empty <= 1;
            end

            if ((out_start && `N == 4) || out_busy && out_counter == `N/4-1) begin
                out_buf_consume_ptr <= ~out_buf_consume_ptr;
            // 如果out结束的时候，正好又有一个out被计算好了，那么接下来就不是空
                if (~out_buf_consume_ptr == out_buf_produce_ptr && !(compute_busy && compute_counter == `lgN+compute_dalay)) begin
                    out_buf_not_empty <= 0;
                end
            end
        end
    end

    logic out_busy;
    always_ff @(posedge clock) begin
        if (reset) begin
            out_busy <= 0;
        end else begin
            if (`N != 4 && out_start) begin
                out_busy <= 1;
            end else begin
                if (out_busy && out_counter == `N/4-1) begin
                    out_busy <= 0;
                end
            end
        end
    end

    logic[31:0] out_counter;
    always_ff @(posedge clock) begin
        if (reset) begin
            out_counter <= 0;
        end else begin
            if (`N != 4 && out_start) begin
                out_counter <= 1;
            end else begin
                if (out_busy) begin
                    out_counter <= out_counter + 1;
                end
                else begin
                    out_counter <= 0;
                end
            end
        end
    end

    data_t out_data_reg[1:0][`N-1:0][`N-1:0];
    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < `N; i = i+1) begin
                for (int j = 0; j < `N; j = j+1) begin
                    out_data_reg[0][i][j] <= 0;
                    out_data_reg[1][i][j] <= 0;
                end
            end
        end else begin
            if (compute_busy && compute_counter == `lgN+compute_dalay) begin
                for (int i = 0; i < `N; i = i+1) begin
                    for (int j = 0; j < `N; j = j+1) begin
                        if (lhs_os) begin
                            out_data_reg[out_buf_produce_ptr][i][j] <= out_data_reg[out_buf_consume_ptr][i][j] + pe_out[i][j];
                        end
                        else begin
                            out_data_reg[out_buf_produce_ptr][i][j] <= pe_out[i][j];
                        end
                    end
                end
            end
        end
    end

    // 如果只有一个矩阵，且被output-stationary，那么out_ready就被占用了，不行了
    // assign out_ready = ~out_busy && out_buf_not_empty && (!lhs_os || (lhs_os && (out_buf_produce_ptr == out_buf_consume_ptr)));
    assign out_ready = ~out_busy && out_buf_not_empty;

    genvar outIdx, ii;
    generate
        for (outIdx=0; outIdx<4; outIdx=outIdx+1) begin : out
            for (ii=0; ii<`N; ii=ii+1) begin
                assign out_data[outIdx][ii] = out_data_reg[out_buf_consume_ptr][ii][out_counter*4+outIdx];
            end
        end
    endgenerate


    // ------------------------------------------------------
    data_t rhs_transpose[`N-1:0][`N-1:0];
    genvar x1, x2;
    generate
        for (x1=0; x1<`N; x1=x1+1) begin : transpose
            for (x2=0; x2<`N; x2=x2+1) begin
                assign rhs_transpose[x1][x2] = rhs_data_reg[rhs_buf_consume_ptr][x2%4][x2/4][x1];
            end
        end
    endgenerate


    // 例化PE

    genvar peIdx;
    data_t pe_out [`N-1:0][`N-1:0];
    generate
        for (peIdx=0; peIdx<`N; peIdx=peIdx+1) begin : PE
            PE pe(
                .clock(clock),
                .reset(reset),
                .lhs_start(lhs_start),
                .lhs_ptr(lhs_ptr),
                .lhs_col(lhs_col),
                .lhs_data(lhs_data),
                // .rhs(rhs_data_reg[rhs_buf_consume_ptr][peIdx%4][peIdx/4]),
                .rhs(rhs_transpose[peIdx]),
                .out(pe_out[peIdx]),
                .delay(),
                .num_el()
            );
        end
    endgenerate

    // assign lhs_ready_ns = 0;
    // assign lhs_ready_ws = 0;
    // assign lhs_ready_os = 0;
    // assign lhs_ready_wos = 0;
    // assign rhs_ready = 0;
    // assign out_ready = 0;
endmodule
