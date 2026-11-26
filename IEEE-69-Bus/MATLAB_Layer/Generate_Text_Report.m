%% Generate_Text_Report.m - V17.1 终极动态兼容批量生成与横向对比版
% =========================================================================
%   [目标] 一键生成四大策略(S4_A, S4_B, S4_C, S4_D)的完整底层物理底账，
%          并额外生成 1 份横向对比报告 (Comparative_Summary_Report.txt)。
%   [升级 V17.1] 彻底删除布尔化冗余拓扑计算，全面接入 GridEnv 的原生 Area ID。
%   [升级 V17.0] 彻底解耦硬编码，全面自适应 IEEE 69 节点 (及任意规模网络)。
%   [输出] Data 目录下共计 5 个 TXT 报告文件。
% =========================================================================

clc; clear; close all;
warning('off', 'all');

% --- YALMIP 路径安全防护 ---
yalmip_root = getenv('YALMIP_ROOT');
if ~isempty(yalmip_root), addpath(genpath(yalmip_root)); end
assert(exist('sdpvar','file') == 2, 'Install YALMIP and add it to the MATLAB path.');

fprintf('\n>>> 启动终极报告引擎 (V17.1 动态兼容批量多策略版)...\n');

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
NB = Env.NB; 
NT = Env.NT;

% 推理与拓扑报告共用 Area ID：主网为 0，独立孤岛为 1..N。
Island_Matrix = Env.Python_Area_ID_Daily;

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
    
    Res = local_objective_wrapper_detailed(target_price, Env, START_HOUR, py_adapter, Island_Matrix);
    
    report_file = fullfile(data_dir, sprintf('Detailed_Simulation_Report_%s.txt', str_label));
    fid = fopen(report_file, 'w', 'n', 'UTF-8');
    
    print_both(fid, '====================================================================================================================================\n');
    print_both(fid, '                                 微电网灾后应急博弈全息运行超级底账 - 策略: %s (%s) \n', str_label, str_title);
    print_both(fid, '====================================================================================================================================\n\n');

    tot_ess_shed = sum(sum(Res.Shed_Mat(Env.Idx_Essential, :)));
    tot_ord_shed = sum(sum(Res.Shed_Mat(Env.Idx_Ordinary, :)));
    tot_cost = sum(Res.Cost_T) / 1000;
    tot_outage = sum(Res.Outage_T);
    
    Summary_Data(k, 1) = tot_ess_shed;
    Summary_Data(k, 2) = tot_ord_shed;
    Summary_Data(k, 3) = tot_cost;
    Summary_Data(k, 4) = tot_outage;
    
    print_both(fid, '【一】 宏观系统指标总览 (Global Metrics)\n');
    print_both(fid, '------------------------------------------------------------------------------------------------------------------------------------\n');
    print_both(fid, ' > 关键供暖失负荷 (Essential Shedding): %10.3f MWh   (决定生死的底线指标)\n', tot_ess_shed);
    print_both(fid, ' > 普通失负荷 (Ordinary Shedding)     : %10.3f MWh   (决定生活质量的辅助指标)\n', tot_ord_shed);
    print_both(fid, ' > 上层博弈总激励支出 (Total Cost)    : %10.3f kCNY  (DSO的经济压力)\n', tot_cost);
    print_both(fid, ' > 关键负荷累计等效停电              : %10.1f mins\n\n', tot_outage);

    print_both(fid, '【二】 博弈核心：动态电价指令演化 (Dynamic Pricing)\n');
    print_both(fid, '------------------------------------------------------------------------------------------------------------------------------------\n');
    print_both(fid, '   Time | Price (CNY/kWh)\n');
    for t = 1:NT
        print_both(fid, '  T=%02d  | %12.3f \n', t, target_price(t));
    end
    print_both(fid, '\n');

    print_both(fid, '【三】 移动储能集群 (MESS) 物理响应细节 (含意图-现实验证)\n');
    print_both(fid, '------------------------------------------------------------------------------------------------------------------------------------\n');
    tot_m_ch = 0; tot_m_dis = 0;
    for m = 1:2
        print_both(fid, '[MESS %d] 响应轨迹记录:\n', m);
        print_both(fid, '   Time | 物理阵地 (Pos) | AI指令意图 (Cmd MW) | 真实落地位 (Act MW) | 荷电状态 (SOC) | 响应评估\n');
        for t = 1:NT
            pos = MESS_Schedule(m, t);
            if pos == -1, pos_str = ' 在途/待命'; else, pos_str = sprintf('Node %02d   ', pos); end
            cmd = Res.P_M_Cmd(m, t); act = Res.P_M_Act(m, t); soc = Res.SOC_M(m, t);
            
            if act > 0, tot_m_dis = tot_m_dis + act; elseif act < 0, tot_m_ch = tot_m_ch + act; end
            
            if abs(cmd - act) < 1e-4, status = '完美执行';
            elseif act == 0 && abs(cmd) > 1e-4, status = '物理拦截 (越限或孤岛空置)';
            else, status = '降级折损 (受限执行)'; end
            
            print_both(fid, '  T=%02d  | %s   | %16.3f    | %16.3f    |   %8.2f   | %s\n', t, pos_str, cmd, act, soc, status);
        end
        print_both(fid, '  --- 累计充电: %.3f MWh | 累计放电: %.3f MWh ---\n\n', abs(tot_m_ch), tot_m_dis);
    end
    Summary_Data(k, 5) = abs(tot_m_ch); Summary_Data(k, 6) = tot_m_dis;

    print_both(fid, '【四】 电动汽车集群 (EV) 物理响应细节 (抗极寒冻结特性)\n');
    print_both(fid, '------------------------------------------------------------------------------------------------------------------------------------\n');
    tot_e_ch = 0; tot_e_dis = 0;
    for e = 1:3
        print_both(fid, '[EV %d 聚合商 @ Node %02d] 响应轨迹记录:\n', e, Env.Idx_EV(e));
        print_both(fid, '   Time | 物理在网 (Avail) | AI指令意图 (Cmd) | 真实落地位 (Act) | 荷电状态 (SOC) | 响应评估\n');
        for t = 1:NT
            avail = Env.EV_Avail_Daily(e, t);
            if avail == 1, avail_str = ' [并网]'; else, avail_str = ' [离网]'; end
            cmd = Res.P_E_Cmd(e, t); act = Res.P_E_Act(e, t); soc = Res.SOC_E(e, t);
            
            if act > 0, tot_e_dis = tot_e_dis + act; elseif act < 0, tot_e_ch = tot_e_ch + act; end
            
            if avail == 0 && act == 0, status = '离网免责';
            elseif abs(cmd - act) < 1e-4, status = '完美执行';
            elseif act == 0 && abs(cmd) > 1e-4, status = 'SOC触底/爆顶拦截';
            else, status = '功率降级执行'; end
            
            print_both(fid, '  T=%02d  |  %s        | %14.3f   | %14.3f   |   %8.2f   | %s\n', t, avail_str, cmd, act, soc, status);
        end
        print_both(fid, '  --- 累计充电: %.3f MWh | 累计放电: %.3f MWh ---\n\n', abs(tot_e_ch), tot_e_dis);
    end
    Summary_Data(k, 7) = abs(tot_e_ch); Summary_Data(k, 8) = tot_e_dis;
    
    print_both(fid, '【五】 极寒保供引擎：应急柴发 (EDG) 与 关键负荷失能审计\n');
    print_both(fid, '------------------------------------------------------------------------------------------------------------------------------------\n');
    print_both(fid, '   Time | PV发电 (MW) | EDG兜底 (MW) | 关键节点失负荷 (Essential) | 普通节点失负荷 (Ordinary)\n');
    tot_pv_gen = 0; tot_edg_gen = 0;
    for t = 1:NT
        pv = sum(Res.PV_Mat(:, t)); edg = sum(Res.EDG_Mat(:, t));
        ess_shed = sum(Res.Shed_Mat(Env.Idx_Essential, t));
        ord_shed = sum(Res.Shed_Mat(Env.Idx_Ordinary, t));
        tot_pv_gen = tot_pv_gen + pv; tot_edg_gen = tot_edg_gen + edg;
        print_both(fid, '  T=%02d  | %10.3f  | %11.3f  | %18.3f           | %18.3f\n', t, pv, edg, ess_shed, ord_shed);
    end
    Summary_Data(k, 9) = tot_pv_gen; Summary_Data(k, 10) = tot_edg_gen;
    print_both(fid, '\n');

    print_both(fid, '【六】 配电网潮流电压极值监测 (V_min=0.90, V_max=1.10)\n');
    print_both(fid, '------------------------------------------------------------------------------------------------------------------------------------\n');
    print_both(fid, '   Time | 孤岛数量 | 网络连通性快照                     | 绝低电压 (Min p.u.) | 绝高电压 (Max p.u.) | 安全状态\n');
    
    max_volt_all = 0; min_volt_all = 999;
    for t = 1:NT
        area_ids = Island_Matrix(:, t);
        num_islands = max(area_ids);
        island_desc = sprintf('[主网区:%02d]', sum(area_ids == 0));
        for isl = 1:num_islands
            n_count = sum(area_ids == isl);
            island_desc = [island_desc, sprintf('[孤岛%d:%02d]', isl, n_count)];
        end
        if length(island_desc) > 30, island_desc = [island_desc(1:27), '...']; end
        
        v_col = Res.V_Mat(:, t);
        v_valid = v_col(~isnan(v_col)); % 过滤出所有存活节点的电压
        if isempty(v_valid)
            min_v = 0.000; max_v = 0.000; % 极端情况：全网死绝
        else
            min_v = min(v_valid); max_v = max(v_valid);
        end
        if min_v < min_volt_all, min_volt_all = min_v; end
        if max_v > max_volt_all, max_volt_all = max_v; end
        
        if min_v < Env.V_MIN - 1e-8 || max_v > Env.V_MAX + 1e-8, s_stat = '⚠️ 越界警告'; else, s_stat = '✅ 稳定运行'; end
        print_both(fid, '  T=%02d  | %7d  | %-34s | %18.3f  | %18.3f  | %s\n', t, num_islands, island_desc, min_v, max_v, s_stat);
    end
    Summary_Data(k, 11) = min_volt_all;
    
    fclose(fid);
end

% =========================================================================
% Phase 4: 生成横向对比总结报告 (Comparative Summary)
% =========================================================================
fprintf('    正在生成横向对比报告...\n');
comp_file = fullfile(data_dir, 'Comparative_Summary_Report.txt');
f_comp = fopen(comp_file, 'w', 'n', 'UTF-8');

print_both(f_comp, '====================================================================================================\n');
print_both(f_comp, '                  多智能体强化学习 (DRO-MADDPG) 四大极值演化策略横向对比总账\n');
print_both(f_comp, '====================================================================================================\n\n');

metrics_names = {
    '关键负荷总缺电量 (MWh)',
    '普通负荷总缺电量 (MWh)',
    '调度激励总成本 (kCNY)',
    '关键节点停电时长 (Mins)',
    'MESS 全天总充电量 (MWh)',
    'MESS 应急总放电量 (MWh)',
    'EV 集群全天总充电量 (MWh)',
    'EV 集群应急总放电量 (MWh)',
    '全网光伏总消纳量 (MWh)',
    '柴发应急总发电量 (MWh)',
    '系统最低电压极值 (p.u.)'
};

print_both(f_comp, '【核心指标横向扫描】\n');
print_both(f_comp, '----------------------------------------------------------------------------------------------------\n');
print_both(f_comp, '%-26s | %12s | %12s | %12s | %12s\n', '物理审计指标名称', 'S4_A(保供)', 'S4_B(经济)', 'S4_C(恢复)', 'S4_D(均衡)');
print_both(f_comp, '----------------------------------------------------------------------------------------------------\n');

for idx = 1:11
    print_both(f_comp, '%-26s | %12.3f | %12.3f | %12.3f | %12.3f\n', ...
        metrics_names{idx}, Summary_Data(1, idx), Summary_Data(2, idx), Summary_Data(3, idx), Summary_Data(4, idx));
end
print_both(f_comp, '----------------------------------------------------------------------------------------------------\n');

fclose(f_comp);

fprintf('\n>>> 完美完成！5 份全息报告 (支持任意拓扑规模) 已批量生成并存至 Data 目录下！\n');

% =========================================================================
% 辅助函数
% =========================================================================
function print_both(fid, format, varargin)
    fprintf(fid, format, varargin{:});
end

function Res = local_objective_wrapper_detailed(price_seq, Env, start_h, py_adapter, Island_Mat)
    N_MESS = 2; N_EV = 3; Horizon = 24;
    Res.SOC_M = zeros(N_MESS, Horizon); Res.SOC_E = zeros(N_EV, Horizon);
    Res.P_M_Cmd = zeros(N_MESS, Horizon); Res.P_E_Cmd = zeros(N_EV, Horizon);
    Res.P_M_Act = zeros(N_MESS, Horizon); Res.P_E_Act = zeros(N_EV, Horizon);
    Res.Shed_Mat = zeros(Env.NB, Horizon); Res.Outage_T = zeros(1, Horizon);
    Res.Demand_Mat = zeros(Env.NB, Horizon); Res.PV_Mat = zeros(Env.NB, Horizon);
    Res.V_Mat = zeros(Env.NB, Horizon); Res.Cost_T = zeros(1, Horizon);
    Res.EDG_Mat = zeros(Env.NB, Horizon); 
    
    curr_soc_m = [0.9, 0.9]; curr_soc_e = [0.65, 0.65, 0.65];
    
    for t = 1:Horizon
        m_sched_t = Env.MESS_Schedule(:, t);
        m_isl_t = zeros(2, 1);
        
        % [V17.1 对齐修复] 直接提取真实 Area ID，不在网的赋予虚拟 0
        for m = 1:2
            if m_sched_t(m) > 0
                m_isl_t(m) = Island_Mat(m_sched_t(m), t); 
            else
                m_isl_t(m) = 0; 
            end
        end
        
        e_isl_t = zeros(3, 1);
        for e = 1:3
            e_isl_t(e) = Island_Mat(Env.Idx_EV(e), t); 
        end
        
        py_m_sched_t = py.list(num2cell(int32(m_sched_t'))); 
        py_m_isl_t   = py.list(num2cell(int32(m_isl_t'))); 
        py_e_isl_t   = py.list(num2cell(int32(e_isl_t')));
        
        py_price_t = py.list({price_seq(t)});
        py_soc_m = py.list(num2cell(curr_soc_m)); 
        py_soc_e = py.list(num2cell(curr_soc_e));
        
        py_resp_flat = py_adapter.get_batch_step_response(...
            py_price_t, py_soc_m, py_soc_e, py_m_sched_t, py_m_isl_t, py_e_isl_t, int32(start_h), int32(t));
        
        act_arr = double(py_resp_flat);
        p_m_cmd = act_arr(1:2); p_e_cmd = act_arr(3:5);
        
        [~, s_cost, s_outage, p_m_act_mw, p_e_act_mw, Extra] = Env.step_simulation(t, price_seq(t), p_m_cmd, p_e_cmd);
        
        Res.SOC_M(:, t) = curr_soc_m'; Res.SOC_E(:, t) = curr_soc_e';
        Res.P_M_Cmd(:, t) = p_m_cmd'; Res.P_E_Cmd(:, t) = p_e_cmd';
        Res.P_M_Act(:, t) = p_m_act_mw'; Res.P_E_Act(:, t) = p_e_act_mw';
        Res.Shed_Mat(:, t) = Extra.Shed_Matrix_Col; Res.Outage_T(t) = s_outage;
        Res.V_Mat(:, t) = Extra.V_Mag; Res.Cost_T(t) = s_cost;        
        Res.EDG_Mat(:, t) = Extra.EDG_Matrix_Col; 
        
        [P_L, ~, ~] = Env.get_snapshot_state(t);
        Res.Demand_Mat(:, t) = P_L * Env.BASE_MVA; Res.PV_Mat(:, t) = Extra.PV_Act_MW;
        
        curr_soc_m = curr_soc_m - (p_m_act_mw(:)' / 2.0); 
        curr_soc_e = curr_soc_e - (p_e_act_mw(:)' / 1.0);
        
        curr_soc_m = max(0.10, min(0.95, curr_soc_m)); 
        curr_soc_e = max(0.10, min(0.95, curr_soc_e));
    end
end
