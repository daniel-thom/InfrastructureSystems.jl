# Adds can be batched through `begin_time_series_update` to amortize store flushes.
const ADD_TIME_SERIES_BATCH_SIZE = 100

mutable struct TimeSeriesManager <: InfrastructureSystemsType
    data_store::TimeSeriesStorage
    read_only::Bool
end

function TimeSeriesManager(;
    data_store = nothing,
    in_memory = false,
    read_only = false,
    directory = nothing,
    compression = CompressionSettings(),
)
    if isnothing(directory) && haskey(ENV, TIME_SERIES_DIRECTORY_ENV_VAR)
        directory = ENV[TIME_SERIES_DIRECTORY_ENV_VAR]
    end

    if isnothing(data_store)
        # The Rust store unifies data + metadata. On-disk artifacts live at
        # `<dir>/<uuid>_time_series.nc` (+ sidecar `.sqlite`).
        path = if in_memory
            nothing
        else
            # `directory` may be an explicit kwarg, the SIENNA_TIME_SERIES_DIRECTORY
            # env var, or `tempdir()`. Create it if missing (e.g. an HPC per-job
            # scratch path that doesn't exist yet).
            dir = isnothing(directory) ? tempdir() : directory
            mkpath(dir)
            joinpath(dir, string(UUIDs.uuid4()) * "_time_series.nc")
        end
        data_store =
            RustTimeSeriesStore(; in_memory = in_memory, path = path, compression = compression)
    end
    return TimeSeriesManager(data_store, read_only)
end

# (owner_uuid::String, owner_type::String, owner_category::String) for the Rust FFI.
function _rust_owner_args(owner::TimeSeriesOwners)
    return (
        string(get_uuid(owner)),
        string(nameof(typeof(owner))),
        _get_owner_category(owner),
    )
end

_rust_features(features) = Dict{String, Any}(string(k) => v for (k, v) in features)

"""
Begin an update of time series. Use this function when adding many time series arrays
in order to improve performance by amortizing store flushes across the batch.
"""
function begin_time_series_update(
    func::Function,
    mgr::TimeSeriesManager,
)
    open_store!(mgr.data_store, "r+") do
        func()
    end
    flush!(mgr.data_store)
    return
end

function bulk_add_time_series!(
    mgr::TimeSeriesManager,
    associations;
    kwargs...,
)
    ts_keys = TimeSeriesKey[]
    begin_time_series_update(mgr) do
        for association in associations
            key = add_time_series!(
                mgr,
                association.owner,
                association.time_series; association.features...,
            )
            push!(ts_keys, key)
        end
    end

    return ts_keys
end

function add_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    _throw_if_read_only(mgr)
    return _rust_add_time_series!(mgr, owner, time_series; features...)
end

function clear_time_series!(mgr::TimeSeriesManager)
    _throw_if_read_only(mgr)
    clear_time_series!(mgr.data_store)
    return
end

function clear_time_series!(mgr::TimeSeriesManager, component::TimeSeriesOwners)
    _throw_if_read_only(mgr)
    owner_uuid, _, _ = _rust_owner_args(component)
    _rust_clear_owner!(mgr.data_store, owner_uuid)
    @debug "Cleared time_series in $(summary(component))." _group =
        LOG_GROUP_TIME_SERIES
    return
end

get_metadata(
    mgr::TimeSeriesManager,
    component::TimeSeriesOwners,
    time_series_type::Type{<:TimeSeriesData},
    name::String;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) = _rust_get_metadata(
    component,
    time_series_type,
    name;
    resolution = resolution,
    interval = interval,
    features...,
)

list_metadata(
    mgr::TimeSeriesManager,
    component::TimeSeriesOwners;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) = _rust_owner_list_metadata(
    component;
    time_series_type = time_series_type,
    name = name,
    resolution = resolution,
    interval = interval,
    features...,
)

"""
Remove the time series data for a component.
"""
function remove_time_series!(
    mgr::TimeSeriesManager,
    time_series_type::Type{<:TimeSeriesData},
    owner::TimeSeriesOwners,
    name::String;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    _throw_if_read_only(mgr)
    owner_uuid, _, _ = _rust_owner_args(owner)
    feats = _rust_features(features)
    if time_series_type <: SingleTimeSeries
        # A DeterministicSingleTimeSeries shares the underlying SingleTimeSeries
        # array, so the base series cannot be removed while a DST references it.
        if has_typed(mgr.data_store, owner_uuid, name, TSS.TS_TYPE_DETERMINISTIC_SINGLE;
            resolution = resolution, features = feats)
            throw(ArgumentError(
                "Cannot remove SingleTimeSeries '$name' because it is attached to a " *
                "DeterministicSingleTimeSeries."))
        end
        remove_single!(mgr.data_store, owner_uuid, name;
            resolution = resolution, features = feats)
    elseif time_series_type <: Forecast
        for tt in (TSS.TS_TYPE_DETERMINISTIC, TSS.TS_TYPE_DETERMINISTIC_SINGLE,
            TSS.TS_TYPE_PROBABILISTIC, TSS.TS_TYPE_SCENARIOS)
            if has_typed(mgr.data_store, owner_uuid, name, tt;
                resolution = resolution, features = feats)
                remove_typed!(mgr.data_store, owner_uuid, name, tt;
                    resolution = resolution, features = feats)
            end
        end
    else
        error("Rust backend does not support $time_series_type")
    end
    return
end

function remove_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    metadata::TimeSeriesMetadata,
)
    _throw_if_read_only(mgr)
    feats = (Symbol(k) => v for (k, v) in get_features(metadata))
    remove_time_series!(
        mgr,
        time_series_metadata_to_data(metadata),
        owner,
        get_name(metadata);
        resolution = get_resolution(metadata),
        feats...,
    )
    return
end

function _throw_if_read_only(mgr::TimeSeriesManager)
    if mgr.read_only
        throw(ArgumentError("Time series operation is not allowed in read-only mode."))
    end
end

function compare_values(
    match_fn::Union{Function, Nothing},
    x::TimeSeriesManager,
    y::TimeSeriesManager;
    compare_uuids = false,
    exclude = Set{Symbol}(),
)
    # `read_only` can be changed during deserialization and is tested separately;
    # structural equality is the data store's count comparison.
    return compare_values(
        match_fn,
        x.data_store,
        y.data_store;
        compare_uuids = compare_uuids,
        exclude = exclude,
    )
end
