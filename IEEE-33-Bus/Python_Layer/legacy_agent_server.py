import os
import sys

# === [Core Fix] Prevent OpenMP conflict crash when called from MATLAB ===
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"
# ======================================================================

import torch
import numpy as np

# Set current directory path
current_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.append(current_dir)

from models import DynamicActor
from dro_sampler import WorstCaseSampler

class StackelbergAdapter:
    def __init__(self):
        print("[Python] Initializing Stackelberg Adapter (V8.1 - True Identity Split)...")

        self.device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        print(f"[Python] Inference Device: {self.device}")

        self.model_dir = os.path.join(current_dir, 'saved_models')

        # [Dimension Alignment with V8.1 Training Script]
        self.MESS_SELF_DIM = 6  # [Price, SOC, Avail, Island, Time, Pad]
        self.EV_SELF_DIM = 6    # [Price, SOC, Target, Avail, Time, Island]
        self.NEIGH_DIM = 3

        # --- Helper for Smart Loading ---
        def load_smart(name_prefix, self_dim):
            path_best = os.path.join(self.model_dir, f'{name_prefix}_best.pth')
            path_final = os.path.join(self.model_dir, f'{name_prefix}.pth')

            # Prioritize Best checkpoint
            target_path = None
            if os.path.exists(path_best):
                print(f"    -> [LOADED BEST] Found best checkpoint for {name_prefix}!")
                target_path = path_best
            elif os.path.exists(path_final):
                print(f"    -> [LOADED FINAL] Best not found, using final checkpoint for {name_prefix}.")
                target_path = path_final
            else:
                print(f"    [Warning] Model {name_prefix} not found! Initializing dummy.")
                return DynamicActor(self_dim, self.NEIGH_DIM, 1).to(self.device)

            return torch.load(target_path, map_location=self.device, weights_only=False)

        # --- 1. Load Models ---
        try:
            print("[Python] Loading Models...")
            self.mess_actor = load_smart('actor_mess', self.MESS_SELF_DIM)
            self.ev_actor_altruistic = load_smart('actor_ev_altruistic', self.EV_SELF_DIM)
            self.ev_actor_selfish = load_smart('actor_ev_selfish', self.EV_SELF_DIM)

            self.mess_actor.eval()
            self.ev_actor_altruistic.eval()
            self.ev_actor_selfish.eval()
            print("[Python] All models loaded successfully.")

        except Exception as e:
            print(f"[Error] Failed to load models: {e}")
            return

        # --- 2. Physical Params ---
        self.N_MESS = 2
        self.N_EV = 3
        self.N_AGENTS = self.N_MESS + self.N_EV
        self.Horizon = 24
        self.MESS_Cap = 2.0; self.MESS_P_Max = 0.5
        self.EV_Cap = 1.0; self.EV_P_Max = 0.3

        # DRO Sampler for Inference
        self.dro = WorstCaseSampler(num_ev_agents=self.N_EV, horizon=self.Horizon)

    # =========================================================================
    # Helper: Dynamic Power Scaling (Safety Layer)
    # =========================================================================
    def dynamic_power_scaling(self, raw_action, soc, cap, p_max_rated, is_islanded=False):
        """ Safety Layer (Supports Tensor Operations) """
        SOC_MIN = 0.10; SOC_MAX = 0.95

        # Compatibility for Tensor and Scalar
        if isinstance(soc, torch.Tensor):
            zero = torch.tensor(0.0, device=self.device)
            e_dis_max = torch.maximum(zero, (soc - SOC_MIN) * cap)
            e_ch_max = torch.maximum(zero, (SOC_MAX - soc) * cap)
        else:
            e_dis_max = max(0.0, (soc - SOC_MIN) * cap)
            e_ch_max = max(0.0, (SOC_MAX - soc) * cap)

        p_dis_max_phys = e_dis_max / 1.0
        p_ch_max_phys = e_ch_max / 1.0

        if isinstance(raw_action, torch.Tensor):
            p_upper = torch.minimum(torch.tensor(p_max_rated, device=self.device), p_dis_max_phys)
            p_lower = -torch.minimum(torch.tensor(p_max_rated, device=self.device), p_ch_max_phys)
        else:
            p_upper = min(p_max_rated, p_dis_max_phys)
            p_lower = -min(p_max_rated, p_ch_max_phys)

        # Strict Island Constraint (No discharge at low SOC)
        if is_islanded:
            if isinstance(soc, torch.Tensor):
                mask = (soc < 0.15)
                p_upper = torch.where(mask, torch.tensor(0.0, device=self.device), p_upper)
            elif soc < 0.15:
                p_upper = 0.0

        center = (p_upper + p_lower) / 2.0
        radius = (p_upper - p_lower) / 2.0
        return center + raw_action * radius


    # =========================================================================
    # NEW Interface: Single Step Batch Response (V8.1 Closed-Loop System)
    # =========================================================================
    def get_batch_step_response(self, batch_prices_t, mess_soc_batch, ev_soc_batch,
                                m_sched_t, m_isl_t, e_isl_t, start_hour, current_t):
        """
        执行单步（当前小时 current_t）的大批量推理。
        SOC 由 MATLAB 层计算物理潮流后真实反馈，Python 不再内部虚假扣减。
        """
        start_hour = int(start_hour)
        # current_t is 1-based from MATLAB (1~24), convert to 0-based for Python
        t_idx = int(current_t) - 1

        price_tensor = torch.tensor(batch_prices_t, dtype=torch.float32, device=self.device)
        batch_size = price_tensor.shape[0]

        # 1. 还原物理环境反馈的真实 SOC
        mess_soc = torch.tensor(mess_soc_batch, dtype=torch.float32, device=self.device).view(batch_size, self.N_MESS)
        ev_soc = torch.tensor(ev_soc_batch, dtype=torch.float32, device=self.device).view(batch_size, self.N_EV)

        m_sched_np = np.array(m_sched_t)
        m_isl_np = np.array(m_isl_t)
        e_isl_np = np.array(e_isl_t)

        # 2. DRO 场景计算 (基于起始时间戳)
        ev_avail_mask, ev_target_soc = self.dro.get_worst_case_scenario(start_hour=start_hour)
        ev_avail_t = 1.0 if ev_avail_mask[t_idx] > 0 else 0.0

        # 3. 归一化时间
        norm_time = ((start_hour + t_idx) % 24) / 24.0

        step_actions = torch.zeros((batch_size, self.N_AGENTS), device=self.device)

        # 4. 构建邻居特征
        m_feats = []
        for i in range(self.N_MESS):
            avail = 1.0 if m_sched_np[i] != -1 else 0.0
            feat = torch.stack([
                mess_soc[:, i],
                torch.full((batch_size,), avail, device=self.device),
                torch.full((batch_size,), m_isl_np[i], device=self.device)
            ], dim=1)
            m_feats.append(feat)

        e_feats = []
        for i in range(self.N_EV):
            feat = torch.stack([
                ev_soc[:, i],
                torch.full((batch_size,), ev_avail_t, device=self.device),
                torch.full((batch_size,), e_isl_np[i], device=self.device)
            ], dim=1)
            e_feats.append(feat)

        all_feats = m_feats + e_feats

        # 5. 智能体独立决策
        for i in range(self.N_AGENTS):
            # A. 自身特征构建
            if i < self.N_MESS:
                m_idx = i
                if m_sched_np[m_idx] == -1: continue

                s_vec = torch.stack([
                    price_tensor,
                    mess_soc[:, m_idx],
                    torch.ones(batch_size, device=self.device),
                    torch.full((batch_size,), m_isl_np[m_idx], device=self.device),
                    torch.full((batch_size,), norm_time, device=self.device),
                    torch.zeros(batch_size, device=self.device)
                ], dim=1)
                model = self.mess_actor
                my_isl = m_isl_np[m_idx]
            else:
                e_idx = i - self.N_MESS
                if ev_avail_t == 0: continue

                # [核心同步修复] 无私型 EV (EV#1) 不设离场电量考核目标
                actual_target_soc = 0.0 if e_idx == 0 else ev_target_soc

                s_vec = torch.stack([
                    price_tensor,
                    ev_soc[:, e_idx],
                    torch.full((batch_size,), actual_target_soc, device=self.device),
                    torch.ones(batch_size, device=self.device),
                    torch.full((batch_size,), norm_time, device=self.device),
                    torch.full((batch_size,), e_isl_np[e_idx], device=self.device)
                ], dim=1)
                model = self.ev_actor_altruistic if e_idx == 0 else self.ev_actor_selfish
                my_isl = e_isl_np[e_idx]

            # B. 邻居特征与注意力掩码 (Masking)
            neigh_list = [f for j, f in enumerate(all_feats) if j != i]
            n_tensor = torch.stack(neigh_list, dim=1)

            vis_avail = (n_tensor[:, :, 1] > 0.5)
            vis_isl = (torch.abs(n_tensor[:, :, 2] - my_isl) < 0.1)
            mask_tensor = (vis_avail & vis_isl).float()

            # C. 前向推理
            with torch.no_grad():
                raw_action = model(s_vec, n_tensor, mask_tensor)

            # view(-1) 保障即使 batch_size=1 时结构也不坍塌
            raw_action = raw_action.view(-1)

            # D. 安全层与动作收集 (绝不更新SOC！)
            if i < self.N_MESS:
                is_islanded = (my_isl == 1)
                p = self.dynamic_power_scaling(raw_action, mess_soc[:, i], self.MESS_Cap, self.MESS_P_Max, is_islanded)
                step_actions[:, i] = p
            else:
                e_idx = i - self.N_MESS
                p = self.dynamic_power_scaling(raw_action, ev_soc[:, e_idx], self.EV_Cap, self.EV_P_Max)
                step_actions[:, i] = p

        # 6. 展平返回给 MATLAB
        # 格式: [P_Mess1_Pop1, P_Mess2_Pop1, P_EV1_Pop1..., P_Mess1_Pop2...]
        return step_actions.cpu().numpy().flatten().tolist()


    # =========================================================================
    # Legacy Interface: Batch Response (Open-Loop, kept for fallback)
    # =========================================================================
    def get_batch_follower_response(self, batch_prices_list, mess_sched_list=None, mess_island_list=None, ev_island_list=None, start_hour=0):
        start_hour = int(start_hour)
        price_tensor = torch.tensor(batch_prices_list, dtype=torch.float32).to(self.device)
        batch_size = price_tensor.shape[0]

        if mess_sched_list is None: mess_sched_np = np.ones((self.N_MESS, self.Horizon))
        else: mess_sched_np = np.array(mess_sched_list).reshape(self.N_MESS, self.Horizon)

        if mess_island_list is None: mess_island_np = np.zeros((self.N_MESS, self.Horizon))
        else: mess_island_np = np.array(mess_island_list).reshape(self.N_MESS, self.Horizon)

        if ev_island_list is None: ev_island_np = np.zeros((self.N_EV, self.Horizon))
        else: ev_island_np = np.array(ev_island_list).reshape(self.N_EV, self.Horizon)

        mess_soc = torch.ones((batch_size, self.N_MESS), device=self.device) * 0.9
        ev_soc = torch.ones((batch_size, self.N_EV), device=self.device) * 0.65
        ev_avail_mask, ev_target_soc = self.dro.get_worst_case_scenario(start_hour=start_hour)
        all_actions = torch.zeros((batch_size, self.N_AGENTS, self.Horizon), device=self.device)

        for t in range(self.Horizon):
            current_prices = price_tensor[:, t]
            norm_time = ((start_hour + t) % 24) / 24.0

            m_sched_t = mess_sched_np[:, t]
            m_isl_t = mess_island_np[:, t]
            e_isl_t = ev_island_np[:, t]
            ev_avail_t = 1.0 if ev_avail_mask[t] > 0 else 0.0

            m_feats = []
            for i in range(self.N_MESS):
                avail = 1.0 if m_sched_t[i] != -1 else 0.0
                feat = torch.stack([
                    mess_soc[:, i],
                    torch.full((batch_size,), avail, device=self.device),
                    torch.full((batch_size,), m_isl_t[i], device=self.device)
                ], dim=1)
                m_feats.append(feat)

            e_feats = []
            for i in range(self.N_EV):
                feat = torch.stack([
                    ev_soc[:, i],
                    torch.full((batch_size,), ev_avail_t, device=self.device),
                    torch.full((batch_size,), e_isl_t[i], device=self.device)
                ], dim=1)
                e_feats.append(feat)

            all_feats = m_feats + e_feats

            for i in range(self.N_AGENTS):
                if i < self.N_MESS:
                    m_idx = i
                    if m_sched_t[m_idx] == -1: continue
                    s_vec = torch.stack([
                        current_prices,
                        mess_soc[:, m_idx],
                        torch.ones(batch_size, device=self.device),
                        torch.full((batch_size,), m_isl_t[m_idx], device=self.device),
                        torch.full((batch_size,), norm_time, device=self.device),
                        torch.zeros(batch_size, device=self.device)
                    ], dim=1)
                    model = self.mess_actor
                    my_isl = m_isl_t[m_idx]
                else:
                    e_idx = i - self.N_MESS
                    if ev_avail_t == 0: continue

                    # [核心同步修复] 遗留函数中也必须保持逻辑一致
                    actual_target_soc = 0.0 if e_idx == 0 else ev_target_soc

                    s_vec = torch.stack([
                        current_prices,
                        ev_soc[:, e_idx],
                        torch.full((batch_size,), actual_target_soc, device=self.device),
                        torch.ones(batch_size, device=self.device),
                        torch.full((batch_size,), norm_time, device=self.device),
                        torch.full((batch_size,), e_isl_t[e_idx], device=self.device)
                    ], dim=1)
                    model = self.ev_actor_altruistic if e_idx == 0 else self.ev_actor_selfish
                    my_isl = e_isl_t[e_idx]

                neigh_list = [f for j, f in enumerate(all_feats) if j != i]
                n_tensor = torch.stack(neigh_list, dim=1)
                vis_avail = (n_tensor[:, :, 1] > 0.5)
                vis_isl = (torch.abs(n_tensor[:, :, 2] - my_isl) < 0.1)
                mask_tensor = (vis_avail & vis_isl).float()

                with torch.no_grad():
                    raw_action = model(s_vec, n_tensor, mask_tensor)
                raw_action = raw_action.squeeze()

                if i < self.N_MESS:
                    is_islanded = (my_isl == 1)
                    p = self.dynamic_power_scaling(raw_action, mess_soc[:, i], self.MESS_Cap, self.MESS_P_Max, is_islanded)
                    all_actions[:, i, t] = p
                    mess_soc[:, i] -= p / self.MESS_Cap # 老版本开环扣除
                else:
                    e_idx = i - self.N_MESS
                    p = self.dynamic_power_scaling(raw_action, ev_soc[:, e_idx], self.EV_Cap, self.EV_P_Max)
                    all_actions[:, i, t] = p
                    ev_soc[:, e_idx] -= p / self.EV_Cap

        flat_results = []
        all_actions_cpu = all_actions.cpu().numpy()
        for b in range(batch_size):
            b_act = []
            for agent_idx in range(self.N_AGENTS):
                b_act.extend(all_actions_cpu[b, agent_idx, :].tolist())
            flat_results.extend(b_act)

        return flat_results

adapter = StackelbergAdapter()