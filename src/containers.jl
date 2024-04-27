abstract type InfrastructureSystemsContainer <: InfrastructureSystemsType end

#Base.getindex(x::InfrastructureSystemsContainer, key) = getindex(x.data, key)
#Base.haskey(x::InfrastructureSystemsContainer, key) = haskey(x.data, key)
#Base.isempty(x::InfrastructureSystemsContainer) = isempty(x.data)
#Base.iterate(x::InfrastructureSystemsContainer, args...) = iterate(x.data, args...)
#Base.length(x::InfrastructureSystemsContainer) = length(x.data)
#Base.keys(x::InfrastructureSystemsContainer) = keys(x.data)
#Base.values(x::InfrastructureSystemsContainer) = values(x.data)
#Base.delete!(x::InfrastructureSystemsContainer, key) = delete!(x.data, key)
#Base.empty!(x::InfrastructureSystemsContainer) = empty!(x.data)
#Base.setindex!(x::InfrastructureSystemsContainer, val, key) = setindex!(x.data, val, key)
#Base.pop!(x::InfrastructureSystemsContainer, key) = pop!(x.data, key)

get_display_string(x::InfrastructureSystemsContainer) = string(nameof(typeof(x)))

"""
Iterates over all data in the container.
"""
function iterate_container(container::InfrastructureSystemsContainer)
    return (y for x in values(container.data) for y in values(x))
end

function get_num_members(container::InfrastructureSystemsContainer)
    return mapreduce(length, +, values(container.data); init = 0)
end
