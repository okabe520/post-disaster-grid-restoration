%% Main_NSGA3.m - V8.4 (Ultimate Robust & Dimension-Safe Edition)
% =========================================================================
%   ★ 灾后应急调度系统 - 核心计算引擎 ★
%   [修复 V8.4] 修复 gamultiobj 初始化测试(PopSize=1)引发的标量转 Python List 崩溃。
%   [修复 V8.4] 修复异常捕获域的全局变量未定义问题。
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
    
    fprintf('[Python] 环境配置就绪 (V8.4 Closed-Loop Supported)。\n');
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

fprintf('\n>>> [Step 3] 初始化单步闭环电网环境 (GridEnv V8.3)...\n');
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

fprintf('    -> 正在计算全时域孤岛分布...\n');
Island_Matrix = Env.Python_Area_ID_Daily;
fprintf('    -> 预计算完成。全网共检测到 %d 个节点·小时处于孤岛状态。\n', sum(Island_Matrix(:)));

try
    d_curve = load(fullfile(abs_data_dir, 'curve.mat'));
    sim_start_h = d_curve.START_HOUR;
catch
    sim_start_h = 0;
end

%% 4. 优化问题定义 (NSGA-III 参考点架构初始化)
% =========================================================================
% [V9.04 升级] 彻底抛弃 gamultiobj (NSGA-II)，全面接入 NSGA-III 参考点机制
% =========================================================================
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

    % ---------------- 关键修复区 ----------------
    % 3. 构造 Yarpiz 标准的 params 结构体
    params.nPop = nPop;
    params.Zr = Zr;
    params.nZr = size(Zr, 2);  % <--- 修复点：添加参考点数量
    params.zmin = [];          % 初始为空，由 NormalizePopulation 自动计算
    params.zmax = [];
    params.smin = [];
    
    % 初代非支配排序与参考点关联
    [pop, F, params] = SortAndSelectPopulation(pop, params);
    % --------------------------------------------

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

function Island_Mat = Precompute_Island_Status(Env, Reconfig_Plan)
    NB = Env.NB; NT = Env.NT; Island_Mat = zeros(NB, NT);
    raw_branches = Env.mpc.branch(:, 1:2);
    for t = 1:NT
        status = [Env.Line_Status_Daily(1:32, t); Env.Line_Status_Daily(33:37, t) & Reconfig_Plan(:, t)];
        active = find(status == 1);
        G = graph(raw_branches(active, 1), raw_branches(active, 2), [], NB);
        bins = conncomp(G);
        for n = 1:NB, if bins(n) ~= bins(1), Island_Mat(n, t) = 1; end, end
    end
end

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
        for m = 1:2, if m_sched_t(m) > 0, m_isl_t(m) = Island_Mat(m_sched_t(m), t); end, end
        e_isl_t = zeros(3, 1);
        for e = 1:3, e_isl_t(e) = Island_Mat(env_obj.Idx_EV(e), t); end
        
        % [V8.4 核心修复：加入 num2cell() 安全外壳，彻底消灭标量跌落导致的 TypeError]
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
            
            % [核心解绑] O1 只统计全网真实的物理缺电总量 (MWh)，彻底褪去 1000 权重的数学掩护！
            % 这样既保证了 Gurobi 底层的绝对抢救优先级，又让 NSGA-III 看到了保供普通负荷的物理空间。
            scores(i, 1) = scores(i, 1) + Extra.Real_Shed_MWh; 
            
            scores(i, 2) = scores(i, 2) + s_cost;
            scores(i, 3) = scores(i, 3) + s_outage;
            
            mess_soc_batch(i, :) = max(0.10, min(0.95, mess_soc_batch(i, :) - (p_m_act_mw / MESS_CAP)));
            ev_soc_batch(i, :)   = max(0.10, min(0.95, ev_soc_batch(i, :) - (p_e_act_mw / EV_CAP)));
        end
    end
end

function [state, options, optchanged] = safe_save_output(options, state, flag)
    global GLOBAL_LAST_POP; 
    global GLOBAL_LAST_SCORE;
    GLOBAL_LAST_POP = state.Population; 
    GLOBAL_LAST_SCORE = state.Score;
    optchanged = false;
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