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

# ---- Element encoding ------------------------------------------------------
# Scalars store as a 1-D array tagged with their type name. Fixed-size
# FunctionData tuples store as a `(length, k)` Float64 array; reconstruction keys
# on the `logical_type` tag returned by `get_metadata`.

_storage_array(v::AbstractVector{<:Real}) = (collect(v), string(eltype(v)))

function _storage_array(v::AbstractVector{LinearFunctionData})
    mat = Matrix{Float64}(undef, length(v), 2)
    for (i, fd) in enumerate(v)
        mat[i, 1] = get_proportional_term(fd)
        mat[i, 2] = get_constant_term(fd)
    end
    return (mat, "LinearFunctionData")
end

function _storage_array(v::AbstractVector{QuadraticFunctionData})
    mat = Matrix{Float64}(undef, length(v), 3)
    for (i, fd) in enumerate(v)
        mat[i, 1] = get_quadratic_term(fd)
        mat[i, 2] = get_proportional_term(fd)
        mat[i, 3] = get_constant_term(fd)
    end
    return (mat, "QuadraticFunctionData")
end

# Ragged: each step has a variable number of (x, y) points. Store as a
# `(len, 1 + 2*max_points)` matrix padded with zeros; column 1 of each row is the
# point count, so `shape[0]` stays the timestep count.
function _storage_array(v::AbstractVector{PiecewiseLinearData})
    len = length(v)
    max_n = maximum(length(get_points(fd)) for fd in v; init = 0)
    mat = zeros(Float64, len, 1 + 2 * max_n)
    for (i, fd) in enumerate(v)
        pts = get_points(fd)
        mat[i, 1] = length(pts)
        for (j, p) in enumerate(pts)
            mat[i, 2j] = p.x
            mat[i, 2j + 1] = p.y
        end
    end
    return (mat, "PiecewiseLinearData")
end

_storage_array(v::AbstractVector) =
    error("Rust backend does not support time series element type $(eltype(v)) yet")

# Reconstruct the full value vector from the stored array, keyed on logical_type.
function _read_values(
    store::RustTimeSeriesStore,
    hash::Vector{UInt8},
    logical_type,
    dtype,
    len::Integer,
)
    if logical_type == "LinearFunctionData"
        mat = TSS.get_array_nd(store.inner, hash, Float64, (len, 2))
        return [LinearFunctionData(mat[i, 1], mat[i, 2]) for i in 1:len]
    elseif logical_type == "QuadraticFunctionData"
        mat = TSS.get_array_nd(store.inner, hash, Float64, (len, 3))
        return [QuadraticFunctionData(mat[i, 1], mat[i, 2], mat[i, 3]) for i in 1:len]
    elseif logical_type == "PiecewiseLinearData"
        flat = get_array_by_hash(store, hash, Float64)
        k = div(length(flat), len)  # 1 + 2*max_points (derived from the array size)
        mat = TSS.get_array_nd(store.inner, hash, Float64, (len, k))
        out = Vector{PiecewiseLinearData}(undef, len)
        for i in 1:len
            n = Int(round(mat[i, 1]))
            out[i] = PiecewiseLinearData([(mat[i, 2j], mat[i, 2j + 1]) for j in 1:n])
        end
        return out
    else
        return get_array_by_hash(store, hash, dtype)  # scalar
    end
end

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
    # Encode the values: scalars stay 1-D; FunctionData becomes a (length, k)
    # Float64 matrix. The logical-type tag drives reconstruction on read.
    arr, logical = _storage_array(TimeSeries.values(get_data(sts)))
    # `name` and `scaling_factor_multiplier` are carried on the binding struct
    # (matching the InfrastructureSystems.jl object shape), not on add_time_series!.
    tss_ts = TSS.SingleTimeSeries(
        get_initial_timestamp(sts),
        get_resolution(sts),
        arr,
        name;
        scaling_factor_multiplier = scaling_factor_multiplier,
        logical_type = logical,
    )
    TSS.add_time_series!(store.inner, owner_uuid, owner_type, _tss_category(owner_category),
        tss_ts; features = features, units = units)
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

get_array_by_hash(store::RustTimeSeriesStore, data_hash::Vector{UInt8}, ::Type{T} = Float64) where {T} =
    TSS.get_array_by_hash(store.inner, data_hash, T)

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
    values = _read_values(store, meta.data_hash, meta.logical_type, meta.dtype, meta.length)
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

# The store handle / file path differ across a serialize→deserialize round-trip,
# so compare structurally by counts. Element-level equality is covered by the
# Rust integration tests (`test/rust/rust_system_integration.jl`).
function compare_values(
    match_fn::Union{Function, Nothing},
    x::RustTimeSeriesStore,
    y::RustTimeSeriesStore;
    kwargs...,
)
    return get_counts(x) == get_counts(y)
end

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
    full = _read_values(store, meta.data_hash, meta.logical_type, meta.dtype, meta.length)

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
    percentiles::Vector{Float64}, data::AbstractArray;
    features = Dict{String, Any}(), units::Union{Nothing, AbstractString} = nothing,
    scaling_factor_multiplier::Union{Nothing, AbstractString} = nothing,
)
    prob = TSS.Probabilistic(initial_timestamp, resolution, horizon, interval, count,
        percentiles, data, name; scaling_factor_multiplier = scaling_factor_multiplier)
    TSS.add_time_series!(store.inner, owner_uuid, owner_type, _tss_category(owner_category),
        prob; features = features, units = units)
    return
end

"""
Add a dense `Deterministic` (`ts_type = 2`) or `Scenarios` (`ts_type = 5`) forecast
by building the matching `TimeSeriesStore` struct and routing through the generic
`add_time_series!`. `DeterministicSingleTimeSeries` is not added here — it is
derived from a stored `SingleTimeSeries` via `transform_single_time_series!`.
"""
function add_forecast!(
    store::RustTimeSeriesStore, owner_uuid::AbstractString, owner_type::AbstractString,
    owner_category::AbstractString, name::AbstractString, ts_type::Integer,
    initial_timestamp::Dates.DateTime, resolution::Dates.Period, horizon::Dates.Period,
    interval::Dates.Period, count::Integer, data::AbstractArray;
    features = Dict{String, Any}(), units::Union{Nothing, AbstractString} = nothing,
    scaling_factor_multiplier::Union{Nothing, AbstractString} = nothing,
)
    tss_ts = if ts_type == RTS_TYPE_DETERMINISTIC
        TSS.Deterministic(initial_timestamp, resolution, horizon, interval, count, data, name;
            scaling_factor_multiplier = scaling_factor_multiplier)
    elseif ts_type == RTS_TYPE_SCENARIOS
        TSS.Scenarios(initial_timestamp, resolution, horizon, interval, count, data, name;
            scaling_factor_multiplier = scaling_factor_multiplier)
    else
        error("add_forecast! supports Deterministic ($RTS_TYPE_DETERMINISTIC) and " *
              "Scenarios ($RTS_TYPE_SCENARIOS); got ts_type=$ts_type")
    end
    TSS.add_time_series!(store.inner, owner_uuid, owner_type, _tss_category(owner_category),
        tss_ts; features = features, units = units)
    return
end

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
        arr = Float64.(get_array_for_hdf(ts))  # (percentile_count, horizon_count, count)
        add_probabilistic!(store, owner_uuid, owner_type, owner_category, name,
            get_initial_timestamp(ts), resolution, get_horizon(ts), interval,
            get_count(ts), Float64.(get_percentiles(ts)), arr; features = feats)
        return ForecastKey(;
            time_series_type = typeof(ts), name = name,
            initial_timestamp = get_initial_timestamp(ts), resolution = resolution,
            horizon = get_horizon(ts), interval = interval, count = get_count(ts),
            features = Dict{String, Any}(feats))
    elseif ts isa Deterministic
        windows = collect(values(get_data(ts)))
        arr = Float64.(reduce(hcat, windows))  # (horizon_count, count)
        count = length(windows)
        ts_type = RTS_TYPE_DETERMINISTIC
    elseif ts isa DeterministicSingleTimeSeries
        if has_typed(store, owner_uuid, name, RTS_TYPE_DETERMINISTIC_SINGLE;
            resolution = resolution, features = feats)
            throw(ArgumentError("Time series data with duplicate attributes are already stored"))
        end
        # The Rust store derives a DeterministicSingleTimeSeries from a stored
        # SingleTimeSeries (sharing the array) via transform_single_time_series!,
        # rather than persisting a separate forecast array. Ensure the underlying
        # series is present, then derive the DST.
        underlying = get_single_time_series(ts)
        has_time_series(store, owner_uuid, name; resolution = resolution, features = feats) ||
            serialize_single!(store, owner_uuid, owner_type, owner_category, name, underlying;
                features = feats)
        TSS.transform_single_time_series!(store.inner, get_horizon(ts), interval)
        return ForecastKey(;
            time_series_type = typeof(ts), name = name,
            initial_timestamp = get_initial_timestamp(ts), resolution = resolution,
            horizon = get_horizon(ts), interval = interval, count = get_count(ts),
            features = Dict{String, Any}(feats))
    elseif ts isa Scenarios
        arr = Float64.(get_array_for_hdf(ts))  # (scenario_count, horizon_count, count)
        count = get_count(ts)
        ts_type = RTS_TYPE_SCENARIOS
    else
        error("unsupported forecast type $(typeof(ts))")
    end

    if has_typed(store, owner_uuid, name, ts_type; resolution = resolution, features = feats)
        throw(ArgumentError("Time series data with duplicate attributes are already stored"))
    end
    add_forecast!(store, owner_uuid, owner_type, owner_category, name, ts_type,
        get_initial_timestamp(ts), resolution, get_horizon(ts), interval, count, arr;
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
        # `.data` is the canonical (percentile_count, horizon_count, count) array.
        p = TSS.get_time_series(TSS.Probabilistic, store.inner, owner_uuid, name;
            resolution = resolution, features = feats)
        data = SortedDict{Dates.DateTime, Matrix{Float64}}()
        for i in 1:(p.count)
            data[p.initial_timestamp + p.interval * (i - 1)] = permutedims(p.data[:, :, i])
        end
        return Probabilistic(; name = String(name), data = data,
            percentiles = p.percentiles, resolution = p.resolution, interval = p.interval)
    elseif has_typed(store, owner_uuid, name, RTS_TYPE_DETERMINISTIC;
        resolution = resolution, features = feats)
        # `.data` is the canonical (horizon_count, count) array.
        d = TSS.get_time_series(TSS.Deterministic, store.inner, owner_uuid, name;
            resolution = resolution, features = feats)
        data = SortedDict{Dates.DateTime, Vector{Float64}}()
        for i in 1:(d.count)
            data[d.initial_timestamp + d.interval * (i - 1)] = d.data[:, i]
        end
        return Deterministic(; name = String(name), data = data,
            resolution = d.resolution, interval = d.interval)
    elseif has_typed(store, owner_uuid, name, RTS_TYPE_DETERMINISTIC_SINGLE;
        resolution = resolution, features = feats)
        # A DST shares the underlying SingleTimeSeries array; rebuild that series
        # and wrap it with the DST windowing parameters (read as a Deterministic).
        d = TSS.get_time_series(TSS.DeterministicSingleTimeSeries, store.inner, owner_uuid, name;
            resolution = resolution, features = feats)
        sts = get_single(store, owner_uuid, name; resolution = resolution, features = feats)
        return DeterministicSingleTimeSeries(; single_time_series = sts,
            initial_timestamp = d.initial_timestamp, interval = d.interval,
            count = d.count, horizon = d.horizon)
    elseif has_typed(store, owner_uuid, name, RTS_TYPE_SCENARIOS;
        resolution = resolution, features = feats)
        # `.data` is the canonical (scenario_count, horizon_count, count) array.
        s = TSS.get_time_series(TSS.Scenarios, store.inner, owner_uuid, name;
            resolution = resolution, features = feats)
        data = SortedDict{Dates.DateTime, Matrix{Float64}}()
        for i in 1:(s.count)
            data[s.initial_timestamp + s.interval * (i - 1)] = permutedims(s.data[:, :, i])
        end
        return Scenarios(; name = String(name), data = data, scenario_count = s.scenario_count,
            resolution = s.resolution, interval = s.interval)
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

# Name-less existence queries. `_rust_query_codes(T)` maps a query type to the
# stored TimeSeriesType codes to match (empty tuple = any type).
_rust_query_codes(::Type{<:SingleTimeSeries}) = (TSS.TS_TYPE_SINGLE,)
_rust_query_codes(::Type{<:DeterministicSingleTimeSeries}) = (RTS_TYPE_DETERMINISTIC_SINGLE,)
_rust_query_codes(::Type{<:AbstractDeterministic}) =
    (RTS_TYPE_DETERMINISTIC, RTS_TYPE_DETERMINISTIC_SINGLE)
_rust_query_codes(::Type{<:Probabilistic}) = (RTS_TYPE_PROBABILISTIC,)
_rust_query_codes(::Type{<:Scenarios}) = (RTS_TYPE_SCENARIOS,)
_rust_query_codes(::Type{<:Forecast}) = (RTS_TYPE_DETERMINISTIC,
    RTS_TYPE_DETERMINISTIC_SINGLE, RTS_TYPE_PROBABILISTIC, RTS_TYPE_SCENARIOS)
_rust_query_codes(::Type{<:TimeSeriesData}) = ()

# True iff `owner` has any time series, optionally restricted to type `T`.
function _rust_has_any(owner; time_series_type::Union{Nothing, Type} = nothing)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::RustTimeSeriesStore
    owner_uuid, _, _ = _rust_owner_args(owner)
    codes = time_series_type === nothing ? () : _rust_query_codes(time_series_type)
    isempty(codes) && return TSS.has_for_owner(store.inner, owner_uuid)
    return any(c -> TSS.has_for_owner(store.inner, owner_uuid; time_series_type = c), codes)
end
