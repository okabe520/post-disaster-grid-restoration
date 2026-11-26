function D_ij = cal_distance(branch_data, d0)
% CAL_DISTANCE - V9.0 (Coupled Power-Traffic Network Edition)
% =========================================================================
% 功能：
%   彻底打破"配电网与交通网重合"的物理假象。
%   1. 构建独立的 25 节点交通路网 (包含主干道与快速路)。
%   2. 将 33 个配电网节点 (Power Nodes) 映射到最近的交通节点 (Traffic Nodes)。
%   3. 利用图论计算交通网内的真实最短物理行车距离，并计入配电站接驳距离。
%
% 注意：
%   输入参数 branch_data 和 d0 仅作接口兼容保留，实际内部寻径已完全独立。
% =========================================================================

    % 1. 构建独立交通路网 (5x5 矩阵状路网, 共 25 个交通节点)
    num_traffic_nodes = 25;
    t_from = []; t_to = []; t_weight = [];
    
    rng(2025); % 固定随机数种子，保证每次运行生成的路网完全一致
    
    % 生成网格型主干道
    for i = 1:num_traffic_nodes
        % 横向道路
        if mod(i, 5) ~= 0
            t_from(end+1) = i; t_to(end+1) = i+1; 
            t_weight(end+1) = 1.5 + rand() * 1.5; % 道路长度 1.5 ~ 3.0 km
        end
        % 纵向道路
        if i <= 20
            t_from(end+1) = i; t_to(end+1) = i+5; 
            t_weight(end+1) = 2.0 + rand() * 1.5; % 道路长度 2.0 ~ 3.5 km
        end
    end
    
    % 加入几条跨区"快速路" (对角线)
    express_ways = [1 7; 7 13; 13 19; 19 25; 5 9; 9 13; 13 17; 17 21];
    for k = 1:size(express_ways, 1)
        t_from(end+1) = express_ways(k, 1); t_to(end+1) = express_ways(k, 2); 
        t_weight(end+1) = 3.5; % 快速路长度固定
    end
    
    % 创建交通无向图并计算全源最短路径
    G_traffic = graph(t_from, t_to, t_weight, num_traffic_nodes);
    D_traffic = distances(G_traffic);
    
    % 2. 建立 配电网节点(1-33) 到 交通网节点(1-25) 的空间映射字典
    % 这模拟了真实的地理信息系统 (GIS) 叠加映射
    power_to_traffic_map = [
        1,  1,  2,  3,  3,  4,  5,  6,  7,  8,  ... % Nodes 1-10
        8,  9,  10, 10, 11, 12, 13, 14, 15, 15, ... % Nodes 11-20
        16, 17, 18, 19, 20, 21, 22, 23, 24, 25, ... % Nodes 21-30
        22, 23, 25 ...                              % Nodes 31-33
    ];
    
    % 为每个配电节点生成"接驳距离" (配电站开出小路到达交通主干道的距离)
    access_distance = 0.2 + 1.3 * rand(1, 33); % 0.2km ~ 1.5km
    
    % 3. 计算 33x33 的电网跨区转移真实物理距离矩阵
    num_power_nodes = 33;
    D_ij = zeros(num_power_nodes, num_power_nodes);
    
    for i = 1:num_power_nodes
        for j = 1:num_power_nodes
            if i == j
                D_ij(i, j) = 0;
            else
                t_node_i = power_to_traffic_map(i);
                t_node_j = power_to_traffic_map(j);
                
                if t_node_i == t_node_j
                    % 映射到同一个交通十字路口，只需走两段接驳小路
                    D_ij(i, j) = abs(access_distance(i) - access_distance(j)) + 0.5;
                else
                    % 跨交通节点转移：接驳出门 + 交通主干网寻径 + 接驳抵达
                    D_ij(i, j) = access_distance(i) + D_traffic(t_node_i, t_node_j) + access_distance(j);
                end
            end
        end
    end
end