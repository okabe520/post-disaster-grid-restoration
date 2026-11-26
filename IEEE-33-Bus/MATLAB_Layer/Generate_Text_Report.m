%% Generate_Text_Report.m - V16.0 终极批量生成与横向对比版
% =========================================================================
%   [目标] 一键生成四大策略(S4_A, S4_B, S4_C, S4_D)的完整底层物理底账，
%          并额外生成 1 份横向对比报告 (Comparative_Summary_Report.txt)。
%   [输出] Data 目录下共计 5 个 TXT 报告文件。
% =========================================================================

clc; clear; close all;
warning('off', 'all');

% --- YALMIP 路径安全防护 ---
yalmip_root = getenv('YALMIP_ROOT');
if ~isempty(yalmip_root), addpath(genpath(yalmip_root)); end
assert(exist('sdpvar','file') == 2, 'Install YALMIP and add it to the MATLAB path.');

fprintf('\n>>> 启动终极报告引擎 (V16.0 批量多策略聚合版)...\n');

% =========================================================================
% Phase 1: 加载数据与环境重建
% =========================================================================
current_path = fileparts(mfilename('fullpath'));
data_dir = fullfile(current_path, '..', 'Data');

try
    load(fullfile(data_dir, 'Optimization_Result.mat'), 'x_opt', 'f_val');
    load(fullfile(data_dir, 'strategy.mat'), 'Reconfig_Plan', 'MESS_Schedule');
    load(fullfile(data_dir, 'scenario.mat'), 'Line_Status_Daily');
    load(fullfile(data_dir, 'curve.mat'), 'START_HOUR');
catch
    error('数据加载失败！请确保已完成 Main_NSGA3.m 的推演。');
end

Env = GridEnv();

Island_Matrix = zeros(Env.NB, Env.NT);
Island_Nodes_Cell = cell(1, Env.NT); 
raw_branches = Env.mpc.branch(:, 1:2);
for t = 1:Env.NT
    % 自动匹配前 NL-5 条骨干线，和最后 5 条联络线
    idx_backbone = 1:(Env.NL-5);
    idx_ties = (Env.NL-4):Env.NL;
    status = [Env.Line_Status_Daily(idx_backbone, t); Env.Line_Status_Daily(idx_ties, t) & Reconfig_Plan(:, t)];
    active = find(status == 1);
    G = graph(raw_branches(active, 1), raw_branches(active, 2), [], Env.NB);
    bins = conncomp(G);
    Island_Nodes_Cell{t} = bins;
    for n = 1:Env.NB, if bins(n) ~= bins(1), Island_Matrix(n, t) = 1; end, end
end

fprintf('    -> 正在唤醒 Python 推理大脑...\n');
python_exe = getenv('STACKELBERG_PYTHON');
pe = pyenv;
if pe.Status == "NotLoaded" && ~isempty(python_exe), pyenv('Version', python_exe, 'ExecutionMode', 'InProcess'); end
python_layer_path = fullfile(current_path, '..', 'Python_Layer');
if count(py.sys.path, python_layer_path) == 0, insert(py.sys.path, int32(0), python_layer_path); end
asm = py.importlib.import_module('agent_server');
py.importlib.reload(asm);
py_adapter = asm.adapter;

% =========================================================================
% Phase 2: 提取四大典型策略 (A/B/C/D)
% =========================================================================
[~, sort_idx_shed] = sort(f_val(:, 1)); idx_A = sort_idx_shed(1);
[~, sort_idx_cost] = sort(f_val(:, 2)); idx_B = sort_idx_cost(1);
[~, sort_idx_outage] = sort(f_val(:, 3)); idx_C = sort_idx_outage(1);

norm_f1 = f_val(:, 1) / max(f_val(:, 1) + 1e-6);
norm_f2 = f_val(:, 2) / max(f_val(:, 2) + 1e-6);
norm_f3 = f_val(:, 3) / max(f_val(:, 3) + 1e-6);
dist_to_utopia = sqrt(norm_f1.^2 + norm_f2.^2 + norm_f3.^2);
[~, sort_idx_bal] = sort(dist_to_utopia); idx_D = sort_idx_bal(1);

target_indices = [idx_A, idx_B, idx_C, idx_D];
labels = {'S4_A', 'S4_B', 'S4_C', 'S4_D'};
titles = {'保供优先 (Min Shed)', '经济优先 (Min Cost)', '恢复优先 (Min Outage)', '全局均衡 (Balanced)'};

% 用于存储横向对比的数据矩阵 (4 个策略 x 11 个核心指标)
Summary_Data = zeros(4, 11);

% =========================================================================
% Phase 3: 循环推演并生成 4 份 Detailed Report
% =========================================================================
fprintf('\n>>> 开始批量执行闭环物理透视并生成底账...\n');

for k = 1:4
    idx_target = target_indices(k);
    target_price = x_opt(idx_target, :);
    str_label = labels{k};
    str_title = titles{k};
    
    fprintf('    [%d/4] 正在处理策略 %s: %s (Index: %d)...\n', k, str_label, str_title, idx_target);
    
    Res = local_objective_wrapper_detailed(target_price, Env, START_HOUR, py_adapter, Env.Python_Area_ID_Daily);
    
    report_file = fullfile(data_dir, sprintf('Detailed_Simulation_Report_%s.txt', str_label));
    fid = fopen(report_file, 'w', 'n', 'UTF-8');
    
    print_both(fid, '====================================================================================================================================\n');
    print_both(fid, '                                 微电网灾后应急博弈全息运行超级底账 - 策略: %s (%s) \n', str_label, str_title);
    print_both(fid, '====================================================================================================================================\n\n');

    tot_ess_shed = sum(sum(Res.Shed_Mat(Env.Idx_Essential, :)));
    tot_ord_shed = sum(sum(Res.Shed_Mat(Env.Idx_Ordinary, :)));
    tot_cost = sum(Res.Cost_T) / 1000;
    tot_outage = sum(Res.Outage_T);
    tot_grid_import = sum(sum(Res.Gen_Mat)); 
    tot_pv_used = sum(sum(Res.PV_Mat));
    tot_edg_used = sum(sum(Res.EDG_Mat));    

    % --- Section A: 宏观全局指标 ---
    print_both(fid, '【Section A: 全局核心指标汇总】\n');
    print_both(fid, '------------------------------------------------------------------------\n');
    print_both(fid, ' - 关键负荷总缺电量: %10.3f MWh\n', tot_ess_shed);
    print_both(fid, ' - 普通负荷总缺电量: %10.3f MWh\n', tot_ord_shed);
    print_both(fid, ' - 调度激励总成本:   %10.3f kCNY\n', tot_cost);
    print_both(fid, ' - 关键节点停电时间: %10.0f 分钟\n', tot_outage);
    print_both(fid, ' - 全天主网总购电量: %10.3f MWh\n', tot_grid_import);
    print_both(fid, ' - 柴发应急总发电量: %10.3f MWh\n', tot_edg_used); 
    print_both(fid, '------------------------------------------------------------------------\n\n');

    % --- Section B: 24小时动态电价展板 ---
    print_both(fid, '【Section B: 24小时动态电价策略板 (CNY/kWh)】\n');
    print_both(fid, '------------------------------------------------------------------------\n');
    print_both(fid, ' 时段 |'); for t=1:12, print_both(fid, ' %02d:00 |', t); end; print_both(fid, '\n');
    print_both(fid, ' 电价 |'); for t=1:12, print_both(fid, '  %4.2f |', target_price(t)); end; print_both(fid, '\n');
    print_both(fid, ' 时段 |'); for t=13:24, print_both(fid, ' %02d:00 |', t); end; print_both(fid, '\n');
    print_both(fid, ' 电价 |'); for t=13:24, print_both(fid, '  %4.2f |', target_price(t)); end; print_both(fid, '\n');
    print_both(fid, '------------------------------------------------------------------------\n\n');

    % --- Section C: 逐时电网能量平衡 ---
    print_both(fid, '【Section C: 逐时电网全域能量平衡表 (MW)】\n');
    print_both(fid, ' 时段 | 总负荷需求 | 物理弃负荷 | 光伏消纳 | EDG出力 | MESS出力 | EV 出力 | 主网供给 | 弃电量(废电) \n');
    print_both(fid, '------------------------------------------------------------------------------------------------------\n');
    tot_demand = sum(Res.Demand_Mat, 1);
    tot_shed = sum(Res.Shed_Mat, 1);
    tot_pv = sum(Res.PV_Mat, 1);
    tot_edg = sum(Res.EDG_Mat, 1); 
    total_spill = 0;

    for t = 1:24
        mess_act = sum(Res.P_M_Act(:, t));
        ev_act = sum(Res.P_E_Act(:, t));
        grid_p = sum(Res.Gen_Mat(:, t));
        edg_act = tot_edg(t);
        
        p_spill = Res.Spill_T(t);
        total_spill = total_spill + p_spill;
        
        print_both(fid, ' T=%02d |   %8.3f |   %8.3f | %8.3f | %7.3f | %8.3f | %7.3f | %8.3f |   %8.3f \n', ...
            t, tot_demand(t), tot_shed(t), tot_pv(t), edg_act, mess_act, ev_act, grid_p, p_spill);
    end
    print_both(fid, '------------------------------------------------------------------------------------------------------\n');
    print_both(fid, '       [全天弃电累计]: %8.3f MWh\n\n', total_spill);

    % --- Section D: 重构与交通映射 ---
    print_both(fid, '【Section D: 联络线重构状态 (1=连通) & MESS 交通路网位置 (T-Node) 】\n');
    print_both(fid, ' 时段 | T-33 | T-34 | T-35 | T-36 | T-37 || M1 路网位置 | M2 路网位置 \n');
    print_both(fid, '-------------------------------------------------------------------------\n');
    power_to_traffic_map = [1,1,2,3,3,4,5,6,7,8,8,9,10,10,11,12,13,14,15,15,16,17,18,19,20,21,22,23,24,25,22,23,25];
    for t = 1:24
        p1 = MESS_Schedule(1,t); p2 = MESS_Schedule(2,t);
        t1_str = '在途...'; if p1 ~= -1, t1_str = sprintf('T-%02d', power_to_traffic_map(p1)); end
        t2_str = '在途...'; if p2 ~= -1, t2_str = sprintf('T-%02d', power_to_traffic_map(p2)); end
        print_both(fid, ' T=%02d |   %d  |   %d  |   %d  |   %d  |   %d  ||  %8s   |  %8s \n', ...
            t, Reconfig_Plan(1,t), Reconfig_Plan(2,t), Reconfig_Plan(3,t), Reconfig_Plan(4,t), Reconfig_Plan(5,t), t1_str, t2_str);
    end
    print_both(fid, '\n');

    % --- Section E: 拓扑演化 ---
    print_both(fid, '【Section E: 孤岛划分结果与拓扑动态演化档案】\n');
    print_both(fid, ' 时段 | 孤岛总数 | 详细孤岛组成 (主网 = Isl1)\n');
    print_both(fid, '------------------------------------------------------------------------------------------------------------------------\n');
    for t = 1:Env.NT
        bins = Island_Nodes_Cell{t};
        island_desc = '';
        for i = 1:max(bins)
            nodes_in_i = find(bins == i);
            island_desc = [island_desc, sprintf('Isl%d:{%s}  ', i, strtrim(num2str(nodes_in_i)))];
        end
        print_both(fid, ' T=%02d |    %d     | %s\n', t, max(bins), island_desc);
    end
    print_both(fid, '\n');

    % --- Section F: 33 节点微观物理账本 ---
    print_both(fid, '【Section F: 33 节点全天微观物理账本 (MWh)】\n');
    print_both(fid, ' 节点编号 | 节点属性 | 全天总需求 | 实际断电量 | 断电率(%%) | 光伏总产出 | EDG总兜底 \n');
    print_both(fid, '------------------------------------------------------------------------------------------\n');
    node_demands = sum(Res.Demand_Mat, 2);
    node_sheds = sum(Res.Shed_Mat, 2);
    node_pvs = sum(Res.PV_Mat, 2);
    node_edgs = sum(Res.EDG_Mat, 2);
    for n = 1:Env.NB
        attr = '普通负荷'; if ismember(n, Env.Idx_Essential), attr = '关键医院'; end
        shed_rate = 0; if node_demands(n) > 1e-4, shed_rate = (node_sheds(n) / node_demands(n)) * 100; end
        print_both(fid, ' Node %02d  | %s |   %8.3f |   %8.3f |   %6.2f %% |   %8.3f |   %8.3f \n', ...
            n, attr, node_demands(n), node_sheds(n), shed_rate, node_pvs(n), node_edgs(n));
    end
    print_both(fid, '------------------------------------------------------------------------------------------\n\n');

    % --- Section G: MESS 物理与财务流水账 ---
    print_both(fid, '【Section G: 移动储能 (MESS) 物理与财务流水表】\n');
    print_both(fid, ' * 注：功率为正代表放电(赚取CNY)，为负代表充电(花费CNY)。\n');
    print_both(fid, ' 时段 | M1位置(孤岛) | M1功率 | M1_SOC | M1收支(CNY) || M2位置(孤岛) | M2功率 | M2_SOC | M2收支(CNY) \n');
    print_both(fid, '---------------------------------------------------------------------------------------------------------\n');
    net_profit_m = zeros(1, 2);
    for t = 1:24
        p1 = MESS_Schedule(1,t); p2 = MESS_Schedule(2,t);
        s1 = sprintf('%02d(%d)', p1, Island_Matrix(max(1,p1), t)); if p1 == -1, s1 = '在途(0)'; end
        s2 = sprintf('%02d(%d)', p2, Island_Matrix(max(1,p2), t)); if p2 == -1, s2 = '在途(0)'; end
        
        act1 = Res.P_M_Act(1,t); act2 = Res.P_M_Act(2,t);
        cash1 = act1 * 1000 * target_price(t); net_profit_m(1) = net_profit_m(1) + cash1;
        cash2 = act2 * 1000 * target_price(t); net_profit_m(2) = net_profit_m(2) + cash2;
        
        print_both(fid, ' T=%02d | %10s | %6.3f | %6.3f |  %+9.2f  || %10s | %6.3f | %6.3f |  %+9.2f \n', ...
            t, s1, act1, Res.SOC_M(1,t), cash1, s2, act2, Res.SOC_M(2,t), cash2);
    end
    print_both(fid, '---------------------------------------------------------------------------------------------------------\n');
    print_both(fid, ' [全天净利润] MESS 1: %+9.2f CNY  |  MESS 2: %+9.2f CNY\n\n', net_profit_m(1), net_profit_m(2));

    % --- Section H: EV 物理与财务流水账 ---
    print_both(fid, '【Section H: 电动汽车 (EV) 物理与财务流水表】\n');
    print_both(fid, ' 时段 | EV1(无私)功率 | EV1_SOC | EV1收支(CNY) || EV2(自私)功率 | EV2_SOC | EV2收支(CNY) || EV3(自私)功率 | EV3_SOC | EV3收支(CNY) \n');
    print_both(fid, '-----------------------------------------------------------------------------------------------------------------------------------------\n');
    net_profit_e = zeros(1, 3);
    for t = 1:24
        act1 = Res.P_E_Act(1,t); cash1 = act1 * 1000 * target_price(t); net_profit_e(1) = net_profit_e(1) + cash1;
        act2 = Res.P_E_Act(2,t); cash2 = act2 * 1000 * target_price(t); net_profit_e(2) = net_profit_e(2) + cash2;
        act3 = Res.P_E_Act(3,t); cash3 = act3 * 1000 * target_price(t); net_profit_e(3) = net_profit_e(3) + cash3;
        print_both(fid, ' T=%02d |      %8.3f | %7.3f |    %+9.2f ||      %8.3f | %7.3f |    %+9.2f ||      %8.3f | %7.3f |    %+9.2f \n', ...
            t, act1, Res.SOC_E(1,t), cash1, act2, Res.SOC_E(2,t), cash2, act3, Res.SOC_E(3,t), cash3);
    end
    print_both(fid, '-----------------------------------------------------------------------------------------------------------------------------------------\n');
    print_both(fid, ' [全天净利润] EV 1 (无私): %+9.2f CNY | EV 2 (自私): %+9.2f CNY | EV 3 (自私): %+9.2f CNY\n\n', net_profit_e(1), net_profit_e(2), net_profit_e(3));

    % --- Section I: 电网安全指标 ---
    print_both(fid, '【Section I: 电网底层安全边界 (电压极值) 】\n');
    print_both(fid, ' 时段 | 最低电压(p.u.) | 最高电压(p.u.) | 孤岛节点数 | 发生越限? \n');
    print_both(fid, '-----------------------------------------------------------------\n');
    for t = 1:24
        v = Res.V_Mat(:, t);
        v = v(v > 0);
        v_min = min(v); v_max = max(v);
        island_nodes = sum(Island_Matrix(:, t));
        if isempty(v)
            v_min = NaN; v_max = NaN; violation = '失电';
        elseif v_min < Env.V_MIN - 1e-8 || v_max > Env.V_MAX + 1e-8
            violation = '是';
        else
            violation = '否';
        end
        print_both(fid, ' T=%02d |       %6.4f |       %6.4f |       %4d |     %s \n', t, v_min, v_max, island_nodes, violation);
    end
    print_both(fid, '\n');

    fprintf(fid, '\n============================================ 报告 %s 结束 ============================================\n', str_label);
    fclose(fid);
    
    % 收集横向对比数据
    % 1:关键缺电, 2:普通缺电, 3:总成本, 4:停电(min), 5:废电量, 6:主网购电, 7:柴发发电, 8/9:MESS利润, 10/11/12:EV利润
    Summary_Data(k, :) = [tot_ess_shed, tot_ord_shed, tot_cost, tot_outage, total_spill, ...
                          tot_grid_import, tot_edg_used, net_profit_m(1), net_profit_m(2), ...
                          net_profit_e(1), sum(net_profit_e(2:3))]; % 把两个自私型EV利润加起来看
end

% =========================================================================
% Phase 4: 生成简化横向对比总表 (Comparative Summary)
% =========================================================================
summary_file = fullfile(data_dir, 'Comparative_Summary_Report.txt');
fid_sum = fopen(summary_file, 'w', 'n', 'UTF-8');

fprintf(fid_sum, '==========================================================================================\n');
fprintf(fid_sum, '                    四大均衡策略 (S4_A ~ S4_D) 横向对比摘要报告\n');
fprintf(fid_sum, '==========================================================================================\n\n');

fprintf(fid_sum, ' 评估维度 / 核心指标       |  S4_A (保供优先) |  S4_B (经济优先) |  S4_C (恢复优先) |  S4_D (全局均衡)\n');
fprintf(fid_sum, '---------------------------|------------------|------------------|------------------|------------------\n');
fprintf(fid_sum, ' 关键负荷缺电量 (MWh)      | %16.3f | %16.3f | %16.3f | %16.3f \n', Summary_Data(1,1), Summary_Data(2,1), Summary_Data(3,1), Summary_Data(4,1));
fprintf(fid_sum, ' 普通负荷缺电量 (MWh)      | %16.3f | %16.3f | %16.3f | %16.3f \n', Summary_Data(1,2), Summary_Data(2,2), Summary_Data(3,2), Summary_Data(4,2));
fprintf(fid_sum, ' 关键节点停电时长 (分钟)   | %16.0f | %16.0f | %16.0f | %16.0f \n', Summary_Data(1,4), Summary_Data(2,4), Summary_Data(3,4), Summary_Data(4,4));
fprintf(fid_sum, ' 调度中心激励总成本 (kCNY) | %16.3f | %16.3f | %16.3f | %16.3f \n', Summary_Data(1,3), Summary_Data(2,3), Summary_Data(3,3), Summary_Data(4,3));
fprintf(fid_sum, ' 系统总弃电量/废电 (MWh)   | %16.3f | %16.3f | %16.3f | %16.3f \n', Summary_Data(1,5), Summary_Data(2,5), Summary_Data(3,5), Summary_Data(4,5));
fprintf(fid_sum, '---------------------------|------------------|------------------|------------------|------------------\n');
fprintf(fid_sum, ' MESS 1 净利润 (CNY)       | %16.2f | %16.2f | %16.2f | %16.2f \n', Summary_Data(1,8), Summary_Data(2,8), Summary_Data(3,8), Summary_Data(4,8));
fprintf(fid_sum, ' MESS 2 净利润 (CNY)       | %16.2f | %16.2f | %16.2f | %16.2f \n', Summary_Data(1,9), Summary_Data(2,9), Summary_Data(3,9), Summary_Data(4,9));
fprintf(fid_sum, ' EV 1 (无私型) 利润 (CNY)  | %16.2f | %16.2f | %16.2f | %16.2f \n', Summary_Data(1,10), Summary_Data(2,10), Summary_Data(3,10), Summary_Data(4,10));
fprintf(fid_sum, ' EV 2+3 (自私型) 总润(CNY) | %16.2f | %16.2f | %16.2f | %16.2f \n', Summary_Data(1,11), Summary_Data(2,11), Summary_Data(3,11), Summary_Data(4,11));
fprintf(fid_sum, '==========================================================================================\n');
fclose(fid_sum);

fprintf('\n>>> 完美完成！5 份全息报告已批量生成并存至 Data 目录下！\n');


% =========================================================================
% 辅助函数
% =========================================================================
function print_both(fid, format, varargin)
    % 注：为保持控制台清爽，批量生成时不再输出巨长底账到控制台，仅写入文件。
    % 若需调试可取消下一行的注释。
    % fprintf(format, varargin{:}); 
    fprintf(fid, format, varargin{:});
end

function Res = local_objective_wrapper_detailed(price_seq, Env, start_h, py_adapter, Island_Mat)
    N_MESS = 2; N_EV = 3; Horizon = 24;
    Res.SOC_M = zeros(N_MESS, Horizon); Res.SOC_E = zeros(N_EV, Horizon);
    Res.P_M_Cmd = zeros(N_MESS, Horizon); Res.P_E_Cmd = zeros(N_EV, Horizon);
    Res.P_M_Act = zeros(N_MESS, Horizon); Res.P_E_Act = zeros(N_EV, Horizon);
    Res.Shed_Mat = zeros(Env.NB, Horizon); Res.Gen_Mat =  zeros(Env.NB, Horizon);
    Res.Demand_Mat = zeros(Env.NB, Horizon); Res.PV_Mat = zeros(Env.NB, Horizon);
    Res.V_Mat = zeros(Env.NB, Horizon); Res.Cost_T = zeros(1, Horizon);
    Res.EDG_Mat = zeros(Env.NB, Horizon);
    Res.Outage_T = zeros(1, Horizon); Res.Spill_T = zeros(1, Horizon);
    
    curr_soc_m = [0.9, 0.9]; curr_soc_e = [0.65, 0.65, 0.65];
    
    for t = 1:Horizon
        m_sched_t = Env.MESS_Schedule(:, t);
        m_isl_t = zeros(2, 1);
        for m = 1:2, if m_sched_t(m) > 0, m_isl_t(m) = Island_Mat(m_sched_t(m), t); end, end
        e_isl_t = zeros(3, 1);
        for e = 1:3, e_isl_t(e) = Island_Mat(Env.Idx_EV(e), t); end
        
        py_m_sched_t = py.list(num2cell(int32(m_sched_t'))); 
        py_m_isl_t   = py.list(num2cell(int32(m_isl_t'))); 
        py_e_isl_t   = py.list(num2cell(int32(e_isl_t')));
        py_soc_m = py.list(num2cell(curr_soc_m)); 
        py_soc_e = py.list(num2cell(curr_soc_e));
        
        py_resp_flat = py_adapter.get_batch_step_response(...
            py.list({price_seq(t)}), py_soc_m, py_soc_e, py_m_sched_t, py_m_isl_t, py_e_isl_t, int32(start_h), int32(t));
        
        act_arr = double(py_resp_flat);
        p_m_cmd = act_arr(1:2); p_e_cmd = act_arr(3:5);
        
        [~, s_cost, s_outage, p_m_act_mw, p_e_act_mw, Extra] = Env.step_simulation(t, price_seq(t), p_m_cmd, p_e_cmd);
        
        Res.SOC_M(:, t) = curr_soc_m'; Res.SOC_E(:, t) = curr_soc_e';
        Res.P_M_Cmd(:, t) = p_m_cmd'; Res.P_E_Cmd(:, t) = p_e_cmd';
        Res.P_M_Act(:, t) = p_m_act_mw'; Res.P_E_Act(:, t) = p_e_act_mw';
        Res.Shed_Mat(:, t) = Extra.Shed_Matrix_Col; Res.Gen_Mat(:, t) = Extra.Gen_Matrix_Col;
        Res.V_Mat(:, t) = Extra.V_Mag; Res.Cost_T(t) = s_cost;
        Res.Outage_T(t) = s_outage; Res.Spill_T(t) = sum(Extra.PV_Spill_MW);
        Res.EDG_Mat(:, t) = Extra.EDG_Matrix_Col; 
        
        [P_L, ~, P_PV] = Env.get_snapshot_state(t);
        Res.Demand_Mat(:, t) = P_L * Env.BASE_MVA; Res.PV_Mat(:, t) = Extra.PV_Act_MW;
        
        curr_soc_m = max(0.10, min(0.95, curr_soc_m - (p_m_act_mw / 2.0))); 
        curr_soc_e = max(0.10, min(0.95, curr_soc_e - (p_e_act_mw / 1.0)));
    end
end