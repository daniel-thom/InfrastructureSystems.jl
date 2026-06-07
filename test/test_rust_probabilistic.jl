# Standalone POC: Probabilistic forecast through the real SystemData /
# TimeSeriesManager public API, backed by the Rust store.
#   TIME_SERIES_STORE_LIB=/path/to/libtime_series_store_ffi.dylib \
#     julia --project=. test/test_rust_probabilistic.jl

using Test
using Dates
import TimeSeries
import JSON3
import DataStructures: SortedDict
import InfrastructureSystems
const IS = InfrastructureSystems

haskey(ENV, "TIME_SERIES_STORE_LIB") ||
    error("set TIME_SERIES_STORE_LIB to the cdylib path")

function make_probabilistic(name, initial, res)
    # 3 windows, horizon_count = 4 steps, 2 percentiles ⇒ each window is 4x2.
    percentiles = [0.1, 0.9]
    data = SortedDict(
        initial + Hour(i) => Float64[(10 * i + s) + 0.1 * p for s in 0:3, p in 1:2]
        for i in 0:2
    )
    return IS.Probabilistic(name, data, percentiles, res), data, percentiles
end

@testset "Probabilistic round-trip via Rust backend" begin
    res = Hour(1)
    initial = DateTime(2024, 1, 1)
    prob, data, percentiles = make_probabilistic("load", initial, res)

    sys = IS.SystemData(; time_series_backend = :rust, time_series_in_memory = true)
    comp = IS.TestComponent("gen-1", 5)
    IS.add_component!(sys, comp)
    IS.add_time_series!(sys, comp, prob; scenario = "base")

    @test IS.has_time_series(comp, IS.Probabilistic, "load"; resolution = res, scenario = "base")
    @test IS.get_time_series_counts(sys).forecast_count == 1

    got = IS.get_time_series(IS.Probabilistic, comp, "load"; resolution = res, scenario = "base")
    @test got isa IS.Probabilistic
    @test IS.get_percentiles(got) == percentiles
    @test IS.get_count(got) == 3
    @test IS.get_interval(got) == Hour(1)
    gd = IS.get_data(got)
    @test collect(keys(gd)) == collect(keys(data))
    for k in keys(data)
        @test gd[k] == data[k]
        @test size(gd[k]) == (4, 2)
    end

    IS.remove_time_series!(sys, IS.Probabilistic, comp, "load"; resolution = res, scenario = "base")
    @test !IS.has_time_series(comp, IS.Probabilistic, "load"; resolution = res, scenario = "base")
end

@testset "Probabilistic System serialize/deserialize (.nc + .sqlite)" begin
    res = Hour(1)
    initial = DateTime(2024, 1, 1)
    prob, data, percentiles = make_probabilistic("load", initial, res)

    sys = IS.SystemData(; time_series_backend = :rust, time_series_in_memory = false)
    comp = IS.TestComponent("gen-1", 5)
    IS.add_component!(sys, comp)
    IS.add_time_series!(sys, comp, prob)

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
        got = IS.get_time_series(IS.Probabilistic, comp2, "load"; resolution = res)
        @test IS.get_percentiles(got) == percentiles
        gd = IS.get_data(got)
        for k in keys(data)
            @test gd[k] == data[k]
        end
    finally
        cd(orig)
    end
end
