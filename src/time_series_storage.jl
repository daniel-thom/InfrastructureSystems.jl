
"""
Abstract type for time series storage implementations.

All subtypes must implement:

  - `clear_time_series!`
  - `deserialize_time_series`
  - `get_compression_settings`
  - `get_num_time_series`
  - `remove_time_series!`
  - `serialize_time_series!`
  - `Base.isempty`
"""
abstract type TimeSeriesStorage end

const DEFAULT_COMPRESSION = false

@scoped_enum(CompressionTypes, BLOSC = 0, DEFLATE = 1,)

@doc """
HDF5 compression algorithm types for time series storage.

# Values
- `BLOSC`: Blosc compression (fast, general-purpose)
- `DEFLATE`: Deflate/zlib compression
""" CompressionTypes

"""
    CompressionSettings(enabled, type, level, shuffle)

Provides customization of HDF5 compression settings.

$(TYPEDFIELDS)

Refer to the [HDF5.jl](https://juliaio.github.io/HDF5.jl/stable/) and
[HDF5](https://portal.hdfgroup.org/) documentation for more details on the
options.

# Example
```julia
settings = CompressionSettings(
    enabled = true,
    type = CompressionTypes.DEFLATE,  # BLOSC is also supported
    level = 3,
    shuffle = true,
)
```
"""
struct CompressionSettings
    "Controls whether compression is enabled."
    enabled::Bool
    "Specifies the type of compression to use."
    type::CompressionTypes
    "Supported values are 0-9. Higher values deliver better compression ratios but take longer."
    level::Int
    "Controls whether to enable the shuffle filter. Used with DEFLATE."
    shuffle::Bool
end

function CompressionSettings(;
    enabled = DEFAULT_COMPRESSION,
    type = CompressionTypes.DEFLATE,
    level = 3,
    shuffle = true,
)
    return CompressionSettings(enabled, type, level, shuffle)
end

function make_time_series_storage(;
    in_memory = false,
    filename = nothing,
    directory = nothing,
    compression = CompressionSettings(),
)
    # HDF5 storage has been removed. The in-memory store is the only pure-Julia
    # backend; on-disk persistence is provided by the Rust backend
    # (`RustTimeSeriesStore`, selected with `backend = :rust`).
    return InMemoryTimeSeriesStorage()
end

"""
Open the storage for a batch of operations. The in-memory and Rust backends have
no file handle to manage, so this just runs `func`.
"""
function open_store!(
    func::Function,
    ::TimeSeriesStorage,
    mode = "r",
    args...;
    kwargs...,
)
    return func(args...; kwargs...)
end

function make_component_name(component_uuid::UUIDs.UUID, name::AbstractString)
    return string(component_uuid) * COMPONENT_NAME_DELIMITER * name
end

function deserialize_component_name(component_name::AbstractString)
    data = split(component_name, COMPONENT_NAME_DELIMITER)
    component = UUIDs.UUID(data[1])
    name = data[2]
    return component, name
end

function serialize(storage::TimeSeriesStorage, file_path::AbstractString)
    error(
        "Serializing $(typeof(storage)) time series to disk is no longer supported. " *
        "Use the Rust time series backend (`backend = :rust`) for persistence.",
    )
end
