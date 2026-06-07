# Rust-backed time series storage (proof-of-concept).
#
# `RustTimeSeriesStore` delegates BOTH array data and metadata to the external
# `time-series-store` Rust engine through its C ABI. Unlike the legacy split
# between `Hdf5TimeSeriesStorage` (arrays) and `TimeSeriesMetadataStore`
# (SQLite), the Rust store owns both: arrays land in a NetCDF4 `.nc` file
# (content-addressed by SHA-256 hash) and metadata in a sibling `.sqlite` file.
#
# Time series *data* identity is the array content hash, NOT a UUID. Persisting
# a system writes the `.nc` + `.sqlite` pair directly; the metadata SQLite is
# never embedded in an HDF5 file.
#
# The cdylib is located via the `TIME_SERIES_STORE_LIB` environment variable.
# This module deliberately avoids the registered `TimeSeries` package name and
# makes raw `ccall`s so it has no dependency on the standalone `TimeSeries.jl`
# binding.

# ---- cdylib resolution ----------------------------------------------------

const _RUST_TS_LIB = Ref{String}("")

function rust_ts_lib_path()
    if !isempty(_RUST_TS_LIB[])
        return _RUST_TS_LIB[]
    end
    p = get(ENV, "TIME_SERIES_STORE_LIB", "")
    isempty(p) && error(
        "TIME_SERIES_STORE_LIB env var must point to " *
        "libtime_series_store_ffi.{dylib,so,dll}",
    )
    _RUST_TS_LIB[] = p
    return p
end

# ---- Status codes (must match crates/time-series-store-ffi/src/lib.rs) -----

const RTS_OK = Int32(0)
const RTS_ERR_NOT_FOUND = Int32(4)

struct RustTimeSeriesNotFound <: Exception
    msg::String
end

function _rts_last_error_message()
    needed = Ref{UInt64}(0)
    ccall((:ts_last_error_message, rust_ts_lib_path()), Int32,
        (Ptr{UInt8}, UInt64, Ptr{UInt64}), C_NULL, UInt64(0), needed)
    n = Int(needed[])
    n == 0 && return ""
    buf = Vector{UInt8}(undef, n + 1)
    ccall((:ts_last_error_message, rust_ts_lib_path()), Int32,
        (Ptr{UInt8}, UInt64, Ptr{UInt64}), buf, UInt64(n + 1), C_NULL)
    return String(buf[1:n])
end

function _rts_check(code::Int32)
    code == RTS_OK && return
    msg = _rts_last_error_message()
    if code == RTS_ERR_NOT_FOUND
        throw(RustTimeSeriesNotFound(msg))
    end
    error("time-series-store error ($code): $msg")
end

# ---- Store -----------------------------------------------------------------

mutable struct RustTimeSeriesStore <: TimeSeriesStorage
    handle::Ptr{Cvoid}
    "Filesystem base path for the `.nc` / `.sqlite` pair (nothing if in-memory)."
    path::Union{Nothing, String}

    function RustTimeSeriesStore(handle::Ptr{Cvoid}, path)
        s = new(handle, path)
        finalizer(close!, s)
        return s
    end
end

"""
    RustTimeSeriesStore(; in_memory=false, path=nothing)

Create a Rust-backed time series store. When `in_memory=false`, `path` is the
base path for the on-disk artifacts (`<path>.nc` and `<path>.sqlite`).
"""
function RustTimeSeriesStore(; in_memory::Bool = false, path = nothing)
    out = Ref{Ptr{Cvoid}}(C_NULL)
    cpath = path === nothing ? C_NULL : String(path)
    code = ccall((:ts_store_create, rust_ts_lib_path()), Int32,
        (Cstring, Bool, Ref{Ptr{Cvoid}}), cpath, in_memory, out)
    _rts_check(code)
    return RustTimeSeriesStore(out[], path === nothing ? nothing : String(path))
end

"""
    open_rust_store(path; read_only=false)

Open an existing on-disk Rust store from its `.nc` base path.
"""
function open_rust_store(path::AbstractString; read_only::Bool = false)
    out = Ref{Ptr{Cvoid}}(C_NULL)
    code = ccall((:ts_store_open, rust_ts_lib_path()), Int32,
        (Cstring, Bool, Ref{Ptr{Cvoid}}), String(path), read_only, out)
    _rts_check(code)
    return RustTimeSeriesStore(out[], String(path))
end

function close!(store::RustTimeSeriesStore)
    if store.handle != C_NULL
        ccall((:ts_store_free, rust_ts_lib_path()), Cvoid, (Ptr{Cvoid},), store.handle)
        store.handle = C_NULL
    end
    return
end

# ---- Conversions -----------------------------------------------------------

function _rts_to_unix_ns(dt::Dates.DateTime)
    ms = Int64(Dates.datetime2unix(dt) * 1000)
    return ms * 1_000_000
end

function _rts_from_unix_ns(ns::Int64)
    ms_total = div(ns, 1_000_000)
    return Dates.unix2datetime(ms_total / 1000)
end

_rts_resolution_to_ns(p::Dates.Period) = Dates.toms(p) * 1_000_000

_rts_owner_category_int(category::AbstractString) =
    category == "Component" ? Int32(0) :
    category == "SupplementalAttribute" ? Int32(1) :
    error("unknown owner category $category")

# Returns a String (held by the caller's local, so it stays GC-rooted across the
# ccall) or C_NULL. The Rust side treats null / empty / whitespace as no features.
_rts_features_json(features) = isempty(features) ? C_NULL : JSON3.write(features)

# ---- Operations ------------------------------------------------------------

"""
    serialize_single!(store, owner_uuid, owner_type, owner_category, name, sts;
                      features=Dict(), units=nothing, scaling_factor_multiplier=nothing)

Add a `SingleTimeSeries` (data + metadata) to the Rust store. `owner_uuid` is
the stringified UUID of the owning component / supplemental attribute. The array
is content-addressed; identical arrays are de-duplicated automatically.
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
    initial_ns = _rts_to_unix_ns(get_initial_timestamp(sts))
    resolution_ns = _rts_resolution_to_ns(get_resolution(sts))
    data = Vector{Float64}(TimeSeries.values(get_data(sts)))
    features_json = _rts_features_json(features)
    units_ptr = units === nothing ? C_NULL : String(units)
    scaling_ptr = scaling_factor_multiplier === nothing ? C_NULL :
                  String(scaling_factor_multiplier)

    out_key = Ref{Ptr{Cvoid}}(C_NULL)
    code = ccall((:ts_store_add_single, rust_ts_lib_path()), Int32,
        (Ptr{Cvoid}, Cstring, Cstring, Int32, Cstring, Int64, Int64,
            Ptr{Float64}, UInt64, Cstring, Cstring, Cstring, Ref{Ptr{Cvoid}}),
        store.handle, owner_uuid, owner_type,
        _rts_owner_category_int(owner_category), name,
        initial_ns, resolution_ns, data, UInt64(length(data)),
        features_json, units_ptr, scaling_ptr, out_key)
    _rts_check(code)
    # We don't retain the opaque key handle; attribute-based lookups are used.
    if out_key[] != C_NULL
        ccall((:ts_key_free, rust_ts_lib_path()), Cvoid, (Ptr{Cvoid},), out_key[])
    end
    return
end

"""
    get_metadata(store, owner_uuid, name; resolution, features=Dict())

Return `(; initial_timestamp, resolution, length, data_hash)` for a stored
SingleTimeSeries. `data_hash` is the 32-byte content hash. Throws
`RustTimeSeriesNotFound` if absent.
"""
function get_metadata(
    store::RustTimeSeriesStore,
    owner_uuid::AbstractString,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}(),
)
    resolution_ns = resolution === nothing ? Int64(0) : _rts_resolution_to_ns(resolution)
    features_json = _rts_features_json(features)
    out_initial = Ref{Int64}(0)
    out_resolution = Ref{Int64}(0)
    out_length = Ref{UInt64}(0)
    out_hash = Vector{UInt8}(undef, 32)
    code = ccall((:ts_store_get_metadata, rust_ts_lib_path()), Int32,
        (Ptr{Cvoid}, Cstring, Cstring, Int64, Cstring,
            Ref{Int64}, Ref{Int64}, Ref{UInt64}, Ptr{UInt8}),
        store.handle, owner_uuid, name, resolution_ns, features_json,
        out_initial, out_resolution, out_length, out_hash)
    _rts_check(code)
    res_ms = div(out_resolution[], 1_000_000)
    return (
        initial_timestamp = _rts_from_unix_ns(out_initial[]),
        resolution = Dates.Millisecond(res_ms),
        length = Int(out_length[]),
        data_hash = out_hash,
    )
end

"""
    get_array_by_hash(store, data_hash) -> Vector{Float64}
"""
function get_array_by_hash(store::RustTimeSeriesStore, data_hash::Vector{UInt8})
    length(data_hash) == 32 || error("data_hash must be 32 bytes")
    out_data = Ref{Ptr{Float64}}(C_NULL)
    out_len = Ref{UInt64}(0)
    code = ccall((:ts_store_get_array_by_hash, rust_ts_lib_path()), Int32,
        (Ptr{Cvoid}, Ptr{UInt8}, Ref{Ptr{Float64}}, Ref{UInt64}),
        store.handle, data_hash, out_data, out_len)
    _rts_check(code)
    n = Int(out_len[])
    raw = unsafe_wrap(Array, out_data[], n; own = false)
    result = copy(raw)
    ccall((:ts_buffer_free_f64, rust_ts_lib_path()), Cvoid,
        (Ptr{Float64}, UInt64), out_data[], out_len[])
    return result
end

"""
    get_single(store, owner_uuid, name; resolution, features=Dict()) -> SingleTimeSeries

Reconstruct a `SingleTimeSeries` (metadata + array) from the Rust store. The
timestamps are regenerated from `initial_timestamp + resolution*(i-1)`.
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

function has_time_series(
    store::RustTimeSeriesStore,
    owner_uuid::AbstractString,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}(),
)
    resolution_ns = resolution === nothing ? Int64(0) : _rts_resolution_to_ns(resolution)
    features_json = _rts_features_json(features)
    out = Ref{Bool}(false)
    code = ccall((:ts_store_has_by_attrs, rust_ts_lib_path()), Int32,
        (Ptr{Cvoid}, Cstring, Cstring, Int64, Cstring, Ref{Bool}),
        store.handle, owner_uuid, name, resolution_ns, features_json, out)
    _rts_check(code)
    return out[]
end

function remove_single!(
    store::RustTimeSeriesStore,
    owner_uuid::AbstractString,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}(),
)
    resolution_ns = resolution === nothing ? Int64(0) : _rts_resolution_to_ns(resolution)
    features_json = _rts_features_json(features)
    code = ccall((:ts_store_remove_by_attrs, rust_ts_lib_path()), Int32,
        (Ptr{Cvoid}, Cstring, Cstring, Int64, Cstring),
        store.handle, owner_uuid, name, resolution_ns, features_json)
    _rts_check(code)
    return
end

function get_counts(store::RustTimeSeriesStore)
    a = Ref{Int64}(0)
    b = Ref{Int64}(0)
    c = Ref{Int64}(0)
    code = ccall((:ts_store_counts, rust_ts_lib_path()), Int32,
        (Ptr{Cvoid}, Ref{Int64}, Ref{Int64}, Ref{Int64}), store.handle, a, b, c)
    _rts_check(code)
    return (
        components_with_time_series = a[],
        static_time_series = b[],
        forecasts = c[],
    )
end

function get_num_time_series(store::RustTimeSeriesStore)
    return get_counts(store).static_time_series
end

function flush!(store::RustTimeSeriesStore)
    code = ccall((:ts_store_flush, rust_ts_lib_path()), Int32, (Ptr{Cvoid},), store.handle)
    _rts_check(code)
    return
end

Base.isempty(store::RustTimeSeriesStore) = get_num_time_series(store) == 0

# No NetCDF compression knob is exposed through the FFI yet.
get_compression_settings(::RustTimeSeriesStore) = CompressionSettings(; enabled = false)

"""
    serialize(store::RustTimeSeriesStore, file_path)

Persist the store's two artifacts to `file_path` (the NetCDF arrays) and
`file_path * ".sqlite"` (the metadata). No HDF5 bundle is produced and the
SQLite database is never embedded in HDF5.
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
function clear_time_series!(store::RustTimeSeriesStore)
    code = ccall((:ts_store_clear, rust_ts_lib_path()), Int32,
        (Ptr{Cvoid}, Cstring), store.handle, C_NULL)
    _rts_check(code)
    return
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
    time_series isa SingleTimeSeries ||
        error("Rust backend supports only SingleTimeSeries (got $(typeof(time_series)))")
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
    T <: SingleTimeSeries ||
        error("Rust backend supports only SingleTimeSeries (requested $T)")
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

"""Route `has_time_series(owner, T, name; ...)` to the Rust store."""
function _rust_has_time_series(
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::RustTimeSeriesStore
    owner_uuid, _, _ = _rust_owner_args(owner)
    return has_time_series(store, owner_uuid, name;
        resolution = resolution, features = _rust_features(features))
end
