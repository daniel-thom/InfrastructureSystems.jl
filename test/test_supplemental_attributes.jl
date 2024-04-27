@testset "Test add_supplemental_attribute" begin
    mgr = IS.SupplementalAttributeManager(IS.TimeSeriesManager(; in_memory = true))
    geo_supplemental_attribute = IS.GeographicInfo()
    component = IS.TestComponent("component1", 5)
    IS.add_supplemental_attribute!(mgr, component, geo_supplemental_attribute)
    @test length(mgr.data) == 1
    @test length(mgr.data[IS.GeographicInfo]) == 1
    @test IS.get_num_attributes(mgr.associations) == 1
    @test_throws ArgumentError IS.add_supplemental_attribute!(
        mgr,
        component,
        geo_supplemental_attribute,
    )
end

@testset "Test clear_supplemental_attributes" begin
    mgr = IS.SupplementalAttributeManager(IS.TimeSeriesManager(; in_memory = true))
    geo_supplemental_attribute = IS.GeographicInfo()
    component1 = IS.TestComponent("component1", 5)
    component2 = IS.TestComponent("component2", 6)
    IS.add_supplemental_attribute!(mgr, component1, geo_supplemental_attribute)
    IS.add_supplemental_attribute!(mgr, component2, geo_supplemental_attribute)
    @test IS.get_num_attributes(mgr.associations) == 1

    IS.clear_supplemental_attributes!(component1)
    @test IS.get_num_attributes(mgr.associations) == 1
    IS.clear_supplemental_attributes!(mgr)
    supplemental_attributes = IS.get_supplemental_attributes(IS.GeographicInfo, mgr)
    @test length(supplemental_attributes) == 0
end

@testset "Test remove_supplemental_attribute" begin
    mgr = IS.SupplementalAttributeManager(IS.TimeSeriesManager(; in_memory = true))
    geo_supplemental_attribute = IS.GeographicInfo()
    component = IS.TestComponent("component1", 5)
    IS.add_supplemental_attribute!(mgr, component, geo_supplemental_attribute)
    @test IS.get_num_attributes(mgr.associations) == 1
    IS.remove_supplemental_attribute!(mgr, component, geo_supplemental_attribute)
    @test IS.get_num_attributes(mgr.associations) == 0
end

@testset "Test supplemental attribute attached to multiple components" begin
    data = IS.SystemData()
    geo_supplemental_attribute = IS.GeographicInfo()
    component1 = IS.TestComponent("component1", 5)
    component2 = IS.TestComponent("component2", 7)
    IS.add_component!(data, component1)
    IS.add_component!(data, component2)
    IS.add_supplemental_attribute!(data, component1, geo_supplemental_attribute)
    IS.add_supplemental_attribute!(data, component2, geo_supplemental_attribute)
    @test IS.get_num_supplemental_attributes(data) == 1

    IS.remove_supplemental_attribute!(data, component1, geo_supplemental_attribute)
    @test IS.get_num_supplemental_attributes(data) == 1
    IS.remove_supplemental_attribute!(data, component2, geo_supplemental_attribute)
    @test IS.get_num_supplemental_attributes(data) == 0
end

@testset "Test iterate_SupplementalAttributeManager" begin
    mgr = IS.SupplementalAttributeManager(IS.TimeSeriesManager(; in_memory = true))
    geo_supplemental_attribute = IS.GeographicInfo()
    component = IS.TestComponent("component1", 5)
    IS.add_supplemental_attribute!(mgr, component, geo_supplemental_attribute)
    @test length(collect(IS.iterate_supplemental_attributes(mgr))) == 1
end

@testset "Summarize SupplementalAttributeManager" begin
    mgr = IS.SupplementalAttributeManager(IS.TimeSeriesManager(; in_memory = true))
    geo_supplemental_attribute = IS.GeographicInfo()
    component = IS.TestComponent("component1", 5)
    IS.add_supplemental_attribute!(mgr, component, geo_supplemental_attribute)
    summary(devnull, mgr)
end

@testset "Test supplemental_attributes serialization" begin
    data = IS.SystemData()
    geo_supplemental_attribute = IS.GeographicInfo()
    component = IS.TestComponent("component1", 5)
    IS.add_component!(data, component)
    IS.add_supplemental_attribute!(data, component, geo_supplemental_attribute)
    data = IS.serialize(data.supplemental_attribute_manager)
    @test data isa Dict
    @test length(data["associations"]) == 1
    @test length(data["attributes"]) == 1
end

@testset "Add time series to supplemental_attribute" begin
    data = IS.SystemData()
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    ta = TimeSeries.TimeArray(range(initial_time; length = 24, step = resolution), ones(24))
    ts = IS.SingleTimeSeries(; data = ta, name = "test")

    for i in 1:3
        name = "component_$(i)"
        component = IS.TestComponent(name, 5)
        IS.add_component!(data, component)
        supp_attribute = IS.TestSupplemental(; value = Float64(i))
        IS.add_supplemental_attribute!(data, component, supp_attribute)
        IS.add_time_series!(data, supp_attribute, ts)
    end

    for attribute in IS.iterate_supplemental_attributes(data)
        ts_ = IS.get_time_series(IS.SingleTimeSeries, attribute, "test")
        @test IS.get_initial_timestamp(ts_) == initial_time
    end

    @test length(collect(IS.iterate_supplemental_attributes_with_time_series(data))) == 3
end

@testset "Test counts of supplemental attribute" begin
    data = IS.SystemData()
    geo_supplemental_attribute = IS.GeographicInfo()
    component1 = IS.TestComponent("component1", 5)
    component2 = IS.TestComponent("component2", 7)
    IS.add_component!(data, component1)
    IS.add_component!(data, component2)
    IS.add_supplemental_attribute!(data, component1, geo_supplemental_attribute)
    IS.add_supplemental_attribute!(data, component2, geo_supplemental_attribute)
    IS.add_supplemental_attribute!(
        data,
        component1,
        IS.TestSupplemental(; value = Float64(1)),
    )
    IS.add_supplemental_attribute!(
        data,
        component2,
        IS.TestSupplemental(; value = Float64(2)),
    )
    df = IS.get_supplemental_attribute_summary_table(data)
    for (a_type, c_type) in
        zip(("GeographicInfo", "TestSupplemental"), ("TestComponent", "TestComponent"))
        subdf = filter(x -> x.attribute_type == a_type && x.component_type == c_type, df)
        @test DataFrames.nrow(subdf) == 1
        @test subdf[!, "count"][1] == 2
    end

    counts = IS.get_supplemental_attribute_counts_by_type(data)
    types = Set{String}()
    @test length(counts) == 2
    for item in counts
        @test item["count"] == 2
        push!(types, item["type"])
    end
    @test sort!(collect(types)) == ["GeographicInfo", "TestSupplemental"]

    @test IS.get_num_components_with_supplemental_attributes(data) == 2

    # The attributes can be counted in the assocation table or in the attribute dicts.
    @test IS.get_num_supplemental_attributes(data) == 3
    @test IS.get_num_members(data.supplemental_attribute_manager) == 3

    table = Tables.rowtable(
        IS.sql(
            data.supplemental_attribute_manager.associations,
            "SELECT * FROM $(IS.SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME)",
        ),
    )
    @test length(table) == 4
end
