
function make_metadata(ts::IS.TimeSeriesData)
    return IS.time_series_data_to_metadata(typeof(ts))(ts)
end

"""
Helper function that gets all values and then deserializes a full object.
"""
function _deserialize_full(storage, ts)
    ts_metadata = make_metadata(ts)
    return IS.deserialize_time_series(
        IS.SingleTimeSeries,
        storage,
        ts_metadata,
        UnitRange(1, length(ts)),
        UnitRange(1, 1),
    )
end

function test_add_remove(storage::IS.TimeSeriesStorage)
    name = "component1"
    name = "val"
    ts = IS.SingleTimeSeries(; data = create_time_array(), name = "test")
    IS.serialize_time_series!(storage, ts)

    ts2 = _deserialize_full(storage, ts)
    @test TimeSeries.timestamp(IS.get_data(ts2)) == TimeSeries.timestamp(IS.get_data(ts))
    @test TimeSeries.values(IS.get_data(ts2)) == TimeSeries.values(IS.get_data(ts))

    @test IS.get_num_time_series(storage) == 1
    IS.remove_time_series!(storage, IS.get_uuid(ts))
    @test_throws ArgumentError _deserialize_full(storage, ts)
    return IS.get_num_time_series(storage) == 0
end

function test_get_subset(storage::IS.TimeSeriesStorage)
    ts = IS.SingleTimeSeries(; data = create_time_array(), name = "test")
    IS.serialize_time_series!(storage, ts)
    ts2 = _deserialize_full(storage, ts)

    @test TimeSeries.timestamp(IS.get_data(ts2)) == TimeSeries.timestamp(IS.get_data(ts))
    rows = UnitRange(3, 8)
    columns = UnitRange(1, 1)
    ts_metadata = make_metadata(ts)
    ts_subset =
        IS.deserialize_time_series(IS.SingleTimeSeries, storage, ts_metadata, rows, columns)
    @test IS.get_data(ts_subset)[1] == IS.get_data(ts2)[rows.start]
    @test length(ts_subset) == length(rows)

    initial_time1 = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    initial_time2 = initial_time1 + resolution
    name = "test"
    horizon_count = 24
    data = SortedDict(
        initial_time1 => ones(horizon_count),
        initial_time2 => ones(horizon_count),
    )

    ts = IS.Deterministic(; data = data, name = name, resolution = resolution)
    IS.serialize_time_series!(storage, ts)
    ts_metadata = make_metadata(ts)
    rows = UnitRange(1, horizon_count)
    columns = UnitRange(1, 2)
    ts2 = IS.deserialize_time_series(IS.Deterministic, storage, ts_metadata, rows, columns)
    @test collect(IS.get_initial_times(ts2)) == collect(IS.get_initial_times(ts))
    @test collect(IS.iterate_windows(ts2)) == collect(IS.iterate_windows(ts))

    rows = UnitRange(3, 8)
    columns = UnitRange(1, 2)
    ts_subset =
        IS.deserialize_time_series(IS.Deterministic, storage, ts_metadata, rows, columns)
    @test IS.get_horizon_count(ts_subset) == length(rows)
    @test IS.get_count(ts_subset) == columns.stop
    @test IS.get_initial_timestamp(ts_subset) ==
          initial_time1 + resolution * (rows.start - 1)

    rows = UnitRange(2, 7)
    columns = UnitRange(1, 1)
    ts_subset =
        IS.deserialize_time_series(IS.Deterministic, storage, ts_metadata, rows, columns)
    @test IS.get_horizon_count(ts_subset) == length(rows)
    @test IS.get_count(ts_subset) == columns.stop
    @test IS.get_initial_timestamp(ts_subset) ==
          initial_time1 + resolution * (rows.start - 1)
end

function test_clear(storage::IS.TimeSeriesStorage)
    ts = IS.SingleTimeSeries(; data = create_time_array(), name = "test")
    IS.serialize_time_series!(storage, ts)

    ts2 = _deserialize_full(storage, ts)
    @test TimeSeries.timestamp(IS.get_data(ts2)) == TimeSeries.timestamp(IS.get_data(ts))
    @test TimeSeries.values(IS.get_data(ts2)) == TimeSeries.values(IS.get_data(ts))

    IS.clear_time_series!(storage)
    @test_throws ArgumentError _deserialize_full(storage, ts)
end

# HDF5 storage was removed; the in-memory store is the only pure-Julia backend.
# On-disk persistence (NetCDF + SQLite, compression) is covered by the Rust
# backend tests (test_rust_*.jl).
@testset "Test time series storage implementations" begin
    test_add_remove(IS.make_time_series_storage(; in_memory = true))
    test_get_subset(IS.make_time_series_storage(; in_memory = true))
    test_clear(IS.make_time_series_storage(; in_memory = true))
end

@testset "Test isempty" begin
    storage = IS.make_time_series_storage(; in_memory = true)
    @test isempty(storage)
    ts = IS.SingleTimeSeries(; data = create_time_array(), name = "test")
    IS.serialize_time_series!(storage, ts)
    @test !isempty(storage)
end
