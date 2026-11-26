import numpy as np

class WorstCaseSampler:
    """
    Distributionally Robust Optimization (DRO) Sampler (V2.4 - Cross-day Logic Fixed)
    [Updates]
    1. 修复了跨日判定 Bug：引入 Modulo (取余) 逻辑，完美解决凌晨时段 (00:00-09:00) EV被误判为不在网的问题。
    2. 确保 AI 在夜间低谷期能够自由接管充电权限。
    """
    def __init__(self, num_ev_agents=3, horizon=24):
        self.num_ev = num_ev_agents
        self.T = horizon
        
        # [物理行为参数]
        # 15.0 = 下午 15:00 归队 (下班回家)
        self.abs_mu_arr = 15.0   
        self.sigma_arr = 1.5 
        
        # 33.0 = 次日早上 09:00 离开 (24 + 9)
        self.abs_mu_dep = 33.0   
        self.sigma_dep = 1.0 
        
        self.rho = 0.5 
        
        # 必须与 train_maddpg.py 一致
        self.EV_P_MAX_PU = 0.3 
        self.EV_CAP = 1.0

    def get_worst_case_scenario(self, start_hour=0):
        """
        生成 EV 的可用性掩码和目标电量
        """
        # 1. 计算物理到达/离开时间
        # 最晚到达 (Mean + Uncertainty)
        raw_arr_abs = self.abs_mu_arr + self.rho * self.sigma_arr
        # 最早离开 (Mean - Uncertainty)
        raw_dep_abs = self.abs_mu_dep - self.rho * self.sigma_dep
        
        # 将绝对时间映射到 24 小时制的时钟面上
        arr_mod = raw_arr_abs % 24
        dep_mod = raw_dep_abs % 24
        
        # 2. 构建滚动时间窗掩码
        availability = np.zeros(self.T)
        
        for t_rel in range(self.T):
            # 将当前测试时间也映射到 24 小时制
            t_mod = (start_hour + t_rel) % 24
            
            # [核心修复] 跨日判定逻辑
            if arr_mod > dep_mod:
                # 过夜充电场景 (例如: 15.75 到次日 8.5)
                # 只要时间在 15.75 之后(前半夜) 或者 8.5 之前(后半夜及清晨)，都算在网
                if (t_mod >= arr_mod) or (t_mod < dep_mod):
                    availability[t_rel] = 1.0
            else:
                # 日间充电场景 (常规包围，通常不会触发，除非有人白天充电)
                if arr_mod <= t_mod < dep_mod:
                    availability[t_rel] = 1.0
        
        # 3. 计算目标 SOC (Target SOC)
        window_len = np.sum(availability)
        if window_len == 0:
            return availability, 0.5
        
        # 基础目标：保障通勤快充线 (0.8)
        base_target_soc = 0.8
        
        # 物理约束检查：确保给定的时间窗口足够充到目标电量
        max_added_soc = (self.EV_P_MAX_PU * window_len) / self.EV_CAP
        feasible_target = 0.3 + max_added_soc
        
        target_soc = min(base_target_soc, feasible_target)
        target_soc = round(target_soc, 2)
        
        return availability, target_soc

    def sample_distribution(self):
        return np.ones(24), 0.8