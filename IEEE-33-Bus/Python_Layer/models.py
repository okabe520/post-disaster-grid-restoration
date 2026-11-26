import torch
import torch.nn as nn
import torch.nn.functional as F
import os

class AttentionBlock(nn.Module):
    """
    [V5.2 Core] 动态注意力模块 (含全盲保护 & 数值稳定)
    """
    def __init__(self, q_dim, k_dim, v_dim, hidden_dim=64):
        super(AttentionBlock, self).__init__()
        # Query: 自身状态映射
        self.W_q = nn.Linear(q_dim, hidden_dim)
        # Key: 邻居状态映射 (用于计算匹配度)
        self.W_k = nn.Linear(k_dim, hidden_dim)
        # Value: 邻居特征映射 (用于提取信息)
        self.W_v = nn.Linear(v_dim, hidden_dim)
        
        self.hidden_dim = hidden_dim
        self.scale = hidden_dim ** -0.5
        
    def forward(self, query, keys, mask=None):
        """
        Args:
            query: [Batch, q_dim]
            keys:  [Batch, N_Neighbors, k_dim]
            mask:  [Batch, N_Neighbors] (1=可见, 0=不可见)
        """
        # 1. 线性变换
        Q = self.W_q(query).unsqueeze(1)       # [Batch, 1, Hidden]
        K = self.W_k(keys)                     # [Batch, N, Hidden]
        V = self.W_v(keys)                     # [Batch, N, Hidden]
        
        # 2. 计算注意力分数
        # 使用 scale 防止点积过大导致梯度消失
        scores = torch.bmm(Q, K.transpose(1, 2)) * self.scale # [Batch, 1, N]
        
        # 3. [关键] Masking
        if mask is not None:
            mask = mask.unsqueeze(1) # [Batch, 1, N]
            # 使用极小负数 (-1e18) 彻底屏蔽，防止 Softmax 后有残留
            scores = scores.masked_fill(mask == 0, -1e18)
        
        # 4. 归一化
        weights = F.softmax(scores, dim=-1) # [Batch, 1, N]
        
        # 5. 加权聚合
        context = torch.bmm(weights, V)     # [Batch, 1, Hidden]
        context = context.squeeze(1)        # [Batch, Hidden]
        
        # 6. [关键] 全盲保护 (Zero-Mask Safety)
        # 如果所有邻居都不可见 (孤岛且无内部邻居)，Softmax 会输出均匀噪声。
        # 必须强制将 Context 置零。
        if mask is not None:
            # mask shape: [Batch, 1, N] -> sum -> [Batch, 1, 1] -> squeeze -> [Batch, 1]
            valid_count = mask.sum(dim=2, keepdim=True).squeeze(1)
            context = context * (valid_count > 0).float()
            
        return context

class DynamicActor(nn.Module):
    """
    [V5.2] 增强版 Actor 网络
    结构：Encoder -> Attention -> LayerNorm -> Deep MLP -> Action
    """
    def __init__(self, self_dim, neighbor_dim, action_dim, hidden_dim=128):
        super(DynamicActor, self).__init__()
        
        # 1. 自身特征提取
        self.l_self = nn.Linear(self_dim, hidden_dim)
        
        # 2. 邻居特征聚合 (Attention)
        self.attn = AttentionBlock(self_dim, neighbor_dim, neighbor_dim, hidden_dim)
        
        # 3. 融合层 (加入 LayerNorm 加速收敛)
        self.ln1 = nn.LayerNorm(hidden_dim * 2)
        
        # 4. 决策 MLP (3层深度网络，增强拟合能力)
        self.decision_net = nn.Sequential(
            nn.Linear(hidden_dim * 2, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, action_dim)
        )
        
        self.apply(self._init_weights)
        
        # 输出层初始化在 0 附近，减少初始震荡
        nn.init.uniform_(self.decision_net[-1].weight, -3e-3, 3e-3)
        nn.init.uniform_(self.decision_net[-1].bias, -3e-3, 3e-3)

    def _init_weights(self, m):
        if isinstance(m, nn.Linear):
            nn.init.xavier_uniform_(m.weight)
            if m.bias is not None:
                nn.init.constant_(m.bias, 0.0)

    def forward(self, state_self, state_neighbors, mask_neighbors):
        # A. 编码
        feat_self = F.relu(self.l_self(state_self))
        feat_context = self.attn(state_self, state_neighbors, mask_neighbors)
        
        # B. 融合
        combined = torch.cat([feat_self, feat_context], dim=1)
        combined = self.ln1(combined)
        
        # C. 决策
        action = torch.tanh(self.decision_net(combined))
        return action

class DynamicCritic(nn.Module):
    """
    [V5.2] 增强版 Critic 网络
    """
    def __init__(self, self_dim, neighbor_dim, action_dim, hidden_dim=128):
        super(DynamicCritic, self).__init__()
        
        # Query 包含: 自身状态 + 自身动作
        self.l_sa = nn.Linear(self_dim + action_dim, hidden_dim)
        
        # Attention Key/Value 包含: 邻居状态 + 邻居动作
        self.attn = AttentionBlock(self_dim + action_dim, neighbor_dim, neighbor_dim, hidden_dim)
        
        self.ln1 = nn.LayerNorm(hidden_dim * 2)
        
        self.value_net = nn.Sequential(
            nn.Linear(hidden_dim * 2, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, 1)
        )
        
        self.apply(self._init_weights)

    def _init_weights(self, m):
        if isinstance(m, nn.Linear):
            nn.init.xavier_uniform_(m.weight)
            if m.bias is not None:
                nn.init.constant_(m.bias, 0.0)

    def forward(self, state_self, state_neighbors, mask_neighbors, action):
        sa = torch.cat([state_self, action], dim=1)
        feat_sa = F.relu(self.l_sa(sa))
        
        feat_context = self.attn(sa, state_neighbors, mask_neighbors)
        
        combined = torch.cat([feat_sa, feat_context], dim=1)
        combined = self.ln1(combined)
        
        q_value = self.value_net(combined)
        return q_value

# =========================================================
# [CRITICAL FIX] 兼容性补丁
# 允许旧的 .pth 文件 (保存时名为 Actor/Critic) 被正确加载
# =========================================================
Actor = DynamicActor
Critic = DynamicCritic

def save_dummy_models(path_dir):
    """
    初始化模型占位符 (用于 agent_server.py 首次启动)
    [注意] 这里的维度必须与 train_maddpg.py 中的最新定义一致！
    MESS_SELF_DIM = 6
    EV_SELF_DIM = 6
    """
    if not os.path.exists(path_dir):
        os.makedirs(path_dir)
    
    # 维度对齐 V5.2 标准
    MESS_SELF_DIM = 6 
    EV_SELF_DIM = 6
    NEIGHBOR_STATE_DIM = 3
    
    mess_actor = DynamicActor(self_dim=MESS_SELF_DIM, neighbor_dim=NEIGHBOR_STATE_DIM, action_dim=1)
    torch.save(mess_actor, os.path.join(path_dir, 'actor_mess.pth'))
    
    ev_actor = DynamicActor(self_dim=EV_SELF_DIM, neighbor_dim=NEIGHBOR_STATE_DIM, action_dim=1)
    torch.save(ev_actor, os.path.join(path_dir, 'actor_ev_altruistic.pth'))
    torch.save(ev_actor, os.path.join(path_dir, 'actor_ev_selfish.pth'))
    
    print(f"[V5.2] Compatible models initialized at {path_dir}")

if __name__ == "__main__":
    save_dummy_models('./saved_models')