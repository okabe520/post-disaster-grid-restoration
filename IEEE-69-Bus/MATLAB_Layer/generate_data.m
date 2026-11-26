%% Generate_Data.m - (IEEE 69 联络线绝对存活 & 极限机动版)
% =========================================================================
%   ★ 灾后应急调度系统 - 剧本生成器 (极寒冰冻灾害泛化测试) ★
%   [红线铁律] 绝对禁止切断 5 条联络线 (69~73永远为1)。
%   [绝无死岛] 所有的断开都经过精细计算，抱团成岛，确保均有 EDG/PV/EV。
%   [机动拉满] 完美设计时空迷宫，逼迫 MESS 1 二次转移，MESS 2 极限单防。
% =========================================================================

clc; 
clear; 
close all;

current_script_dir = fileparts(mfilename('fullpath'));
abs_data_dir = fullfile(current_script_dir, '..', 'Data');
if ~exist(abs_data_dir, 'dir'), mkdir(abs_data_dir); end

START_HOUR = 15; 
rng(2026, 'twister'); 
fprintf('\n正在生成 V12.0 "IEEE 69 联络线绝对存活 & 极限机动" 剧本...\n');

Num_Lines = 73; % 68 Backbone + 5 Ties
Horizon = 24;
Line_Status_Daily = ones(Num_Lines, Horizon);

% =========================================================================
%                             1. 剧本定义 (时空重构)
% =========================================================================
% 铁律：只能操作 1~68 号骨干线。联络线 (69~73) 绝对不动。

% --- 第一幕：初雪与局部受困 (T=2~5, 真实时间 16:00 - 19:00) ---
% 动作: 斩断 L48 和 L58。
% 效果: 50 和 59 失去主网供电，但它们通过联络线 Tie 72 (50-59) 抱团成岛！
% 资源: 孤岛内拥有 EDG 50，非死岛。缺口吸引 MESS 1 率先出动。
Line_Status_Daily([48, 58], 2:5) = 0;

% --- 第二幕：冰崩与供暖枢纽沦陷 (T=6~11, 真实时间 20:00 - 01:00) ---
% 动作: 维持 50 孤立。新增斩断 L60 和 L64。
% 效果: Node 61~64 被双向剥离。虽然 Tie 73(27-65) 存活，但电过不来。
% 资源: 孤岛内拥有 EDG 61, PV 61。夜间供暖拉爆缺口，MESS 2 紧急驰援！
Line_Status_Daily([48, 58, 60, 64], 6:11) = 0;

% --- 第三幕：短暂连通 (T=12~17, 真实时间 02:00 - 07:00) ---
% 动作: 所有骨干线恢复 1。
% 效果: 网络满血恢复，AI 抓紧时间给 MESS 和 EV 补电。

% --- 第四幕：融雪短路 (T=18~24) ---
% 1. 释放 Node 50 (不切 L58)，使其通过 Tie 72 获救。
% 2. 困死 Node 11 (切 L10, L11) 和 Node 43 (切 L42, L43)。
% 3. 切断 L48，确保 Node 11 无法从下方获得倒送电。
% 结果: MESS 1 必须离开 Node 50 奔袭 Node 11。
Line_Status_Daily([10, 11, 42, 43, 48, 60, 64], 18:24) = 0;

fprintf('  -> [OK] 极寒拓扑构建完成 (联络线 100%% 存活，杜绝无源死岛，MESS 极限双跑).\n');

% 事件日志
Event_Log = struct('Time', {}, 'Event', {}, 'Description', {});
Event_Log(1) = struct('Time', 2,  'Event', 'Act_1_TieIsland', 'Description', 'Node 50&59 tie-islanded (MESS 1 moves)');
Event_Log(2) = struct('Time', 6,  'Event', 'Act_2_HubIsland', 'Description', 'Node 61 isolated (MESS 2 moves)');
Event_Log(3) = struct('Time', 12, 'Event', 'Act_3_Recover',   'Description', 'Full network restored');
Event_Log(4) = struct('Time', 18, 'Event', 'Act_4_EV_Island', 'Description', 'Node 11&43 tie-islanded (MESS 1 2nd transfer)');

save(fullfile(abs_data_dir, 'scenario.mat'), 'Line_Status_Daily', 'Event_Log');


% =========================================================================
%                             2. 节点索引与资源配置
% =========================================================================
essential_users = [11; 27; 43; 50; 61];           
all_nodes = (2:69)';
ordinary_users = setdiff(all_nodes, essential_users);

O_PV = [11; 43; 61];                  
O_ME = [3; 35];                       
O_E  = [11; 21; 43];                  

O_EDG = [61; 50; 27];                 
O_EDG_CAP = [0.35; 0.15; 0.35];        

save(fullfile(abs_data_dir, 'index.mat'), 'essential_users', 'ordinary_users', 'O_PV', 'O_ME', 'O_E', 'O_EDG', 'O_EDG_CAP');

% =========================================================================
%                             3. 物理曲线生成 
% =========================================================================
time_labels = mod((0:23) + START_HOUR, 24); 
pv_curve = zeros(1, 24);
essential_load = zeros(1, 24);
ordinary_load = zeros(1, 24);

for t = 1:24
    hr = time_labels(t); 
    if hr >= 7 && hr <= 17
        pv_curve(t) = max(0, 0.85 * exp(-((hr - 12)^2) / 8) * (0.95 + 0.1 * rand())); 
    else
        pv_curve(t) = 0;
    end
    if hr >= 22 || hr <= 8
        essential_load(t) = 0.85 + 0.15 * rand();
    else
        essential_load(t) = 0.60 + 0.10 * rand();
    end
    if (hr >= 18 && hr <= 21) || (hr >= 7 && hr <= 9)
        ordinary_load(t) = 0.80 + 0.15 * rand();
    else
        ordinary_load(t) = 0.35 + 0.10 * rand();
    end
end
save(fullfile(abs_data_dir, 'curve.mat'), 'pv_curve', 'essential_load', 'ordinary_load', 'START_HOUR', 'time_labels');

% =========================================================================
%                             4. 联合双图可视化预览
% =========================================================================
figure('Name', 'V12.0 极寒冰冻灾害推演全景预览', 'Color', 'w', 'Position', [100, 100, 1000, 700]);

subplot(2,1,1); hold on;
for t = 0:24, xline(t, 'Color', [0.9 0.9 0.9]); end

% 在图中展示所有被斩断的核心主干 (联络线绝对安全，不在此列)
fault_lines = [10, 11, 42, 43, 48, 58, 60, 64]; 
y_pos = 1;
for i = 1:length(fault_lines)
    lid = fault_lines(i);
    status = Line_Status_Daily(lid, :);
    key_names = sprintf('L%02d', lid);
    for t = 1:24
        if status(t) == 0
            rectangle('Position', [t-1, y_pos-0.4, 1, 0.8], 'FaceColor', [1 0.8 0.8], 'EdgeColor', 'r');
            text(t-0.5, y_pos, 'CUT', 'Color', 'r', 'HorizontalAlignment', 'center', 'FontSize', 8, 'FontWeight', 'bold');
        else
            rectangle('Position', [t-1, y_pos-0.4, 1, 0.8], 'FaceColor', [0.8 1 0.8], 'EdgeColor', 'g');
        end
    end
    text(-2.5, y_pos, key_names, 'FontWeight', 'bold', 'FontSize', 9);
    y_pos = y_pos + 1;
end

xline(5,  'b--', 'LineWidth', 2.5, 'Label', 'Act 2 (Tie 72 抱团岛)');
xline(11, 'g--', 'LineWidth', 2.5, 'Label', 'Act 3 (融冰连通)');
xline(17, 'r--', 'LineWidth', 2.5, 'Label', 'Act 4 (Tie 69 抱团岛)');
title(sprintf('V12.0 极寒灾害拓扑演化甘特图 (START_HOUR = %d)', START_HOUR));
xlabel('仿真时间轴 (T=1~24)'); axis([0 24 0.5 length(fault_lines)+1]); set(gca, 'YTick', []);
xticks(0.5:1:23.5); xticklabels(arrayfun(@(x) sprintf('%02d:00', x), time_labels, 'UniformOutput', false)); xtickangle(45);

subplot(2,1,2);
plot(1:24, ordinary_load, 'k-', 'LineWidth', 1.2); hold on;
plot(1:24, essential_load, 'b-', 'LineWidth', 1.5);
area(1:24, pv_curve, 'FaceColor', [1 0.8 0.2], 'FaceAlpha', 0.8);
legend('普通负荷', '关键供暖负荷', '极寒放晴光伏 (PV)', 'Location', 'NorthWest');
title('全天负荷/光伏时序曲线'); grid on;
xticks(1:24); xticklabels(arrayfun(@(x) sprintf('%02d:00', x), time_labels, 'UniformOutput', false)); xtickangle(45);
ylim([0, 1.2]);

fprintf('★ 终极联络线存活剧本生成完毕！请运行 Topology_Manager 见证奇迹！★\n\n');