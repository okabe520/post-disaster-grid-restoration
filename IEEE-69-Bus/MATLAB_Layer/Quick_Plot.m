%% Quick_Plot.m - V13.0 (IEEE 69 节点动态兼容版 & 4D Pareto Utopia Edition)
% =========================================================================
%   ★ 灾后应急调度系统 - 全息可视化分析工具 (四大场景升级版) ★
%   [升级 V13.0] 彻底解耦硬编码，全面自适应 IEEE 69 节点 (及任意节点网络)。
%   [升级 V12.9] 引入三大极值优先 + 一大全局均衡 (基于归一化理想点最小欧氏距离)。
%   [升级 V12.0] 全面升级配色系统 (基于 Nature Science 经典色系)。
% =========================================================================

clc; 
close all;
warning('off', 'all');

% --- [核心修复] 强行将 YALMIP 置于路径最顶层 ---
yalmip_root = getenv('YALMIP_ROOT');
if ~isempty(yalmip_root), addpath(genpath(yalmip_root)); end
assert(exist('sdpvar','file') == 2, 'Install YALMIP and add it to the MATLAB path.');

% --- 0. 全局高级学术样式设置 ---
set(0, 'DefaultFigureColor', 'w');
set(0, 'DefaultAxesColor', 'w');
set(0, 'DefaultAxesFontName', 'Helvetica'); % 顶刊极简字体
set(0, 'DefaultTextFontName', 'Helvetica');
set(0, 'DefaultAxesFontSize', 11);
set(0, 'DefaultLineLineWidth', 1.5);
set(0, 'DefaultAxesTickDir', 'out'); % 刻度线向外，更清爽

% 顶级期刊常用配色字典 (Nature Publishing Group Style)
C_RED    = '#E64B35';
C_BLUE   = '#4DBBD5';
C_GREEN  = '#00A087';
C_NAVY   = '#3C5488';
C_ORANGE = '#F39B7F';
C_PURPLE = '#8491B4';
C_GRAY   = '#7E818D';
C_EDG    = '#B0BEC5'; % 稳重的浅灰色，代表柴发基荷

fprintf('\n>>> [Quick_Plot V13.0] 启动高级学术审美绘图引擎 (IEEE 69 兼容版)...\n');

% =========================================================================
%                     Phase 1: 环境与安全数据加载
% =========================================================================
yalmip('clear');
current_path = fileparts(mfilename('fullpath'));
data_file = fullfile(current_path, '..', 'Data', 'Optimization_Result.mat');
scen_file = fullfile(current_path, '..', 'Data', 'scenario.mat');
strat_file = fullfile(current_path, '..', 'Data', 'strategy.mat');
curve_file = fullfile(current_path, '..', 'Data', 'curve.mat');

if exist(data_file, 'file')
    temp_data = load(data_file);
    if isfield(temp_data, 'Env'), temp_data = rmfield(temp_data, 'Env'); end
    if isfield(temp_data, 'MESS_Actor'), temp_data = rmfield(temp_data, 'MESS_Actor'); end
    if isfield(temp_data, 'py_adapter'), temp_data = rmfield(temp_data, 'py_adapter'); end
    vars = fieldnames(temp_data);
    for i = 1:length(vars), assignin('caller', vars{i}, temp_data.(vars{i})); end
else
    error('错误：找不到 Optimization_Result.mat！请先运行 Main_NSGA3。');
end

Env = GridEnv(); 
load(strat_file, 'Reconfig_Plan', 'MESS_Schedule');

NB = Env.NB; % 动态获取节点数 (例如 69)
NT = Env.NT; 
NL = Env.NL; % 动态获取总线路数 (骨干+联络)
Island_Matrix = Env.Python_Area_ID_Daily;
raw_branches = Env.mpc.branch(:, 1:2);

try d_curve = load(curve_file); sim_start_h = d_curve.START_HOUR; catch, sim_start_h = 0; end

% =========================================================================
% 唤醒 Python 闭环引擎
% =========================================================================
try
    pe = pyenv;
    python_exe = getenv('STACKELBERG_PYTHON'); 
    if pe.Status == "NotLoaded" && ~isempty(python_exe)
        try pyenv('Version', python_exe, 'ExecutionMode', 'OutOfProcess');
        catch, pyenv('Version', python_exe, 'ExecutionMode', 'InProcess'); end
    end
    python_layer_path = fullfile(current_path, '..', 'Python_Layer');
    if count(py.sys.path, python_layer_path) == 0
        insert(py.sys.path, int32(0), python_layer_path);
    end
    asm = py.importlib.import_module('agent_server');
    py.importlib.reload(asm); 
    py_adapter = asm.adapter; 
catch ME
    error('Python 接口连接失败: %s', ME.message);
end

% =========================================================================
%                     Phase 2: 全局物理指标重算
% =========================================================================
[PopSize, ~] = size(x_opt);
Phys_Metrics = zeros(PopSize, 5); 

fprintf('    正在计算物理指标 (共需进行 %d 次 24小时闭环推演，预计 1-2 分钟)...\n', PopSize);
h_wait = waitbar(0, '正在拆解闭环物理指标 (AI 推理 + 物理校验)...');

for i = 1:PopSize
    price_strategy = x_opt(i, :);
    Res = local_objective_wrapper_detailed(price_strategy, Env, sim_start_h, py_adapter, Island_Matrix);
    shed_ess_MWh = sum(sum(Res.Shed_Mat(Env.Idx_Essential, :)));
    shed_ord_MWh = sum(sum(Res.Shed_Mat(Env.Idx_Ordinary, :)));
    cost_kCNY = f_val(i, 2) / 1000;
    outage_mins = f_val(i, 3);
    Phys_Metrics(i, :) = [shed_ess_MWh, shed_ord_MWh, cost_kCNY, outage_mins, i];
    
    if mod(i, 5) == 0
        waitbar(i/PopSize, h_wait, sprintf('进度: %d / %d 个策略', i, PopSize));
        fprintf('      ... 已处理 %d / %d \n', i, PopSize);
    end
end
close(h_wait);
fprintf('    -> 物理指标拆解完成！开始绘制高级学术图表...\n');

% =========================================================================
%                     Phase 3: 典型场景筛选 (V12.9 四大场景升级版)
% =========================================================================
[~, sort_idx_shed] = sort(Phys_Metrics(:, 1) + Phys_Metrics(:, 2)); 
idx_min_shed = Phys_Metrics(sort_idx_shed(1), 5);  

[~, sort_idx_cost] = sort(Phys_Metrics(:, 3));
idx_min_cost = Phys_Metrics(sort_idx_cost(1), 5); 

[~, sort_idx_outage] = sort(Phys_Metrics(:, 4));
idx_min_outage = Phys_Metrics(sort_idx_outage(1), 5); 

norm_shed = (Phys_Metrics(:,1)+Phys_Metrics(:,2)) / max(Phys_Metrics(:,1)+Phys_Metrics(:,2) + 1e-6);
norm_cost = Phys_Metrics(:,3) / max(Phys_Metrics(:,3) + 1e-6);
norm_out  = Phys_Metrics(:,4) / max(Phys_Metrics(:,4) + 1e-6);
dist_to_utopia = sqrt(norm_shed.^2 + norm_cost.^2 + norm_out.^2);
[~, sort_idx_bal] = sort(dist_to_utopia);
idx_balanced = Phys_Metrics(sort_idx_bal(1), 5);      

indices_to_show = [idx_min_shed, idx_min_cost, idx_min_outage, idx_balanced];
labels = {'场景 A (保供优先)', '场景 B (经济优先)', '场景 C (恢复优先)', '场景 D (全局均衡)'};
file_tags = {'MinShed', 'MinCost', 'MinOutage', 'Balanced'};
p_colors = {C_RED, C_BLUE, C_PURPLE, C_GREEN}; 

save_dir = fullfile(Env.Abs_Data_Dir, 'Figures_V13_Aesthetic');
if ~exist(save_dir, 'dir'), mkdir(save_dir); end

% =========================================================================
%                     Phase 4: Theme 0 - 4D 物理 Pareto 前沿
% =========================================================================
f0 = figure('Name', 'Theme 0 - Physical Pareto', 'Color', 'w', 'Position', [100, 100, 900, 600]);
scatter3(Phys_Metrics(:, 1), Phys_Metrics(:, 2), Phys_Metrics(:, 3), 60, Phys_Metrics(:, 4), 'filled', 'MarkerFaceAlpha', 0.8);
hold on; grid on; 
colormap(parula); 
cb = colorbar; ylabel(cb, '关键停电 (min)', 'FontWeight', 'bold');

for k = 1:4
    row_id = find(Phys_Metrics(:, 5) == indices_to_show(k));
    pt = Phys_Metrics(row_id, :);
    plot3(pt(1), pt(2), pt(3), 'p', 'MarkerSize', 20, 'MarkerFaceColor', p_colors{k}, 'MarkerEdgeColor', 'w', 'LineWidth', 1.0);
    text(pt(1), pt(2), pt(3), sprintf('  %s', labels{k}), 'FontSize', 11, 'FontWeight', 'bold', 'Color', 'k');
end

xlabel('关键缺电 (MWh)'); ylabel('普通缺电 (MWh)'); zlabel('激励成本 (kCNY)');
title('多目标博弈Pareto前沿'); 
view(135, 25);
local_save_fig(f0, save_dir, 'Theme0_Physical_Pareto_4Scenarios');

% =========================================================================
%                     Phase 5: 详细场景展示 (升级为 4 场景循环)
% =========================================================================
for k = 1:4
    idx = indices_to_show(k);
    price_k = x_opt(idx, :);
    Res = local_objective_wrapper_detailed(price_k, Env, sim_start_h, py_adapter, Island_Matrix);
    
    tot_demand = sum(Res.Demand_Mat, 1); 
    tot_pv = sum(Res.PV_Mat, 1);
    tot_edg = sum(Res.EDG_Mat, 1); 
    tot_shed = sum(Res.Shed_Mat, 1); 
    tot_supplied = tot_demand - tot_shed;
    
    % --- Theme 1: 宏观策略电价变化 ---
    f1 = figure('Name', 'Theme 1 Price Only', 'Color', 'w', 'Position', [50, 50, 1000, 420]);
    h_bar = bar(1:24, price_k, 0.7, 'FaceColor', C_NAVY, 'FaceAlpha', 0.6, 'EdgeColor', 'none');
    xlabel('时间 (h)', 'FontWeight', 'bold'); ylabel('动态电价 (CNY/kWh)', 'FontWeight', 'bold'); 
    ylim([0, 3.5]); xlim([0.5 24.5]); xticks(1:24); grid on;
    title(sprintf('%s - 动态电价时序演化图', labels{k}), 'FontWeight', 'bold'); 
    legend(h_bar, {'动态电价'}, 'Location', 'southoutside', 'Orientation', 'horizontal', 'FontSize', 10);
    local_save_fig(f1, save_dir, sprintf('S%d_%s_T1_PriceOnly', k, file_tags{k}));
    
    % --- Theme 2: 闭环 MESS 意图与现实 ---
    f2 = figure('Name', 'Theme 2 MESS', 'Color', 'w', 'Position', [100, 100, 1000, 420]);
    x_stairs = 0.5:1:24.5; ax = zeros(1, 2); 
    for m = 1:2
        ax(m) = subplot(1, 2, m); 
        yyaxis left;
        cmd_ext = [Res.P_M_Cmd(m, :), Res.P_M_Cmd(m, end)];
        h_cmd = stairs(x_stairs, cmd_ext, 'Color', C_GRAY, 'LineWidth', 2.0, 'LineStyle', '--'); hold on;
        c_act = C_BLUE; if m == 2, c_act = C_GREEN; end
        h_act = bar(1:24, Res.P_M_Act(m, :), 0.65, 'FaceColor', c_act, 'FaceAlpha', 0.85, 'EdgeColor', 'none'); 
        ylabel('充放电功率 (MW)', 'FontWeight', 'bold'); ylim([-0.6 0.6]);
        yyaxis right; 
        h_soc = plot(1:24, Res.SOC_M(m, :), '-o', 'Color', C_RED, 'MarkerFaceColor', 'w', 'LineWidth', 1.5); 
        ylabel('荷电状态 (SOC)', 'FontWeight', 'bold'); ylim([0 1]);
        title(sprintf('MESS %d 运行状态', m), 'FontWeight', 'bold'); 
        xlim([0.5 24.5]); grid on;
        if m == 1, leg_handles = [h_cmd, h_act, h_soc]; end
    end
    hL = legend(ax(1), leg_handles, {'智能体指令 (Cmd)', '实际响应 (Act)', '荷电状态 (SOC)'}, 'Orientation', 'horizontal', 'NumColumns', 3, 'FontSize', 10);
    set(hL, 'Units', 'normalized', 'Position', [0.35, 0.02, 0.3, 0.05]);
    for i = 1:2, pos = get(ax(i), 'Position'); pos(2) = 0.15; pos(4) = 0.72; set(ax(i), 'Position', pos); end
    local_save_fig(f2, save_dir, sprintf('S%d_%s_T2_MESS_ClosedLoop', k, file_tags{k}));

    % --- Theme 3: 闭环 EV 意图与现实 ---
    f3 = figure('Name', 'Theme 3 EV', 'Color', 'w', 'Position', [150, 150, 1200, 420]);
    colors_ev = {C_ORANGE, C_BLUE, C_PURPLE}; ax_ev = zeros(1, 3);
    for e = 1:3
        ax_ev(e) = subplot(1, 3, e); 
        yyaxis left;
        cmd_ext = [Res.P_E_Cmd(e, :), Res.P_E_Cmd(e, end)];
        h_cmd = stairs(x_stairs, cmd_ext, 'Color', C_GRAY, 'LineWidth', 2.0, 'LineStyle', '--'); hold on;
        h_act = bar(1:24, Res.P_E_Act(e, :), 0.65, 'FaceColor', colors_ev{e}, 'FaceAlpha', 0.85, 'EdgeColor', 'none'); 
        ylabel('功率 (MW)', 'FontWeight', 'bold'); ylim([-0.4 0.4]); set(gca, 'YColor', 'k');
        yyaxis right; 
        h_soc = plot(1:24, Res.SOC_E(e, :), '-s', 'Color', C_NAVY, 'MarkerFaceColor', 'w', 'LineWidth', 1.5, 'MarkerSize', 4); 
        ylabel('SOC', 'FontWeight', 'bold'); ylim([0 1]); set(gca, 'YColor', C_NAVY);
        title(sprintf('EV 聚合商 %d', e), 'FontWeight', 'bold'); xlabel('时间 (h)'); xlim([0.5 24.5]); grid on;
        if e == 1, leg_handles_ev = [h_cmd, h_act, h_soc]; end
    end
    hL_ev = legend(ax_ev(1), leg_handles_ev, {'指令 (Cmd)', '物理响应 (Act)', '荷电状态 (SOC)'}, 'Orientation', 'horizontal', 'NumColumns', 3, 'FontSize', 10);
    set(hL_ev, 'Units', 'normalized', 'Position', [0.35, 0.01, 0.3, 0.05], 'Color', 'w');
    sub_width = 0.22; sub_gap = 0.10; left_edge = 0.06;
    for i = 1:3
        pos_ev = get(ax_ev(i), 'Position'); pos_ev(2) = 0.20; pos_ev(4) = 0.68; 
        pos_ev(1) = left_edge + (i-1) * (sub_width + sub_gap); pos_ev(3) = sub_width; set(ax_ev(i), 'Position', pos_ev);
    end
    local_save_fig(f3, save_dir, sprintf('S%d_%s_T3_EV_ClosedLoop', k, file_tags{k}));

    % --- Theme 4: 全局能量平衡 Area ---
    f4 = figure('Name', 'Theme 4 Balance', 'Color', 'w', 'Position', [200, 200, 850, 450]);
    tot_charging = sum(abs(min(0, Res.P_M_Act)), 1) + sum(abs(min(0, Res.P_E_Act)), 1);
    grid_export = max(0, -Res.Grid_MW);
    storage_discharge = sum(max(0, Res.P_M_Act), 1) + sum(max(0, Res.P_E_Act), 1);
    other_supply = max(0, Res.Grid_MW) + storage_discharge;
    assert(all(abs(tot_pv + tot_edg + other_supply - ...
        (tot_supplied + tot_charging + grid_export)) < 1e-5), ...
        'Power-balance plot inputs do not reconcile with the solved dispatch.');
    Stack_Mat = [tot_pv', tot_edg', other_supply', tot_shed'];
    
    h_area = area(1:24, Stack_Mat, 'EdgeColor', 'none');
    h_area(1).FaceColor = '#FFC107'; h_area(2).FaceColor = C_EDG; h_area(3).FaceColor = C_GREEN; h_area(4).FaceColor = C_RED;     
    hold on;
    h_line_base = plot(1:24, tot_demand, 'k--', 'LineWidth', 1.5); 
    h_line_total = plot(1:24, tot_demand + tot_charging + grid_export, '-', 'Color', '#222222', 'LineWidth', 2.0);
    title(sprintf('%s - 全局能量平衡', labels{k})); xlim([1 24]); box on; grid on;
    legend([h_area(1), h_area(2), h_area(3), h_area(4), h_line_base, h_line_total], ...
           {'光伏实际出力', '柴发实际出力', '主网输入与储能放电', '失负荷量', '原始负荷线', '负荷、充电与主网反送'}, ...
           'Location', 'southoutside', 'Orientation', 'horizontal', 'NumColumns', 3);
    local_save_fig(f4, save_dir, sprintf('S%d_%s_T4_PowerBalance', k, file_tags{k}));
    
    % --- Theme 5 & 6: 热力图 (动态兼容任意节点数 NB) ---
    f5 = figure('Name', 'Theme 5 Voltage', 'Color', 'w', 'Position', [250, 250, 750, 450]);
    
    % [核心视觉升级] 让 NaN(死岛) 显示为透明/白色留白！
    h_im = imagesc(1:24, 1:NB, Res.V_Mat); 
    set(h_im, 'AlphaData', ~isnan(Res.V_Mat)); 
    
    colormap(gca, parula); 
    cb = colorbar; title(cb, '电压 (p.u.)'); caxis([0.85, 1.15]); hold on; 
    
    % 越界标识 (同样自动无视 NaN)
    [r, c] = find(Res.V_Mat < Env.V_MIN - 1e-8 | Res.V_Mat > Env.V_MAX + 1e-8);
    if ~isempty(r), scatter(c, r, 20, 'wx', 'LineWidth', 1.2); end
    title(sprintf('%s - 节点电压热力图', labels{k})); 
    yticks(1:ceil(NB/15):NB); xticks(1:24); set(gca, 'YDir', 'reverse');
    local_save_fig(f5, save_dir, sprintf('S%d_%s_T5_Voltage', k, file_tags{k}));

    f6 = figure('Name', 'Theme 6 Shed Heatmap', 'Color', 'w', 'Position', [300, 300, 750, 450]);
    shed_perc = Res.Shed_Mat ./ (Res.Demand_Mat + 1e-6) * 100; shed_perc(shed_perc < 1) = 0;
    imagesc(1:24, 1:NB, shed_perc); 
    base_hot = flipud(hot(256)); cmap_alert = base_hot(1:220, :); colormap(gca, cmap_alert);
    cb = colorbar; title(cb, '失负荷百分比 (%)'); caxis([0 100]);
    title(sprintf('%s - 节点失负荷百分比分布', labels{k})); 
    yticks(1:ceil(NB/15):NB); xticks(1:24); set(gca, 'YDir', 'reverse');
    hold on; 
    for i = 0.5:1:(NB+0.5), plot([0.5, 24.5], [i, i], 'Color', [0.9 0.9 0.9], 'LineWidth', 0.5); end
    for j = 0.5:1:24.5, plot([j, j], [0.5, (NB+0.5)], 'Color', [0.9 0.9 0.9], 'LineWidth', 0.5); end
    local_save_fig(f6, save_dir, sprintf('S%d_%s_T6_Shedding', k, file_tags{k}));

    % --- Theme 7: MESS 空间轨迹 (动态兼容节点上限) ---
    f7 = figure('Name', 'Theme 7 Trajectory', 'Color', 'w', 'Position', [350, 350, 700, 420]);
    stairs(1:24, MESS_Schedule(1, :), 'LineWidth', 2.5, 'Color', C_BLUE); hold on;
    stairs(1:24, MESS_Schedule(2, :), 'LineWidth', 2.5, 'Color', C_RED);
    yline(0, '-', '在途 / 待命区', 'Color', C_GRAY, 'LabelVerticalAlignment', 'bottom'); 
    
    for n = Env.Idx_Essential'
        yline(n, ':', 'Color', [0.8 0.4 0.4 0.6], 'LineWidth', 1.2);
    end
    
    title(sprintf('%s - MESS 空间转移与驻留轨迹', labels{k})); 
    % 动态生成 Y 轴刻度，避免挤作一团
    y_ticks_dynamic = [0, round(linspace(1, NB, 7))];
    yticks(unique(y_ticks_dynamic)); ylim([-2 NB+2]); xlim([1 24]); grid on;
    legend('MESS 1 轨迹', 'MESS 2 轨迹', 'Location', 'southoutside', 'Orientation', 'horizontal');
    local_save_fig(f7, save_dir, sprintf('S%d_%s_T7_Trajectory', k, file_tags{k}));

    % --- Theme 8: 拓扑重构计划 (动态读取真实联络线) ---
    f8 = figure('Name', 'Theme 8 Reconfig', 'Color', 'w', 'Position', [400, 400, 800, 300]);
    ties = Reconfig_Plan; 
    tie_names = cell(1, 5);
    % 动态生成联络线名称标签 (提取最后 5 条线)
    for t_idx = 1:5
        branch_idx = NL - 5 + t_idx;
        tie_names{t_idx} = sprintf('Tie %d-%d', raw_branches(branch_idx, 1), raw_branches(branch_idx, 2));
    end
    
    hold on;
    for tie_idx = 1:5
        for t = 1:24
            if ties(tie_idx, t) == 1
                rectangle('Position', [t-0.45, tie_idx-0.3, 0.9, 0.6], 'FaceColor', C_GREEN, 'EdgeColor', 'none');
            else
                rectangle('Position', [t-0.45, tie_idx-0.3, 0.9, 0.6], 'FaceColor', '#F5F5F5', 'EdgeColor', 'none');
            end
        end
    end
    yticks(1:5); yticklabels(tie_names); xlim([0.5 24.5]); axis([0.5 24.5 0.5 5.5]);
    title(sprintf('%s - 联络线动作时序', labels{k}));
    local_save_fig(f8, save_dir, sprintf('S%d_%s_T8_Reconfig', k, file_tags{k}));

    % --- Theme 9: 博弈现金流 ---
    f9 = figure('Name', 'Theme 9 Cash Flow', 'Color', 'w', 'Position', [450, 450, 650, 350]);
    bar(1:24, Res.Cost_T / 1000, 0.6, 'FaceColor', C_NAVY, 'EdgeColor', 'none');
    title(sprintf('%s - 上层总支出', labels{k})); ylabel('支出 (kCNY)'); xlim([0.5 24.5]); grid on;
    local_save_fig(f9, save_dir, sprintf('S%d_%s_T9_CashFlow', k, file_tags{k}));

    % --- Theme 10: 柔性资源物理响应堆叠 ---
    f10 = figure('Name', 'Theme 10 Flex Stack', 'Color', 'w', 'Position', [500, 500, 700, 400]);
    stack_data = [sum(Res.P_M_Act, 1)', sum(Res.P_E_Act, 1)', tot_edg'];
    b = bar(1:24, stack_data, 'stacked', 'EdgeColor', 'none');
    b(1).FaceColor = C_BLUE; b(2).FaceColor = C_ORANGE; b(3).FaceColor = C_EDG; 
    title(sprintf('%s - 灵活性资源出力堆叠图', labels{k})); ylabel('注入功率 (MW)'); xlim([0.5 24.5]); grid on;
    legend('MESS 集群出力', 'EV 集群出力', 'EDG 应急柴发基荷', 'Location', 'southoutside', 'Orientation', 'horizontal');
    local_save_fig(f10, save_dir, sprintf('S%d_%s_T10_FlexStack', k, file_tags{k}));

    % --- Theme 11: 独立交通路网映射轨迹 (动态兼容网络尺度) ---
    f11 = figure('Name', 'Theme 11 Traffic Trajectory', 'Color', 'w', 'Position', [550, 550, 750, 400]);
    % 根据节点总数动态生成一个平滑的虚拟交通映射规律 (代替原本定死的33节点map)
    power_to_traffic_map = mod((1:NB) * 7, ceil(NB/2)) + 1; 
    
    Traffic_Sched = zeros(2, 24);
    for m = 1:2
        for t = 1:24
            if MESS_Schedule(m, t) == -1
                Traffic_Sched(m, t) = 0; 
            else
                Traffic_Sched(m, t) = power_to_traffic_map(MESS_Schedule(m, t));
            end
        end
    end
    
    stairs(1:24, Traffic_Sched(1, :), '-o', 'LineWidth', 2.5, 'MarkerSize', 6, 'Color', C_BLUE, 'MarkerFaceColor', 'w'); hold on;
    stairs(1:24, Traffic_Sched(2, :), '-s', 'LineWidth', 2.5, 'MarkerSize', 6, 'Color', C_RED,  'MarkerFaceColor', 'w');
    yline(0, '-', '在途 / 待命区', 'Color', C_GRAY, 'LabelVerticalAlignment', 'bottom'); 
    
    hosp_traffic_nodes = unique(power_to_traffic_map(Env.Idx_Essential));
    for n = hosp_traffic_nodes
        yline(n, ':', 'Color', [0.8 0.4 0.4 0.6], 'LineWidth', 1.5);
    end
    
    title(sprintf('%s - MESS 交通路网调度轨迹', labels{k}), 'FontWeight', 'bold'); 
    ylabel('交通网节点编号', 'FontWeight', 'bold'); xlabel('时间 (h)', 'FontWeight', 'bold');
    
    max_t_node = max(power_to_traffic_map);
    yticks([0, round(linspace(1, max_t_node, 6))]); ylim([-2 max_t_node+2]); xlim([1 24]); grid on;
    legend('MESS 1 轨迹', 'MESS 2 轨迹', 'Location', 'southoutside', 'Orientation', 'horizontal');
    local_save_fig(f11, save_dir, sprintf('S%d_%s_T11_TrafficNet', k, file_tags{k}));

    close all; 
end

fprintf('\n★ Quick Plot V13.0 运行完成！四大场景图表已存入 Data/Figures_V13_Aesthetic ★\n');

%% =========================================================================
%                 辅助函数
% ==========================================================================
function local_save_fig(fig_handle, dir_path, tag)
    fname = fullfile(dir_path, tag);
    try 
        exportgraphics(fig_handle, [fname, '.png'], 'Resolution', 300); 
    catch
        saveas(fig_handle, [fname, '.png']); 
    end
end

function Res = local_objective_wrapper_detailed(price_seq, Env, start_h, py_adapter, Island_Mat)
    N_MESS = 2; N_EV = 3; Horizon = 24;
    Res.SOC_M = zeros(N_MESS, Horizon); Res.SOC_E = zeros(N_EV, Horizon);
    Res.P_M_Cmd = zeros(N_MESS, Horizon); Res.P_E_Cmd = zeros(N_EV, Horizon);
    Res.P_M_Act = zeros(N_MESS, Horizon); Res.P_E_Act = zeros(N_EV, Horizon);
    Res.Shed_Mat = zeros(Env.NB, Horizon); Res.Grid_MW = zeros(1, Horizon);
    Res.Demand_Mat = zeros(Env.NB, Horizon); Res.PV_Mat = zeros(Env.NB, Horizon);
    Res.V_Mat = zeros(Env.NB, Horizon); Res.Cost_T = zeros(1, Horizon);
    Res.EDG_Mat = zeros(Env.NB, Horizon); 
    
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
        
        py_price_t = py.list({price_seq(t)});
        py_soc_m = py.list(num2cell(curr_soc_m)); 
        py_soc_e = py.list(num2cell(curr_soc_e));
        
        py_resp_flat = py_adapter.get_batch_step_response(...
            py_price_t, py_soc_m, py_soc_e, py_m_sched_t, py_m_isl_t, py_e_isl_t, int32(start_h), int32(t));
        
        act_arr = double(py_resp_flat);
        p_m_cmd = act_arr(1:2); p_e_cmd = act_arr(3:5);
        
        [~, s_cost, ~, p_m_act_mw, p_e_act_mw, Extra] = Env.step_simulation(t, price_seq(t), p_m_cmd, p_e_cmd);
        
        Res.SOC_M(:, t) = curr_soc_m'; Res.SOC_E(:, t) = curr_soc_e';
        Res.P_M_Cmd(:, t) = p_m_cmd'; Res.P_E_Cmd(:, t) = p_e_cmd';
        Res.P_M_Act(:, t) = p_m_act_mw'; Res.P_E_Act(:, t) = p_e_act_mw';
        Res.Shed_Mat(:, t) = Extra.Shed_Matrix_Col; Res.Grid_MW(t) = Extra.Grid_MW;
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
