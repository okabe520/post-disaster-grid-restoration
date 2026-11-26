function [Reconfig_Plan, MESS_Schedule] = Topology_Manager()
% TOPOLOGY_MANAGER - V16.0 终极融合版 (动态净缺口 + 容量柔性排斥 + 拓扑自适应)
% =========================================================================

    fprintf('\n>>> [终极指挥中心] 启动全时域动态重构与调度引擎...\n');
    
    current_script_dir = fileparts(mfilename('fullpath'));
    data_dir = fullfile(current_script_dir, '..', 'Data');
    
    %% 1. 加载全息数据
    idx_data = load(fullfile(data_dir, 'index.mat'));
    ess_nodes = idx_data.essential_users;
    ord_nodes = idx_data.ordinary_users;
    O_PV = idx_data.O_PV;
    O_ME = idx_data.O_ME;
    if isfield(idx_data, 'O_EDG')
        O_EDG = idx_data.O_EDG; O_EDG_CAP = idx_data.O_EDG_CAP; 
    else, O_EDG = []; O_EDG_CAP = []; end
    
    crv_data = load(fullfile(data_dir, 'curve.mat'));
    curve_pv = crv_data.pv_curve;
    curve_ess = crv_data.essential_load;
    curve_ord = crv_data.ordinary_load;
    
    % [拓扑自适应] 设定为 IEEE 69
    mpc = IEEE69; 
    NB = size(mpc.bus, 1);
    NL = size(mpc.branch, 1);
    branches = mpc.branch(:, 1:2);
    Base_Load_MW = mpc.bus(:, 3); 
    
    idx_backbone = find(mpc.branch(:, 11) == 1);
    idx_ties = find(mpc.branch(:, 11) == 0);
    num_ties = length(idx_ties);
    
    scen_data = load(fullfile(data_dir, 'scenario.mat'));
    Line_Status_Daily = scen_data.Line_Status_Daily; 
    
    LOAD_SCALE = 0.9;  
    PV_CAP_MW = 0.5;   
    
    fprintf('    [初始化] 计算路网物理距离矩阵...\n');
    Unit_Length_KM = 2.0; 
    Dist_Mat = cal_distance(mpc.branch, Unit_Length_KM);
    
    Horizon = 24; N_MESS = 2; MESS_Speed_KMH = 15.0; 
    Reconfig_Plan = zeros(num_ties, Horizon); 
    MESS_Schedule = zeros(N_MESS, Horizon);
    MESS_State = struct('Pos', {O_ME(1), O_ME(2)}, 'Status', {0, 0}, 'Dest', {1, 1}, 'ETA', {0, 0});
    
    %% 3. 逐小时动态推演
    fprintf('    [推演] 开始 24 小时动态缺口追踪循环 (时速: %.1f km/h)...\n', MESS_Speed_KMH);
    
    for t = 1:Horizon
        pv_t = curve_pv(t); ess_t = curve_ess(t); ord_t = curve_ord(t);
        
        % =================================================================
        % A. 物理拓扑感知与重构
        % =================================================================
        backbone_status = Line_Status_Daily(idx_backbone, t);
        tie_avail = Line_Status_Daily(idx_ties, t);
        
        adj_matrix = zeros(NB, NB);
        for k = 1:length(idx_backbone)
            if backbone_status(k) == 1
                u = branches(idx_backbone(k), 1); v = branches(idx_backbone(k), 2);
                adj_matrix(u, v) = 1; adj_matrix(v, u) = 1;
            end
        end
        G_base = graph(adj_matrix);
        closed_ties = zeros(num_ties, 1);
        [bins, ~] = conncomp(G_base);
        
        for k = 1:num_ties
            if tie_avail(k) == 1
                u = branches(idx_ties(k), 1); v = branches(idx_ties(k), 2);
                if bins(u) ~= bins(v) 
                    G_base = addedge(G_base, u, v, 1);
                    closed_ties(k) = 1;
                    [bins, ~] = conncomp(G_base); 
                end
            end
        end
        Reconfig_Plan(:, t) = closed_ties;
        
        % =================================================================
        % B. 孤岛价值评估 - 真实物理净缺口精算
        % =================================================================
        [bins, ~] = conncomp(G_base);
        num_islands = max(bins);
        dead_islands = [];
        
        for i = 1:num_islands
            nodes = find(bins == i);
            if ~ismember(1, nodes) 
                total_load_mw = 0; total_pv_mw = 0; total_edg_mw = 0;
                has_hosp = false;
                
                for idx_node = 1:length(nodes)
                    n = nodes(idx_node);
                    node_base_mw = Base_Load_MW(n) * LOAD_SCALE;
                    
                    if ismember(n, ess_nodes)
                        total_load_mw = total_load_mw + node_base_mw * ess_t;
                        has_hosp = true;
                    else
                        total_load_mw = total_load_mw + node_base_mw * ord_t;
                    end
                    
                    if ismember(n, O_PV)
                        total_pv_mw = total_pv_mw + PV_CAP_MW * pv_t;
                    end
                    
                    edg_idx = find(O_EDG == n, 1);
                    if ~isempty(edg_idx)
                        total_edg_mw = total_edg_mw + O_EDG_CAP(edg_idx);
                    end
                end
                
                net_deficit_mw = total_load_mw - total_edg_mw - total_pv_mw;
                
                center_node = nodes(round(length(nodes)/2)); 
                if has_hosp 
                    h_nodes = nodes(ismember(nodes, ess_nodes));
                    center_node = h_nodes(1); 
                end
                
                % 记录孤岛物理基础数据，供调度阶动态算账
                dead_islands = [dead_islands; struct('ID', i, 'Deficit', net_deficit_mw, 'HasHosp', has_hosp, 'Center', center_node)];
            end
        end
        
        % =================================================================
        % C. MESS 动态调度 - 容量感知柔性排斥
        % =================================================================
        MESS_POWER_LIMIT = 0.5; % MESS最大支撑缺口

        for m = 1:N_MESS
            if MESS_State(m).Status == 1
                MESS_State(m).ETA = MESS_State(m).ETA - 1;
                MESS_Schedule(m, t) = -1; 
                if MESS_State(m).ETA <= 0
                    MESS_State(m).Pos = MESS_State(m).Dest;
                    MESS_State(m).Status = 0; 
                    fprintf('    [T=%02d] 🚚 MESS %d 抵达 Node %d (投入作战)！\n', t, m, MESS_State(m).Pos);
                    MESS_Schedule(m, t) = MESS_State(m).Pos;
                end
                continue; 
            end
            
            current_pos = MESS_State(m).Pos;
            MESS_Schedule(m, t) = current_pos;
            best_target = current_pos;
            move_time = 0;
            current_island_id = bins(current_pos);
            current_gain = 0;
            
            % --- 1. 评估驻留收益 ---
            curr_isl_struct = [];
            for idx = 1:length(dead_islands)
                if dead_islands(idx).ID == current_island_id
                    curr_isl_struct = dead_islands(idx); break;
                end
            end
            
            if ~isempty(curr_isl_struct)
                allies_in_curr = 0;
                for other_m = 1:N_MESS
                    if other_m ~= m 
                        o_pos = MESS_State(other_m).Pos; o_dest = MESS_State(other_m).Dest;
                        if (MESS_State(other_m).Status == 0 && bins(o_pos) == current_island_id) || ...
                           (MESS_State(other_m).Status == 1 && bins(o_dest) == current_island_id)
                            allies_in_curr = allies_in_curr + 1;
                        end
                    end
                end
                eff_curr_def = max(0, curr_isl_struct.Deficit - allies_in_curr * MESS_POWER_LIMIT);
                if eff_curr_def <= 1e-3, raw_curr_score = 10;
                else, raw_curr_score = eff_curr_def * 5000 + curr_isl_struct.HasHosp * 3000; end
                
                dist_to_center = Dist_Mat(current_pos, curr_isl_struct.Center);
                current_gain = raw_curr_score - (dist_to_center * 20); 
            end
            
            % --- 2. 扫描寻找最佳目标 ---
            for idx = 1:length(dead_islands)
                candidate_node = dead_islands(idx).Center;
                candidate_isl_id = dead_islands(idx).ID;
                
                node_occupied = false;
                allies_in_candidate = 0; 
                
                for other_m = 1:N_MESS
                    if other_m ~= m 
                        o_pos = MESS_State(other_m).Pos; o_dest = MESS_State(other_m).Dest;
                        if (MESS_State(other_m).Status == 0 && o_pos == candidate_node) || ...
                           (MESS_State(other_m).Status == 1 && o_dest == candidate_node)
                            node_occupied = true; break;
                        end
                        if (MESS_State(other_m).Status == 0 && bins(o_pos) == candidate_isl_id) || ...
                           (MESS_State(other_m).Status == 1 && bins(o_dest) == candidate_isl_id)
                            allies_in_candidate = allies_in_candidate + 1;
                        end
                    end
                end
                if node_occupied, continue; end
                
                % 【柔性排斥算账】
                eff_cand_def = max(0, dead_islands(idx).Deficit - allies_in_candidate * MESS_POWER_LIMIT);
                if eff_cand_def <= 1e-3, raw_score = 10; 
                else, raw_score = eff_cand_def * 5000 + dead_islands(idx).HasHosp * 3000; end
                
                dist_km = Dist_Mat(current_pos, candidate_node);
                candidate_gain = raw_score - (dist_km * 20); 
                
                if candidate_gain > current_gain + 100
                    needed_hours = ceil(dist_km / MESS_Speed_KMH);
                    if t + needed_hours < Horizon 
                        best_target = candidate_node;
                        move_time = needed_hours;
                        current_gain = candidate_gain; 
                    end
                end
            end
            
            if best_target ~= current_pos
                dist_real = Dist_Mat(current_pos, best_target);
                fprintf('    [T=%02d] 🚨 MESS %d 转移: Node %d -> Node %d (路程 %.1f km)\n', ...
                    t, m, current_pos, best_target, dist_real);
                MESS_State(m).Status = 1;
                MESS_State(m).Dest = best_target;
                MESS_State(m).ETA = move_time;
                MESS_Schedule(m, t) = -1; 
            end
        end
    end
    
    %% 4. 结果保存
    save(fullfile(data_dir, 'strategy.mat'), 'Reconfig_Plan', 'MESS_Schedule');
    fprintf('\n>>> [终极融合] 物理净缺口精算与动态拓扑自适应完成！\n');
end