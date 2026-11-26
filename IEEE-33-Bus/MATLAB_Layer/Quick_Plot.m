%% Quick_Plot.m - V12.9 (EDG Integrated & 4D Pareto Utopia Edition)
% =========================================================================
%   ★ 灾后应急调度系统 - 全息可视化分析工具 (四大场景升级版) ★
%   [升级 V12.9] 引入三大极值优先 + 一大全局均衡 (基于归一化理想点最小欧氏距离)。
%   [升级 V12.9] 画图引擎支持 4 大典型场景的独立生成与比对。
%   [升级 V12.0] 全面升级配色系统 (基于 Nature Science 经典色系)。
%   [升级 V12.0] AI 指令可视化由"空心柱"改为"阶梯虚线 (Stairs)"，画面大幅降噪。
%   [物理升级 V12.8] 深度融合应急柴发 (EDG) 物理数据。
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
C_EDG    = '#B0BEC5'; % [新增] 稳重的浅灰色，代表柴发实际出力

fprintf('\n>>> [Quick_Plot V12.9] 启动高级学术审美绘图引擎 (四大场景进化版)...\n');

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

NB = Env.NB; 
NT = Env.NT; 
Island_Matrix = zeros(NB, NT);
raw_branches = Env.mpc.branch(:, 1:2);

for t = 1:NT
    status_backbone = Env.Line_Status_Daily(1:32, t);
    status_ties = Env.Line_Status_Daily(33:37, t) & Reconfig_Plan(:, t);
    status = [status_backbone; status_ties];
    active = find(status == 1);
    G = graph(raw_branches(active, 1), raw_branches(active, 2), [], NB);
    bins = conncomp(G);
    for n = 1:NB
        if bins(n) ~= bins(1), Island_Matrix(n, t) = 1; end
    end
end

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
    Res = local_objective_wrapper_detailed(price_strategy, Env, sim_start_h, py_adapter, Env.Python_Area_ID_Daily);
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
% 1. 提取三个维度的极端优先解
[~, sort_idx_shed] = sort(Phys_Metrics(:, 1) + Phys_Metrics(:, 2)); 
idx_min_shed = Phys_Metrics(sort_idx_shed(1), 5);  % 缺电最小 (保供优先)

[~, sort_idx_cost] = sort(Phys_Metrics(:, 3));
idx_min_cost = Phys_Metrics(sort_idx_cost(1), 5);  % 成本最小 (经济优先)

[~, sort_idx_outage] = sort(Phys_Metrics(:, 4));
idx_min_outage = Phys_Metrics(sort_idx_outage(1), 5); % 停电最小 (恢复优先)

% 2. 提取真正的 3D 空间均衡解 (基于归一化理想点距离)
norm_shed = (Phys_Metrics(:,1)+Phys_Metrics(:,2)) / max(Phys_Metrics(:,1)+Phys_Metrics(:,2) + 1e-6);
norm_cost = Phys_Metrics(:,3) / max(Phys_Metrics(:,3) + 1e-6);
norm_out  = Phys_Metrics(:,4) / max(Phys_Metrics(:,4) + 1e-6);
dist_to_utopia = sqrt(norm_shed.^2 + norm_cost.^2 + norm_out.^2);
[~, sort_idx_bal] = sort(dist_to_utopia);
idx_balanced = Phys_Metrics(sort_idx_bal(1), 5);      % 均衡妥协

% 3. 组合四大场景
indices_to_show = [idx_min_shed, idx_min_cost, idx_min_outage, idx_balanced];
labels = {'场景 A (保供优先)', '场景 B (经济优先)', '场景 C (恢复优先)', '场景 D (全局均衡)'};
file_tags = {'MinShed', 'MinCost', 'MinOutage', 'Balanced'};
p_colors = {C_RED, C_BLUE, C_PURPLE, C_GREEN}; 

save_dir = fullfile(Env.Abs_Data_Dir, 'Figures_V12_Aesthetic');
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
    Res = local_objective_wrapper_detailed(price_k, Env, sim_start_h, py_adapter, Env.Python_Area_ID_Daily);
    
    tot_demand = sum(Res.Demand_Mat, 1); 
    tot_pv = sum(Res.PV_Mat, 1);
    tot_edg = sum(Res.EDG_Mat, 1); 
    tot_shed = sum(Res.Shed_Mat, 1); 
    tot_supplied = tot_demand - tot_shed;
    
    % --- Theme 1: 宏观策略电价变化 (纯净版) ---
    f1 = figure('Name', 'Theme 1 Price Only', 'Color', 'w', 'Position', [50, 50, 1000, 420]);

    % 绘制动态电价
    h_bar = bar(1:24, price_k, 0.7, 'FaceColor', C_NAVY, 'FaceAlpha', 0.6, 'EdgeColor', 'none');

    % 坐标轴设置
    xlabel('时间 (h)', 'FontWeight', 'bold');
    ylabel('动态电价 (CNY/kWh)', 'FontWeight', 'bold'); 
    ylim([0, 3.5]); 
    xlim([0.5 24.5]); 
    xticks(1:24);

    % 图形美化与标题
    grid on;
    title(sprintf('%s - 动态电价时序演化图', labels{k}), 'FontWeight', 'bold'); 

    % 图例设置 (居中放在图表下方)
    legend(h_bar, {'动态电价'}, 'Location', 'southoutside', 'Orientation', 'horizontal', 'FontSize', 10);

    % 保存图像 (文件名加了后缀以作区分)
    local_save_fig(f1, save_dir, sprintf('S%d_%s_T1_PriceOnly', k, file_tags{k}));
    
    % --- Theme 2: 闭环 MESS 意图与现实 ---
    f2 = figure('Name', 'Theme 2 MESS', 'Color', 'w', 'Position', [100, 100, 1000, 420]);
    x_stairs = 0.5:1:24.5; 
    
    % 预分配坐标轴数组，保存左右两个子图的句柄
    ax = zeros(1, 2); 
    
    for m = 1:2
        ax(m) = subplot(1, 2, m); 
        
        yyaxis left;
        cmd_ext = [Res.P_M_Cmd(m, :), Res.P_M_Cmd(m, end)];
        h_cmd = stairs(x_stairs, cmd_ext, 'Color', C_GRAY, 'LineWidth', 2.0, 'LineStyle', '--'); 
        hold on;
        
        c_act = C_BLUE; if m == 2, c_act = C_GREEN; end
        h_act = bar(1:24, Res.P_M_Act(m, :), 0.65, 'FaceColor', c_act, 'FaceAlpha', 0.85, 'EdgeColor', 'none'); 
        ylabel('充放电功率 (MW)', 'FontWeight', 'bold'); 
        ylim([-0.6 0.6]);
        
        yyaxis right; 
        h_soc = plot(1:24, Res.SOC_M(m, :), '-o', 'Color', C_RED, 'MarkerFaceColor', 'w', 'LineWidth', 1.5); 
        ylabel('荷电状态 (SOC)', 'FontWeight', 'bold'); 
        ylim([0 1]);
        
        title(sprintf('MESS %d 运行状态', m), 'FontWeight', 'bold'); 
        xlim([0.5 24.5]); grid on;
        
        % 记录左图的句柄，准备在循环外部统一生成全局图例
        if m == 1
            leg_handles = [h_cmd, h_act, h_soc];
        end
    end
    
    % 【核心修复】在循环外部生成全局图例，彻底剥离与左图的自动排版绑定
    hL = legend(ax(1), leg_handles, ...
        {'智能体指令 (Cmd)', '实际物理响应 (Act)', '荷电状态 (SOC)'}, ...
        'Orientation', 'horizontal', 'NumColumns', 3, 'FontSize', 10);
    
    % 强制绝对定位：将图例放置在全图底部的正中央
    set(hL, 'Units', 'normalized', 'Position', [0.35, 0.02, 0.3, 0.05]);
    
    % 【终极兼容性修复】：使用 get 和 set 修改 Position，兼容所有 MATLAB 版本
    for i = 1:2
        pos = get(ax(i), 'Position');
        pos(2) = 0.15; % 统一抬高底边
        pos(4) = 0.72; % 统一设定高度
        set(ax(i), 'Position', pos);
    end
    
    local_save_fig(f2, save_dir, sprintf('S%d_%s_T2_MESS_ClosedLoop', k, file_tags{k}));

    % --- Theme 3: 闭环 EV 意图与现实 (发表级排版优化) ---
    f3 = figure('Name', 'Theme 3 EV', 'Color', 'w', 'Position', [150, 150, 1200, 420]);
    colors_ev = {C_ORANGE, C_BLUE, C_PURPLE};
    
    % 预分配坐标轴句柄数组
    ax_ev = zeros(1, 3);
    
    for e = 1:3
        ax_ev(e) = subplot(1, 3, e); 
        
        % 左侧 Y 轴：功率维度
        yyaxis left;
        cmd_ext = [Res.P_E_Cmd(e, :), Res.P_E_Cmd(e, end)];
        h_cmd = stairs(x_stairs, cmd_ext, 'Color', C_GRAY, 'LineWidth', 2.0, 'LineStyle', '--'); 
        hold on;
        
        h_act = bar(1:24, Res.P_E_Act(e, :), 0.65, 'FaceColor', colors_ev{e}, 'FaceAlpha', 0.85, 'EdgeColor', 'none'); 
        ylabel('充放电功率 (MW)', 'FontWeight', 'bold'); 
        ylim([-0.4 0.4]);
        set(gca, 'YColor', 'k');
        
        % 右侧 Y 轴：状态维度
        yyaxis right; 
        h_soc = plot(1:24, Res.SOC_E(e, :), '-s', 'Color', C_NAVY, 'MarkerFaceColor', 'w', 'LineWidth', 1.5, 'MarkerSize', 4); 
        ylabel('荷电状态 (SOC)', 'FontWeight', 'bold'); 
        ylim([0 1]);
        set(gca, 'YColor', C_NAVY);
        
        % 标题与坐标轴美化
        title(sprintf('EV 聚合商 %d 运行状态', e), 'FontWeight', 'bold'); 
        xlabel('时间 (h)');
        xlim([0.5 24.5]); 
        grid on;
        
        % 捕获第一组句柄用于生成全局图例
        if e == 1
            leg_handles_ev = [h_cmd, h_act, h_soc];
        end
    end

    % 【核心修复 1】生成全局图例并脱离自动排版约束
    hL_ev = legend(ax_ev(1), leg_handles_ev, ...
        {'智能体指令 (Cmd)', '实际物理响应 (Act)', '荷电状态 (SOC)'}, ...
        'Orientation', 'horizontal', 'NumColumns', 3, 'FontSize', 10);
    
    % 【关键防重叠 1】：绝对定位图例并向下微调，设置白色背景以防线条穿透
    set(hL_ev, 'Units', 'normalized', 'Position', [0.35, 0.01, 0.3, 0.05], 'Color', 'w');
    
    % 【关键防重叠 2 & 3】：彻底接管 X轴和 Y轴的绝对排版 (防高度挤压 + 防横向文字重叠)
    sub_width = 0.22;  % 适度压缩每个子图的绝对宽度
    sub_gap = 0.10;    % 大幅拉开子图之间的横向安全间距
    left_edge = 0.06;  % 图纸最左侧的留白起点

    for i = 1:3
        pos_ev = get(ax_ev(i), 'Position');
        
        % 1. 调整高度与底边距 (避开图例)
        pos_ev(2) = 0.20; 
        pos_ev(4) = 0.68; 
        
        % 2. 调整横向位置与宽度 (彻底解决 Y 轴文字撞车)
        pos_ev(1) = left_edge + (i-1) * (sub_width + sub_gap); 
        pos_ev(3) = sub_width; 
        
        % 应用新坐标
        set(ax_ev(i), 'Position', pos_ev);
    end

    local_save_fig(f3, save_dir, sprintf('S%d_%s_T3_EV_ClosedLoop', k, file_tags{k}));

    % --- Theme 4: 全局能量平衡 Area (纯堆叠绝对闭环版) ---
    f4 = figure('Name', 'Theme 4 Balance', 'Color', 'w', 'Position', [200, 200, 850, 450]);
    
    tot_charging = sum(abs(min(0, Res.P_M_Act)), 1) + sum(abs(min(0, Res.P_E_Act)), 1);
    grid_net = sum(Res.Gen_Mat, 1);
    grid_export = max(0, -grid_net);
    storage_discharge = sum(max(0,Res.P_M_Act),1) + sum(max(0,Res.P_E_Act),1);
    other_supply = max(0,grid_net) + storage_discharge;
    assert(all(abs(tot_pv + tot_edg + other_supply - ...
        (tot_supplied + tot_charging + grid_export)) < 1e-5));
    Stack_Mat = [tot_pv', tot_edg', other_supply', tot_shed'];

    h_area = area(1:24, Stack_Mat, 'EdgeColor', 'none');
    h_area(1).FaceColor = '#FFC107'; % 光伏 - 明黄
    h_area(2).FaceColor = C_EDG;     % 柴发 - 稳重灰
    h_area(3).FaceColor = C_GREEN;   % 其他供电 - 护眼绿
    h_area(4).FaceColor = C_RED;     % 失负荷 - 警示红
    
    hold on;
    h_line_base = plot(1:24, tot_demand, 'k--', 'LineWidth', 1.5); 
    h_line_total = plot(1:24, tot_demand + tot_charging + grid_export, '-', 'Color', '#222222', 'LineWidth', 2.0);
    
    title(sprintf('%s - 全局能量平衡', labels{k})); 
    xlim([1 24]); box on; grid on;
    
    legend([h_area(1), h_area(2), h_area(3), h_area(4), h_line_base, h_line_total], ...
           {'光伏实际消纳', '柴发实际出力', '主网与储能放电', '失负荷量', '原始总负荷线', '含充电总负荷线'}, ...
           'Location', 'southoutside', 'Orientation', 'horizontal', 'NumColumns', 3);
           
    local_save_fig(f4, save_dir, sprintf('S%d_%s_T4_PowerBalance', k, file_tags{k}));
    
    % --- Theme 5 & 6: 热力图 ---
    f5 = figure('Name', 'Theme 5 Voltage', 'Color', 'w', 'Position', [250, 250, 750, 450]);
    voltage_image = imagesc(1:24, 1:33, Res.V_Mat);
    set(voltage_image, 'AlphaData', Res.V_Mat > 0);
    colormap(gca, parula); 
    cb = colorbar; title(cb, '电压 (p.u.)'); caxis([0.85, 1.15]);
    hold on; 
    live_voltage = Res.V_Mat > 0;
    [r, c] = find(live_voltage & (Res.V_Mat < Env.V_MIN - 1e-8 | Res.V_Mat > Env.V_MAX + 1e-8));
    if ~isempty(r), scatter(c, r, 20, 'wx', 'LineWidth', 1.2); end
    title(sprintf('%s - 节点电压热力图', labels{k})); 
    yticks(1:2:33); xticks(1:24); set(gca, 'YDir', 'reverse');
    local_save_fig(f5, save_dir, sprintf('S%d_%s_T5_Voltage', k, file_tags{k}));

    f6 = figure('Name', 'Theme 6 Shed Heatmap', 'Color', 'w', 'Position', [300, 300, 750, 450]);
    shed_perc = Res.Shed_Mat ./ (Res.Demand_Mat + 1e-6) * 100; 
    shed_perc(shed_perc < 1) = 0;
    imagesc(1:24, 1:33, shed_perc); 
    
    base_hot = flipud(hot(256)); 
    cmap_alert = base_hot(1:220, :); 
    colormap(gca, cmap_alert);
    
    cb = colorbar; title(cb, '失负荷百分比 (%)'); caxis([0 100]);
    title(sprintf('%s - 节点失负荷百分比分布', labels{k})); 
    yticks(1:2:33); xticks(1:24); set(gca, 'YDir', 'reverse');
    
    hold on; 
    for i = 0.5:1:33.5, plot([0.5, 24.5], [i, i], 'Color', [0.9 0.9 0.9], 'LineWidth', 0.5); end
    for j = 0.5:1:24.5, plot([j, j], [0.5, 33.5], 'Color', [0.9 0.9 0.9], 'LineWidth', 0.5); end
    local_save_fig(f6, save_dir, sprintf('S%d_%s_T6_Shedding', k, file_tags{k}));

    % --- Theme 7: MESS 空间轨迹 ---
    f7 = figure('Name', 'Theme 7 Trajectory', 'Color', 'w', 'Position', [350, 350, 700, 420]);
    stairs(1:24, MESS_Schedule(1, :), 'LineWidth', 2.5, 'Color', C_BLUE); hold on;
    stairs(1:24, MESS_Schedule(2, :), 'LineWidth', 2.5, 'Color', C_RED);
    yline(0, '-', '在途 / 待命区', 'Color', C_GRAY, 'LabelVerticalAlignment', 'bottom'); 
    
    ess_nodes = [6, 14, 19, 24, 30];
    for n = ess_nodes
        yline(n, ':', 'Color', [0.8 0.4 0.4 0.6], 'LineWidth', 1.2);
    end
    
    title(sprintf('%s - MESS 空间转移与驻留轨迹', labels{k})); 
    yticks([0, 5, 10, 15, 20, 25, 30, 33]); ylim([-2 35]); xlim([1 24]); grid on;
    legend('MESS 1 轨迹', 'MESS 2 轨迹', 'Location', 'southoutside', 'Orientation', 'horizontal');
    local_save_fig(f7, save_dir, sprintf('S%d_%s_T7_Trajectory', k, file_tags{k}));

    % --- Theme 8: 拓扑重构计划 ---
    f8 = figure('Name', 'Theme 8 Reconfig', 'Color', 'w', 'Position', [400, 400, 800, 300]);
    ties = Reconfig_Plan; 
    tie_names = {'Tie 8-21', 'Tie 9-15', 'Tie 12-22', 'Tie 18-33', 'Tie 25-29'}; 
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
    title(sprintf('%s - 上层总支出', labels{k})); 
    ylabel('支出 (kCNY)'); xlim([0.5 24.5]); grid on;
    local_save_fig(f9, save_dir, sprintf('S%d_%s_T9_CashFlow', k, file_tags{k}));

    % --- Theme 10: 柔性资源物理响应堆叠 (引入 EDG) ---
    f10 = figure('Name', 'Theme 10 Flex Stack', 'Color', 'w', 'Position', [500, 500, 700, 400]);
    stack_data = [sum(Res.P_M_Act, 1)', sum(Res.P_E_Act, 1)', tot_edg'];
    b = bar(1:24, stack_data, 'stacked', 'EdgeColor', 'none');
    b(1).FaceColor = C_BLUE; b(2).FaceColor = C_ORANGE; b(3).FaceColor = C_EDG; 
    title(sprintf('%s - 灵活性资源出力堆叠图', labels{k})); 
    ylabel('注入功率 (MW)'); xlim([0.5 24.5]); grid on;
    legend('MESS 集群出力', 'EV 集群出力', 'EDG 应急柴发出力', 'Location', 'southoutside', 'Orientation', 'horizontal');
    local_save_fig(f10, save_dir, sprintf('S%d_%s_T10_FlexStack', k, file_tags{k}));

    % --- Theme 11: 独立交通路网映射轨迹 (修正版：彻底对齐在途时间) ---
    f11 = figure('Name', 'Theme 11 Traffic Trajectory', 'Color', 'w', 'Position', [550, 550, 750, 400]);
    power_to_traffic_map = [1,1,2,3,3,4,5,6,7,8,8,9,10,10,11,12,13,14,15,15,16,17,18,19,20,21,22,23,24,25,22,23,25];
    
    Traffic_Sched = zeros(2, 24);
    for m = 1:2
        for t = 1:24
            if MESS_Schedule(m, t) == -1
                Traffic_Sched(m, t) = 0; % [核心修正] 0 表示在途/待命区，直接替代原来的 NaN
            else
                Traffic_Sched(m, t) = power_to_traffic_map(MESS_Schedule(m, t));
            end
        end
    end
    
    % [核心修正] 废弃 plot+interp1 的斜线画法，改用 stairs 阶梯图
    % 使视觉上的"在途跨度"严格压缩为 1 个时段，与配电网驻留图绝对对齐！
    stairs(1:24, Traffic_Sched(1, :), '-o', 'LineWidth', 2.5, 'MarkerSize', 6, 'Color', C_BLUE, 'MarkerFaceColor', 'w'); hold on;
    stairs(1:24, Traffic_Sched(2, :), '-s', 'LineWidth', 2.5, 'MarkerSize', 6, 'Color', C_RED,  'MarkerFaceColor', 'w');
    
    % 绘制在途/待命区分界线
    yline(0, '-', '在途 / 待命区', 'Color', C_GRAY, 'LabelVerticalAlignment', 'bottom'); 
    
    % 绘制关键负荷节点的辅助线
    hosp_traffic_nodes = unique(power_to_traffic_map([6, 14, 19, 24, 30]));
    for n = hosp_traffic_nodes
        yline(n, ':', 'Color', [0.8 0.4 0.4 0.6], 'LineWidth', 1.5);
    end
    
    title(sprintf('%s - MESS 交通路网调度轨迹', labels{k}), 'FontWeight', 'bold'); 
    ylabel('交通网节点编号', 'FontWeight', 'bold'); 
    xlabel('时间 (h)', 'FontWeight', 'bold');
    
    % 坐标轴优化：把 0 (在途区) 加入 Y 轴刻度显示
    yticks([0, 1:2:25]); ylim([-2 26]); xlim([1 24]); grid on;
    legend('MESS 1 轨迹', 'MESS 2 轨迹', 'Location', 'southoutside', 'Orientation', 'horizontal');
    
    local_save_fig(f11, save_dir, sprintf('S%d_%s_T11_TrafficNet', k, file_tags{k}));

    close all; 
end

fprintf('\n★ Quick Plot V12.9 运行完成！四大场景图表已存入 Data/Figures_V12_Aesthetic ★\n');

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
    Res.Shed_Mat = zeros(Env.NB, Horizon); Res.Gen_Mat =  zeros(Env.NB, Horizon);
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
        Res.Shed_Mat(:, t) = Extra.Shed_Matrix_Col; Res.Gen_Mat(:, t) = Extra.Gen_Matrix_Col;
        Res.V_Mat(:, t) = Extra.V_Mag; Res.Cost_T(t) = s_cost;        
        Res.EDG_Mat(:, t) = Extra.EDG_Matrix_Col; 
        
        [P_L, ~, P_PV] = Env.get_snapshot_state(t);
        Res.Demand_Mat(:, t) = P_L * Env.BASE_MVA; Res.PV_Mat(:, t) = Extra.PV_Act_MW;
        
        curr_soc_m = curr_soc_m - (p_m_act_mw / 2.0); 
        curr_soc_e = curr_soc_e - (p_e_act_mw / 1.0);
        
        curr_soc_m = max(0.10, min(0.95, curr_soc_m)); 
        curr_soc_e = max(0.10, min(0.95, curr_soc_e));
    end
end