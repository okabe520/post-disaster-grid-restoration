%% Main_NSGA3.m - V9.0 (Ultimate Robust & Area ID Alignment Edition)
% =========================================================================
%   ★ 灾后应急调度系统 - 核心计算引擎 ★
%   [升级 V9.0] 彻底抛弃布尔化孤岛判断，全面接入 GridEnv 的原生 Area_ID_Daily，
%               完美实现多孤岛并行环境下的 Masked GAT 物理与信息双重隔离。
%   [修复 V8.4] 修复 gamultiobj 初始化测试(PopSize=1)引发的标量转 Python List 崩溃。
%   [修复 V8.3] 引入 Python 柔性重载 (importlib.reload)，根除 Error 87。
%   [修复 V8.3] 强制 YALMIP 路径置顶，彻底解决内置 export 遮蔽问题。
% =========================================================================

%% 1. 系统初始化
clc; 
clear; 
close all;
warning('off', 'all');

% --- [核心修复] 强行将 YALMIP 置于路径最顶层，防止 export 被官方库遮蔽 ---
yalmip_root = getenv('YALMIP_ROOT');
if ~isempty(yalmip_root), addpath(genpath(yalmip_root)); end
assert(exist('sdpvar','file') == 2, 'Install YALMIP and add it to the MATLAB path.');

% --- 强制覆盖系统深色模式设置 ---
set(0, 'DefaultFigureColor', 'w');       
set(0, 'DefaultAxesColor', 'w');         
set(0, 'DefaultAxesXColor', 'k');        
set(0, 'DefaultAxesYColor', 'k');        
set(0, 'DefaultTextColor', 'k');         
set(0, 'DefaultAxesGridColor', [0.15 0.15 0.15]); 
set(0, 'DefaultAxesGridAlpha', 0.2);     
set(0, 'DefaultAxesXGrid', 'on');        
set(0, 'DefaultAxesYGrid', 'on');        

manual_seed = 2025; 
rng(manual_seed);

current_script_path = fileparts(mfilename('fullpath'));
python_layer_path = fullfile(current_script_path, '..', 'Python_Layer');
abs_data_dir = fullfile(current_script_path, '..', 'Data');

if ~exist(python_layer_path, 'dir')
    error('错误: 找不到 Python_Layer 文件夹！'); 
end
if ~exist(abs_data_dir, 'dir')
    mkdir(abs_data_dir);
end

%% 2. Python 环境安全连接 (防 IPC 管道崩溃)
fprintf('\n[System] 检查 Python 环境...\n');
python_executable = getenv('STACKELBERG_PYTHON'); 

pe = pyenv;
if pe.Status == "NotLoaded" && ~isempty(python_executable)
    fprintf('    -> 首次加载 Python 环境 (OutOfProcess)...\n');
    try
        pyenv('Version', python_executable, 'ExecutionMode', 'OutOfProcess');
    catch ME
        fprintf(2, '    -> OutOfProcess 加载失败，尝试 InProcess 模式...\n');
        pyenv('Version', python_executable, 'ExecutionMode', 'InProcess');
    end
else
    fprintf('    -> Python 引擎已驻留内存，无需重启。\n');
end

try
    if count(py.sys.path, python_layer_path) == 0
        insert(py.sys.path, int32(0), python_layer_path);
    end
    fprintf('[Python] 正在加载智能体服务 (agent_server)...\n');
    asm = py.importlib.import_module('agent_server'); 
    
    % [核心修复] 使用 reload 刷新 Python 缓存，替代暴力的 terminate
    py.importlib.reload(asm); 
    
    fprintf('[Python] 环境配置就绪 (V9.0 Area ID Closed-Loop Supported)。\n');
catch ME
    error('Stackelberg:EnvInit', 'Python 模块加载失败: %s', ME.message);
end

%% 3. 数据准备与环境构建
fprintf('\n>>> [Step 1] 准备仿真数据...\n');
if ~exist(fullfile(abs_data_dir, 'scenario.mat'), 'file')
    fprintf('    -> 生成剧本...\n');
    run(fullfile(current_script_path, 'generate_data.m'));
end

fprintf('\n>>> [Step 2] 启动指挥中心 (Topology_Manager)...\n');
[Reconfig_Plan, MESS_Schedule] = Topology_Manager();

fprintf('\n>>> [Step 3] 初始化单步闭环电网环境 (GridEnv V16.1)...\n');
try
    Env = GridEnv(); 
catch ME
    fprintf(2, '\n======================================================\n');
    fprintf(2, '❌ 致命错误：GridEnv 初始化失败！详细堆栈跟踪如下：\n');
    fprintf(2, '错误标志: %s\n', ME.identifier);
    fprintf(2, '错误原因: %s\n', ME.message);
    fprintf(2, '------------------------------------------------------\n');
    for k = 1:length(ME.stack)
        fprintf(2, '  文件: %s\n  函数: %s\n  行号: 第 %d 行\n\n', ...
            ME.stack(k).file, ME.stack(k).name, ME.stack(k).line);
    end
    fprintf(2, '======================================================\n');
    rethrow(ME);
end

% Python contract: bus-1 component is 0 (grid-connected), while every
% disconnected component has a distinct positive island ID.
fprintf('    -> 正在提取全时域 Python Area ID 映射...\n');
Island_Matrix = Env.Python_Area_ID_Daily;
fprintf('    -> 已完成主网=0、孤岛=1..N 的跨语言拓扑映射。\n');

try
    d_curve = load(fullfile(abs_data_dir, 'curve.mat'));
    sim_start_h = d_curve.START_HOUR;
catch
    sim_start_h = 0;
end

%% 4. 优化问题定义 (NSGA-III 参考点架构初始化)
nvars = 24;                 
lb_base = 0.1 * ones(1, 24);   
ub_base = 3.5 * ones(1, 24);   

lb = circshift(lb_base, -sim_start_h);
ub = circshift(ub_base, -sim_start_h);

FitnessFunction = @(x) closed_loop_objective_wrapper(x, Env, sim_start_h, Island_Matrix);

% --- NSGA-III 核心参数 ---
MaxIt = 50;           % 最大迭代次数
nPop = 100;           % 种群规模
nObj = 3;             % 目标函数个数 (缺电量、调度成本、停电时间)

% 生成参考点 (NSGA-III 灵魂机制)
% 依赖文件: GenerateReferencePoints.m
nDivision = 12;       % 分割数 (3目标12分割，会生成 91 个超平面参考点，匹配 nPop=100)
Zr = GenerateReferencePoints(nObj, nDivision);

% 遗传算子参数
pCrossover = 0.7;                         % 交叉概率
nCrossover = 2 * round(pCrossover * nPop / 2); % 交叉子代数
pMutation = 0.3;                          % 变异概率
nMutation = round(pMutation * nPop);      % 变异子代数
mu = 0.05;                                % 变异率
sigma = 0.1 * (ub - lb);                  % 变一步长

%% 5. 执行优化 (NSGA-III 矢量化闭环加速引擎)
fprintf('\n>>> [Step 4] 开始双层博弈优化 (正统 NSGA-III 架构)...\n');
fprintf('    提示: 采用矢量化种群合并推理，完美兼容 Python Agent 批量加速！\n');

global GLOBAL_LAST_POP GLOBAL_LAST_SCORE;

tic;
try
    % 1. 初始化空个体结构体 (Yarpiz NSGA-III 标准格式)
    empty_individual.Position = [];
    empty_individual.Cost = [];
    empty_individual.Rank = [];
    empty_individual.DominationSet = [];
    empty_individual.DominatedCount = [];
    empty_individual.NormalizedCost = [];
    empty_individual.AssociatedRef = [];
    empty_individual.DistanceToAssociatedRef = [];

    pop = repmat(empty_individual, nPop, 1);

    % 2. 批量生成初代位置并执行闭环推理
    PopDec = unifrnd(repmat(lb, nPop, 1), repmat(ub, nPop, 1));
    fprintf('    -> 正在进行初代种群(Pop=%d)的物理闭环推理...\n', nPop);
    PopObj = FitnessFunction(PopDec);

    for i = 1:nPop
        pop(i).Position = PopDec(i, :);
        pop(i).Cost = PopObj(i, :)';
    end

    % 3. 构造 Yarpiz 标准的 params 结构体
    params.nPop = nPop;
    params.Zr = Zr;
    params.nZr = size(Zr, 2);  
    params.zmin = [];          
    params.zmax = [];
    params.smin = [];
    
    % 初代非支配排序与参考点关联
    [pop, F, params] = SortAndSelectPopulation(pop, params);

    % =========================================================
    % 准备动态 Pareto 前沿监控画布
    % =========================================================
    fig_monitor = figure('Name', 'NSGA-III 演化过程实时监控', 'Color', 'w', 'Position', [150, 150, 800, 600]);
    ax_monitor = axes('Parent', fig_monitor);
    hold(ax_monitor, 'on'); grid(ax_monitor, 'on'); view(ax_monitor, 3);
    xlabel(ax_monitor, '目标 1：缺电量 (MWh)', 'FontWeight', 'bold');
    ylabel(ax_monitor, '目标 2：调度总支出 (CNY)', 'FontWeight', 'bold');
    zlabel(ax_monitor, '目标 3：停电时间惩罚 (Mins)', 'FontWeight', 'bold');
    title(ax_monitor, 'NSGA-III 种群演化动态 Pareto 前沿 (初始化中...)', 'FontSize', 12, 'FontWeight', 'bold');
    h_scatter = scatter3(ax_monitor, NaN, NaN, NaN, 50, 'filled', 'MarkerEdgeColor', 'k');
    colormap(ax_monitor, jet); 

    % 4. 迭代主循环
    for it = 1:MaxIt
        fprintf('    => NSGA-III 迭代进度: %d / %d ...\n', it, MaxIt);
        
        popc = repmat(empty_individual, nCrossover/2, 2);
        popm = repmat(empty_individual, nMutation, 1);
        
        OffDec = zeros(nCrossover + nMutation, nvars);
        off_idx = 1;
        
        % 交叉操作
        for k = 1:nCrossover/2
            i1 = randi([1 nPop]); i2 = randi([1 nPop]);
            [popc(k, 1).Position, popc(k, 2).Position] = ...
                Crossover_Func(pop(i1).Position, pop(i2).Position, lb, ub);
            
            OffDec(off_idx, :) = popc(k, 1).Position; off_idx = off_idx + 1;
            OffDec(off_idx, :) = popc(k, 2).Position; off_idx = off_idx + 1;
        end
        
        % 变异操作
        for k = 1:nMutation
            i = randi([1 nPop]);
            popm(k).Position = Mutate_Func(pop(i).Position, mu, sigma, lb, ub);
            OffDec(off_idx, :) = popm(k).Position; off_idx = off_idx + 1;
        end
        
        % 核心提速点：子代合并，一键发给 Python 进行批量推理 
        OffObj = FitnessFunction(OffDec);
        
        % 结果回填
        off_idx = 1;
        for k = 1:nCrossover/2
            popc(k, 1).Cost = OffObj(off_idx, :)'; off_idx = off_idx + 1;
            popc(k, 2).Cost = OffObj(off_idx, :)'; off_idx = off_idx + 1;
        end
        for k = 1:nMutation
            popm(k).Cost = OffObj(off_idx, :)'; off_idx = off_idx + 1;
        end
        popc = popc(:);
        
        % 父子代大合并 (2N 规模)
        pop = [pop; popc; popm];
        
        % NSGA-III 核心机制：传入打包好的 params 结构体
        [pop, F, params] = SortAndSelectPopulation(pop, params);
        
        % 安全备份机制
        F1 = pop(F{1});
        GLOBAL_LAST_POP = reshape([F1.Position], nvars, [])';
        GLOBAL_LAST_SCORE = reshape([F1.Cost], nObj, [])';
        
        % =========================================================
        % 详细控制台日志与 3D 画布动态刷新
        % =========================================================
        F1_Costs = GLOBAL_LAST_SCORE; 
        min_obj = min(F1_Costs, [], 1); 
        max_obj = max(F1_Costs, [], 1);
        mean_obj = mean(F1_Costs, 1);
        
        % 计算种群收敛扩散度 
        spread = sqrt(sum((max_obj - min_obj).^2));
        
        fprintf('    [Gen %02d/%02d 完结] 前沿数量: %d | 空间扩散度: %.2f\n', it, MaxIt, size(F1_Costs, 1), spread);
        fprintf('      |> 缺电量 (MWh)   : Min = %.2f | Mean = %.2f | Max = %.2f\n', min_obj(1), mean_obj(1), max_obj(1));
        fprintf('      |> 总支出 (CNY)  : Min = %.2f | Mean = %.2f | Max = %.2f\n', min_obj(2), mean_obj(2), max_obj(2));
        fprintf('      |> 停电惩罚 (Mins): Min = %.2f | Mean = %.2f | Max = %.2f\n', min_obj(3), mean_obj(3), max_obj(3));
        
        if spread < 1e-4
            fprintf('      ⚠️ 警告: 种群扩散度极低，可能已发生早熟坍缩 (陷入局部最优死锁)！\n');
        end
        fprintf('    -----------------------------------------------------------\n');

        if isgraphics(fig_monitor)
            set(h_scatter, 'XData', F1_Costs(:, 1), 'YData', F1_Costs(:, 2), 'ZData', F1_Costs(:, 3), 'CData', F1_Costs(:, 1));
            xlim(ax_monitor, [max(0, min_obj(1)*0.9), max(max_obj(1)*1.1, 0.1)]);
            ylim(ax_monitor, [max(0, min_obj(2)*0.9), max(max_obj(2)*1.1, 0.1)]);
            zlim(ax_monitor, [max(0, min_obj(3)*0.9), max(max_obj(3)*1.1, 0.1)]);
            title(ax_monitor, sprintf('NSGA-III 演化中 (Gen: %d/%d) | 种群扩散度: %.2f', it, MaxIt, spread));
            drawnow; 
        end
    end
    
    x_opt = GLOBAL_LAST_POP;
    f_val = GLOBAL_LAST_SCORE;
    fprintf('NSGA-III 优化成功完成，成功提取 %d 个帕累托最优解。\n', size(x_opt, 1));

catch ME
    fprintf('\n!!! NSGA-III 优化异常中断 !!!\n');
    fprintf('错误信息: %s\n', ME.message);
    if ~isempty(GLOBAL_LAST_POP)
        x_opt = GLOBAL_LAST_POP;
        f_val = GLOBAL_LAST_SCORE;
        fprintf('已为您抢救恢复最近一次有效的帕累托前沿数据。\n');
    else
        rethrow(ME);
    end
end

elapsed_time = toc;
fprintf('总耗时: %.2f 秒。\n', elapsed_time);

%% 6. 数据保存与指引
if ~isempty(x_opt)
    save(fullfile(abs_data_dir, 'Optimization_Result.mat'), 'x_opt', 'f_val', 'elapsed_time');
    fprintf('\n>>> [System] 计算完成，数据已保存至 Data/Optimization_Result.mat\n');
    
    fprintf('>>> [Next Step] 自动启动 Quick_Plot 进行物理指标可视化...\n');
    if exist('Quick_Plot.m', 'file')
        run('Quick_Plot.m');
    end
else
    error('没有结果可供保存。'); 
end

%% ========================================================================
%                               辅助函数库
% =========================================================================

function scores = closed_loop_objective_wrapper(pop_price_matrix, env_obj, start_h, Island_Mat)
    global GLOBAL_LAST_POP;
    
    [PopSize, ~] = size(pop_price_matrix);
    scores = zeros(PopSize, 3);
    
    N_MESS = 2; N_EV = 3;
    MESS_CAP = 2.0; EV_CAP = 1.0; 
    
    mess_soc_batch = 0.9 * ones(PopSize, N_MESS);
    ev_soc_batch   = 0.65 * ones(PopSize, N_EV);
    mess_sched = env_obj.MESS_Schedule; 
    
    try
        asm = py.importlib.import_module('agent_server');
        py_adapter = asm.adapter;
    catch ME
        fprintf(2, '\n[CRITICAL ERROR] 无法连接到 Python Adapter。\n');
        rethrow(ME);
    end
    
    for t = 1:24
        m_sched_t = mess_sched(:, t);
        m_isl_t = zeros(2, 1);
        
        % Extract the Python-facing Area ID, not MATLAB's raw conncomp label.
        for m = 1:2
            if m_sched_t(m) > 0
                m_isl_t(m) = Island_Mat(m_sched_t(m), t); 
            else
                % MESS 不在网内时赋予虚拟 ID，由 Python 掩码自行过滤
                m_isl_t(m) = 0; 
            end
        end
        
        e_isl_t = zeros(3, 1);
        for e = 1:3
            e_isl_t(e) = Island_Mat(env_obj.Idx_EV(e), t); 
        end
        
        % [V8.4 核心修复：加入 num2cell() 安全外壳]
        py_m_sched_t = py.list(num2cell(int32(m_sched_t')));
        py_m_isl_t   = py.list(num2cell(int32(m_isl_t')));
        py_e_isl_t   = py.list(num2cell(int32(e_isl_t')));
        
        prices_t = pop_price_matrix(:, t)';
        py_prices_t = py.list(num2cell(prices_t));
        
        flat_mess_soc = reshape(mess_soc_batch', 1, []);
        flat_ev_soc = reshape(ev_soc_batch', 1, []);
        py_mess_soc = py.list(num2cell(flat_mess_soc));
        py_ev_soc   = py.list(num2cell(flat_ev_soc));
        
        try
            py_resp_flat = py_adapter.get_batch_step_response(...
                py_prices_t, py_mess_soc, py_ev_soc, py_m_sched_t, py_m_isl_t, py_e_isl_t, ...
                int32(start_h), int32(t));
        catch ME
            fprintf(2, '\n[CRITICAL ERROR] Python 单步推理失败 (t=%d)！\n信息: %s\n', t, ME.message);
            rethrow(ME);
        end
        
        all_actions = double(py_resp_flat);
        act_matrix = reshape(all_actions, 5, PopSize)'; 
        
        for i = 1:PopSize
            p_mess_cmd = act_matrix(i, 1:2);
            p_ev_cmd   = act_matrix(i, 3:5);
            price_i_t  = pop_price_matrix(i, t);
            
            [s_shed, s_cost, s_outage, p_m_act_mw, p_e_act_mw, Extra] = ...
                env_obj.step_simulation(t, price_i_t, p_mess_cmd, p_ev_cmd);
            
            % [核心解绑] O1 只统计全网真实的物理缺电总量 (MWh)
            scores(i, 1) = scores(i, 1) + Extra.Real_Shed_MWh; 
            
            scores(i, 2) = scores(i, 2) + s_cost;
            scores(i, 3) = scores(i, 3) + s_outage;
            
            % [终极维度对齐补丁] 使用 (:)' 强制转置为行向量
            mess_soc_batch(i, :) = max(0.10, min(0.95, mess_soc_batch(i, :) - (p_m_act_mw(:)' / MESS_CAP)));
            ev_soc_batch(i, :)   = max(0.10, min(0.95, ev_soc_batch(i, :) - (p_e_act_mw(:)' / EV_CAP)));
        end
    end
end

function [y1, y2] = Crossover_Func(x1, x2, lb, ub)
    % 模拟算术交叉 (Arithmetic Crossover)
    alpha = rand(size(x1));
    y1 = alpha.*x1 + (1-alpha).*x2;
    y2 = alpha.*x2 + (1-alpha).*x1;
    % 严格越界保护
    y1 = max(lb, min(ub, y1));
    y2 = max(lb, min(ub, y2));
end

function y = Mutate_Func(x, mu, sigma, lb, ub)
    % 高斯变异 (Gaussian Mutation)
    flag = (rand(size(x)) < mu);
    y = x;
    y(flag) = x(flag) + sigma(flag) .* randn(size(x(flag)));
    % 严格越界保护
    y = max(lb, min(ub, y));
end
