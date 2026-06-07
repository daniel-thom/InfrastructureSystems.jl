# Rust-backed time series storage.
#
# `RustTimeSeriesStore` delegates BOTH array data and metadata to the external
# `time-series-store` Rust engine, via the `TimeSeriesStore.jl` binding package.
# The Rust store owns both: arrays land in a NetCDF4 `.nc` file (content-addressed
# by SHA-256 hash) and metadata in a sibling `.sqlite` file. Time series *data*
# identity is the array content hash, not a UUID. Persisting a system writes the
# `.nc` + `.sqlite` pair directly; no HDF5 is involved.
#
# This file holds the IS-specific glue (owner/feature conversion, window
# flatten/reshape, manager routing). All low-level FFI lives in `TimeSeriesStore`.

const TSS = TimeSeriesStore

# Not-found is raised by the binding; alias keeps the IS-facing name + tests stable.
const RustTimeSeriesNotFound = TimeSeriesStore.NotFoundError

# ---- Store -----------------------------------------------------------------

mutable struct RustTimeSeriesStore <: TimeSeriesStorage
    inner::TSS.Store
    "Filesystem base path for the `.nc` / `.sqlite` pair (nothing if in-memory)."
    path::Union{Nothing, String}
end

"""
    RustTimeSeriesStore(; in_memory=false, path=nothing)

Create a Rust-backed time series store. When `in_memory=false`, `path` is the
base path for the on-disk artifacts (`<path>.nc` and `<path>.sqlite`).
"""
function RustTimeSeriesStore(; in_memory::Bool = false, path = nothing)
    store = in_memory ? TSS.Store(; in_memory = true) :
            TSS.Store(; in_memory = false, path = path)
    return RustTimeSeriesStore(store, path === nothing ? nothing : String(path))
end

"""
    open_rust_store(path; read_only=false)

Open an existing on-disk Rust store from its `.nc` base path.
"""
function open_rust_store(path::AbstractString; read_only::Bool = false)
    return RustTimeSeriesStore(TSS.open_store(String(path); read_only = read_only), String(path))
end

close!(store::RustTimeSeriesStore) = TSS.close!(store.inner)

# ---- Conversions -----------------------------------------------------------

_tss_category(category::AbstractString) =
    category == "Component" ? TSS.Component :
    category == "SupplementalAttribute" ? TSS.SupplementalAttribute :
    error("unknown owner category $category")

# ---- Operations (thin delegations to TimeSeriesStore) ----------------------

"""
    serialize_single!(store, owner_uuid, owner_type, owner_category, name, sts;
                      features=Dict(), units=nothing, scaling_factor_multiplier=nothing)

Add a `SingleTimeSeries` (data + metadata) to the Rust store. The array is
content-addressed; identical arrays are de-duplicated automatically.
"""
function serialize_single!(
    store::RustTimeSeriesStore,
    owner_uuid::AbstractString,
    owner_type::AbstractString,
    owner_category::AbstractString,
    name::AbstractString,
    sts::SingleTimeSeries;
    features = Dict{String, Any}(),
    units::Union{Nothing, AbstractString} = nothing,
    scaling_factor_multiplier::Union{Nothing, AbstractString} = nothing,
)
    tss_ts = TSS.SingleTimeSeries(
        get_initial_timestamp(sts),
        get_resolution(sts),
        Vector{Float64}(TimeSeries.values(get_data(sts))),
    )
    TSS.add_time_series!(store.inner, owner_uuid, owner_type, _tss_category(owner_category),
        name, tss_ts; features = features, units = units,
        scaling_factor_multiplier = scaling_factor_multiplier)
    return
end

"""
    get_metadata(store, owner_uuid, name; resolution, features=Dict())

Return `(; initial_timestamp, resolution, length, data_hash)` for a stored
SingleTimeSeries. Throws `RustTimeSeriesNotFound` if absent.
"""
get_metadata(store::RustTimeSeriesStore, owner_uuid::AbstractString, name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing, features = Dict{String, Any}()) =
    TSS.get_metadata(store.inner, owner_uuid, name; resolution = resolution, features = features)

get_array_by_hash(store::RustTimeSeriesStore, data_hash::Vector{UInt8}) =
    TSS.get_array_by_hash(store.inner, data_hash)

"""
    get_single(store, owner_uuid, name; resolution, features=Dict()) -> SingleTimeSeries

Reconstruct a `SingleTimeSeries` (metadata + array) from the Rust store.
"""
function get_single(
    store::RustTimeSeriesStore,
    owner_uuid::AbstractString,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}(),
)
    meta = get_metadata(store, owner_uuid, name; resolution = resolution, features = features)
    values = get_array_by_hash(store, meta.data_hash)
    timestamps = range(meta.initial_timestamp; length = meta.length, step = meta.resolution)
    return SingleTimeSeries(;
        name = String(name),
        data = TimeSeries.TimeArray(collect(timestamps), values),
        resolution = meta.resolution,
    )
end

has_time_series(store::RustTimeSeriesStore, owner_uuid::AbstractString, name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing, features = Dict{String, Any}()) =
    TSS.has_time_series(store.inner, owner_uuid, name; resolution = resolution, features = features)

remove_single!(store::RustTimeSeriesStore, owner_uuid::AbstractString, name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing, features = Dict{String, Any}()) =
    TSS.remove_time_series!(store.inner, owner_uuid, name;
        resolution = resolution, features = features)

get_counts(store::RustTimeSeriesStore) = TSS.get_counts(store.inner)

function get_num_time_series(store::RustTimeSeriesStore)
    c = get_counts(store)
    return c.static_time_series + c.forecasts
end

flush!(store::RustTimeSeriesStore) = TSS.flush!(store.inner)

Base.isempty(store::RustTimeSeriesStore) = get_num_time_series(store) == 0

# No NetCDF compression knob is exposed through the FFI yet.
get_compression_settings(::RustTimeSeriesStore) = CompressionSettings(; enabled = false)

"""
    serialize(store::RustTimeSeriesStore, file_path)

Persist the store's two artifacts to `file_path` (the NetCDF arrays) and
`file_path * ".sqlite"` (the metadata). No HDF5 is produced.
"""
function serialize(store::RustTimeSeriesStore, file_path::AbstractString)
    isnothing(store.path) && error(
        "cannot serialize an in-memory RustTimeSeriesStore; create the System " *
        "with time_series_in_memory=false")
    flush!(store)
    cp(store.path, file_path; force = true)
    cp(store.path * ".sqlite", file_path * ".sqlite"; force = true)
    @info "Serialized Rust time series store to $file_path (+ .sqlite)"
    return
end

"""Remove all time series (data + metadata) from the store."""
clear_time_series!(store::RustTimeSeriesStore) = TSS.clear!(store.inner)

# ---- TimeSeriesManager routing (SingleTimeSeries only) ---------------------

"""
Route a manager-level `add_time_series!` to the Rust store. Only SingleTimeSeries
is supported; data identity is the array content hash (no `time_series_uuid`).
"""
function _rust_add_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    if time_series isa Forecast
        return _rust_add_forecast!(mgr, owner, time_series; features...)
    end
    time_series isa SingleTimeSeries ||
        error("Rust backend supports SingleTimeSeries, Deterministic, " *
              "DeterministicSingleTimeSeries, and Probabilistic (got $(typeof(time_series)))")
    store = mgr.data_store::RustTimeSeriesStore
    owner_uuid, owner_type, owner_category = _rust_owner_args(owner)
    name = get_name(time_series)
    resolution = get_resolution(time_series)
    feats = _rust_features(features)

    if has_time_series(store, owner_uuid, name; resolution = resolution, features = feats)
        throw(ArgumentError(
            "Time series data with duplicate attributes are already stored: " *
            "$(owner_type)/$(name) resolution=$(resolution) features=$(feats)"))
    end

    isnothing(get_scaling_factor_multiplier(time_series)) ||
        error("scaling_factor_multiplier is not yet supported on the Rust backend")

    serialize_single!(store, owner_uuid, owner_type, owner_category, name, time_series;
        features = feats)
    return StaticTimeSeriesKey(;
        time_series_type = SingleTimeSeries,
        name = name,
        initial_timestamp = get_initial_timestamp(time_series),
        resolution = resolution,
        length = length(time_series),
        features = Dict{String, Any}(feats),
    )
end

"""
Route a public `get_time_series(SingleTimeSeries, owner, name; ...)` to the Rust
store, honoring `start_time` / `len` slicing on the time axis.
"""
function _rust_get_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    if T <: Forecast
        return _rust_get_forecast(owner, name; resolution = resolution, features...)
    end
    T <: SingleTimeSeries ||
        error("Rust backend supports SingleTimeSeries, Deterministic, " *
              "DeterministicSingleTimeSeries, and Probabilistic (requested $T)")
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::RustTimeSeriesStore
    owner_uuid, _, _ = _rust_owner_args(owner)
    feats = _rust_features(features)
    meta = get_metadata(store, owner_uuid, name; resolution = resolution, features = feats)
    full = get_array_by_hash(store, meta.data_hash)

    start = isnothing(start_time) ? meta.initial_timestamp : start_time
    index = compute_time_array_index(meta.initial_timestamp, start, meta.resolution)
    n = isnothing(len) ? (meta.length - index + 1) : len
    if index < 1 || index + n - 1 > meta.length
        throw(ArgumentError("requested index=$index len=$n exceeds range $(meta.length)"))
    end
    vals = full[index:(index + n - 1)]
    t0 = meta.initial_timestamp + meta.resolution * (index - 1)
    timestamps = range(t0; length = n, step = meta.resolution)
    return SingleTimeSeries(;
        name = String(name),
        data = TimeSeries.TimeArray(collect(timestamps), vals),
        resolution = meta.resolution,
    )
end

# ---- Forecasts (Deterministic / DeterministicSingleTimeSeries) -------------

const RTS_TYPE_DETERMINISTIC = TSS.TS_TYPE_DETERMINISTIC
const RTS_TYPE_DETERMINISTIC_SINGLE = TSS.TS_TYPE_DETERMINISTIC_SINGLE
const RTS_TYPE_PROBABILISTIC = TSS.TS_TYPE_PROBABILISTIC
const RTS_TYPE_SCENARIOS = TSS.TS_TYPE_SCENARIOS

function add_probabilistic!(
    store::RustTimeSeriesStore, owner_uuid::AbstractString, owner_type::AbstractString,
    owner_category::AbstractString, name::AbstractString, initial_timestamp::Dates.DateTime,
    resolution::Dates.Period, horizon::Dates.Period, interval::Dates.Period, count::Integer,
    percentiles::Vector{Float64}, flat_values::Vector{Float64};
    features = Dict{String, Any}(), units::Union{Nothing, AbstractString} = nothing,
    scaling_factor_multiplier::Union{Nothing, AbstractString} = nothing,
)
    TSS.add_probabilistic!(store.inner, owner_uuid, owner_type, _tss_category(owner_category),
        name, initial_timestamp, resolution, horizon, interval, count, percentiles, flat_values;
        features = features, units = units, scaling_factor_multiplier = scaling_factor_multiplier)
    return
end

get_probabilistic_metadata(store::RustTimeSeriesStore, owner_uuid::AbstractString,
    name::AbstractString; resolution::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}()) =
    TSS.get_probabilistic_metadata(store.inner, owner_uuid, name;
        resolution = resolution, features = features)

function add_forecast!(
    store::RustTimeSeriesStore, owner_uuid::AbstractString, owner_type::AbstractString,
    owner_category::AbstractString, name::AbstractString, ts_type::Integer,
    initial_timestamp::Dates.DateTime, resolution::Dates.Period, horizon::Dates.Period,
    interval::Dates.Period, count::Integer, flat_values::Vector{Float64};
    features = Dict{String, Any}(), units::Union{Nothing, AbstractString} = nothing,
    scaling_factor_multiplier::Union{Nothing, AbstractString} = nothing,
)
    TSS.add_forecast!(store.inner, owner_uuid, owner_type, _tss_category(owner_category),
        name, ts_type, initial_timestamp, resolution, horizon, interval, count, flat_values;
        features = features, units = units, scaling_factor_multiplier = scaling_factor_multiplier)
    return
end

get_forecast_metadata(store::RustTimeSeriesStore, owner_uuid::AbstractString,
    name::AbstractString, ts_type::Integer; resolution::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}()) =
    TSS.get_forecast_metadata(store.inner, owner_uuid, name, ts_type;
        resolution = resolution, features = features)

has_typed(store::RustTimeSeriesStore, owner_uuid::AbstractString, name::AbstractString,
    ts_type::Integer; resolution::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}()) =
    TSS.has_typed(store.inner, owner_uuid, name, ts_type;
        resolution = resolution, features = features)

remove_typed!(store::RustTimeSeriesStore, owner_uuid::AbstractString, name::AbstractString,
    ts_type::Integer; resolution::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}()) =
    TSS.remove_typed!(store.inner, owner_uuid, name, ts_type;
        resolution = resolution, features = features)

# Flatten a Deterministic's SortedDict windows column-major: [w1; w2; ...].
function _flatten_deterministic(ts::Deterministic)
    windows = collect(values(get_data(ts)))
    return (Float64.(reduce(vcat, windows)), length(first(windows)), length(windows))
end

"""Add a Deterministic or DeterministicSingleTimeSeries via the Rust store."""
function _rust_add_forecast!(mgr::TimeSeriesManager, owner, ts; features...)
    store = mgr.data_store::RustTimeSeriesStore
    owner_uuid, owner_type, owner_category = _rust_owner_args(owner)
    name = get_name(ts)
    resolution = get_resolution(ts)
    interval = get_interval(ts)
    feats = _rust_features(features)
    isnothing(get_scaling_factor_multiplier(ts)) ||
        error("scaling_factor_multiplier is not yet supported on the Rust backend")

    if ts isa Probabilistic
        if has_typed(store, owner_uuid, name, RTS_TYPE_PROBABILISTIC;
            resolution = resolution, features = feats)
            throw(ArgumentError("Time series data with duplicate attributes are already stored"))
        end
        flat = vec(Float64.(get_array_for_hdf(ts)))
        add_probabilistic!(store, owner_uuid, owner_type, owner_category, name,
            get_initial_timestamp(ts), resolution, get_horizon(ts), interval,
            get_count(ts), Float64.(get_percentiles(ts)), flat; features = feats)
        return ForecastKey(;
            time_series_type = typeof(ts), name = name,
            initial_timestamp = get_initial_timestamp(ts), resolution = resolution,
            horizon = get_horizon(ts), interval = interval, count = get_count(ts),
            features = Dict{String, Any}(feats))
    elseif ts isa Deterministic
        flat, _, count = _flatten_deterministic(ts)
        ts_type = RTS_TYPE_DETERMINISTIC
    elseif ts isa DeterministicSingleTimeSeries
        flat = Float64.(TimeSeries.values(get_data(get_single_time_series(ts))))
        count = get_count(ts)
        ts_type = RTS_TYPE_DETERMINISTIC_SINGLE
    elseif ts isa Scenarios
        flat = vec(Float64.(get_array_for_hdf(ts)))  # (scenario_count, horizon_count, count)
        count = get_count(ts)
        ts_type = RTS_TYPE_SCENARIOS
    else
        error("unsupported forecast type $(typeof(ts))")
    end

    if has_typed(store, owner_uuid, name, ts_type; resolution = resolution, features = feats)
        throw(ArgumentError("Time series data with duplicate attributes are already stored"))
    end
    add_forecast!(store, owner_uuid, owner_type, owner_category, name, ts_type,
        get_initial_timestamp(ts), resolution, get_horizon(ts), interval, count, flat;
        features = feats)
    return ForecastKey(;
        time_series_type = typeof(ts), name = name,
        initial_timestamp = get_initial_timestamp(ts), resolution = resolution,
        horizon = get_horizon(ts), interval = interval, count = count,
        features = Dict{String, Any}(feats))
end

"""Reconstruct a forecast from the Rust store (matches the STORED type)."""
function _rust_get_forecast(
    owner, name; resolution::Union{Nothing, Dates.Period} = nothing, features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::RustTimeSeriesStore
    owner_uuid, _, _ = _rust_owner_args(owner)
    feats = _rust_features(features)

    if has_typed(store, owner_uuid, name, RTS_TYPE_PROBABILISTIC;
        resolution = resolution, features = feats)
        m = get_probabilistic_metadata(store, owner_uuid, name;
            resolution = resolution, features = feats)
        flat = get_array_by_hash(store, m.data_hash)
        percentile_count = length(m.percentiles)
        horizon_count = div(m.length, percentile_count * m.count)
        arr = reshape(flat, percentile_count, horizon_count, m.count)
        data = SortedDict{Dates.DateTime, Matrix{Float64}}()
        for i in 1:(m.count)
            data[m.initial_timestamp + m.interval * (i - 1)] = permutedims(arr[:, :, i])
        end
        return Probabilistic(; name = String(name), data = data,
            percentiles = m.percentiles, resolution = m.resolution, interval = m.interval)
    elseif has_typed(store, owner_uuid, name, RTS_TYPE_DETERMINISTIC;
        resolution = resolution, features = feats)
        m = get_forecast_metadata(store, owner_uuid, name, RTS_TYPE_DETERMINISTIC;
            resolution = resolution, features = feats)
        flat = get_array_by_hash(store, m.data_hash)
        horizon_count = div(m.length, m.count)
        mat = reshape(flat, horizon_count, m.count)
        data = SortedDict{Dates.DateTime, Vector{Float64}}()
        for i in 1:(m.count)
            data[m.initial_timestamp + m.interval * (i - 1)] = mat[:, i]
        end
        return Deterministic(; name = String(name), data = data,
            resolution = m.resolution, interval = m.interval)
    elseif has_typed(store, owner_uuid, name, RTS_TYPE_DETERMINISTIC_SINGLE;
        resolution = resolution, features = feats)
        m = get_forecast_metadata(store, owner_uuid, name, RTS_TYPE_DETERMINISTIC_SINGLE;
            resolution = resolution, features = feats)
        arr = get_array_by_hash(store, m.data_hash)
        timestamps = range(m.initial_timestamp; length = length(arr), step = m.resolution)
        sts = SingleTimeSeries(; name = String(name),
            data = TimeSeries.TimeArray(collect(timestamps), arr), resolution = m.resolution)
        return DeterministicSingleTimeSeries(; single_time_series = sts,
            initial_timestamp = m.initial_timestamp, interval = m.interval,
            count = m.count, horizon = m.horizon)
    elseif has_typed(store, owner_uuid, name, RTS_TYPE_SCENARIOS;
        resolution = resolution, features = feats)
        m = get_forecast_metadata(store, owner_uuid, name, RTS_TYPE_SCENARIOS;
            resolution = resolution, features = feats)
        flat = get_array_by_hash(store, m.data_hash)
        horizon_count = Int(div(m.horizon, m.resolution))
        scenario_count = div(m.length, horizon_count * m.count)
        arr = reshape(flat, scenario_count, horizon_count, m.count)
        data = SortedDict{Dates.DateTime, Matrix{Float64}}()
        for i in 1:(m.count)
            data[m.initial_timestamp + m.interval * (i - 1)] = permutedims(arr[:, :, i])
        end
        return Scenarios(; name = String(name), data = data, scenario_count = scenario_count,
            resolution = m.resolution, interval = m.interval)
    end
    throw(RustTimeSeriesNotFound("no forecast for owner=$owner_uuid name=$name"))
end

"""Route `has_time_series(owner, T, name; ...)` to the Rust store."""
function _rust_has_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::RustTimeSeriesStore
    owner_uuid, _, _ = _rust_owner_args(owner)
    feats = _rust_features(features)
    if T <: SingleTimeSeries
        return has_time_series(store, owner_uuid, name; resolution = resolution, features = feats)
    elseif T <: AbstractDeterministic
        return has_typed(store, owner_uuid, name, RTS_TYPE_DETERMINISTIC;
            resolution = resolution, features = feats) ||
               has_typed(store, owner_uuid, name, RTS_TYPE_DETERMINISTIC_SINGLE;
            resolution = resolution, features = feats)
    elseif T <: Probabilistic
        return has_typed(store, owner_uuid, name, RTS_TYPE_PROBABILISTIC;
            resolution = resolution, features = feats)
    elseif T <: Scenarios
        return has_typed(store, owner_uuid, name, RTS_TYPE_SCENARIOS;
            resolution = resolution, features = feats)
    elseif T <: Forecast
        # generic forecast query: match any stored forecast type
        return any(tt -> has_typed(store, owner_uuid, name, tt;
                resolution = resolution, features = feats),
            (RTS_TYPE_DETERMINISTIC, RTS_TYPE_DETERMINISTIC_SINGLE,
                RTS_TYPE_PROBABILISTIC, RTS_TYPE_SCENARIOS))
    end
    return false
end
