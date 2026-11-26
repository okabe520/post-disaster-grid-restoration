import os
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"

import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.optim as optim
import numpy as np
import sys
import time
import argparse
from pathlib import Path

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from models import DynamicActor, DynamicCritic 
from dro_sampler import WorstCaseSampler

# ==========================================
# 0. Global Config & Physical Parameters
# ==========================================
DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

N_MESS = 2
N_EV = 3
N_AGENTS = N_MESS + N_EV
HORIZON = 24

MESS_SELF_DIM = 6      
EV_SELF_DIM = 6        
NEIGHBOR_STATE_DIM = 3 

MESS_CAP = 2.0
MESS_P_MAX = 0.5
EV_CAP = 1.0
EV_P_MAX = 0.3

MAX_EPISODES = 15000   
BATCH_SIZE = 1024       
LR_ACTOR = 3e-4         
LR_CRITIC = 1e-3
GAMMA = 0.99
TAU = 0.005

# ==========================================
# 1. Core Tools: Dynamic Safety & Reward
# ==========================================
def dynamic_power_scaling(raw_action, soc, cap, p_max_rated, is_islanded=False):
    SOC_MIN = 0.10; SOC_MAX = 0.95
    e_dis_max = max(0.0, (soc - SOC_MIN) * cap)
    e_ch_max = max(0.0, (SOC_MAX - soc) * cap)
    p_dis_max_phys = e_dis_max / 1.0 
    p_ch_max_phys = e_ch_max / 1.0
    p_upper = min(p_max_rated, p_dis_max_phys)
    p_lower = -min(p_max_rated, p_ch_max_phys)
    
    if is_islanded and soc < 0.15: p_upper = 0.0
    
    center = (p_upper + p_lower) / 2.0
    radius = (p_upper - p_lower) / 2.0
    return center + raw_action * radius

def get_personality_reward(idx, p, price, soc, target, is_island, is_connected, hours_left, local_scarcity):
    if not is_connected:
        return 0.0
        
    COST_THRESHOLD_MESS = 0.8 
    COST_THRESHOLD_EV   = 0.6  

    # 动态阈值机制：只受“同孤岛局部稀缺度”影响，最高上浮 0.2
    dyn_thresh_mess = COST_THRESHOLD_MESS + local_scarcity * 0.2
    dyn_thresh_ev   = COST_THRESHOLD_EV   + local_scarcity * 0.2

    if idx < 2:  # === MESS ===
        if p > 0: 
            eco = p * (price - dyn_thresh_mess) * 10.0
            if is_island: eco += p * 2.0  
        else:
            eco = (p * price) * 10.0
            
        penalty = 0.0
        if soc < 0.20: penalty += (0.20 - soc) * 200.0 
        elif soc > 0.90: penalty += (soc - 0.90) * 200.0
            
        return eco - penalty

    else:  # === EV ===
        ev_id = idx - 2
        is_altruistic = (ev_id == 0) 
        
        if p > 0:
            eco = p * (price - dyn_thresh_ev) * 10.0
        else:
            eco = (p * price) * 10.0
            
        if is_island and p > 0:
            if is_altruistic:
                eco += p * 1.5  
            else:
                pass 
        
        penalty = 0.0
        if not is_altruistic:
            if 0 < hours_left <= 4 and soc < target:
                penalty += 100.0 * (target - soc) / (hours_left + 0.1)
            if soc < 0.3: 
                penalty += (0.3 - soc) * 100.0
        else:
            if soc < 0.15: 
                penalty += (0.15 - soc) * 200.0
            
        return eco - penalty

# ==========================================
# 2. Structured Experience Buffer
# ==========================================
class StructuredBuffer:
    def __init__(self, capacity):
        self.capacity = capacity
        self.ptr = 0
        self.size = 0
        self.storage = [] 

    def push(self, transition):
        if len(self.storage) < self.capacity: self.storage.append(None)
        self.storage[self.ptr] = transition
        self.ptr = (self.ptr + 1) % self.capacity
        self.size = min(self.size + 1, self.capacity)

    def sample(self, batch_size):
        indices = np.random.randint(0, self.size, size=batch_size)
        batch = [self.storage[i] for i in indices]
        def stack(k):
            return torch.FloatTensor(np.array([b[k] for b in batch])).to(DEVICE)
        return stack(0), stack(1), stack(2), stack(3), stack(4), stack(5), stack(6), stack(7), stack(8)

# ==========================================
# 3. Agent Wrapper
# ==========================================
class Agent:
    def __init__(self, self_dim, neigh_dim, act_dim=1):
        self.actor = DynamicActor(self_dim, neigh_dim, act_dim).to(DEVICE)
        self.actor_target = DynamicActor(self_dim, neigh_dim, act_dim).to(DEVICE)
        self.actor_target.load_state_dict(self.actor.state_dict())
        self.actor_opt = optim.Adam(self.actor.parameters(), lr=LR_ACTOR)
        
        critic_neigh_dim = neigh_dim + act_dim
        self.critic = DynamicCritic(self_dim, critic_neigh_dim, act_dim).to(DEVICE)
        self.critic_target = DynamicCritic(self_dim, critic_neigh_dim, act_dim).to(DEVICE)
        self.critic_target.load_state_dict(self.critic.state_dict())
        self.critic_opt = optim.Adam(self.critic.parameters(), lr=LR_CRITIC)

    def soft_update(self):
        for tp, p in zip(self.actor_target.parameters(), self.actor.parameters()):
            tp.data.copy_(tp.data * (1-TAU) + p.data * TAU)
        for tp, p in zip(self.critic_target.parameters(), self.critic.parameters()):
            tp.data.copy_(tp.data * (1-TAU) + p.data * TAU)

# ==========================================
# 4. Graph Construction
# ==========================================
def hours_until_departure(daily_availability, t):
    """Count consecutive available slots, including t, on the recurring clock."""
    for offset in range(len(daily_availability)):
        if not daily_availability[(t + offset) % len(daily_availability)]:
            return offset
    return len(daily_availability)


def build_graph(price, sh, t, ms, es, et, mm, em, isl):
    all_self, all_neigh, all_mask = [], [], []
    base_feats = []
    
    for i in range(N_MESS):
        av = 1.0 if mm[i][t] == 1 else 0.0
        base_feats.append([ms[i], av, isl[i][t]])
    for i in range(N_EV):
        av = 1.0 if em[t] > 0 else 0.0
        base_feats.append([es[i], av, isl[N_MESS+i][t]])
    base_feats = np.array(base_feats)

    nt = ((sh + t) % 24) / 24.0 

    for i in range(N_AGENTS):
        if i < N_MESS:
            s = [price, ms[i], mm[i][t], isl[i][t], nt, 0.0] 
        else:
            idx = i - N_MESS
            av = 1.0 if em[t] > 0 else 0.0
            s = [price, es[idx], et[idx], av, nt, isl[i][t]]
        
        all_self.append(np.array(s))
        
        neighs = np.delete(base_feats, i, axis=0)
        my_isl = isl[i][t]
        masks = []
        for feat in neighs:
            masks.append(float(my_isl == feat[2] and feat[1] > 0.5))
            
        all_neigh.append(neighs)
        all_mask.append(np.array(masks))
        
    return all_self, all_neigh, all_mask

# ==========================================
# 5. Evaluation Function
# ==========================================
def evaluate(agents, dro, mode='dro', test_scenarios=None):
    total_r = 0.0
    for scen in test_scenarios:
        sh, p_crv, ms, es, isl_flag, isl_mask = scen
        ms_eval = ms.copy()
        es_eval = es.copy()
        
        if mode == 'deterministic':
            perfect_arr = 15; perfect_dep = 9 
            em = np.zeros(24)
            for t_rel in range(24):
                t_mod = (sh + t_rel) % 24
                if (t_mod >= perfect_arr) or (t_mod < perfect_dep):
                    em[t_rel] = 1.0
            et_val = 0.8
        else:
            em, et_val = dro.get_worst_case_scenario(sh)
            
        et = [0.0, et_val, et_val] 
        mm = [np.ones(24) for _ in range(N_MESS)]
        
        isl = [np.zeros(24) for _ in range(N_AGENTS)]
        if isl_flag:
            for t in range(HORIZON):
                if isl_mask[t] == 1.0:
                    # 默认测试集灾害赋予 ID = 1.0
                    isl[1][t] = 1.0; isl[3][t] = 1.0; isl[4][t] = 1.0
        
        c_s, c_n, c_m = build_graph(p_crv[0], sh, 0, ms_eval, es_eval, et, mm, em, isl)
        ep_r = 0.0
        
        for t in range(HORIZON):
            actions = []
            with torch.no_grad():
                for i, ag in enumerate(agents):
                    s = torch.FloatTensor(c_s[i]).unsqueeze(0).to(DEVICE)
                    n = torch.FloatTensor(c_n[i]).unsqueeze(0).to(DEVICE)
                    m = torch.FloatTensor(c_m[i]).unsqueeze(0).to(DEVICE)
                    a_raw = ag.actor(s, n, m).item()

                    # 只要 > 0.0 就视为在孤岛
                    my_isl_flag = (isl[i][t] > 0.0)
                    if i < N_MESS:
                        p = dynamic_power_scaling(a_raw, ms_eval[i], MESS_CAP, MESS_P_MAX, my_isl_flag)
                    else:
                        av = (em[t]>0)
                        p = dynamic_power_scaling(a_raw, es_eval[i-N_MESS], EV_CAP, EV_P_MAX, my_isl_flag) if av else 0.0
                    actions.append(p)

            step_r = 0.0
            for i in range(N_AGENTS):
                p = actions[i]
                actual_p = p
                my_isl = isl[i][t]

                # 计算局部稀缺度 (Local Scarcity)
                if my_isl > 0.0:
                    local_island_agents = sum([1 for idx_ag in range(N_AGENTS) if isl[idx_ag][t] == my_isl])
                    local_scarcity = local_island_agents / N_AGENTS
                else:
                    local_scarcity = 0.0

                if my_isl > 0.0 and p > 0: actual_p = p * 0.6
                
                if i < N_MESS:
                    ms_eval[i] = np.clip(ms_eval[i] - actual_p / MESS_CAP, 0.10, 0.95)
                    is_conn = (mm[i][t] == 1.0)
                    r = get_personality_reward(i, actual_p, p_crv[t], ms_eval[i], 0, my_isl > 0.0, is_conn, 24, local_scarcity)
                else:
                    idx = i - N_MESS
                    es_eval[idx] = np.clip(es_eval[idx] - actual_p / EV_CAP, 0.10, 0.95)
                    is_conn = (em[t] > 0)
                    
                    h_left = hours_until_departure(em, t)
                            
                    r = get_personality_reward(i, actual_p, p_crv[t], es_eval[idx], et[idx], my_isl > 0.0, is_conn, h_left, local_scarcity)
                step_r += r
            ep_r += step_r
            
            next_t = t+1 if t<23 else 0
            np_ = p_crv[next_t] if t<23 else 0
            n_s, n_n, n_m = build_graph(np_, sh, next_t, ms_eval, es_eval, et, mm, em, isl)
            c_s, c_n, c_m = n_s, n_n, n_m
            
        total_r += ep_r
        
    return total_r / len(test_scenarios)

# ==========================================
# 6. Main Training Loop
# ==========================================
def train_maddpg_v9(args):
    print(f"⚡ Training Mode: {args.mode.upper()} ⚡")
    print("   -> Version: V9.08 (Local Scarcity, Area ID Sync & Precise Threshold=0.2)")
    seed = args.seed if args.seed is not None else int(time.time())
    output = args.output or Path(__file__).resolve().parent / "saved_models" / f"actor_team_{args.mode}_best.pth"
    if output.exists():
        raise FileExistsError(f"Choose a fresh checkpoint path: {output}")
    torch.manual_seed(seed)
    print(f"Device: {DEVICE} | Seed: {seed} | Checkpoint: {output}")
    
    agents = [Agent(MESS_SELF_DIM, NEIGHBOR_STATE_DIM) for _ in range(N_MESS)] + \
             [Agent(EV_SELF_DIM, NEIGHBOR_STATE_DIM) for _ in range(N_EV)]
    
    buffer = StructuredBuffer(100000)
    dro = WorstCaseSampler(N_EV)
    
    np.random.seed(42)
    test_scenarios = []
    
    test_configs = [
        (0,  False, []),
        (12, False, []),
        (8,  True,  [(4, 8)]),
        (14, True,  [(4, 8), (11, 16)]),
        (22, True,  [(2, 8)])
    ]
    
    for sh_test, is_isl, isl_periods in test_configs:
        p_crv_test = np.random.uniform(0.3, 0.6, 24)
        isl_mask = np.zeros(24)
        
        if is_isl:
            for (isl_s, isl_e) in isl_periods:
                p_crv_test[isl_s:isl_e] = np.random.uniform(2.0, 3.2, isl_e - isl_s)
                if isl_s > 0: p_crv_test[isl_s-1] = np.random.uniform(1.0, 1.5)
                for t in range(isl_s, isl_e):
                    isl_mask[t] = 1.0
        else:
            for t in range(24):
                if 18 <= ((sh_test + t) % 24) <= 21:
                    p_crv_test[t] = np.random.uniform(1.5, 2.2)

        ms_test = np.ones(N_MESS) * 0.9
        es_test = np.ones(N_EV) * 0.5
        
        test_scenarios.append((sh_test, p_crv_test, ms_test, es_test, is_isl, isl_mask))
        
    np.random.seed(seed)
    
    noise = 0.5 
    best_score = -np.inf
    t0 = time.time()
    
    for ep in range(MAX_EPISODES):
        sh = np.random.randint(0, 24)
        p_crv = np.random.uniform(0.1, 1.5, 24) 
        
        peak_start = np.random.randint(0, 24)
        peak_len = np.random.randint(2, 5)
        peak_end = min(24, peak_start + peak_len)
        p_crv[peak_start:peak_end] = np.random.uniform(1.8, 3.5, peak_end - peak_start)
        
        p_crv += np.random.normal(0, 0.05, 24)
        p_crv = np.clip(p_crv, 0.1, 3.5) 
        p_crv = np.roll(p_crv, -sh)
        
        ms = np.ones(N_MESS)*0.9; es = np.random.uniform(0.4, 0.7, N_EV)
        
        if args.mode == 'deterministic':
            perfect_arr = 15; perfect_dep = 9
            em = np.zeros(24)
            for t_rel in range(24):
                t_mod = (sh + t_rel) % 24
                if (t_mod >= perfect_arr) or (t_mod < perfect_dep):
                    em[t_rel] = 1.0
            et_val = 0.8  
        else:
            em, et_val = dro.get_worst_case_scenario(sh)
            
        et = [0.0, et_val, et_val] 
        mm = [np.ones(24) for _ in range(N_MESS)]
        isl = [np.zeros(24) for _ in range(N_AGENTS)]
        
        # [动态区域 ID 升级] 为每次灾害随机分配一个唯一的 Area ID
        num_faults = np.random.randint(1, 5) 
        for fault_id in range(1, num_faults + 1):
            f_start = np.random.randint(0, 22)
            f_len = np.random.randint(2, 6)
            f_end = min(24, f_start + f_len)

            affected_agents = np.random.choice([0, 1, 2, 3, 4], size=np.random.randint(1, 4), replace=False)

            for t in range(f_start, f_end):
                for ag_idx in affected_agents:
                    isl[ag_idx][t] = float(fault_id)
        
        ep_rew = np.zeros(N_AGENTS)
        c_s, c_n, c_m = build_graph(p_crv[0], sh, 0, ms, es, et, mm, em, isl)
        
        for t in range(HORIZON):
            raws, reals = [], []
            with torch.no_grad():
                for i, ag in enumerate(agents):
                    s = torch.FloatTensor(c_s[i]).unsqueeze(0).to(DEVICE)
                    n = torch.FloatTensor(c_n[i]).unsqueeze(0).to(DEVICE)
                    m = torch.FloatTensor(c_m[i]).unsqueeze(0).to(DEVICE)
                    a = ag.actor(s, n, m).item()
                    a = np.clip(a + np.random.normal(0, noise), -1.0, 1.0)
                    raws.append(a)

                    my_isl_flag = (isl[i][t] > 0.0)
                    if i < N_MESS:
                        p = dynamic_power_scaling(a, ms[i], MESS_CAP, MESS_P_MAX, my_isl_flag)
                    else:
                        p = dynamic_power_scaling(a, es[i-N_MESS], EV_CAP, EV_P_MAX, my_isl_flag) if em[t]>0 else 0.0
                    reals.append(p)
            
            step_rs = []; n_ms = ms.copy(); n_es = es.copy()
            for i in range(N_AGENTS):
                p = reals[i]
                actual_p = p
                my_isl = isl[i][t]

                # 计算局部稀缺度 (Local Scarcity)
                if my_isl > 0.0:
                    local_island_agents = sum([1 for idx_ag in range(N_AGENTS) if isl[idx_ag][t] == my_isl])
                    local_scarcity = local_island_agents / N_AGENTS
                else:
                    local_scarcity = 0.0

                if my_isl > 0.0 and p > 0: actual_p = p * 0.6
                
                if i < N_MESS:
                    n_ms[i] = np.clip(n_ms[i] - actual_p / MESS_CAP, 0.10, 0.95)
                    is_conn = (mm[i][t] == 1.0)
                    r = get_personality_reward(i, actual_p, p_crv[t], n_ms[i], 0, my_isl > 0.0, is_conn, 24, local_scarcity)
                else:
                    idx = i - N_MESS
                    n_es[idx] = np.clip(n_es[idx] - actual_p / EV_CAP, 0.10, 0.95)
                    is_conn = (em[t] > 0)
                    
                    h_left = hours_until_departure(em, t)
                            
                    r = get_personality_reward(i, actual_p, p_crv[t], n_es[idx], et[idx], my_isl > 0.0, is_conn, h_left, local_scarcity)
                step_rs.append(r)
            ep_rew += np.array(step_rs)
            
            next_t = t+1 if t<23 else 0
            np_ = p_crv[next_t] if t<23 else 0
            n_s, n_n, n_m = build_graph(np_, sh, next_t, n_ms, n_es, et, mm, em, isl)
            
            buffer.push([c_s, c_n, c_m, np.array(raws).reshape(-1,1), np.array(step_rs), n_s, n_n, n_m, np.array([float(t==23)]*N_AGENTS).reshape(-1,1)])
            c_s, c_n, c_m = n_s, n_n, n_m
            ms = n_ms; es = n_es

        if buffer.size > BATCH_SIZE and ep % 5 == 0:
            for _ in range(10):
                batch = buffer.sample(BATCH_SIZE)
                b_s, b_n, b_m, b_a, b_r, b_ns, b_nn, b_nm, b_d = batch
                
                all_tgt_acts = []
                with torch.no_grad():
                    for j in range(N_AGENTS):
                        all_tgt_acts.append(agents[j].actor_target(b_ns[:,j], b_nn[:,j], b_nm[:,j]))
                
                all_curr_acts = []
                for j in range(N_AGENTS):
                    all_curr_acts.append(agents[j].actor(b_s[:,j], b_n[:,j], b_m[:,j]))

                for i in range(N_AGENTS):
                    ag = agents[i]
                    tgt_neigh_acts = [all_tgt_acts[j] for j in range(N_AGENTS) if j!=i]
                    tgt_neigh_acts = torch.stack(tgt_neigh_acts, dim=1)
                    tgt_neigh_feat = torch.cat([b_nn[:,i], tgt_neigh_acts], dim=2)
                    with torch.no_grad():
                        qt = ag.critic_target(b_ns[:,i], tgt_neigh_feat, b_nm[:,i], all_tgt_acts[i])
                        y = b_r[:,i].unsqueeze(1) + (1 - b_d[:,i]) * GAMMA * qt
                    
                    curr_neigh_acts_buf = [b_a[:,j] for j in range(N_AGENTS) if j!=i]
                    curr_neigh_acts_buf = torch.stack(curr_neigh_acts_buf, dim=1)
                    curr_neigh_feat = torch.cat([b_n[:,i], curr_neigh_acts_buf], dim=2)
                    qc = ag.critic(b_s[:,i], curr_neigh_feat, b_m[:,i], b_a[:,i])
                    c_loss = nn.MSELoss()(qc, y)
                    ag.critic_opt.zero_grad(); c_loss.backward(); ag.critic_opt.step()
                    
                    pred_a = all_curr_acts[i] 
                    curr_neigh_acts_pol = [all_curr_acts[j].detach() for j in range(N_AGENTS) if j!=i]
                    curr_neigh_acts_pol = torch.stack(curr_neigh_acts_pol, dim=1)
                    curr_neigh_feat_pol = torch.cat([b_n[:,i], curr_neigh_acts_pol], dim=2)
                    a_loss = -ag.critic(b_s[:,i], curr_neigh_feat_pol, b_m[:,i], pred_a).mean()
                    ag.actor_opt.zero_grad(); a_loss.backward(); ag.actor_opt.step()
                    ag.soft_update()

        noise = max(0.05, noise * 0.9998)

        if ep > 0 and ep % 100 == 0:
            avg = ep_rew / HORIZON
            print(f"Ep {ep:5d} | Mode: {args.mode} | Noise {noise:.3f} | "
                  f"MESS: {avg[0]:.1f} | EV_Altruistic: {avg[2]:.1f} | EV_Selfish: {avg[3]:.1f} | "
                  f"Total: {np.mean(ep_rew):.1f} | Time: {time.time()-t0:.1f}s")
            
            score = evaluate(agents, dro, args.mode, test_scenarios)
            status = "(Keep)"
            if score > best_score:
                best_score = score; status = "🌟 NEW RECORD!"
                
                output.parent.mkdir(parents=True, exist_ok=True)
                pending = output.with_suffix(output.suffix + ".tmp")
                torch.save({
                    "actor_states": [agent.actor.state_dict() for agent in agents],
                    "mode": args.mode,
                    "seed": seed,
                    "episode": ep + 1,
                    "score": float(score),
                }, pending)
                pending.replace(output)
                
            print(f"    [Eval] Current: {score:7.1f} | Best: {best_score:7.1f} | {status}")

    print("Training Finished.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='MADDPG Training V9.08')
    parser.add_argument('--mode', type=str, default='dro', choices=['dro', 'deterministic'],
                        help='Training mode: "dro" (Robust) or "deterministic" (Baseline)')
    parser.add_argument('--seed', type=int)
    parser.add_argument('--output', type=Path, help='New file for the complete five-actor checkpoint')
    args = parser.parse_args()
    
    train_maddpg_v9(args)
