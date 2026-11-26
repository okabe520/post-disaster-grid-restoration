%% Benchmark_Runner.m - 全场景对比测试平台 (V14.0 Ultimate Aligned Edition)
% =========================================================================
%   [对齐 V14.0] 彻底修复了微观柱状图中"重要负荷停电时间"的伪造惩罚逻辑，确保与底层宏观控制台绝对对齐。
%   [对齐 V14.0] 重新梳理其他 6 个微观指标的数学严谨性，电压得分规范化为百分制。
%   [报告 V14.0] 自动生成详细的 TXT 对比报告，宏观与微观指标同台展示。
%   [终极整合 V13.0] 将 Evaluate_Utility 功能完美并入，宏观 4D 散点与微观 7 柱状图一体化。
% =========================================================================

clc; close all;
warning('off', 'all');

% --- [核心防护] 强行将 YALMIP 置于路径最顶层 ---
yalmip_root = getenv('YALMIP_ROOT');
if ~isempty(yalmip_root), addpath(genpath(yalmip_root)); end
assert(exist('sdpvar','file') == 2, 'Install YALMIP and add it to the MATLAB path.');

% --- 0. 基础样式设置 ---
set(0, 'DefaultFigureColor', 'w');
set(0, 'DefaultAxesColor', 'w');
set(0, 'DefaultAxesXColor', 'k');
set(0, 'DefaultAxesYColor', 'k');
set(0, 'DefaultTextColor', 'k');
set(0, 'DefaultAxesFontName', 'Helvetica'); 
set(0, 'DefaultAxesFontSize', 11);
set(0, 'DefaultLineLineWidth', 1.5);

fprintf('\n>>> [Benchmark V14.0] 启动全场景闭环基准对比测试 (宏微观一致版)...\n');

% =========================================================================
%                     Phase 1: 环境与数据锚定
% =========================================================================
current_path = fileparts(mfilename('fullpath'));
data_dir = fullfile(current_path, '..', 'Data');
python_layer_path = fullfile(current_path, '..', 'Python_Layer');

strategy_file = fullfile(data_dir, 'strategy.mat');
opt_res_file = fullfile(data_dir, 'Optimization_Result.mat');
idx_file = fullfile(data_dir, 'index.mat');

if exist(strategy_file, 'file'), Backup_Data = load(strategy_file);
else, error('错误：找不到 strategy.mat！'); end

if exist(idx_file, 'file'), idx_data = load(idx_file); essential_nodes = idx_data.essential_users;
else, error('错误：找不到 index.mat！'); end

% Python 环境安全连接
fprintf('    [系统] 检查 Python 环境...\n');
python_executable = getenv('STACKELBERG_PYTHON'); 
pe = pyenv;
if pe.Status == "NotLoaded" && ~isempty(python_executable)
    try pyenv('Version', python_executable, 'ExecutionMode', 'OutOfProcess');
    catch, pyenv('Version', python_executable, 'ExecutionMode', 'InProcess'); end
end
try
    if count(py.sys.path, python_layer_path) == 0, insert(py.sys.path, int32(0), python_layer_path); end
    asm = py.importlib.import_module('agent_server'); 
    py.importlib.reload(asm); 
    py_adapter = asm.adapter;
    fprintf('    -> Python 接口加载成功。\n');
catch ME
    error('Python 加载失败: %s', ME.message);
end

try d_curve = load(fullfile(data_dir, 'curve.mat')); sim_start_h = d_curve.START_HOUR;
catch, sim_start_h = 0; end

% =========================================================================
%                     Phase 2: 准备基准环境矩阵
% =========================================================================
fprintf('\n>>> 正在初始化物理隔离环境...\n');

% 1. 环境 S1: 强制剥夺重构能力 (绝对的裸奔基准)
Temp_Plan = Backup_Data;
Temp_Plan.Reconfig_Plan = zeros(size(Backup_Data.Reconfig_Plan)); 
save(strategy_file, '-struct', 'Temp_Plan');
Env_NoReconfig = GridEnv();
Island_Mat_NoReconfig = Env_NoReconfig.Python_Area_ID_Daily;

% 2. 环境 S2-S4: 正常的重构能力
save(strategy_file, '-struct', 'Backup_Data'); 
Env_Normal = GridEnv();
Island_Mat_Normal = Env_Normal.Python_Area_ID_Daily;

% =========================================================================
%                     Phase 3: 执行七大策略闭环推演
% =========================================================================
if ~exist(opt_res_file, 'file'), error('找不到 Optimization_Result.mat'); end
load(opt_res_file, 'x_opt', 'f_val');

% --- 提取 S4 的四大战术锚点 ---
[~, sort_idx_shed]   = sort(f_val(:, 1)); idx_min_shed   = sort_idx_shed(1); 
[~, sort_idx_cost]   = sort(f_val(:, 2)); idx_min_cost   = sort_idx_cost(1); 
[~, sort_idx_outage] = sort(f_val(:, 3)); idx_min_outage = sort_idx_outage(1); 
norm_f1 = f_val(:, 1) / max(f_val(:, 1) + 1e-6);
norm_f2 = f_val(:, 2) / max(f_val(:, 2) + 1e-6);
norm_f3 = f_val(:, 3) / max(f_val(:, 3) + 1e-6);
dist_to_utopia = sqrt(norm_f1.^2 + norm_f2.^2 + norm_f3.^2);
[~, sort_idx_bal] = sort(dist_to_utopia); idx_balanced = sort_idx_bal(1);

% 生成 TOU (S3)
tou_base = zeros(1, 24);
for h = 0:23
    if (h >= 0 && h < 7), tou_base(h+1) = 0.3;
    elseif (h >= 10 && h < 15), tou_base(h+1) = 0.5;
    elseif (h >= 18 && h < 21), tou_base(h+1) = 3.0;
    else, tou_base(h+1) = 0.8; end
end
fixed_price = circshift(tou_base, -sim_start_h);

% --- 开始集中推演 ---
fprintf('\n>>> 正在执行全场景闭环物理推演...\n');

fprintf('    [1/7] S1 (无协同 / 纯自然灾害)...\n');
[Res_S1, Met_S1]   = local_run_simulation(zeros(1,24), Env_NoReconfig, sim_start_h, py_adapter, Island_Mat_NoReconfig, true);

fprintf('    [2/7] S2 (仅静态重构)...\n');
[Res_S2, Met_S2]   = local_run_simulation(zeros(1,24), Env_Normal, sim_start_h, py_adapter, Island_Mat_Normal, true);

fprintf('    [3/7] S3 (固定分时电价 TOU)...\n');
[Res_S3, Met_S3]   = local_run_simulation(fixed_price, Env_Normal, sim_start_h, py_adapter, Island_Mat_Normal, false);

fprintf('    [4/7] S4_A (本文战术: 保供优先)...\n');
[Res_S4A, Met_S4A] = local_run_simulation(x_opt(idx_min_shed,:), Env_Normal, sim_start_h, py_adapter, Island_Mat_Normal, false);

fprintf('    [5/7] S4_B (本文战术: 经济优先)...\n');
[Res_S4B, Met_S4B] = local_run_simulation(x_opt(idx_min_cost,:), Env_Normal, sim_start_h, py_adapter, Island_Mat_Normal, false);

fprintf('    [6/7] S4_C (本文战术: 恢复优先)...\n');
[Res_S4C, Met_S4C] = local_run_simulation(x_opt(idx_min_outage,:), Env_Normal, sim_start_h, py_adapter, Island_Mat_Normal, false);

fprintf('    [7/7] S4_D (本文战术: 全局均衡)...\n');
[Res_S4D, Met_S4D] = local_run_simulation(x_opt(idx_balanced,:), Env_Normal, sim_start_h, py_adapter, Island_Mat_Normal, false);

% --- 构建点云 (用于 4D 散点图) ---
Phys_Metrics_All = zeros(size(x_opt, 1), 4);
h_wait = waitbar(0, '正在计算全景 Pareto 点云...');
for i = 1:size(x_opt, 1)
    [~, m_table] = local_run_simulation(x_opt(i,:), Env_Normal, sim_start_h, py_adapter, Island_Mat_Normal, false);
    Phys_Metrics_All(i,:) = m_table;
    if mod(i, 5)==0, waitbar(i/size(x_opt,1), h_wait); end
end
close(h_wait);

% =========================================================================
%                     Phase 4: 生成文本评估报告 (表 4-3 与详细 TXT)
% =========================================================================
fprintf('\n================================================================================================\n');
fprintf('                 表 4-3 不同策略在"孤岛围城"场景下的关键指标统计\n');
fprintf('================================================================================================\n');
fprintf(' %-20s | %-12s | %-12s | %-10s | %-15s\n', '策略描述', '关键缺电(MWh)', '普通缺电(MWh)', '总成本(kCNY)', '累计停电指标(h)');
fprintf('------------------------------------------------------------------------------------------------\n');
fprintf(' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S1:无协同', Met_S1(1), Met_S1(2), Met_S1(3), Met_S1(4));
fprintf(' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S2:仅静态重构', Met_S2(1), Met_S2(2), Met_S2(3), Met_S2(4));
fprintf(' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S3:固定电价协同', Met_S3(1), Met_S3(2), Met_S3(3), Met_S3(4));
fprintf('------------------------------------------------------------------------------------------------\n');
fprintf(' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S4_A:保供优先', Met_S4A(1), Met_S4A(2), Met_S4A(3), Met_S4A(4));
fprintf(' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S4_B:经济优先', Met_S4B(1), Met_S4B(2), Met_S4B(3), Met_S4B(4));
fprintf(' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S4_C:恢复优先', Met_S4C(1), Met_S4C(2), Met_S4C(3), Met_S4C(4));
fprintf(' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S4_D:全局均衡', Met_S4D(1), Met_S4D(2), Met_S4D(3), Met_S4D(4));
fprintf('================================================================================================\n');

% =========================================================================
%                     Phase 5: 绘制全景 4D 散点对比图
% =========================================================================
fprintf('\n>>> 正在生成全景 4D Pareto 散点图与微观 7 柱状图...\n');

f_3d = figure('Name', 'Fig 4-11 4D Pareto Comparison', 'Color', 'w', 'Position', [50, 50, 1100, 750]);
hold on; grid on; grid minor;

% 1. S4 (Pareto 点云)
h_pareto = scatter3(Phys_Metrics_All(:,1), Phys_Metrics_All(:,2), Phys_Metrics_All(:,3), ...
         60, Phys_Metrics_All(:,4), 'filled', 'MarkerFaceAlpha', 0.85);
colormap(parula); 
cb = colorbar; ylabel(cb, '关键负荷停电时间 (h)', 'FontSize', 11, 'FontWeight', 'bold');

% 2. 代表性 7 大节点
h_pts = zeros(1, 7);
h_pts(1) = plot3(Met_S1(1), Met_S1(2), Met_S1(3), 'x', 'MarkerSize', 14, 'LineWidth', 3, 'Color', '#7E818D'); % S1
h_pts(2) = plot3(Met_S2(1), Met_S2(2), Met_S2(3), 's', 'MarkerSize', 14, 'MarkerFaceColor', '#66C2A5', 'MarkerEdgeColor', 'w'); % S2
h_pts(3) = plot3(Met_S3(1), Met_S3(2), Met_S3(3), 'd', 'MarkerSize', 14, 'MarkerFaceColor', '#F39B7F', 'MarkerEdgeColor', 'w'); % S3

h_pts(4) = plot3(Met_S4A(1), Met_S4A(2), Met_S4A(3), 'p', 'MarkerSize', 24, 'MarkerFaceColor', '#E64B35', 'MarkerEdgeColor', 'w'); % S4A
h_pts(5) = plot3(Met_S4B(1), Met_S4B(2), Met_S4B(3), 'p', 'MarkerSize', 24, 'MarkerFaceColor', '#4DBBD5', 'MarkerEdgeColor', 'w'); % S4B
h_pts(6) = plot3(Met_S4C(1), Met_S4C(2), Met_S4C(3), 'p', 'MarkerSize', 24, 'MarkerFaceColor', '#8491B4', 'MarkerEdgeColor', 'w'); % S4C
h_pts(7) = plot3(Met_S4D(1), Met_S4D(2), Met_S4D(3), 'p', 'MarkerSize', 24, 'MarkerFaceColor', '#00A087', 'MarkerEdgeColor', 'w'); % S4D

xlabel('关键负荷缺电 (MWh)', 'FontSize', 12, 'FontWeight', 'bold'); 
ylabel('普通负荷缺电 (MWh)', 'FontSize', 12, 'FontWeight', 'bold'); 
zlabel('激励成本 (kCNY)', 'FontSize', 12, 'FontWeight', 'bold');
title('多策略对比Pareto散点图', 'FontSize', 14, 'FontWeight', 'bold');

legend([h_pareto, h_pts(1), h_pts(2), h_pts(3), h_pts(4), h_pts(5), h_pts(6), h_pts(7)], ...
       {'Pareto 解集云', 'S1:无协同', 'S2:仅静态重构', 'S3:固定电价协同', ...
        'S4_A:保供优先', 'S4_B:经济优先', 'S4_C:恢复优先', 'S4_D:全局均衡'}, ...
       'Location', 'bestoutside', 'FontSize', 10);
view(135, 25);

save_dir = fullfile(data_dir, 'Figures_V12_Aesthetic');
if ~exist(save_dir, 'dir'), mkdir(save_dir); end
exportgraphics(f_3d, fullfile(save_dir, 'Fig_4_11_Full_Comparison.png'), 'Resolution', 300);

% =========================================================================
%                     Phase 6: 微观物理效用评估 (7柱状图矩阵)
% =========================================================================
% [V14.0 核心修正] 强制传入 Met 宏观数组，确保 M6 停电时间与控制台绝对对齐
Met7_S1 = local_extract_7metrics(Res_S1, Met_S1, essential_nodes, Env_NoReconfig);
Met7_S2 = local_extract_7metrics(Res_S2, Met_S2, essential_nodes, Env_Normal);
Met7_S3 = local_extract_7metrics(Res_S3, Met_S3, essential_nodes, Env_Normal);
Met7_S4A = local_extract_7metrics(Res_S4A, Met_S4A, essential_nodes, Env_Normal);
Met7_S4B = local_extract_7metrics(Res_S4B, Met_S4B, essential_nodes, Env_Normal);
Met7_S4C = local_extract_7metrics(Res_S4C, Met_S4C, essential_nodes, Env_Normal);
Met7_S4D = local_extract_7metrics(Res_S4D, Met_S4D, essential_nodes, Env_Normal);

All_7Metrics = [Met7_S1; Met7_S2; Met7_S3; Met7_S4A; Met7_S4B; Met7_S4C; Met7_S4D];

% 把原来的利用率，改为"等效放电深度"
metric_names = {'加权负荷恢复率', '加权平均缺电功率', '重要负荷支撑率', 'EV 等效放电深度', 'MESS 等效放电深度', '重要负荷累计等效停电', '电压质量稳定性'};
metric_units = {'%', 'MW', '%', '%', '%', 'h', '分'};

C_7Bars = [
    0.65, 0.65, 0.65;  % S1: 灰
    0.40, 0.76, 0.65;  % S2: 浅绿
    0.95, 0.61, 0.50;  % S3: 橙
    0.90, 0.29, 0.21;  % S4A: 红
    0.30, 0.73, 0.83;  % S4B: 蓝
    0.52, 0.57, 0.71;  % S4C: 紫
    0.00, 0.63, 0.53   % S4D: 深绿
];
str_labels = {'S1', 'S2', 'S3', 'S4_A', 'S4_B', 'S4_C', 'S4_D'};

f_bars = figure('Name', '7-Scenario Utility Assessment', 'Color', 'w', 'Position', [100, 100, 1800, 700]);

for i = 1:7
    ax = subplot(2, 4, i);
    vals = All_7Metrics(:, i)'; 
    
    b = bar(1:7, vals, 0.7, 'FaceColor', 'flat', 'EdgeColor', 'none');
    b.CData = C_7Bars; 
    
    set(gca, 'XTick', 1:7, 'XTickLabel', str_labels, 'FontSize', 9, 'FontWeight', 'bold');
    ax.XTickLabelRotation = 30;
    ylabel(metric_units{i}, 'FontSize', 11, 'FontWeight', 'bold');
    title(metric_names{i}, 'FontSize', 13, 'FontWeight', 'bold');
    grid on; set(gca, 'GridLineStyle', ':', 'GridAlpha', 0.5);
    
    y_max = max(vals); if y_max < 1e-4, y_max = 1.0; end
    if i == 7, ylim([min(vals) - 5, 100]); else, ylim([0, y_max * 1.35]); end
    
    for j = 1:7
        text(j, vals(j), sprintf('%.2f', vals(j)), 'HorizontalAlignment', 'center', ...
             'VerticalAlignment', 'bottom', 'FontWeight', 'bold', 'FontSize', 9, 'Color', C_7Bars(j,:));
    end
end

ax8 = subplot(2, 4, 8);
hold(ax8, 'on'); axis(ax8, 'off'); xlim(ax8, [0, 1]); ylim(ax8, [0, 1]);
text(ax8, 0.5, 0.85, '策略名称', 'FontSize', 16, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');

h_dummy = zeros(1, 7);
for j = 1:7, h_dummy(j) = bar(ax8, -1, 1, 'FaceColor', C_7Bars(j,:), 'EdgeColor', 'none'); end
    
lgd = legend(ax8, h_dummy, ...
    {'S1: 无协同', 'S2: 仅静态拓扑重构', 'S3: 固定分时电价协同', ...
     'S4_A: 动态博弈 - 保供优先', 'S4_B: 动态博弈 - 经济优先', 'S4_C: 动态博弈 - 恢复优先', 'S4_D: 动态博弈 - 全局均衡'}, ...
    'Location', 'south', 'FontSize', 12, 'FontWeight', 'bold', 'TextColor', 'k');
set(lgd, 'Box', 'off', 'Color', 'none');
disableDefaultInteractivity(ax8);

exportgraphics(f_bars, fullfile(save_dir, 'Utility_Assessment_7Scenarios.png'), 'Resolution', 300);
fprintf('    -> 7 大微观效用柱状对比图已保存。\n');

% =========================================================================
%                     Phase 7: 输出 TXT 终极对比报告
% =========================================================================
report_path = fullfile(data_dir, 'Benchmark_Detailed_Report.txt');
fid = fopen(report_path, 'w', 'n', 'UTF-8');

fprintf(fid, '======================================================================\n');
fprintf(fid, '              全场景闭环基准对比测试报告 (V14.0 宏微观对齐版)\n');
fprintf(fid, '======================================================================\n\n');

fprintf(fid, '[第一部分] 宏观物理寻优指标 (对应控制台输出与 Pareto 散点)\n');
fprintf(fid, '------------------------------------------------------------------------------------------------\n');
fprintf(fid, ' %-20s | %-12s | %-12s | %-10s | %-15s\n', '策略描述', '关键缺电(MWh)', '普通缺电(MWh)', '总成本(kCNY)', '累计停电指标(h)');
fprintf(fid, '------------------------------------------------------------------------------------------------\n');
fprintf(fid, ' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S1:无协同(各顾各)', Met_S1(1), Met_S1(2), Met_S1(3), Met_S1(4));
fprintf(fid, ' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S2:仅静态重构', Met_S2(1), Met_S2(2), Met_S2(3), Met_S2(4));
fprintf(fid, ' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S3:固定电价协同', Met_S3(1), Met_S3(2), Met_S3(3), Met_S3(4));
fprintf(fid, ' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S4_A:保供优先', Met_S4A(1), Met_S4A(2), Met_S4A(3), Met_S4A(4));
fprintf(fid, ' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S4_B:经济优先', Met_S4B(1), Met_S4B(2), Met_S4B(3), Met_S4B(4));
fprintf(fid, ' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S4_C:恢复优先', Met_S4C(1), Met_S4C(2), Met_S4C(3), Met_S4C(4));
fprintf(fid, ' %-20s | %12.2f | %12.2f | %10.2f | %15.2f\n', 'S4_D:全局均衡', Met_S4D(1), Met_S4D(2), Met_S4D(3), Met_S4D(4));
fprintf(fid, '------------------------------------------------------------------------------------------------\n\n');

fprintf(fid, '[第二部分] 微观物理效用评估指标 (对应 7 柱状对比图)\n');
fprintf(fid, '------------------------------------------------------------------------------------------------------------------------------------------------\n');
fprintf(fid, ' %-16s | %-12s | %-12s | %-12s | %-12s | %-12s | %-12s | %-12s\n', '策略描述', '负荷恢复(%)', '平均缺电功率(MW)', '医院支撑(%)', 'EV利用率(%)', 'MESS利用率(%)', '累计停电指标(h)', '电压评分(分)');
fprintf(fid, '------------------------------------------------------------------------------------------------------------------------------------------------\n');
fprintf(fid, ' %-20s | %13.2f | %14.2f | %13.2f | %13.2f | %13.2f | %13.2f | %13.2f\n', 'S1:无协同(各顾各)', All_7Metrics(1,:));
fprintf(fid, ' %-20s | %13.2f | %14.2f | %13.2f | %13.2f | %13.2f | %13.2f | %13.2f\n', 'S2:仅静态重构', All_7Metrics(2,:));
fprintf(fid, ' %-20s | %13.2f | %14.2f | %13.2f | %13.2f | %13.2f | %13.2f | %13.2f\n', 'S3:固定电价协同', All_7Metrics(3,:));
fprintf(fid, ' %-20s | %13.2f | %14.2f | %13.2f | %13.2f | %13.2f | %13.2f | %13.2f\n', 'S4_A:保供优先', All_7Metrics(4,:));
fprintf(fid, ' %-20s | %13.2f | %14.2f | %13.2f | %13.2f | %13.2f | %13.2f | %13.2f\n', 'S4_B:经济优先', All_7Metrics(5,:));
fprintf(fid, ' %-20s | %13.2f | %14.2f | %13.2f | %13.2f | %13.2f | %13.2f | %13.2f\n', 'S4_C:恢复优先', All_7Metrics(6,:));
fprintf(fid, ' %-20s | %13.2f | %14.2f | %13.2f | %13.2f | %13.2f | %13.2f | %13.2f\n', 'S4_D:全局均衡', All_7Metrics(7,:));
fprintf(fid, '------------------------------------------------------------------------------------------------------------------------------------------------\n\n');
fprintf(fid, '注：M6"重要负荷停电时长"现已与底层调度引擎宏观指标绝对对齐，M7"电压稳定性评分"规范化为百分制。\n');
fclose(fid);

fprintf('    -> TXT 对比报告已保存至 Data/Benchmark_Detailed_Report.txt\n\n>>> 全部基准测试与图表生成完毕！\n');


%% ------------------------------------------------------------------------
%  本地核心模拟与提取库
% -------------------------------------------------------------------------
function [Res, Met] = local_run_simulation(price_seq, env_obj, start_h, py_adapter, Island_Mat, is_base)
    % is_base 为 true 时，AI 不响应电价 (P_M_Cmd=0, P_E_Cmd=0)
    N_MESS = 2; N_EV = 3; Horizon = 24;
    Res.P_M_Act = zeros(N_MESS, Horizon); Res.P_E_Act = zeros(N_EV, Horizon);
    Res.Shed_Mat = zeros(env_obj.NB, Horizon); Res.Demand_Mat = zeros(env_obj.NB, Horizon);
    Res.V_Mat = zeros(env_obj.NB, Horizon);
    
    curr_soc_m = [0.9, 0.9]; curr_soc_e = [0.65, 0.65, 0.65];
    cost_total = 0; mins_total = 0; shed_e = 0; shed_o = 0;
    
    for t = 1:Horizon
        if is_base
            p_m_cmd = [0; 0]; p_e_cmd = [0; 0; 0];
        else
            m_sched_t = env_obj.MESS_Schedule(:, t);
            m_isl_t = zeros(2, 1);
            for m = 1:2, if m_sched_t(m) > 0, m_isl_t(m) = Island_Mat(m_sched_t(m), t); end, end
            e_isl_t = zeros(3, 1);
            for e = 1:3, e_isl_t(e) = Island_Mat(env_obj.Idx_EV(e), t); end
            
            py_m_sched_t = py.list(num2cell(int32(m_sched_t'))); 
            py_m_isl_t   = py.list(num2cell(int32(m_isl_t'))); 
            py_e_isl_t   = py.list(num2cell(int32(e_isl_t')));
            py_soc_m = py.list(num2cell(curr_soc_m)); 
            py_soc_e = py.list(num2cell(curr_soc_e));
            
            py_resp_flat = py_adapter.get_batch_step_response(...
                py.list({price_seq(t)}), py_soc_m, py_soc_e, py_m_sched_t, py_m_isl_t, py_e_isl_t, int32(start_h), int32(t));
            act_arr = double(py_resp_flat);
            p_m_cmd = act_arr(1:2); p_e_cmd = act_arr(3:5);
        end
        
        [~, s_cost, s_outage, p_m_act_mw, p_e_act_mw, Extra] = env_obj.step_simulation(t, price_seq(t), p_m_cmd, p_e_cmd);
        
        Res.P_M_Act(:, t) = p_m_act_mw'; Res.P_E_Act(:, t) = p_e_act_mw';
        Res.Shed_Mat(:, t) = Extra.Shed_Matrix_Col; Res.V_Mat(:, t) = Extra.V_Mag; 
        
        [P_L, ~, ~] = env_obj.get_snapshot_state(t);
        Res.Demand_Mat(:, t) = P_L * env_obj.BASE_MVA; 
        
        cost_total = cost_total + s_cost;
        mins_total = mins_total + s_outage;
        shed_e = shed_e + sum(Extra.Shed_Matrix_Col(env_obj.Idx_Essential));
        shed_o = shed_o + sum(Extra.Shed_Matrix_Col(env_obj.Idx_Ordinary));
        
        if ~is_base
            curr_soc_m = max(0.10, min(0.95, curr_soc_m - (p_m_act_mw / 2.0))); 
            curr_soc_e = max(0.10, min(0.95, curr_soc_e - (p_e_act_mw / 1.0)));
        end
    end
    Met = [shed_e, shed_o, cost_total/1000, mins_total/60]; 
end

function M7_arr = local_extract_7metrics(Res, Met, essential_nodes, Env)
    NB = Env.NB; NT = Env.NT;
    Shed_Matrix = Res.Shed_Mat; Demand_Matrix = Res.Demand_Mat; V_Matrix = Res.V_Mat;
    
    weights = ones(NB, 1); weights(essential_nodes) = 100;
    W_Demand_Total = sum(Demand_Matrix .* weights, 'all');
    W_Shed_Total = sum(Shed_Matrix .* weights, 'all');
    
    M1 = max(0, (W_Demand_Total - W_Shed_Total) / max(W_Demand_Total, 1e-4) * 100);
    
    weights_norm = weights / sum(weights) * NB;
    M2 = sum(Shed_Matrix .* weights_norm, 'all') / NT;
    
    % [核心修正] 拆除 min(100) 封印！允许体现 AI 多次"抢充-放电"的循环套利活跃度
    Total_EV_Cap_MWh = length(Env.Idx_EV) * 1.0; 
    Discharge_EV = sum(Res.P_E_Act(Res.P_E_Act > 0), 'all'); 
    M4 = (Discharge_EV / max(Total_EV_Cap_MWh, 1e-4)) * 100; % 允许突破 100%
    
    Total_MESS_Cap_MWh = 2 * 2.0; % 2辆车，每辆 2.0 MWh
    Discharge_MESS = sum(Res.P_M_Act(Res.P_M_Act > 0), 'all'); 
    M5 = (Discharge_MESS / max(Total_MESS_Cap_MWh, 1e-4)) * 100; % 允许突破 100%
    
    % [核心修正] M6 直接采用底层真实的停电小时数，剥离虚假延迟惩罚
    M6 = Met(4); 
    
    Imp_Demand = sum(sum(Demand_Matrix(essential_nodes, :)));
    Imp_Shed = sum(sum(Shed_Matrix(essential_nodes, :)));
    % [核心修正] 剥离基于 M6 的粗暴扣分，真实反映物理支撑率
    if Imp_Demand > 0
        M3 = max(0, (Imp_Demand - Imp_Shed) / Imp_Demand * 100);
    else, M3 = 100; end
    
    % [终极学术修正] 采用 IEEE 标准的综合电压质量指数，且防 NaN 投毒
    valid_voltage = V_Matrix(V_Matrix > 0);
    Valid_Node_Hours = numel(valid_voltage);
    
    if Valid_Node_Hours > 0
        % 1. 越界惩罚
        Viol_Count = sum(valid_voltage < Env.V_MIN - 1e-8 | valid_voltage > Env.V_MAX + 1e-8);
        VQR_Score = (1 - Viol_Count / Valid_Node_Hours) * 100; % 分母用活着的节点数
        
        % 2. 稳态偏移惩罚 (必须加 'omitnan')
        MAVD = mean(abs(valid_voltage - 1.0));
    else
        VQR_Score = 0; MAVD = 0.2; % 如果全网死绝，给个极差的分数
    end
    
    M7 = max(0, VQR_Score - MAVD * 100);
    
    M7_arr = [M1, M2, M3, M4, M5, M6, M7];
end

function Island_Mat = local_get_island_matrix(Env, Reconfig_Plan)
    NB = Env.NB; NT = Env.NT; 
    Island_Mat = zeros(NB, NT);
    raw_branches = Env.mpc.branch(:, 1:2);
    for t = 1:NT
        % 自动匹配前 NL-5 条骨干线，和最后 5 条联络线
        idx_backbone = 1:(Env.NL-5);
        idx_ties = (Env.NL-4):Env.NL;
        status = [Env.Line_Status_Daily(idx_backbone, t); Env.Line_Status_Daily(idx_ties, t) & Reconfig_Plan(:, t)];
        active = find(status == 1);
        G = graph(raw_branches(active, 1), raw_branches(active, 2), [], NB);
        bins = conncomp(G);
        for n = 1:NB, if bins(n) ~= bins(1), Island_Mat(n, t) = 1; end, end
    end
end