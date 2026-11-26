classdef GridEnv < handle
    % GRIDENV (V16.1 - 终极物理大锁 & EDG柔性基荷 & 拓扑全息追踪版)
    % =====================================================================
    % [物理大锁 V15.0] 彻底删除作弊软惩罚，引入 P_Act <= P_Cmd 绝对物理死锁。
    % [单位对齐 V15.1] 修复 Python 传回 MW 未除以 BASE_MVA 导致的强充强放 Bug。
    % [基荷修复 V16.0] 引入 P_EDG_Act 变量，允许应急柴发降功率运行，彻底消灭
    %                  低谷期由于"满发强制注入"引发的 Infeasible 白色宕机现象。
    % [拓扑追踪] 保留原始连通分量标签供 MATLAB 使用，并导出 Python 专用
    %            Area ID：主网为 0，独立孤岛为 1..N。
    % =====================================================================

    properties (Constant)
        BASE_MVA = 10;          
        P_GRID_MAX = 0.2;       
        
        V_MIN = 0.90;           
        V_MAX = 1.10;           
        
        WEIGHT_ESSENTIAL = 1000; 
        WEIGHT_ORDINARY = 1;     
        
        PENALTY_VOLTAGE = 1e5;   
        
        MESS_POWER_LIMIT = 0.5;  
        EV_SLACK_LIMIT = 0.3;    
    end

    properties (SetAccess = private)
        mpc
        NB; NL; NT
        Branch_From; Branch_To; Branch_R; Branch_X;
        Load_Active_Base; Load_Reactive_Base;
        Curve_Essential; Curve_Ordinary; Curve_PV;
        Idx_Essential; Idx_Ordinary; Idx_PV; Idx_EV;
        Idx_EDG; Idx_EDG_Cap; 
        
        Line_Status_Daily   
        Reconfig_Plan       
        MESS_Schedule       
        
        EDG_Records_Daily 
        EV_Avail_Daily      
        
        Area_ID_Daily       % MATLAB 原始 conncomp labels；仅供内部拓扑/MILP 语义使用
        Python_Area_ID_Daily % Python contract: main grid=0, islands=1..N
        
        Abs_Data_Dir 
        
        Optimizers = cell(1, 24);
        Is_Compiled = false;
    end

    methods
        function obj = GridEnv()
            current_class_dir = fileparts(mfilename('fullpath'));
            obj.Abs_Data_Dir = fullfile(current_class_dir, '..', 'Data');
            addpath(obj.Abs_Data_Dir); 
            
            obj.mpc = IEEE69;
            obj.NB = size(obj.mpc.bus, 1);
            obj.NL = size(obj.mpc.branch, 1);
            obj.NT = 24;
            
            obj.EDG_Records_Daily = zeros(obj.NB, obj.NT);
            obj.Area_ID_Daily = ones(obj.NB, obj.NT);
            obj.Python_Area_ID_Daily = zeros(obj.NB, obj.NT);
            
            obj.Branch_From = obj.mpc.branch(:, 1);
            obj.Branch_To = obj.mpc.branch(:, 2);
            obj.Branch_R = obj.mpc.branch(:, 3);
            obj.Branch_X = obj.mpc.branch(:, 4);
            
            obj.Load_Active_Base = obj.mpc.bus(:, 3) / obj.BASE_MVA;
            obj.Load_Reactive_Base = obj.mpc.bus(:, 4) / obj.BASE_MVA;
            
            obj.load_external_data();
            obj.load_scenario_and_strategy();
            
            fprintf('GridEnv (V16.1 Ultimate Lock & EDG Flex & Area Tracker) 初始化...\n');
            obj.build_optimizers();
        end

        function load_external_data(obj)
            d_idx = load('index.mat');
            obj.Idx_Essential = d_idx.essential_users;
            obj.Idx_Ordinary = d_idx.ordinary_users;
            obj.Idx_PV = d_idx.O_PV;
            obj.Idx_EV = d_idx.O_E;
            
            if isfield(d_idx, 'O_EDG')
                obj.Idx_EDG = d_idx.O_EDG;
                obj.Idx_EDG_Cap = d_idx.O_EDG_CAP;
            else
                obj.Idx_EDG = []; obj.Idx_EDG_Cap = [];
            end
            
            d_curve = load('curve.mat');
            obj.Curve_Essential = d_curve.essential_load;
            obj.Curve_Ordinary = d_curve.ordinary_load;
            obj.Curve_PV = d_curve.pv_curve;
             
             % =========================================================
             % [V16.2 DRO 边界同步修复] 彻底废除 18-8 的硬编码死锁
             % 完美复刻 Python 层 WorstCaseSampler 的分布鲁棒最劣极值边界
             % =========================================================
             abs_mu_arr = 15.0; sigma_arr = 1.5;
             abs_mu_dep = 33.0; sigma_dep = 1.0;
             rho = 0.5; 
             
             % 解析计算最恶劣情况的绝对物理时间
             raw_arr_abs = abs_mu_arr + rho * sigma_arr; % 15.75 (最晚到达)
             raw_dep_abs = abs_mu_dep - rho * sigma_dep; % 32.50 (即次日 8.5，最早离开)
             
             % 将绝对时间映射到 24 小时制
             arr_mod = mod(raw_arr_abs, 24);
             dep_mod = mod(raw_dep_abs, 24);
             
             if isfield(d_curve, 'START_HOUR'), sh = d_curve.START_HOUR; end
             obj.EV_Avail_Daily = zeros(3, obj.NT);
             
             for t = 1:obj.NT
                 t_mod = mod(sh + t - 1, 24); 
                 
                 is_avail = false;
                 if arr_mod > dep_mod 
                     % 跨日挂网判定 (例如 15.75 到次日 8.5)
                     if (t_mod >= arr_mod) || (t_mod < dep_mod)
                         is_avail = true;
                     end
                 else 
                     % 日间挂网判定
                     if (t_mod >= arr_mod) && (t_mod < dep_mod)
                         is_avail = true;
                     end
                 end
                 
                 if is_avail
                     obj.EV_Avail_Daily(:, t) = 1;
                 end
             end
        end

        function [P_L, Q_L, P_PV] = get_snapshot_state(obj, t)
            LOAD_SCALE = 0.9; 
            P_L = zeros(obj.NB, 1); Q_L = zeros(obj.NB, 1); P_PV = zeros(obj.NB, 1);
            P_L(obj.Idx_Essential) = obj.Load_Active_Base(obj.Idx_Essential) * obj.Curve_Essential(t) * LOAD_SCALE;
            Q_L(obj.Idx_Essential) = obj.Load_Reactive_Base(obj.Idx_Essential) * obj.Curve_Essential(t) * LOAD_SCALE;
            
            P_L(obj.Idx_Ordinary) = obj.Load_Active_Base(obj.Idx_Ordinary) * obj.Curve_Ordinary(t) * LOAD_SCALE;
            Q_L(obj.Idx_Ordinary) = obj.Load_Reactive_Base(obj.Idx_Ordinary) * obj.Curve_Ordinary(t) * LOAD_SCALE;
            
            P_PV(obj.Idx_PV) = 0.5 * obj.Curve_PV(t) / obj.BASE_MVA; 
        end

        function load_scenario_and_strategy(obj)
            d_scen = load(fullfile(obj.Abs_Data_Dir, 'scenario.mat'));
            obj.Line_Status_Daily = d_scen.Line_Status_Daily;
            
            d_strat = load(fullfile(obj.Abs_Data_Dir, 'strategy.mat'));
            obj.Reconfig_Plan = d_strat.Reconfig_Plan;
            obj.MESS_Schedule = d_strat.MESS_Schedule;
        end

        function build_optimizers(obj)
            fprintf('   -> [System] 正在编译 24 个时段的 MILP 潮流求解器 (Pre-compiling)...\n');
            tic;
            solver = getenv('STACKELBERG_SOLVER');
            if isempty(solver), solver = 'linprog'; end
            ops = sdpsettings('solver', solver, 'verbose', 0, 'savesolveroutput', 0);
            
            for t = 1:obj.NT
                status = [obj.Line_Status_Daily(1:obj.NL-5, t); 
                          obj.Line_Status_Daily(obj.NL-4:obj.NL, t) & obj.Reconfig_Plan(:, t)];
                active_lines = find(status == 1);
                
                mess_nodes_t = obj.MESS_Schedule(:, t);
                [P_L_val, Q_L_val, P_PV_val] = obj.get_snapshot_state(t);
                
                G = graph(obj.Branch_From(active_lines), obj.Branch_To(active_lines), [], obj.NB);
                bins = conncomp(G); 
                num_islands = max(bins);
                
                % Preserve raw labels for MATLAB optimization.  CONNCOMP label
                % numbers are not a cross-language semantic contract.
                obj.Area_ID_Daily(:, t) = bins'; 
                % Python training defines 0 as grid-connected and positive
                % values as distinct islands.  Bus 1 is the grid/PCC component.
                obj.Python_Area_ID_Daily(:, t) = map_area_ids_for_python(bins');
                
                mask_v_ref = false(obj.NB, 1);
                for isl = 1:num_islands
                    nodes_in_isl = find(bins == isl);
                    if ismember(1, nodes_in_isl)
                        mask_v_ref(1) = true;
                    else
                        mask_v_ref(nodes_in_isl(1)) = true; 
                    end
                end
                
                P_Cmd_MESS_Pos = sdpvar(2, 1); P_Cmd_MESS_Neg = sdpvar(2, 1);
                P_Cmd_EV_Pos = sdpvar(3, 1); P_Cmd_EV_Neg = sdpvar(3, 1);
                Price_t = sdpvar(1, 1);
                
                u_in = sdpvar(15, 1); 
                
                assign_constr = [
                    P_Cmd_MESS_Pos == u_in(1:2);
                    P_Cmd_MESS_Neg == u_in(3:4);
                    P_Cmd_EV_Pos == u_in(5:7);
                    P_Cmd_EV_Neg == u_in(8:10);
                    Price_t == u_in(11);
                ];
                
                % Topology fixes every indicator before solving; no integer
                % decisions remain in the per-hour dispatch problem.
                Island_Shed_Indicator = zeros(num_islands, 1);
                P_shed = sdpvar(obj.NB, 1); Q_shed = sdpvar(obj.NB, 1);
                V_sqr  = sdpvar(obj.NB, 1);
                P_flow = sdpvar(obj.NL, 1); Q_flow = sdpvar(obj.NL, 1);
                P_spill = sdpvar(obj.NB, 1);      
                Slack_V_Low = sdpvar(obj.NB, 1); Slack_V_High = sdpvar(obj.NB, 1); 
                P_Grid = sdpvar(1, 1); Q_Grid = sdpvar(1, 1);
                
                P_MESS_Act_Pos = sdpvar(2, 1); P_MESS_Act_Neg = sdpvar(2, 1);
                P_EV_Act_Pos = sdpvar(3, 1); P_EV_Act_Neg = sdpvar(3, 1);
                
                % [V16.0 核心修复] 将 EDG 有功出力改为决策变量，防止死锁
                P_EDG_Act = sdpvar(length(obj.Idx_EDG), 1);
                Q_EDG_Act = sdpvar(length(obj.Idx_EDG), 1);
                
                P_Miss_Charge_MESS = sdpvar(2, 1);
                P_Miss_Charge_EV = sdpvar(3, 1);
                
                C = assign_constr;
                
                mask_live = false(obj.NB, 1);
                
                for k = 1:num_islands
                    nodes = find(bins == k);
                    has_gen = ismember(1, nodes) || any(ismember(obj.Idx_EDG, nodes));
                    Island_Shed_Indicator(k) = ~has_gen;
                    mask_live(nodes) = has_gen;
                end
                
                for i = 1:obj.NB
                    if mask_live(i)
                        isl = bins(i);
                        C = [C, 0 <= P_shed(i) <= P_L_val(i)];
                        C = [C, 0 <= Q_shed(i) <= Q_L_val(i)];
                        
                        C = [C, P_shed(i) >= P_L_val(i) * Island_Shed_Indicator(isl)];
                        C = [C, Q_shed(i) >= Q_L_val(i) * Island_Shed_Indicator(isl)];
                        
                        C = [C, 0 <= P_spill(i) <= P_PV_val(i)];
                        
                        v_min_sqr = obj.V_MIN^2; v_max_sqr = obj.V_MAX^2;
                        C = [C, v_min_sqr - Slack_V_Low(i) <= V_sqr(i) <= v_max_sqr + Slack_V_High(i)];
                        C = [C, Slack_V_Low(i) >= 0, Slack_V_High(i) >= 0];
                    else
                        C = [C, P_shed(i) == P_L_val(i), Q_shed(i) == Q_L_val(i), P_spill(i) == P_PV_val(i)];
                        C = [C, V_sqr(i) == 0, Slack_V_Low(i) == 0, Slack_V_High(i) == 0];
                    end
                end
                
                % 电压参考约束只适用于已带电的分量。
                C = [C, V_sqr(mask_v_ref & mask_live) == 1.0];
                
                C = [C, P_MESS_Act_Pos >= 0, P_MESS_Act_Neg >= 0, P_Miss_Charge_MESS >= 0];
                for k = 1:2
                    node = mess_nodes_t(k);
                    if node > 0 && mask_live(node)
                        isl = bins(node);
                        lim = obj.MESS_POWER_LIMIT / obj.BASE_MVA;
                        
                        C = [C, P_MESS_Act_Pos(k) <= lim];
                        C = [C, P_MESS_Act_Pos(k) <= P_Cmd_MESS_Pos(k)]; 
                        C = [C, P_MESS_Act_Neg(k) <= lim * (1 - Island_Shed_Indicator(isl))];
                        C = [C, P_MESS_Act_Neg(k) <= P_Cmd_MESS_Neg(k)]; 
                        
                        C = [C, P_Cmd_MESS_Neg(k) - P_MESS_Act_Neg(k) <= P_Miss_Charge_MESS(k)];
                    else
                        C = [C, P_MESS_Act_Pos(k) == 0, P_MESS_Act_Neg(k) == 0, P_Miss_Charge_MESS(k) == 0];
                    end
                end
                
                C = [C, P_EV_Act_Pos >= 0, P_EV_Act_Neg >= 0, P_Miss_Charge_EV >= 0];
                for k = 1:3
                    node = obj.Idx_EV(k);
                    is_ev_avail = obj.EV_Avail_Daily(k, t); 
                    
                    if mask_live(node) && is_ev_avail
                        isl = bins(node);
                        lim = obj.EV_SLACK_LIMIT / obj.BASE_MVA;
                        
                        C = [C, P_EV_Act_Pos(k) <= lim];
                        C = [C, P_EV_Act_Pos(k) <= P_Cmd_EV_Pos(k)]; 
                        C = [C, P_EV_Act_Neg(k) <= lim * (1 - Island_Shed_Indicator(isl))];
                        C = [C, P_EV_Act_Neg(k) <= P_Cmd_EV_Neg(k)]; 
                        
                        C = [C, P_Cmd_EV_Neg(k) - P_EV_Act_Neg(k) <= P_Miss_Charge_EV(k)];
                    else
                        C = [C, P_EV_Act_Pos(k) == 0, P_EV_Act_Neg(k) == 0, P_Miss_Charge_EV(k) == 0];
                    end
                end
                
                if mask_live(1)
                    C = [C, -obj.P_GRID_MAX <= P_Grid <= obj.P_GRID_MAX];
                else
                    C = [C, P_Grid == 0, Q_Grid == 0];
                end
                
                % [V16.0 核心修复] 为 EDG 设定灵活出力范围，允许降功率运行
                for e_idx = 1:length(obj.Idx_EDG)
                    node = obj.Idx_EDG(e_idx);
                    cap = obj.Idx_EDG_Cap(e_idx) / obj.BASE_MVA;
                    if mask_live(node)
                        isl = bins(node);
                        C = [C, 0 <= P_EDG_Act(e_idx) <= cap]; 
                        if isl == bins(1)
                            C = [C, Q_EDG_Act(e_idx) == 0]; 
                        else
                            C = [C, -cap <= Q_EDG_Act(e_idx) <= cap];
                        end
                    else
                        C = [C, P_EDG_Act(e_idx) == 0, Q_EDG_Act(e_idx) == 0];
                    end
                end
                
                energized_lines = active_lines(mask_live(obj.Branch_From(active_lines)));
                inactive_lines = setdiff(1:obj.NL, energized_lines);
                C = [C, P_flow(inactive_lines) == 0, Q_flow(inactive_lines) == 0];
                
                for i = 1:obj.NB
                    if ~mask_live(i), continue; end
                    
                    P_inj = (P_PV_val(i) - P_spill(i)) - (P_L_val(i) - P_shed(i));
                    Q_inj = 0 - (Q_L_val(i) - Q_shed(i));
                    
                    if i == 1
                        P_inj = P_inj + P_Grid;
                        Q_inj = Q_inj + Q_Grid;
                    end
                    
                    % [V16.0 核心修复] 注入节点实际调度的 EDG 有功功率，而不是盲目加死 cap
                    edg_idx = find(obj.Idx_EDG == i, 1);
                    if ~isempty(edg_idx)
                        P_inj = P_inj + P_EDG_Act(edg_idx); 
                        Q_inj = Q_inj + Q_EDG_Act(edg_idx);
                    end
                    
                    m_idx = find(mess_nodes_t == i);
                    if ~isempty(m_idx)
                        for mm = m_idx'
                            P_inj = P_inj + P_MESS_Act_Pos(mm) - P_MESS_Act_Neg(mm);
                        end
                    end
                    
                    e_idx = find(obj.Idx_EV == i);
                    if ~isempty(e_idx)
                        is_ev_avail = obj.EV_Avail_Daily(e_idx, t);
                        if is_ev_avail
                            P_inj = P_inj + P_EV_Act_Pos(e_idx) - P_EV_Act_Neg(e_idx);
                        end
                    end
                    
                    children = find(obj.Branch_From == i);
                    parents = find(obj.Branch_To == i);
                    
                    p_out = sum(P_flow(children)); q_out = sum(Q_flow(children));
                    p_in = sum(P_flow(parents)); q_in = sum(Q_flow(parents));
                    
                    C = [C, P_inj + p_in - p_out == 0];
                    C = [C, Q_inj + q_in - q_out == 0];
                end
                
                for l = energized_lines'
                    fr = obj.Branch_From(l); to = obj.Branch_To(l);
                    R = obj.Branch_R(l); X = obj.Branch_X(l);
                    C = [C, V_sqr(to) == V_sqr(fr) - 2*(R*P_flow(l) + X*Q_flow(l))];
                end
                
                cost_shed = sum(P_shed(obj.Idx_Essential)) * obj.WEIGHT_ESSENTIAL + ...
                            sum(P_shed(obj.Idx_Ordinary)) * obj.WEIGHT_ORDINARY;
                            
                cost_volt = sum(Slack_V_Low) * obj.PENALTY_VOLTAGE + sum(Slack_V_High) * obj.PENALTY_VOLTAGE;
                cost_spill = sum(P_spill) * 10.0; 
                
                cost_miss_charge = sum(P_Miss_Charge_MESS) * 0.05 + sum(P_Miss_Charge_EV) * 0.05;
                          
                Obj = cost_shed + cost_volt + cost_spill + cost_miss_charge;
                
                % 输出清单中追加 P_EDG_Act，方便观测柴发真实出力
                out_vars = {P_shed, P_Grid, P_MESS_Act_Pos, P_MESS_Act_Neg, P_EV_Act_Pos, P_EV_Act_Neg, V_sqr, ...
                            Q_EDG_Act, P_EDG_Act, P_spill};
                
                obj.Optimizers{t} = optimizer(C, Obj, ops, u_in, out_vars);
            end
            
            elapsed = toc;
            fprintf('   -> [System] 预编译完成！耗时: %.2f 秒。\n', elapsed);
            obj.Is_Compiled = true;
        end

        function [step_shed, step_cost, step_outage, P_MESS_Act_MW, P_EV_Act_MW, Extra] = step_simulation(obj, t, Price_t, P_MESS_t, P_EV_t)
            if ~obj.Is_Compiled, error('环境尚未编译！'); end
            
            % [V15.1 单位对齐修复] 彻底解决 MW 与 p.u. 混淆导致的强充强放
            P_Cmd_MESS_Pos = max(0, P_MESS_t(:)) / obj.BASE_MVA; 
            P_Cmd_MESS_Neg = max(0, -P_MESS_t(:)) / obj.BASE_MVA;
            P_Cmd_EV_Pos = max(0, P_EV_t(:)) / obj.BASE_MVA;     
            P_Cmd_EV_Neg = max(0, -P_EV_t(:)) / obj.BASE_MVA;
            
            u_val = [P_Cmd_MESS_Pos; P_Cmd_MESS_Neg; P_Cmd_EV_Pos; P_Cmd_EV_Neg; Price_t(:); zeros(4,1)];
            
            [sol, err] = obj.Optimizers{t}(u_val);
            if err ~= 0
                error('GridEnv:SolverFailure', 'T=%02d 求解异常，代码：%d (%s)', t, err, yalmiperror(err));
            end
            
            p_s = sol{1}; p_grid = sol{2}; 
            p_m_pos = sol{3}; p_m_neg = sol{4};
            p_e_pos = sol{5}; p_e_neg = sol{6};
            v_sqr_val = sol{7};
            
            step_shed = sum(p_s) * obj.BASE_MVA;
            
            P_MESS_Act_MW = (p_m_pos - p_m_neg) * obj.BASE_MVA;
            P_EV_Act_MW = (p_e_pos - p_e_neg) * obj.BASE_MVA;
            
            sum_discharge_mw = (sum(p_e_pos) + sum(p_m_pos)) * obj.BASE_MVA;
            step_cost = sum_discharge_mw * Price_t * 1000;
            
            step_outage = 0;
            [P_L_t, ~, P_PV_available] = obj.get_snapshot_state(t);
            
            for idx_n = 1:length(obj.Idx_Essential)
                n = obj.Idx_Essential(idx_n);
                demand_node = P_L_t(n);
                shed_node = p_s(n);
                
                if demand_node > 1e-4
                    local_shed_ratio = shed_node / demand_node; 
                    if local_shed_ratio > 0.20
                        node_outage_mins = 15 + (local_shed_ratio - 0.20) * (60 - 15) / (1.0 - 0.20); 
                        step_outage = step_outage + node_outage_mins;
                    end
                end
            end
            
            Extra.Real_Shed_MWh = sum(p_s) * obj.BASE_MVA;
            Extra.Shed_Matrix_Col = p_s * obj.BASE_MVA;
            Extra.Grid_MW = p_grid * obj.BASE_MVA;
            Extra.PV_Spill_MW = sol{10} * obj.BASE_MVA;
            Extra.PV_Act_MW = P_PV_available * obj.BASE_MVA - Extra.PV_Spill_MW;
            
            raw_v_mag = sqrt(max(0, v_sqr_val));
            raw_v_mag(raw_v_mag < 0.1) = NaN; 
            Extra.V_Mag = raw_v_mag;
            
            % [V16.0 核心记录修复] 记录真实的 EDG 动态出力，而不是定死的容量
            obj.EDG_Records_Daily(:, t) = 0;
            p_edg_act_vals = sol{9}; % 读取优化器反馈的真实出力变量
            for e_idx = 1:length(obj.Idx_EDG)
                node = obj.Idx_EDG(e_idx);
                obj.EDG_Records_Daily(node, t) = p_edg_act_vals(e_idx) * obj.BASE_MVA; 
            end
            Extra.EDG_Matrix_Col = obj.EDG_Records_Daily(:, t);
            
            % [V16.1 核心传出接口] 完美闭环：将计算好的原始拓扑编号送入物理数据流
            Extra.Area_ID_Col = obj.Area_ID_Daily(:, t); 
        end
    end
end
