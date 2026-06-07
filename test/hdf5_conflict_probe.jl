# Probe: does the Rust on-disk (NetCDF) store fail when HDF5.jl is merely LOADED
# vs only when it is USED? Run with TIME_SERIES_STORE_LIB set.
#   julia --project=. test/hdf5_conflict_probe.jl load     # import HDF5, don't use
#   julia --project=. test/hdf5_conflict_probe.jl use      # import + use HDF5
#   julia --project=. test/hdf5_conflict_probe.jl none      # control: no HDF5

mode = isempty(ARGS) ? "none" : ARGS[1]
const LIB = ENV["TIME_SERIES_STORE_LIB"]

if mode in ("load", "use")
    import HDF5
end

if mode == "use"
    # Actually exercise libhdf5 before touching the Rust store.
    tmp = tempname() * ".h5"
    HDF5.h5open(tmp, "w") do f
        f["x"] = collect(1.0:10.0)
    end
    @info "used HDF5.jl to write $tmp"
end

function last_err()
    needed = Ref{UInt64}(0)
    ccall((:ts_last_error_message, LIB), Int32, (Ptr{UInt8}, UInt64, Ptr{UInt64}),
        C_NULL, UInt64(0), needed)
    n = Int(needed[]); n == 0 && return ""
    buf = Vector{UInt8}(undef, n + 1)
    ccall((:ts_last_error_message, LIB), Int32, (Ptr{UInt8}, UInt64, Ptr{UInt64}),
        buf, UInt64(n + 1), C_NULL)
    return String(buf[1:n])
end

dir = mktempdir()
path = joinpath(dir, "probe.nc")
out = Ref{Ptr{Cvoid}}(C_NULL)
code = ccall((:ts_store_create, LIB), Int32, (Cstring, Bool, Ref{Ptr{Cvoid}}),
    path, false, out)
code != 0 && (println("CREATE FAILED ($code): ", last_err()); exit(1))

data = collect(1.0:24.0)
initial_ns = Int64(1_704_067_200) * 1_000_000_000   # 2024-01-01 UTC
res_ns = Int64(3600) * 1_000_000_000
out_key = Ref{Ptr{Cvoid}}(C_NULL)
code = ccall((:ts_store_add_single, LIB), Int32,
    (Ptr{Cvoid}, Cstring, Cstring, Int32, Cstring, Int64, Int64,
        Ptr{Float64}, UInt64, Cstring, Cstring, Cstring, Ref{Ptr{Cvoid}}),
    out[], "owner-1", "Generator", Int32(0), "load", initial_ns, res_ns,
    data, UInt64(length(data)), C_NULL, C_NULL, C_NULL, out_key)

if code == 0
    ccall((:ts_store_flush, LIB), Int32, (Ptr{Cvoid},), out[])
    println("RESULT[$mode]: SUCCESS — on-disk NetCDF write worked")
else
    println("RESULT[$mode]: FAILED ($code) — ", last_err())
end
ccall((:ts_store_free, LIB), Cvoid, (Ptr{Cvoid},), out[])
