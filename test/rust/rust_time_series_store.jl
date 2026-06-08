# Standalone proof-of-concept test for the Rust-backed time series store.
#
# Requires the time-series-store cdylib. Run with:
#   TIME_SERIES_STORE_LIB=/path/to/libtime_series_store_ffi.dylib \
#     julia --project=. test/test_rust_time_series_store.jl
#
# Not part of the default runtests.jl suite because CI does not build the cdylib.
# IS.jl no longer depends on HDF5, so the on-disk NetCDF path has no libhdf5
# conflict and needs no special configuration.

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
    # Metadata persists as a standalone SQLite file — never embedded in HDF5.
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

@testset "dtype + FunctionData element types through the Rust backend" begin
    initial = Dates.DateTime("2024-01-01")
    res = Dates.Hour(1)
    stamps = collect(range(initial; length = 3, step = res))

    sys = IS.SystemData(; time_series_backend = :rust)
    c = IS.TestComponent("c", 1)
    IS.add_component!(sys, c)

    # Int64 scalar series round-trips with its element type.
    IS.add_time_series!(sys, c,
        IS.SingleTimeSeries(; name = "ints", data = TimeSeries.TimeArray(stamps, Int64[10, 20, 30])))
    ints = IS.get_time_series(IS.SingleTimeSeries, c, "ints")
    @test eltype(TimeSeries.values(IS.get_data(ints))) == Int64
    @test TimeSeries.values(IS.get_data(ints)) == Int64[10, 20, 30]

    # QuadraticFunctionData (3-tuple) round-trips, non-parametric get.
    qvals = [IS.QuadraticFunctionData(1.0 + i, 2.0 + i, 3.0 + i) for i in 1:3]
    IS.add_time_series!(sys, c,
        IS.SingleTimeSeries(; name = "quad", data = TimeSeries.TimeArray(stamps, qvals)))
    quad = IS.get_time_series(IS.SingleTimeSeries, c, "quad")
    @test TimeSeries.values(IS.get_data(quad)) == qvals

    # LinearFunctionData (2-tuple), parametric get.
    lvals = [IS.LinearFunctionData(10.0 + i, 20.0 + i) for i in 1:3]
    IS.add_time_series!(sys, c,
        IS.SingleTimeSeries(; name = "lin", data = TimeSeries.TimeArray(stamps, lvals)))
    lin = IS.get_time_series(IS.SingleTimeSeries{IS.LinearFunctionData}, c, "lin")
    @test TimeSeries.values(IS.get_data(lin)) == lvals

    # PiecewiseLinearData (ragged: 2, 3, 2 points) round-trips.
    pwl = [
        IS.PiecewiseLinearData([(0.0, 1.0), (2.0, 3.0)]),
        IS.PiecewiseLinearData([(0.0, 1.0), (1.0, 2.0), (2.0, 4.0)]),
        IS.PiecewiseLinearData([(0.0, 0.0), (5.0, 9.0)]),
    ]
    IS.add_time_series!(sys, c,
        IS.SingleTimeSeries(; name = "pwl", data = TimeSeries.TimeArray(stamps, pwl)))
    got_pwl = TimeSeries.values(IS.get_data(IS.get_time_series(IS.SingleTimeSeries, c, "pwl")))
    @test eltype(got_pwl) == IS.PiecewiseLinearData
    @test all(IS.get_points(got_pwl[i]) == IS.get_points(pwl[i]) for i in 1:3)
end

@testset "CompressionSettings flow through to the Rust backend" begin
    settings = [
        IS.CompressionSettings(; enabled = false),
        IS.CompressionSettings(; enabled = true, type = IS.CompressionTypes.DEFLATE, level = 9),
        IS.CompressionSettings(;
            enabled = true,
            type = IS.CompressionTypes.DEFLATE,
            level = 1,
            shuffle = false,
        ),
    ]
    for compression in settings
        mktempdir() do dir
            base = joinpath(dir, "system_time_series.nc")
            store = IS.RustTimeSeriesStore(; in_memory = false, path = base, compression = compression)
            @test IS.get_compression_settings(store) == compression
            sts = make_sts("load", INITIAL, RES, VALUES)
            IS.serialize_single!(store, OWNER, "Generator", "Component", "load", sts)
            IS.flush!(store)
            IS.close!(store)

            reopened = IS.open_rust_store(base; read_only = true)
            try
                # The reopened store reports the persisted policy (queried over
                # the FFI), not a placeholder.
                restored = IS.get_compression_settings(reopened)
                @test restored.enabled == compression.enabled
                if compression.enabled
                    @test restored.type == compression.type
                    @test restored.level == compression.level
                    @test restored.shuffle == compression.shuffle
                end
                got = IS.get_single(reopened, OWNER, "load"; resolution = RES)
                @test TimeSeries.values(IS.get_data(got)) == VALUES
            finally
                IS.close!(reopened)
            end
        end
    end

    # End-to-end: a SystemData created with DEFLATE level 9 round-trips, and the
    # setting reaches the storage layer.
    sys = IS.SystemData(;
        time_series_backend = :rust,
        compression = IS.CompressionSettings(; enabled = true, level = 9),
    )
    @test IS.get_compression_settings(sys).enabled
    @test IS.get_compression_settings(sys).level == 9

    # BLOSC is not supported by the Rust backend.
    @test_throws ErrorException IS.RustTimeSeriesStore(;
        in_memory = true,
        compression = IS.CompressionSettings(; enabled = true, type = IS.CompressionTypes.BLOSC),
    )
end
