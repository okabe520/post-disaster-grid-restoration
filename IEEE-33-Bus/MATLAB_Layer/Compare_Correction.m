function Compare_Correction(baseline_dir, output_dir, baseline_hourly_file)
% Compare the saved baseline dispatch with two current-policy replays.
here = fileparts(mfilename('fullpath'));
data_dir = fullfile(here, '..', 'Data');
if nargin < 3
    baseline_hourly_file = fullfile(data_dir, 'Comparisons', 'baseline_balanced_hourly.csv');
end
old = load(fullfile(baseline_dir, 'Data', 'Optimization_Result.mat'), 'x_opt', 'f_val');
new = load(fullfile(data_dir, 'Optimization_Result.mat'), 'x_opt', 'f_val');
old_strategy = load(fullfile(baseline_dir, 'Data', 'strategy.mat'));
new_strategy = load(fullfile(data_dir, 'strategy.mat'));
assert(isequal(old_strategy.Reconfig_Plan, new_strategy.Reconfig_Plan));
assert(isequal(old_strategy.MESS_Schedule, new_strategy.MESS_Schedule));

env = GridEnv();
curve = load(fullfile(data_dir, 'curve.mat'), 'START_HOUR');
python_dir = fullfile(here, '..', 'Python_Layer');
if count(py.sys.path, python_dir) == 0
    insert(py.sys.path, int32(0), python_dir);
end
server = py.importlib.import_module('agent_server');
corrected = server.adapter;

old_indices = select_strategies(old.f_val);
new_indices = select_strategies(new.f_val);
old_price = old.x_opt(old_indices(4), :);
new_price = new.x_opt(new_indices(4), :);
a = readtable(baseline_hourly_file);
assert(isequal(a.Step, (1:env.NT)') && max(abs(a.Price - old_price')) < 1e-10, ...
    'Baseline dispatch does not use the saved baseline price.');
b = replay(env, corrected, old_price, curve.START_HOUR);
c = replay(env, corrected, new_price, curve.START_HOUR);
for k = 1:3
    replay(env, corrected, new.x_opt(new_indices(k), :), curve.START_HOUR);
end
assert(max(abs([sum(a.Shed_MW), sum(a.Cost_CNY), sum(a.Outage_min)] - old.f_val(old_indices(4), :)) ./ ...
    max(1, abs(old.f_val(old_indices(4), :)))) < 1e-4, 'Saved baseline dispatch does not match optimization.');
assert(max(abs([sum(c.Shed_MW), sum(c.Cost_CNY), sum(c.Outage_min)] - new.f_val(new_indices(4), :)) ./ ...
    max(1, abs(new.f_val(new_indices(4), :)))) < 1e-4, 'Corrected replay does not match optimization.');

writetable(a, fullfile(output_dir, 'baseline_balanced_hourly.csv'));
writetable(b, fullfile(output_dir, 'corrected_same_price_hourly.csv'));
writetable(c, fullfile(output_dir, 'corrected_optimized_hourly.csv'));
cols = {'CriticalShed_MW','OtherShed_MW','Shed_MW','Cost_CNY','Outage_min', ...
    'PV_MW','Spill_MW','MESSDischarge_MW','EVDischarge_MW'};
summary = array2table([sum(a{:,cols},1); sum(b{:,cols},1); sum(c{:,cols},1)], ...
    'VariableNames', {'CriticalShed_MWh','OtherShed_MWh','Shed_MWh','Cost_CNY','Outage_min', ...
    'PV_MWh','Spill_MWh','MESSDischarge_MWh','EVDischarge_MWh'});
summary = addvars(summary, ["Baseline";"CorrectedSamePrice";"CorrectedOptimized"], 'Before',1,'NewVariableNames','Run');
writetable(summary, fullfile(output_dir, 'balanced_comparison.csv'));
disp(summary);

metrics = [old.f_val(old_indices,:), new.f_val(new_indices,:)];
comparison = array2table(metrics,'VariableNames',{'OldShed_MWh','OldCost_CNY','OldOutage_min', ...
    'NewShed_MWh','NewCost_CNY','NewOutage_min'});
comparison = addvars(comparison, ["MinShed";"MinCost";"MinOutage";"Balanced"], 'Before',1,'NewVariableNames','Strategy');
writetable(comparison, fullfile(output_dir, 'optimized_strategy_comparison.csv'));

f = figure('Visible','off','Color','white','Position',[100 100 1050 730]);
tiledlayout(3,2,'TileSpacing','compact','Padding','compact');
names = {'Price','Shed_MW','PV_MW','Spill_MW','MESSDischarge_MW','EVDischarge_MW'};
titles = {'Price (CNY/kWh)','Unserved load (MW)','Actual PV (MW)','Curtailed PV (MW)', ...
    'MESS discharge (MW)','EV discharge (MW)'};
for k = 1:numel(names)
    nexttile;
    plot(a.Step,[a.(names{k}), b.(names{k}), c.(names{k})], 'LineWidth',1.4);
    grid on; xlim([1 24]); title(titles{k}); xlabel('Simulation hour');
    if k == 1
        legend('Baseline','Corrected, same price','Corrected, optimized','Location','best');
    end
end
exportgraphics(f, fullfile(output_dir, 'balanced_comparison.png'), 'Resolution',180);
close(f);
end

function indices = select_strategies(f)
[~, a] = min(f(:,1));
[~, b] = min(f(:,2));
[~, c] = min(f(:,3));
[~, d] = min(sum((f ./ max(f + 1e-6, [], 1)).^2, 2));
indices = [a,b,c,d];
end

function out = replay(env, adapter, price, start_hour)
values = zeros(env.NT,11);
m_soc = [0.9,0.9]; e_soc = [0.65,0.65,0.65];
for t = 1:env.NT
    m_nodes = env.MESS_Schedule(:,t);
    ids = env.Python_Area_ID_Daily(:,t);
    m_ids = zeros(2,1);
    m_ids(m_nodes > 0) = ids(m_nodes(m_nodes > 0));
    actions = double(adapter.get_batch_step_response(py.list({price(t)}), ...
        py.list(num2cell(m_soc)), py.list(num2cell(e_soc)), ...
        py.list(num2cell(int32(m_nodes'))), py.list(num2cell(int32(m_ids'))), ...
        py.list(num2cell(int32(ids(env.Idx_EV)'))), int32(start_hour), int32(t)));
    [~,cost,outage,m,e,x] = env.step_simulation(t,price(t),actions(1:2),actions(3:5));
    shed = x.Real_Shed_MWh;
    m_soc = min(0.95,max(0.10,m_soc-m(:)'/2));
    e_soc = min(0.95,max(0.10,e_soc-e(:)'/1));
    [load_p,~,pv] = env.get_snapshot_state(t);
    assert(all(x.PV_Act_MW >= -1e-6 & x.PV_Spill_MW >= -1e-6), 'Invalid PV or curtailment at step %d.', t);
    assert(abs(sum(x.PV_Act_MW + x.PV_Spill_MW - pv*env.BASE_MVA)) < 1e-6);
    residual = x.Grid_MW + sum(x.PV_Act_MW) + sum(x.EDG_Matrix_Col) + sum(m) + sum(e) ...
        - (sum(load_p)*env.BASE_MVA - shed);
    assert(abs(residual) < 1e-5, 'Solved dispatch must balance at step %d.', t);
    values(t,:) = [t,price(t),sum(x.Shed_Matrix_Col(env.Idx_Essential)), ...
        sum(x.Shed_Matrix_Col(env.Idx_Ordinary)),shed,cost,outage,sum(x.PV_Act_MW), ...
        sum(x.PV_Spill_MW), sum(max(0,m)), sum(max(0,e))];
end
out = array2table(values,'VariableNames',{'Step','Price','CriticalShed_MW', ...
    'OtherShed_MW','Shed_MW','Cost_CNY','Outage_min','PV_MW','Spill_MW','MESSDischarge_MW','EVDischarge_MW'});
end
