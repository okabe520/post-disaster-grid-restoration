%% Generate_Data.m - V11.0 (The "Giant Island & Multi-Node Bunkers" Edition)
% =========================================================================
%   ★ 灾后应急调度系统 - 剧本生成器 (多节点孤岛 & 晚高峰大瘫痪版) ★
%   [绝不妥协] 100% 保持 AI 初始电量满血，依靠真实的晚高峰大孤岛将其物理榨干。
%   [多节点圈地] 摒弃单一节点孤岛，所有灾区均包含多个普通节点，逼迫 AI 进行分配博弈。
%   [台风眼抢充] 21:00-01:00 留出宝贵的 4 小时全网连通期，极其考验抢充战术。
% =========================================================================

clc; 
clear; 
close all;

% 路径锚定
current_script_dir = fileparts(mfilename('fullpath'));
abs_data_dir = fullfile(current_script_dir, '..', 'Data');
if ~exist(abs_data_dir, 'dir'), mkdir(abs_data_dir); end

% 从正午12点灾害爆发开始推演
START_HOUR = 12; 
rng(2026, 'twister'); 
fprintf('\n正在生成 V11.0 "晚高峰大孤岛与多节点死牢" 剧本...\n');

Num_Lines = 37; % 32 Backbone + 5 Ties
Horizon = 24;
Line_Status_Daily = ones(Num_Lines, Horizon);

% =========================================================================
%                             1. 剧本定义 (时空重构)
% =========================================================================
% T=1 对应真实的 12:00。

% --- 第一幕：正午消耗战 (T=2~5, 真实时间 13:00 - 17:00) ---
% 动作 A: 断 L12+L14 -> 圈出多节点孤岛 {13, 14(Hosp)}。
% 动作 B: 断 L22+L24 -> 圈出多节点孤岛 {23, 24(Hosp)}。
% 效果: 无 EV 协助，迫使 MESS 1 和 MESS 2 出动，消耗初始电量。
Line_Status_Daily([12, 14, 22, 24], 2:5) = 0;

% --- 第二幕：晚高峰大瘫痪 (T=6~9, 真实时间 17:00 - 21:00) ---
% 动作: 仅切断 L6。
% 效果: Node 7~33 形成极其庞大的"大孤岛"！适逢晚高峰，MESS 和 EV 疯狂放电救灾，电量彻底见底。
Line_Status_Daily(6, 6:9) = 0;

% --- 第二点五幕：台风眼 (T=10~13, 真实时间 21:00 - 01:00) ---
% 动作: 全网恢复连通 (Line_Status_Daily 默认为 1)。
% 效果: S4 的 AI 趁机从主网低价吸血，S3 的 EV 可能错过机会。

% --- 第三幕：黎明前的多节点死牢 (T=14~19, 真实时间 01:00 - 07:00) ---
% 动作 A: 断 L9, L14, L21, L22 -> 圈出超大多节点死牢 {10(EV1), 11, 12, 13, 14(Hosp), 22(EV2)}！
% 动作 B: 断 L29, L32 -> 圈出多节点死牢 {30(Hosp), 31(EV3), 32}！
% 效果: 联络线均在圈内/外完好，但死牢无法连通主网。EV 被完美锁在医院身旁。
Line_Status_Daily([9, 14, 21, 22, 29, 32], 14:19) = 0;

fprintf('  -> 多节点孤岛与大瘫痪拓扑构建完成 (联络线 100%% 安全存活).\n');

% 事件日志
Event_Log = struct('Time', {}, 'Event', {}, 'Description', {});
Event_Log(1) = struct('Time', 2,  'Event', 'Act_1_MultiNode', 'Description', 'Real 13:00 - {13,14} & {23,24} Multi-node islands drain MESS');
Event_Log(2) = struct('Time', 6,  'Event', 'Act_2_GiantIsl',  'Description', 'Real 17:00 - Line 6 cut, Giant Island (7-33) drains EVs');
Event_Log(3) = struct('Time', 10, 'Event', 'Act_2.5_Eye',     'Description', 'Real 21:00 - Grid restored, critical charging window');
Event_Log(4) = struct('Time', 14, 'Event', 'Act_3_Bunkers',   'Description', 'Real 01:00 - EV+Hosp trapped in multi-node bunkers');

save(fullfile(abs_data_dir, 'scenario.mat'), 'Line_Status_Daily', 'Event_Log');

% =========================================================================
%                             2. 节点索引与 EDG 精准配置
% =========================================================================
essential_users = [6; 14; 19; 24; 30]; 
all_nodes = (2:33)';
ordinary_users = setdiff(all_nodes, essential_users);

O_PV = [13; 24; 30]; 
O_ME = [6; 26]; 
O_E = [10; 22; 31]; 

% EDG 容量配置 (精确卡住多节点孤岛的生死线)
O_EDG = [14; 24; 30]; 
O_EDG_CAP = [0.05; 0.20; 0.08]; % 精准施压容量 (MW)

save(fullfile(abs_data_dir, 'index.mat'), 'essential_users', 'ordinary_users', 'O_PV', 'O_ME', 'O_E', 'O_EDG', 'O_EDG_CAP');

% =========================================================================
%                             3. 曲线生成 (台风碾压光伏)
% =========================================================================
t_base = 1:24; 
% 光伏出力极限压制 (最高 15%)
pv_raw = max(0, min(1, exp(-((t_base - 12).^2) / 10) .* (0.10 + 0.05 * rand(1, 24))));
ess_raw = max(0.6, min(1.0, 0.7 + 0.1 * sin((t_base-10)*pi/12) + 0.05 * randn(1,24)));
ord_raw = max(0.2, min(1.0, (0.3 + 0.4 * exp(-((t_base - 10).^2) / 8) + 0.6 * exp(-((t_base - 19).^2) / 10)) .* (0.95 + 0.1 * rand(1, 24))));

shift_amount = -(START_HOUR);
pv_curve = circshift(pv_raw, shift_amount);
essential_load = circshift(ess_raw, shift_amount);
ordinary_load = circshift(ord_raw, shift_amount);
time_labels = mod((0:23) + START_HOUR, 24);

save(fullfile(abs_data_dir, 'curve.mat'), 'pv_curve', 'essential_load', 'ordinary_load', 'START_HOUR', 'time_labels');

% =========================================================================
%                             4. 可视化预览
% =========================================================================
figure('Name', 'V11.0 Giant Island & Bunkers Preview', 'Color', 'w', 'Position', [100, 100, 1000, 700]);
subplot(2,1,1); hold on;
for t = 0:24, xline(t, 'Color', [0.9 0.9 0.9]); end

% 在图中展示最具代表性的几把"切刀"
key_lines = [12, 22, 6, 9, 29]; 
key_names = {'L12 (孤立13-14)', 'L22 (孤立23-24)', 'L6 (晚高峰大瘫痪)', 'L9 (圈闭10-14,22)', 'L29 (圈闭30-32)'};
y_pos = 1;

for i = 1:length(key_lines)
    lid = key_lines(i);
    status = Line_Status_Daily(lid, :);
    for t = 1:24
        if status(t) == 0
            rectangle('Position', [t-1, y_pos-0.4, 1, 0.8], 'FaceColor', [1 0.8 0.8], 'EdgeColor', 'r');
            text(t-0.5, y_pos, 'CUT', 'Color', 'r', 'HorizontalAlignment', 'center', 'FontSize', 8, 'FontWeight', 'bold');
        else
            rectangle('Position', [t-1, y_pos-0.4, 1, 0.8], 'FaceColor', [0.8 1 0.8], 'EdgeColor', 'g');
        end
    end
    text(-3.0, y_pos, key_names{i}, 'FontWeight', 'bold', 'FontSize', 9);
    y_pos = y_pos + 1;
end

xline(5, 'b--', 'LineWidth', 2.5, 'Label', 'Act 2 (Real 17:00 Giant Island)');
xline(9, 'g--', 'LineWidth', 2.5, 'Label', 'Act 2.5 (Real 21:00 Eye of Storm)');
xline(13, 'r--', 'LineWidth', 2.5, 'Label', 'Act 3 (Real 01:00 Multi-Node Bunkers)');

rectangle('Position', [3, y_pos-0.5, 18, 0.2], 'FaceColor', [0.8 0.8 1], 'EdgeColor', 'b', 'LineWidth', 1.5);
text(12, y_pos-0.4, 'EV 在网周期 (Real 15:00 - 09:00)', 'HorizontalAlignment', 'center', 'Color', 'b', 'FontWeight', 'bold');

title(sprintf('V11.0 "大瘫痪与多节点死牢" 演化图 (START_HOUR = %d)', START_HOUR));
xlabel('仿真时间轴 (T=1~24)'); axis([0 24 0.5 length(key_lines)+1]); set(gca, 'YTick', []);
xticks(0.5:1:23.5); xticklabels(arrayfun(@(x) sprintf('%02d:00', x), time_labels, 'UniformOutput', false));
xtickangle(45);

subplot(2,1,2);
plot(1:24, ordinary_load, 'k-'); hold on;
plot(1:24, essential_load, 'b-', 'LineWidth', 1.5);
area(1:24, pv_curve, 'FaceColor', [1 0.8 0.2], 'FaceAlpha', 0.8);
legend('普通负荷', '关键负荷', '光伏 (PV)');
title('全天负荷/光伏曲线'); grid on;
xticks(1:24); xticklabels(arrayfun(@(x) sprintf('%02d:00', x), time_labels, 'UniformOutput', false));
xtickangle(45);

fprintf('★ V11.0 终极剧本已生成！晚高峰大瘫痪将完美物理榨干满血 AI！★\n');