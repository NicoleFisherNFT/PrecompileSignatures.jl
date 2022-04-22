module PrecompileSignatures

using Documenter.Utilities: submodules
using Scratch: get_scratch!

export precompilables, precompile_directives, write_directives

include("precompilables.jl")

# Include generated `precompile` directives.
include(precompile_directives(PrecompileSignatures))

end # module
