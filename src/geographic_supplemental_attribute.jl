"""
Attribute to store Geographic Information about the system components
"""
struct GeographicInfo <: InfrastructureSystemsSupplementalAttribute
    geo_json::Dict{String, Any}
    component_uuids::Set{UUIDs.UUID}
    internal::InfrastructureSystemsInternal
end

function GeographicInfo(;
    geo_json::Dict{String, Any} = Dict{String, Any}(),
    component_uuids::Set{UUIDs.UUID} = Set{UUIDs.UUID}(),
)
    return GeographicInfo(geo_json, component_uuids, InfrastructureSystemsInternal())
end

get_geo_json(geo::GeographicInfo) = geo.geo_json
get_internal(geo::GeographicInfo) = geo.internal
get_uuid(geo::GeographicInfo) = get_uuid(get_internal(geo))
get_time_series_container(::GeographicInfo) = nothing
get_component_uuids(geo::GeographicInfo) = geo.component_uuids