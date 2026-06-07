# Standalone POC: SingleTimeSeries through the real SystemData / TimeSeriesManager
# public API, backed by the Rust store (backend=:rust). Requires the cdylib.
#   TIME_SERIES_STORE_LIB=/path/to/libtime_series_store_ffi.dylib \
#     julia --project=. test/test_rust_system_integration.jl
# (For on-disk persistence, HDF5.jl must share the Rust dylib's libhdf5 — see
#  the HDF5 note in test_rust_time_series_store.jl. This test uses in-memory.)

using Test
using Dates
import TimeSeries
import JSON3
import InfrastructureSystems
const IS = InfrastructureSystems

haskey(ENV, "TIME_SERIES_STORE_LIB") ||
    error("set TIME_SERIES_STORE_LIB to the cdylib path")

function make_sts(name, initial, resolution, values)
    timestamps = collect(range(initial; length = length(values), step = resolution))
    return IS.SingleTimeSeries(;
        name = name,
        data = TimeSeries.TimeArray(timestamps, values),
        resolution = resolution,
    )
end

@testset "System SingleTimeSeries round-trip via Rust backend" begin
    initial = DateTime(2024, 1, 1)
    res = Hour(1)
    values = collect(100.0:123.0)

    sys = IS.SystemData(; time_series_backend = :rust, time_series_in_memory = true)
    @test IS._uses_rust_store(sys.time_series_manager)

    comp = IS.TestComponent("generator-1", 5)
    IS.add_component!(sys, comp)

    sts = make_sts("load", initial, res, values)
    IS.add_time_series!(sys, comp, sts; model_year = 2030, scenario = "high")

    # has_time_series through the public API
    @test IS.has_time_series(comp, IS.SingleTimeSeries, "load";
        resolution = res, model_year = 2030, scenario = "high")
    @test !IS.has_time_series(comp, IS.SingleTimeSeries, "load";
        resolution = res, model_year = 2031, scenario = "high")

    # full get
    got = IS.get_time_series(IS.SingleTimeSeries, comp, "load";
        resolution = res, model_year = 2030, scenario = "high")
    @test TimeSeries.values(IS.get_data(got)) == values
    @test TimeSeries.timestamp(IS.get_data(got))[1] == initial
    @test IS.get_resolution(got) == res

    # sliced get (start_time + len)
    sliced = IS.get_time_series(IS.SingleTimeSeries, comp, "load";
        start_time = initial + Hour(2), len = 5,
        resolution = res, model_year = 2030, scenario = "high")
    @test TimeSeries.values(IS.get_data(sliced)) == values[3:7]
    @test TimeSeries.timestamp(IS.get_data(sliced))[1] == initial + Hour(2)

    # counts
    counts = IS.get_time_series_counts(sys)
    @test counts.static_time_series_count == 1
    @test counts.components_with_time_series == 1
    @test counts.forecast_count == 0

    # duplicate rejected
    @test_throws ArgumentError IS.add_time_series!(sys, comp, sts;
        model_year = 2030, scenario = "high")

    # second component sharing the same array (content-addressed dedup)
    comp2 = IS.TestComponent("generator-2", 7)
    IS.add_component!(sys, comp2)
    IS.add_time_series!(sys, comp2, sts; model_year = 2030, scenario = "high")
    @test IS.get_time_series_counts(sys).components_with_time_series == 2

    # remove from comp; comp2 still has it
    IS.remove_time_series!(sys, IS.SingleTimeSeries, comp, "load";
        resolution = res, model_year = 2030, scenario = "high")
    @test !IS.has_time_series(comp, IS.SingleTimeSeries, "load";
        resolution = res, model_year = 2030, scenario = "high")
    @test IS.has_time_series(comp2, IS.SingleTimeSeries, "load";
        resolution = res, model_year = 2030, scenario = "high")
end

@testset "System serialize/deserialize via Rust backend (.nc + .sqlite)" begin
    # On-disk; requires HDF5.jl to share the Rust dylib's libhdf5 (LocalPreferences.toml).
    initial = DateTime(2024, 1, 1)
    res = Hour(1)
    values = collect(50.0:73.0)

    sys = IS.SystemData(; time_series_backend = :rust, time_series_in_memory = false)
    comp = IS.TestComponent("generator-1", 5)
    IS.add_component!(sys, comp)
    IS.add_time_series!(sys, comp, make_sts("load", initial, res, values); model_year = 2030)

    directory = mktempdir()
    filename = joinpath(directory, "sys.json")
    IS.prepare_for_serialization_to_file!(sys, filename; force = true)
    data = IS.serialize(sys)
    open(filename, "w") do io
        JSON3.write(io, data)
    end

    @test haskey(data, "time_series_storage_file")
    @test data["time_series_storage_type"] == "RustTimeSeriesStore"
    nc_file = joinpath(directory, data["time_series_storage_file"])
    @test isfile(nc_file)               # NetCDF arrays
    @test isfile(nc_file * ".sqlite")   # standalone metadata (no HDF5 embedding)

    orig = pwd()
    try
        cd(directory)
        raw = JSON3.read(read(filename, String), Dict)
        sys2 = IS.deserialize(IS.SystemData, raw)
        @test IS._uses_rust_store(sys2.time_series_manager)
        for component in raw["components"]
            type = IS.get_type_from_serialization_data(component)
            IS.add_component!(sys2, IS.deserialize(type, component);
                allow_existing_time_series = true)
        end
        comp2 = only(collect(IS.get_components(IS.TestComponent, sys2)))
        got = IS.get_time_series(IS.SingleTimeSeries, comp2, "load";
            resolution = res, model_year = 2030)
        @test TimeSeries.values(IS.get_data(got)) == values
        @test TimeSeries.timestamp(IS.get_data(got))[1] == initial
        @test IS.get_time_series_counts(sys2).static_time_series_count == 1
    finally
        cd(orig)
    end
end
