"""
A representation of a Julia type that does not need the type to be defined in
the Julia session, and can be stored as a string. This is done by storing the
type name and the module it belongs to as Symbols.

!!! warning
    While `QualifiedType` is currently quite capable, it is not currently
    able to express the full gamut of Julia types. In future this will be improved,
    but it will likely always be restricted to a certain subset.

# Subtyping

While the subtype operator cannot work on QualifiedTypes (`<:` is a built-in),
when the Julia types are defined the subset operator `⊆` can be used instead.
This works by simply `convert`ing the QualifiedTypes to the correspanding Type
and then applying the subtype operator.

```julia-repl
julia> QualifiedTypes(:Base, :Vector) ⊆ QualifiedTypes(:Core, :Array)
true

julia> Matrix ⊆ QualifiedTypes(:Core, :Array)
true

julia> QualifiedTypes(:Base, :Vector) ⊆ AbstractVector
true

julia> QualifiedTypes(:Base, :Foobar) ⊆ AbstractVector
false
```

# Constructors

```julia
QualifiedType(parentmodule::Symbol, typename::Symbol)
QualifiedType(t::Type)
```

# Parsing

A QualifiedType can be expressed as a string as `"\$parentmodule.\$typename"`.
This can be easily `parse`d as a QualifiedType, e.g. `parse(QualifiedType,
"Core.IO")`.
"""
struct QualifiedType
    root::Symbol
    parents::Vector{Symbol}
    name::Symbol
    parameters::Tuple
end

"""
    SmallDict{K, V}

A little (ordered) dictionary type for a small number of keys.
Rather than doing anything clever with hashes, it just keeps
a list of keys, and a list of values.

For a small number of items, this has time and particularly space advantages
over a standard dictionary — a Dict{String, Any}("a" => 1) is about 4x larger
than the equivalent SmallDict. Futrher testing indicates this provides a ~40%
reduction on the overall in-memory size of a `DataCollection`.
"""
struct SmallDict{K, V} <: AbstractDict{K, V}
    keys::Vector{K}
    values::Vector{V}
end

"""
A description that can be used to uniquely identify a DataSet.

Four fields are used to describe the target DataSet:
- `collection`, the name or UUID of the collection (optional).
- `dataset`, the name or UUID of the dataset.
- `type`, the type that should be loaded from the dataset.
- `parameters`, any extra parameters of the dataset that should match.

# Constructors

```julia
Identifier(collection::Union{AbstractString, UUID, Nothing},
           dataset::Union{AbstractString, UUID},
           type::Union{QualifiedType, Nothing},
           parameters::SmallDict{String, Any})
```

# Parsing

An Identifier can be represented as a string with the following form,
with the optional components enclosed by square brackets:
```
[COLLECTION:]DATASET[::TYPE]
```

Such forms can be parsed to an Identifier by simply calling the `parse`
function, i.e. `parse(Identifier, "mycollection:dataset")`.
"""
struct Identifier
    collection::Union{AbstractString, UUID, Nothing}
    dataset::Union{AbstractString, UUID}
    type::Union{<:QualifiedType, Nothing}
    parameters::SmallDict{String, Any}
end

"""
The supertype for methods producing or consuming data.
```
                 ╭────loader─────╮
                 ╵               ▼
Storage ◀────▶ Data          Information
                 ▲               ╷
                 ╰────writer─────╯
```

There are three subtypes:
- `DataStorage`
- `DataLoader`
- `DataWrite`

Each subtype takes a `Symbol` type parameter designating
the driver which should be used to perform the data operation.
In addition, each subtype has the following fields:
- `dataset::DataSet`, the data set the method operates on
- `type::Vector{<:QualifiedType}`, the Julia types the method supports
- `priority::Int`, the priority with which this method should be used,
  compared to alternatives. Lower values have higher priority.
- `parameters::SmallDict{String, Any}`, any parameters applied to the method.
"""
abstract type AbstractDataTransformer{driver} end

struct DataStorage{driver, T} <: AbstractDataTransformer{driver}
    dataset::T
    type::Vector{<:QualifiedType}
    priority::Int
    parameters::SmallDict{String, Any}
end

struct DataLoader{driver} <: AbstractDataTransformer{driver}
    dataset
    type::Vector{<:QualifiedType}
    priority::Int
    parameters::SmallDict{String, Any}
end

struct DataWriter{driver} <: AbstractDataTransformer{driver}
    dataset
    type::Vector{<:QualifiedType}
    priority::Int
    parameters::SmallDict{String, Any}
end

"""
    Advice{func, context} <: Function
Advices allow for composable, highly flexible modifications of data by
encapsulating a function call. They are inspired by elisp's advice system,
namely the most versitile form — `:around` advice, and Clojure's advisors.

A `Advice` is esentially a function wrapper, with a `priority::Int`
attribute. The wrapped functions should be of the form:
```julia
(action::Function, args...; kargs...) ->
  ([post::Function], action::Function, args::Tuple, [kargs::NamedTuple])
```

Short-hand return values with `post` or `kargs` omitted are also accepted, in
which case default values (the `identity` function and `(;)` respectivly) will
be automatically substituted in.

```
    input=(action args kwargs)
         ┃                 ┏╸post=identity
       ╭─╂────advisor 1────╂─╮
       ╰─╂─────────────────╂─╯
       ╭─╂────advisor 2────╂─╮
       ╰─╂─────────────────╂─╯
       ╭─╂────advisor 3────╂─╮
       ╰─╂─────────────────╂─╯
         ┃                 ┃
         ▼                 ▽
action(args; kargs) ━━━━▶ post╺━━▶ result
```

To specify which transforms a Advice should be applied to, ensure you
add the relevant type parameters to your transducing function. In cases where
the transducing function is not applicable, the Advice will simply act
as the identity function.

After all applicable `Advice`s have been applied, `action(args...;
kargs...) |> post` is called to produce the final result.

The final `post` function is created by rightwards-composition with every `post`
entry of the advice forms (i.e. at each stage `post = post ∘ extra` is run).

The overall behaviour can be thought of as *shells* of advice.

```
        ╭╌ advisor 1 ╌╌╌╌╌╌╌╌─╮
        ┆ ╭╌ advisor 2 ╌╌╌╌╌╮ ┆
        ┆ ┆                 ┆ ┆
input ━━┿━┿━━━▶ function ━━━┿━┿━━▶ result
        ┆ ╰╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╯ ┆
        ╰╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╯
```

# Constructors

```julia
Advice(priority::Int, f::Function)
Advice(f::Function) # priority is set to 1
```

# Examples

**1. Logging every time a DataSet is loaded.**

```julia
loggingadvisor = Advice(
    function(post::Function, f::typeof(load), loader::DataLoader, input, outtype)
        @info "Loading \$(loader.data.name)"
        (post, f, (loader, input, outtype))
    end)
```

**2. Automatically committing each data file write.**

```julia
writecommitadvisor = Advice(
    function(post::Function, f::typeof(write), writer::DataWriter{:filesystem}, output, info)
        function writecommit(result)
            run(`git add \$output`)
            run(`git commit -m "update \$output"`)
            result
        end
        (post ∘ writecommit, writefn, (output, info))
    end)
```
"""
struct Advice{func, context} <: Function
    priority::Int # REVIEW should this be an Int?
    f::Function
    function Advice(priority::Int, f::Function)
        validmethods = methods(f, Tuple{Function, Any, Vararg{Any}})
        if length(validmethods) === 0
            throw(ArgumentError("Transducing function $f had no valid methods."))
        end
        functype, context = first(validmethods).sig.types[[2, 3:end]]
        new{functype, Tuple{context...}}(priority, f)
    end
end

struct Plugin
    name::String
    advisors::Vector{Advice}
end

Plugin(name::String, advisors::Vector{<:Function}) =
    Plugin(name, Advice.(advisors))

Plugin(name::String, advisors::Vector{<:Advice}) =
    Plugin(name, Vector{Advice}(advisors))

struct DataSet
    collection
    name::String
    uuid::UUID
    parameters::SmallDict{String, Any}
    storage::Vector{DataStorage}
    loaders::Vector{DataLoader}
    writers::Vector{DataWriter}
end

"""
A collection of `Advices` sourced from availible Plugins.

Like individual `Advices`, a `AdviceAmalgamation` can be called
as a function. However, it also supports the following convenience syntax:
```
(::AdviceAmalgamation)(f::Function, args...; kargs...) # -> result
```

# Constructors

```
AdviceAmalgamation(adviseall::Function, advisors::Vector{Advice},
                   plugins_wanted::Vector{String}, plugins_used::Vector{String})
AdviceAmalgamation(plugins::Vector{String})
AdviceAmalgamation(collection::DataCollection)
```
"""
mutable struct AdviceAmalgamation
    adviseall::Function
    advisors::Vector{Advice}
    plugins_wanted::Vector{String}
    plugins_used::Vector{String}
end

struct DataCollection
    version::Int
    name::Union{String, Nothing}
    uuid::UUID
    plugins::Vector{String}
    parameters::SmallDict{String, Any}
    datasets::Vector{DataSet}
    path::Union{String, Nothing}
    advise::AdviceAmalgamation
    mod::Module
end

"""
    struct FilePath path::String end
Crude stand in for a file path type, which is strangely absent from Base.

This allows for load/write method dispatch, and the distinguishing of
file content (as a String) from file paths.

# Examples

```julia-repl
julia> string(FilePath("some/path"))
"some/path"
```
"""
struct FilePath path::String end
Base.string(fp::FilePath) = fp.path

# `ReplCmd` is documented in interaction/repl.jl
struct ReplCmd{name, E <: Union{Function, Vector}}
    trigger::String
    description::Any
    execute::E
    function ReplCmd{name}(trigger::String, description::Any,
                           execute::Union{Function, Vector{<:ReplCmd}}) where { name }
        if execute isa Function
            new{name, Function}(trigger, description, execute)
        else
            new{name, Vector{ReplCmd}}(trigger, description, execute)
        end
    end
end
