# Standalone POC: Deterministic + DeterministicSingleTimeSeries through the real
# SystemData / TimeSeriesManager public API, backed by the Rust store.
#   TIME_SERIES_STORE_LIB=/path/to/libtime_series_store_ffi.dylib \
#     julia --project=. test/test_rust_forecasts.jl

using Test
using Dates
import TimeSeries
import JSON3
import DataStructures: SortedDict
import InfrastructureSystems
const IS = InfrastructureSystems

haskey(ENV, "TIME_SERIES_STORE_LIB") ||
    error("set TIME_SERIES_STORE_LIB to the cdylib path")

@testset "Deterministic round-trip via Rust backend" begin
    res = Hour(1)
    initial = DateTime(2024, 1, 1)
    # 4 windows, each 6 steps (horizon_count=6); interval = 1h.
    data = SortedDict(
        initial + Hour(i) => collect(Float64, (10 * i):(10 * i + 5)) for i in 0:3
    )

    sys = IS.SystemData(; time_series_backend = :rust, time_series_in_memory = true)
    comp = IS.TestComponent("gen-1", 5)
    IS.add_component!(sys, comp)

    det = IS.Deterministic("load", data, res)
    IS.add_time_series!(sys, comp, det; scenario = "base")

    @test IS.has_time_series(comp, IS.Deterministic, "load"; resolution = res, scenario = "base")
    @test IS.get_time_series_counts(sys).forecast_count == 1

    got = IS.get_time_series(IS.Deterministic, comp, "load"; resolution = res, scenario = "base")
    @test got isa IS.Deterministic
    @test IS.get_count(got) == 4
    @test IS.get_horizon_count(got) == 6
    @test IS.get_interval(got) == Hour(1)
    gd = IS.get_data(got)
    @test collect(keys(gd)) == collect(keys(data))
    for k in keys(data)
        @test gd[k] == data[k]
    end

    IS.remove_time_series!(sys, IS.Deterministic, comp, "load"; resolution = res, scenario = "base")
    @test !IS.has_time_series(comp, IS.Deterministic, "load"; resolution = res, scenario = "base")
end

@testset "DeterministicSingleTimeSeries round-trip via Rust backend" begin
    res = Hour(1)
    initial = DateTime(2024, 1, 1)
    values = collect(100.0:123.0)  # 24-step underlying SingleTimeSeries
    sts = IS.SingleTimeSeries(;
        name = "load",
        data = TimeSeries.TimeArray(collect(range(initial; length = 24, step = res)), values),
        resolution = res,
    )
    # windows of horizon 6h (6 steps), interval 1h ⇒ up to 19 windows fit in 24 steps
    dst = IS.DeterministicSingleTimeSeries(;
        single_time_series = sts, initial_timestamp = initial,
        interval = Hour(1), count = 19, horizon = Hour(6),
    )

    sys = IS.SystemData(; time_series_backend = :rust, time_series_in_memory = true)
    comp = IS.TestComponent("gen-2", 7)
    IS.add_component!(sys, comp)
    IS.add_time_series!(sys, comp, dst)

    @test IS.has_time_series(comp, IS.DeterministicSingleTimeSeries, "load"; resolution = res)
    # AbstractDeterministic query also finds it
    @test IS.has_time_series(comp, IS.Deterministic, "load"; resolution = res)
    @test IS.get_time_series_counts(sys).forecast_count == 1

    got = IS.get_time_series(IS.DeterministicSingleTimeSeries, comp, "load"; resolution = res)
    @test got isa IS.DeterministicSingleTimeSeries
    @test IS.get_count(got) == 19
    @test IS.get_horizon(got) == Hour(6)

    # each reconstructed window equals the matching slice of the underlying series
    for (i, it) in enumerate(range(initial; step = Hour(1), length = 19))
        window = IS.get_window(got, it)
        @test TimeSeries.values(window) == values[i:(i + 5)]
    end

    IS.remove_time_series!(sys, IS.DeterministicSingleTimeSeries, comp, "load"; resolution = res)
    @test !IS.has_time_series(comp, IS.Deterministic, "load"; resolution = res)
end

@testset "Deterministic System serialize/deserialize (.nc + .sqlite)" begin
    # On-disk; needs HDF5.jl sharing the Rust dylib's libhdf5 (LocalPreferences.toml).
    res = Hour(1)
    initial = DateTime(2024, 1, 1)
    data = SortedDict(initial + Hour(i) => collect(Float64, (10 * i):(10 * i + 5)) for i in 0:3)

    sys = IS.SystemData(; time_series_backend = :rust, time_series_in_memory = false)
    comp = IS.TestComponent("gen-1", 5)
    IS.add_component!(sys, comp)
    IS.add_time_series!(sys, comp, IS.Deterministic("load", data, res))

    directory = mktempdir()
    filename = joinpath(directory, "sys.json")
    IS.prepare_for_serialization_to_file!(sys, filename; force = true)
    sdata = IS.serialize(sys)
    open(filename, "w") do io
        JSON3.write(io, sdata)
    end

    orig = pwd()
    try
        cd(directory)
        raw = JSON3.read(read(filename, String), Dict)
        sys2 = IS.deserialize(IS.SystemData, raw)
        for c in raw["components"]
            IS.add_component!(sys2, IS.deserialize(IS.get_type_from_serialization_data(c), c);
                allow_existing_time_series = true)
        end
        comp2 = only(collect(IS.get_components(IS.TestComponent, sys2)))
        got = IS.get_time_series(IS.Deterministic, comp2, "load"; resolution = res)
        gd = IS.get_data(got)
        for k in keys(data)
            @test gd[k] == data[k]
        end
        @test IS.get_time_series_counts(sys2).forecast_count == 1
    finally
        cd(orig)
    end
end
