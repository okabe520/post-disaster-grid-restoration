function area_ids = map_area_ids_for_python(raw_component_ids)
%MAP_AREA_IDS_FOR_PYTHON Translate MATLAB graph labels into the RL contract.
%   Component containing bus 1 is grid-connected (0); every other
%   component is an island (1..N).  Raw CONNCOMP labels stay untouched for
%   the optimization model because their numbering is implementation detail.

    raw_component_ids = raw_component_ids(:);
    if isempty(raw_component_ids)
        area_ids = raw_component_ids;
        return;
    end

    main_component = raw_component_ids(1);
    area_ids = zeros(size(raw_component_ids));
    island_components = unique(raw_component_ids(raw_component_ids ~= main_component), 'stable');

    for island_id = 1:numel(island_components)
        area_ids(raw_component_ids == island_components(island_id)) = island_id;
    end
end
