classdef GridEnv < handle
    % GRIDENV (V9.07 - 终极物理大锁 & 双向非对称 & 绝对数学防崩版)
    % =====================================================================
    % [物理重塑 V9.00] 引入 IDMT 反时限保护曲线，打破死锁，激活三维 Pareto 梯度。
    % [大锁补丁 V9.02] 像素级复刻 Python DRO 采样器，彻底斩断 EV 幽灵充电漏洞。
    % [双向非对称 V9.06] 引入 P_Over_Charge 惩罚(5000)，封锁光伏强灌导致的 SOC 爆炸漏洞。
    % [终极防崩 V9.07] 1. 引入 P_EDG_Act 允许柴发降功率，消灭白屏 Infeasible。
    %                  2. 引入 mask_v_ref & mask_live，彻底修复单节点死岛 0==1 悖论。
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
        Python_Area_ID_Daily
        EV_Avail_Daily      
        
        Abs_Data_Dir 
        
        Optimizers = cell(1, 24);
        Is_Compiled = false;
    end

    methods
        function obj = GridEnv()
            current_class_dir = fileparts(mfilename('fullpath'));
            obj.Abs_Data_Dir = fullfile(current_class_dir, '..', 'Data');
            addpath(obj.Abs_Data_Dir); 
            
            obj.mpc = IEEE33;
            obj.NB = size(obj.mpc.bus, 1);
            obj.NL = size(obj.mpc.branch, 1);
            obj.NT = 24;
            obj.Python_Area_ID_Daily = zeros(obj.NB, obj.NT);
            
            obj.EDG_Records_Daily = zeros(obj.NB, obj.NT);
            
            obj.Branch_From = obj.mpc.branch(:, 1);
            obj.Branch_To = obj.mpc.branch(:, 2);
            obj.Branch_R = obj.mpc.branch(:, 3);
            obj.Branch_X = obj.mpc.branch(:, 4);
            
            obj.Load_Active_Base = obj.mpc.bus(:, 3) / obj.BASE_MVA;
            obj.Load_Reactive_Base = obj.mpc.bus(:, 4) / obj.BASE_MVA;
            
            obj.load_external_data();
            obj.load_scenario_and_strategy();
            
            fprintf('GridEnv (V9.07 Ultimate Anti-Crash Edition) 初始化...\n');
            obj.build_optimizers();
        end
        
        function load_scenario_and_strategy(obj)
            scen_path = fullfile(obj.Abs_Data_Dir, 'scenario.mat');
            strat_path = fullfile(obj.Abs_Data_Dir, 'strategy.mat');
            if ~exist(scen_path, 'file') || ~exist(strat_path, 'file')
                error('数据文件缺失，请先运行 generate_data.m 和 Topology_Manager.m');
            end
            d_scen = load(scen_path);
            d_strat = load(strat_path);
            obj.Line_Status_Daily = d_scen.Line_Status_Daily;
            obj.Reconfig_Plan = d_strat.Reconfig_Plan;
            obj.MESS_Schedule = d_strat.MESS_Schedule;
        end

        function build_optimizers(obj)
            fprintf('   -> [System] 正在编译 24 个时段的 MILP 潮流求解器 (Pre-compiling)...\n');
            tic;
            solver = getenv('STACKELBERG_SOLVER');
            if isempty(solver), solver = 'intlinprog'; end
            ops = sdpsettings('solver', solver, 'verbose', 0, 'savesolveroutput', 0);
            
            for t = 1:obj.NT
                status = [obj.Line_Status_Daily(1:32, t); 
                          obj.Line_Status_Daily(33:37, t) & obj.Reconfig_Plan(:, t)];
                active_lines = find(status == 1);
                
                mess_nodes_t = obj.MESS_Schedule(:, t);
                [P_L_val, Q_L_val, P_PV_val] = obj.get_snapshot_state(t);
                
                G = graph(obj.Branch_From(active_lines), obj.Branch_To(active_lines), [], obj.NB);
                bins = conncomp(G);
                obj.Python_Area_ID_Daily(:, t) = map_area_ids_for_python(bins);
                num_islands = max(bins);
                
                mask_v_ref = false(obj.NB, 1); mask_dead = false(obj.NB, 1);
                for isl = 1:num_islands
                    nodes = find(bins == isl);
                    if ismember(1, nodes)
                        mask_v_ref(1) = true; 
                    else
                        sources = [];
                        for k = 1:length(obj.Idx_EDG)
                            if ismember(obj.Idx_EDG(k), nodes), sources = [sources, obj.Idx_EDG(k)]; end
                        end
                        for m = 1:2
                            if ismember(mess_nodes_t(m), nodes), sources = [sources, mess_nodes_t(m)]; end
                        end
                        for e = 1:3
                            if obj.EV_Avail_Daily(e, t) && ismember(obj.Idx_EV(e), nodes)
                                sources = [sources, obj.Idx_EV(e)];
                            end
                        end
                        if ~isempty(sources)
                            mask_v_ref(sources(1)) = true; 
                        else
                            mask_dead(nodes) = true; 
                        end
                    end
                end
                
                u_in = sdpvar(15, 1); 
                P_Cmd_MESS = u_in(1:2);
                P_Cmd_EV   = u_in(3:5);
                P_Cmd_MESS_Pos = u_in(6:7);   
                P_Cmd_EV_Pos   = u_in(8:10);  
                P_Cmd_MESS_Neg = u_in(11:12); 
                P_Cmd_EV_Neg   = u_in(13:15); 
                
                Island_Shed_Indicator = binvar(num_islands, 1);
                P_shed = sdpvar(obj.NB, 1); Q_shed = sdpvar(obj.NB, 1);
                V_sqr  = sdpvar(obj.NB, 1);
                P_flow = sdpvar(obj.NL, 1); Q_flow = sdpvar(obj.NL, 1);
                P_spill = sdpvar(obj.NB, 1);      
                Slack_V_Low = sdpvar(obj.NB, 1); Slack_V_High = sdpvar(obj.NB, 1); 
                P_Grid = sdpvar(1, 1); Q_Grid = sdpvar(1, 1);
                
                P_MESS_Act_Pos = sdpvar(2, 1); P_MESS_Act_Neg = sdpvar(2, 1);
                P_EV_Act_Pos = sdpvar(3, 1); P_EV_Act_Neg = sdpvar(3, 1);
                P_MESS_Act = P_MESS_Act_Pos - P_MESS_Act_Neg;
                P_EV_Act = P_EV_Act_Pos - P_EV_Act_Neg;
                
                P_Over_Discharge_MESS = sdpvar(2, 1); P_Miss_Charge_MESS = sdpvar(2, 1);
                P_Over_Charge_MESS = sdpvar(2, 1); 
                P_Over_Discharge_EV = sdpvar(3, 1); P_Miss_Charge_EV = sdpvar(3, 1);
                P_Over_Charge_EV = sdpvar(3, 1);   
                
                % [V9.07 修复 1] 增加 EDG 灵活有功出力变量
                P_EDG_Act = sdpvar(length(obj.Idx_EDG), 1);
                Q_EDG_Act = sdpvar(length(obj.Idx_EDG), 1);
                
                C = [];
                C = [C, 0 <= P_shed <= P_L_val, 0 <= Q_shed <= Q_L_val];
                C = [C, 0 <= P_spill <= P_PV_val, Slack_V_Low >= 0, Slack_V_High >= 0];
                C = [C, -obj.P_GRID_MAX <= P_Grid <= obj.P_GRID_MAX];
                
                inactive = setdiff(1:obj.NL, active_lines);
                if ~isempty(inactive), C = [C, P_flow(inactive) == 0, Q_flow(inactive) == 0]; end
                
                for isl = 1:num_islands
                    nodes = find(bins == isl);
                    island_P_L_total = sum(P_L_val(nodes));
                    if island_P_L_total > 1e-6
                        C = [C, sum(P_shed(nodes)) <= island_P_L_total * Island_Shed_Indicator(isl)];
                    else
                        C = [C, Island_Shed_Indicator(isl) == 0];
                    end
                end
                
                if any(mask_dead)
                    C = [C, P_shed(mask_dead) == P_L_val(mask_dead), Q_shed(mask_dead) == Q_L_val(mask_dead)];
                    C = [C, V_sqr(mask_dead) == 0, Slack_V_Low(mask_dead)==0, Slack_V_High(mask_dead)==0];
                end
                
                mask_live = ~mask_dead;
                if any(mask_live)
                    C = [C, obj.V_MIN^2 - Slack_V_Low(mask_live) <= V_sqr(mask_live)];
                    C = [C, V_sqr(mask_live) <= obj.V_MAX^2 + Slack_V_High(mask_live)];
                end
                
                % [V9.07 修复 2] 增加 & mask_live，彻底消灭单节点死岛导致的 0 == 1 悖论
                if any(mask_v_ref & mask_live)
                    C = [C, V_sqr(mask_v_ref & mask_live) == 1.0]; 
                end
                
                % --- [新增] EDG 约束分配 ---
                for e_idx = 1:length(obj.Idx_EDG)
                    node = obj.Idx_EDG(e_idx);
                    cap = obj.Idx_EDG_Cap(e_idx) / obj.BASE_MVA;
                    if mask_live(node)
                        isl = bins(node);
                        C = [C, 0 <= P_EDG_Act(e_idx) <= cap]; 
                        if isl == bins(1)
                            C = [C, Q_EDG_Act(e_idx) == 0]; 
                        else
                            lim_q = cap * 0.8;
                            C = [C, -lim_q <= Q_EDG_Act(e_idx) <= lim_q];
                        end
                    else
                        C = [C, P_EDG_Act(e_idx) == 0, Q_EDG_Act(e_idx) == 0];
                    end
                end
                
                C = [C, P_MESS_Act_Pos >= 0, P_MESS_Act_Neg >= 0];
                C = [C, P_Over_Discharge_MESS >= 0, P_Miss_Charge_MESS >= 0, P_Over_Charge_MESS >= 0];
                for k = 1:2
                    node = mess_nodes_t(k);
                    if node > 0 && mask_live(node)
                        isl = bins(node);
                        lim = obj.MESS_POWER_LIMIT / obj.BASE_MVA;
                        C = [C, 0 <= P_MESS_Act_Pos(k) <= lim];
                        C = [C, 0 <= P_MESS_Act_Neg(k) <= lim * (1 - Island_Shed_Indicator(isl))];
                        
                        C = [C, P_MESS_Act_Pos(k) - P_Cmd_MESS_Pos(k) <= P_Over_Discharge_MESS(k)];
                        C = [C, (-P_Cmd_MESS_Neg(k)) - P_MESS_Act_Neg(k) <= P_Miss_Charge_MESS(k)];
                        C = [C, P_MESS_Act_Neg(k) - (-P_Cmd_MESS_Neg(k)) <= P_Over_Charge_MESS(k)];
                    else
                        C = [C, P_MESS_Act_Pos(k) == 0, P_MESS_Act_Neg(k) == 0];
                        C = [C, P_Over_Discharge_MESS(k) == 0, P_Miss_Charge_MESS(k) == 0, P_Over_Charge_MESS(k) == 0];
                    end
                end
                
                C = [C, P_EV_Act_Pos >= 0, P_EV_Act_Neg >= 0];
                C = [C, P_Over_Discharge_EV >= 0, P_Miss_Charge_EV >= 0, P_Over_Charge_EV >= 0];
                for k = 1:3
                    node = obj.Idx_EV(k);
                    is_ev_avail = obj.EV_Avail_Daily(k, t); 
                    
                    if mask_live(node) && is_ev_avail
                        isl = bins(node);
                        lim = obj.EV_SLACK_LIMIT / obj.BASE_MVA;
                        C = [C, 0 <= P_EV_Act_Pos(k) <= lim];
                        C = [C, 0 <= P_EV_Act_Neg(k) <= lim * (1 - Island_Shed_Indicator(isl))];
                        
                        C = [C, P_EV_Act_Pos(k) - P_Cmd_EV_Pos(k) <= P_Over_Discharge_EV(k)];
                        C = [C, (-P_Cmd_EV_Neg(k)) - P_EV_Act_Neg(k) <= P_Miss_Charge_EV(k)];
                        C = [C, P_EV_Act_Neg(k) - (-P_Cmd_EV_Neg(k)) <= P_Over_Charge_EV(k)];
                    else
                        C = [C, P_EV_Act_Pos(k) == 0, P_EV_Act_Neg(k) == 0];
                        C = [C, P_Over_Discharge_EV(k) == 0, P_Miss_Charge_EV(k) == 0, P_Over_Charge_EV(k) == 0];
                    end
                end
                
                for k = active_lines'
                    u = obj.Branch_From(k); v = obj.Branch_To(k);
                    C = [C, V_sqr(v) == V_sqr(u) - 2*(obj.Branch_R(k)*P_flow(k) + obj.Branch_X(k)*Q_flow(k))];
                end
                
                idx_live_list = find(mask_live);
                for i = idx_live_list'
                    l_in = find(obj.Branch_To == i); l_out = find(obj.Branch_From == i);
                    term_P = sum(P_flow(l_out)) - sum(P_flow(l_in));
                    term_Q = sum(Q_flow(l_out)) - sum(Q_flow(l_in));
                    
                    P_inject = 0; Q_inject = 0;
                    if i == 1, P_inject = P_inject + P_Grid; Q_inject = Q_inject + Q_Grid; end
                    for k = 1:2
                        if mess_nodes_t(k) == i
                            P_inject = P_inject + P_MESS_Act(k);
                            Q_inject = Q_inject + P_MESS_Act(k) * 0.5;
                        end
                    end
                    for k = 1:3
                        if obj.Idx_EV(k) == i
                            P_inject = P_inject + P_EV_Act(k);
                            Q_inject = Q_inject + P_EV_Act(k) * 0.5;
                        end
                    end
                    
                    % [并网/离网全域使能] 允许 EDG 随时向电网注入功率补足缺口
                    edg_idx = find(obj.Idx_EDG == i);
                    if ~isempty(edg_idx)
                        P_inject = P_inject + P_EDG_Act(edg_idx); 
                        Q_inject = Q_inject + Q_EDG_Act(edg_idx); 
                    end
                    
                    P_Base = P_PV_val(i) - P_L_val(i) + P_shed(i);
                    Q_Base = -Q_L_val(i) + Q_shed(i);
                    C = [C, term_P == P_Base + P_inject - P_spill(i), term_Q == Q_Base + Q_inject];
                end
                
                w_shed = ones(obj.NB, 1); 
                w_shed(obj.Idx_Essential) = obj.WEIGHT_ESSENTIAL;
                Cost_Shed = sum(P_shed .* w_shed);
                Cost_Volt = obj.PENALTY_VOLTAGE * sum(Slack_V_Low + Slack_V_High);
                
                Cost_Over_Discharge = 5000 * (sum(P_Over_Discharge_MESS) + sum(P_Over_Discharge_EV));
                Cost_Over_Charge    = 5000 * (sum(P_Over_Charge_MESS) + sum(P_Over_Charge_EV));
                Cost_Miss_Charge    = 0.05 * (sum(P_Miss_Charge_MESS) + sum(P_Miss_Charge_EV));
                Cost_Spill = 10 * sum(P_spill);
                
                Objective = Cost_Shed + Cost_Volt + Cost_Over_Discharge + Cost_Over_Charge + Cost_Miss_Charge + Cost_Spill;
                
                P_g_vec = [P_Grid; zeros(obj.NB-1, 1)];
                
                % 将 P_EDG_Act 追加到提取输出清单中
                Out_Vars = {Objective, P_shed, P_g_vec, P_MESS_Act, P_EV_Act, V_sqr, P_EDG_Act, P_spill .* double(mask_live) + P_PV_val .* double(mask_dead)};
                obj.Optimizers{t} = optimizer(C, Objective, ops, u_in, Out_Vars);
                
                if mod(t, 6) == 0, fprintf('      ... 已编译 T=%02d / 24\n', t); end
            end
            
            obj.Is_Compiled = true;
            fprintf('   -> [Success] 预编译完成！耗时: %.2f 秒。\n', toc);
        end

        function [step_shed, step_cost, step_outage, P_MESS_Act_MW, P_EV_Act_MW, Extra] = step_simulation(obj, t, Price_t, P_MESS_t, P_EV_t)
            p_mess_pu = P_MESS_t(:) / obj.BASE_MVA;
            p_ev_pu   = P_EV_t(:) / obj.BASE_MVA;
            
            u_t = [p_mess_pu; p_ev_pu; max(0, p_mess_pu); max(0, p_ev_pu); min(0, p_mess_pu); min(0, p_ev_pu)];
            [sol, err] = obj.Optimizers{t}(u_t);
            
            if err
                error('GridEnv:SolverFailure','Hour %d: %s', t, yalmiperror(err));
            end
            p_s = sol{2}; p_g = sol{3}; p_m_act = sol{4}; p_e_act = sol{5}; v_sqr_val = sol{6};
            p_edg_act = sol{7};

            % 将优化后的出力写入记录
            p_edg = zeros(obj.NB, 1);
            for e_idx = 1:length(obj.Idx_EDG)
                p_edg(obj.Idx_EDG(e_idx)) = p_edg_act(e_idx);
            end
            obj.EDG_Records_Daily(:, t) = p_edg * obj.BASE_MVA;
            
            P_MESS_Act_MW = p_m_act(:)' * obj.BASE_MVA;
            P_EV_Act_MW   = p_e_act(:)' * obj.BASE_MVA;
            
            w = ones(obj.NB, 1); w(obj.Idx_Essential) = obj.WEIGHT_ESSENTIAL;
            step_shed = sum(p_s .* w);
            
            p_incentive = sum(max(0, P_MESS_Act_MW)) + sum(max(0, P_EV_Act_MW));
            step_cost = p_incentive * Price_t * 1000;
            
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
            Extra.Gen_Matrix_Col = p_g * obj.BASE_MVA;
            Extra.Grid_MW = p_g(1) * obj.BASE_MVA;
            Extra.PV_Spill_MW = sol{8} * obj.BASE_MVA;
            Extra.PV_Act_MW = P_PV_available * obj.BASE_MVA - Extra.PV_Spill_MW;
            Extra.V_Mag = sqrt(max(0, v_sqr_val)); 
            Extra.EDG_Matrix_Col = p_edg * obj.BASE_MVA; 
        end

        function [f1, f2, f3] = evaluate_global(obj, Price, P_MESS, P_EV)
            [f1, f2, f3, ~] = obj.run_fast_simulation(Price, P_MESS, P_EV);
        end
        
        function [Shed, Cost, Mins, Extra] = evaluate_pure_stats(obj, Price, P_MESS, P_EV)
            [~, Cost, Mins, Extra] = obj.run_fast_simulation(Price, P_MESS, P_EV);
            Shed = Extra.Real_Shed_MWh;
        end

        function [O1, O2, O3, Info] = run_fast_simulation(obj, Price, P_MESS, P_EV)
            total_shed = 0; total_cost = 0; total_outage = 0;
            Shed_Mat = zeros(obj.NB, obj.NT); Gen_Mat = zeros(obj.NB, obj.NT);
            V_Mat = zeros(obj.NB, obj.NT); EDG_Mat = zeros(obj.NB, obj.NT);
            
            for t = 1:obj.NT
                [s_shed, s_cost, s_outage, ~, ~, Extra] = obj.step_simulation(t, Price(t), P_MESS(t, :), P_EV(t, :));
                total_shed = total_shed + s_shed; total_cost = total_cost + s_cost; total_outage = total_outage + s_outage;
                Shed_Mat(:, t) = Extra.Shed_Matrix_Col; Gen_Mat(:, t) = Extra.Gen_Matrix_Col;
                V_Mat(:, t) = Extra.V_Mag; EDG_Mat(:, t) = Extra.EDG_Matrix_Col;
            end
            O1 = total_shed; O2 = total_cost; O3 = total_outage;
            if nargout > 3
                Info.Real_Shed_MWh = sum(sum(Shed_Mat)); Info.Shed_Matrix = Shed_Mat;
                Info.Real_Gen_Matrix = Gen_Mat; Info.V_Matrix = V_Mat; Info.EDG_Matrix = EDG_Mat;
            end
        end
        
        function load_external_data(obj)
             idx_path = fullfile(obj.Abs_Data_Dir, 'index.mat');
             crv_path = fullfile(obj.Abs_Data_Dir, 'curve.mat');
             d_index = load(idx_path); d_curve = load(crv_path);
             obj.Curve_PV = d_curve.pv_curve; obj.Curve_Essential = d_curve.essential_load;
             obj.Curve_Ordinary = d_curve.ordinary_load;
             obj.Idx_Essential = d_index.essential_users; obj.Idx_Ordinary = d_index.ordinary_users;
             obj.Idx_PV = d_index.O_PV; obj.Idx_EV = d_index.O_E;
             obj.Idx_EDG = d_index.O_EDG; 
             if isfield(d_index, 'O_EDG_CAP'), obj.Idx_EDG_Cap = d_index.O_EDG_CAP;
             else, obj.Idx_EDG_Cap = 0.6 * ones(length(obj.Idx_EDG), 1); end
             
             abs_mu_arr = 15.0; sigma_arr = 1.5;
             abs_mu_dep = 33.0; sigma_dep = 1.0;
             rho = 0.5; 
             
             raw_arr_abs = abs_mu_arr + rho * sigma_arr; 
             raw_dep_abs = abs_mu_dep - rho * sigma_dep; 
             arr_mod = mod(raw_arr_abs, 24); 
             dep_mod = mod(raw_dep_abs, 24); 
             
             sh = 12; 
             if isfield(d_curve, 'START_HOUR'), sh = d_curve.START_HOUR; end
             obj.EV_Avail_Daily = zeros(3, obj.NT);
             
             for t = 1:obj.NT
                 t_mod = mod(sh + t - 1, 24); 
                 
                 is_avail = false;
                 if arr_mod > dep_mod 
                     if (t_mod >= arr_mod) || (t_mod < dep_mod)
                         is_avail = true;
                     end
                 else 
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
            P_PV(obj.Idx_PV) = (0.5 / obj.BASE_MVA) * obj.Curve_PV(t);
        end
    end
end