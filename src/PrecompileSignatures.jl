module PrecompileSignatures

using Documenter.Utilities: submodules
using Scratch: get_scratch!

export precompilables, precompile_directives, write_directives

function _is_macro(f::Function)
    text = sprint(show, MIME"text/plain"(), f)
    return contains(text, "macro with")
end

_is_function(x) = x isa Function && !_is_macro(x)

_in_module(f::Function, M::Module) = typeof(f).name.module == M
_in_module(M::Module) = f -> _in_module(f, M)

"Return all functions defined in module `M`."
function _module_functions(M::Module)::Vector{Function}
    allnames = names(M; all=true)
    filter!(x -> !(x in [:eval, :include]), allnames)
    properties = Any[getproperty(M, name) for name in allnames]
    filter!(x -> _is_function(x) && _in_module(x, M), properties)
    return properties
end

_all_concrete(type::DataType)::Bool = isconcretetype(type)
_all_concrete(types)::Bool = all(map(isconcretetype, types))

# With loop: @btime PrecompileSignatures._pairs([1:200, 1:10, 1:10]) takes 690.020 μs.
# With vcat: @btime PrecompileSignatures._pairs([1:200, 1:10, 1:10]) takes 1.193 ms.
function _pairs(args)
    prod = Base.product(args...)
    # Using a loop instead of vcat(prod...) to avoid many specializations of vcat.
    out = Any[]
    foreach(prod) do element
        # Using a vector instead of tuples to avoid specializations further on.
        vec = collect(element)
        push!(out, vec)
    end
    return out
end

function _unpack_union!(x::Union; out=[])
    push!(out, x.a)
    return _unpack_union!(x.b; out)
end
function _unpack_union!(x; out=[])
    push!(out, x)
end

function _split_unions_barrier(@nospecialize pairs)
    filtered = filter(_all_concrete, pairs)
    return Set(filtered)
end

"Return converted type after applying `type_conversions`."
function _convert_type(type::Any, type_conversions::Dict{DataType,DataType})
    if isconcretetype(type)
        return type
    end
    out = haskey(type_conversions, type) ? type_conversions[type] : type
    return out
end

"""
    _split_unions(sig::DataType) -> Set

Return multiple `Tuple`s containing only concrete types for each combination of concrete types that can be found.
"""
function _split_unions(sig::DataType, type_conversions::Dict{DataType,DataType})::Set
    method, types... = sig.parameters
    pruned = map(types) do type
        unpacked = _unpack_union!(type)::Vector{Any}
        converted = Any[_convert_type(type, type_conversions) for type in unpacked]
        filtered = filter(isconcretetype, converted)
        return filtered
    end
    pairs = _pairs(pruned)
    return _split_unions_barrier(pairs)
end

const SUBMODULES_DEFAULT = true
const SPLIT_UNIONS_DEFAULT = true
const TYPE_CONVERSIONS_DEFAULT = Dict{DataType,DataType}(AbstractString => String)
const DEFAULT_WRITE_HEADER = """
    # This file is machine-generated by PrecompileSignatures.jl.
    # Editing it directly is not advised.\n
    """

"""
    Config(
        submodules::Bool=$SUBMODULES_DEFAULT,
        split_unions::Bool=$SPLIT_UNIONS_DEFAULT,
        type_conversions::Dict{DataType,DataType}=$TYPE_CONVERSIONS_DEFAULT,
        header::String=\$DEFAULT_WRITE_HEADER
    )

Configuration for generating precompile directives.

Keyword arguments:

- `split_unions`:
    Whether to split union types.
    For example, whether to generate two precompile directives for `f(x::Union{Int,Float64})`.
- `abstracttype_conversions`:
    Mapping of conversions from on type to another.
    For example, for all method signatures containing and argument of type `AbstractString`, you can decide to add a precompile directive for `String` for that type.
- `header`:
    Header used when writing the directives to a file.
    Defaults to:
    $DEFAULT_WRITE_HEADER
"""
@Base.kwdef struct Config
    submodules::Bool=SUBMODULES_DEFAULT
    split_unions::Bool=SPLIT_UNIONS_DEFAULT
    type_conversions::Dict{DataType,DataType}=TYPE_CONVERSIONS_DEFAULT
    header::String=DEFAULT_WRITE_HEADER
end

"""
Return precompile directives datatypes for signature `sig`.
Each returned `DataType` is ready to be passed to `precompile`.
"""
function _directives_datatypes(sig::DataType, config::Config)::Vector{DataType}
    method, types... = sig.parameters
    _all_concrete(types) && return [sig]
    concrete_argument_types = if config.split_unions
        _split_unions(sig, config.type_conversions)
    else
        return DataType[]
    end
    return DataType[Tuple{method, types...} for types in concrete_argument_types]
end

"Return all method signatures for function `f`."
function _signatures(f::Function)::Vector{DataType}
    sigs = map(methods(f)) do method
        sig = method.sig
        # Ignoring parametric types for now.
        sig isa UnionAll ? nothing : sig
    end
    filter!(!isnothing, sigs)
    return sigs
end

function _all_submodules(M::Vector{Module})::Vector{Module}
    return collect(Iterators.flatten(map(submodules, M)))
end

"""
    precompilables(M::Vector{Module}, config::Config=Config()) -> Vector{DataType}
    precompilables(M::Module, config::Config=Config()) -> Vector{DataType}

Return a vector of precompile directives for module `M`.

"""
function precompilables(M::Vector{Module}, config::Config=Config())::Vector{DataType}
    if config.submodules
        M = _all_submodules(M)
    end
    types = map(M) do mod
        functions = _module_functions(mod)
        signatures = Iterators.flatten(map(_signatures, functions))
        directives = [_directives_datatypes(sig, config) for sig in signatures]
        return collect(Iterators.flatten(directives))
    end
    return reduce(vcat, types)
end

function precompilables(M::Module, config::Config=Config())::Vector{DataType}
    return precompilables([M], config)
end

"""
    write_directives(path::AbstractString, types::Vector{DataType}, config::Config=Config())
    write_directives(path::AbstractString, M::AbstractVector{Module}, config::Config=Config())

Write precompile directives to file.
"""
function write_directives(
        path::AbstractString,
        types::Vector{DataType},
        config::Config=Config()
    )::String
    directives = ["precompile($t)" for t in types]
    text = string(config.header, join(directives, '\n'))
    write(path, text)
    return text
end
function write_directives(
        path::AbstractString,
        M::AbstractVector{Module},
        config::Config=Config()
    )::String
    types = precompilables(M, config)
    return write_directives(path, types, config)
end
write_directives(path, M::Module, config=Config()) = write_directives(path, [M], config)

function _precompile_path(M::Module)
    dir = get_scratch!(M, string(M))
    mkpath(dir)
    return joinpath(dir, "_precompile.jl")
end

function _error_text()::String
    if VERSION >= v"1.7.0-"
        exc, bt = last(Base.current_exceptions())
    else
        exc, bt = last(Base.catch_stack())
    end
    error = sprint(Base.showerror, exc, bt)
    return error
end

"""
    precompile_directives(M::Module, config::Config=Config())::String

Return the path to a file containing generated `precompile` directives.

!!! note
    This package needs to write the signatures to a file and then include that.
    Evaluating the directives directly via `eval` will cause "incremental compilation fatally broken" errors.
"""
function precompile_directives(M::Module, config::Config=Config())::String
    # This has to be wrapped in a try-catch to avoid other packages to fail completely.
    try
        path = _precompile_path(M)
        types = precompilables(M, config)
        write_directives(path, types, config)
        return path
    catch
        error = _error_text()
        @warn """Generating precompile directives failed
            $error
            """
        # Write empty file so that `include(precompile_directives(...))` succeeds.
        path, _ = mktemp()
        write(path, "")
        return path
    end
end

# Include generated `precompile` directives.
if ccall(:jl_generating_output, Cint, ()) == 1
    include(precompile_directives(PrecompileSignatures))
end

end # module
