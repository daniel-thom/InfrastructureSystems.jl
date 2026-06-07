# Standalone proof-of-concept test for the Rust-backed time series store.
#
# Requires the time-series-store cdylib. Run with:
#   TIME_SERIES_STORE_LIB=/path/to/libtime_series_store_ffi.dylib \
#     julia --project=. test/test_rust_time_series_store.jl
#
# Not part of the default runtests.jl suite because CI does not build the cdylib.
#
# HDF5 NOTE: the on-disk backend writes NetCDF4, which links libhdf5; IS.jl also
# loads HDF5.jl. Two *copies* of libhdf5 in one process corrupt each other
# ("NetCDF: HDF error") — even at the same version. The fix is to make HDF5.jl
# use the SAME system libhdf5 the Rust dylib links, so there is a single copy.
# Configure once (writes LocalPreferences.toml), then restart Julia:
#   using HDF5
#   HDF5.API.set_libraries!("/opt/homebrew/opt/hdf5/lib/libhdf5.dylib",
#                           "/opt/homebrew/opt/hdf5/lib/libhdf5_hl.dylib")
# With that in place the on-disk testset below passes.

using Test
using Dates
import TimeSeries
import InfrastructureSystems
const IS = InfrastructureSystems

function make_sts(name, initial, resolution, values)
    timestamps = collect(range(initial; length = length(values), step = resolution))
    return IS.SingleTimeSeries(;
        name = name,
        data = TimeSeries.TimeArray(timestamps, values),
        resolution = resolution,
    )
end

haskey(ENV, "TIME_SERIES_STORE_LIB") ||
    error("set TIME_SERIES_STORE_LIB to the cdylib path")

const OWNER = "11111111-1111-1111-1111-111111111111"
const INITIAL = DateTime(2024, 1, 1)
const RES = Hour(1)
const VALUES = collect(100.0:123.0)
const FEATS = Dict("model_year" => 2030, "scenario" => "high")  # int + string features

@testset "RustTimeSeriesStore in-memory data+metadata round-trip" begin
    store = IS.RustTimeSeriesStore(; in_memory = true)
    sts = make_sts("load", INITIAL, RES, VALUES)
    IS.serialize_single!(store, OWNER, "Generator", "Component", "load", sts;
        features = FEATS, units = "MW")

    @test IS.has_time_series(store, OWNER, "load"; resolution = RES, features = FEATS)
    @test !IS.has_time_series(store, OWNER, "load"; resolution = RES,
        features = Dict("model_year" => 2031))

    meta = IS.get_metadata(store, OWNER, "load"; resolution = RES, features = FEATS)
    @test meta.initial_timestamp == INITIAL
    @test meta.length == 24
    @test length(meta.data_hash) == 32

    got = IS.get_single(store, OWNER, "load"; resolution = RES, features = FEATS)
    @test TimeSeries.values(IS.get_data(got)) == VALUES
    @test TimeSeries.timestamp(IS.get_data(got))[1] == INITIAL
    @test IS.get_resolution(got) == RES

    counts = IS.get_counts(store)
    @test counts.static_time_series == 1
    @test counts.components_with_time_series == 1
    @test counts.forecasts == 0
    @test IS.get_num_time_series(store) == 1
    @test !isempty(store)

    # content-addressed dedup: same array under a new name reuses storage (same hash)
    IS.serialize_single!(store, OWNER, "Generator", "Component", "load2", sts; features = FEATS)
    meta2 = IS.get_metadata(store, OWNER, "load2"; resolution = RES, features = FEATS)
    @test meta2.data_hash == meta.data_hash

    # remove "load2"; underlying array still referenced by "load", which survives
    IS.remove_single!(store, OWNER, "load2"; resolution = RES, features = FEATS)
    @test !IS.has_time_series(store, OWNER, "load2"; resolution = RES, features = FEATS)
    @test IS.has_time_series(store, OWNER, "load"; resolution = RES, features = FEATS)
    @test_throws IS.RustTimeSeriesNotFound IS.get_metadata(store, OWNER, "load2";
        resolution = RES, features = FEATS)
end

@testset "RustTimeSeriesStore on-disk persistence (.nc + .sqlite)" begin
    # Requires HDF5.jl configured to share the Rust dylib's system libhdf5 (see
    # the HDF5 NOTE at the top of this file). Metadata persists as a standalone
    # SQLite file — never embedded in HDF5.
    mktempdir() do dir
        base = joinpath(dir, "system_time_series.nc")
        store = IS.RustTimeSeriesStore(; in_memory = false, path = base)
        sts = make_sts("load", INITIAL, RES, VALUES)
        IS.serialize_single!(store, OWNER, "Generator", "Component", "load", sts;
            features = FEATS, units = "MW")
        IS.flush!(store)
        IS.close!(store)

        @test isfile(base)                 # NetCDF arrays
        @test isfile(base * ".sqlite")     # metadata, standalone (no HDF5 embedding)

        reopened = IS.open_rust_store(base; read_only = true)
        try
            got = IS.get_single(reopened, OWNER, "load"; resolution = RES, features = FEATS)
            @test TimeSeries.values(IS.get_data(got)) == VALUES
            @test IS.get_counts(reopened).static_time_series == 1
        finally
            IS.close!(reopened)
        end
    end
end
