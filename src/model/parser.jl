# ---------------
# QualifiedType
# ---------------

function Base.parse(::Type{QualifiedType}, spec::AbstractString)
    if haskey(QUALIFIED_TYPE_SHORTHANDS.forward, spec)
        return QUALIFIED_TYPE_SHORTHANDS.forward[spec]
    end
    components, parameters = let cbsplit = split(spec, '{', limit=2)
        function destruct(param)
            if param isa Number
                param
            elseif param isa QuoteNode
                param.value
            elseif param isa Expr && param.head == :tuple
                Tuple(destruct.(param.args))
            elseif param isa Symbol
                if haskey(QUALIFIED_TYPE_SHORTHANDS.forward, string(param))
                    QUALIFIED_TYPE_SHORTHANDS.forward[string(param)]
                else
                    QualifiedType(Symbol(Base.binding_module(Main, param)),
                                  Symbol[], param, Tuple{}())
                end
            elseif Meta.isexpr(param, :.)
                parse(QualifiedType, string(param))
            elseif Meta.isexpr(param, :<:) && last(param.args) isa Symbol
                TypeVar(if length(param.args) == 2
                            first(param.args)
                        else Symbol("#s0") end,
                        getfield(Main, last(param.args)))
            elseif Meta.isexpr(param, :<:) && (val = typeify(parse(QualifiedType, string(last(param.args))))) |> !isnothing
                TypeVar(if length(param.args) == 2
                            first(param.args)
                        else Symbol("#s0") end,
                        val)
            elseif Meta.isexpr(param, :curly)
                base = parse(QualifiedType, string(first(param.args)))
                QualifiedType(base.root, Symbol[], base.name, Tuple(destruct.(param.args[2:end])))
            else
                throw(ArgumentError("Invalid QualifiedType parameter $(sprint(show, param)) in $(sprint(show, spec))"))
            end
        end
        if length(cbsplit) == 1
            split(cbsplit[1], '.'), Tuple{}()
        else
            typeparams = Meta.parse(spec[1+length(cbsplit[1]):end])
            split(cbsplit[1], '.'), Tuple(destruct.(typeparams.args))
        end
    end
    root, parents, name = if length(components) == 1
        n = Symbol(components[1])
        Symbol(Base.binding_module(Main, n)), Symbol[], n
    elseif length(components) == 2
        Symbol(components[1]), Symbol[], Symbol(components[2])
    else
        Symbol(components[1]), Symbol.(components[2:end-1]), Symbol(components[end])
    end
    QualifiedType(root, parents, name, parameters)
end

# ---------------
# Identifier
# ---------------

function Base.parse(::Type{Identifier}, spec::AbstractString)
    isempty(STACK) && return parse_ident(spec)
    mark = findfirst(':', spec)
    collection = if !isnothing(mark) && (mark == length(spec) || spec[mark+1] != ':')
        cstring = spec[1:prevind(spec, mark)]
        something(tryparse(UUID, cstring), cstring)
    end
    @advise getlayer(collection) parse_ident(spec)
end

function parse_ident(spec::AbstractString)
    mark = findfirst(':', spec)
    collection = if !isnothing(mark) && (mark == length(spec) || spec[mark+1] != ':')
        cstring, spec = spec[begin:prevind(spec, mark)], spec[mark+1:end]
        something(tryparse(UUID, cstring), cstring)
    end
    mark = findfirst(':', spec)
    dataset = if isnothing(mark)
        _, spec = spec, ""
    else
        _, spec = spec[begin:prevind(spec, mark)], spec[mark:end]
    end |> first
    dtype  = if startswith(spec, "::") && length(spec) > 2
        parse(QualifiedType, spec[3:end])
    end
    Identifier(collection, something(tryparse(UUID, dataset), dataset),
                dtype, SmallDict{String,Any}())
end

# ---------------
# DataTransformers
# ---------------

"""
    supportedtypes(ADT::Type{<:AbstractDataTransformer})::Vector{QualifiedType}

Return a list of types supported by the data transformer `ADT`.

This is used as the default value for the `type` key in the Data TOML.
The list of types is dynamically generated based on the availible methods for
the data transformer.

In some cases, it makes sense for this to be explicitly defined for a particular
transformer. """
function supportedtypes end # See `interaction/externals.jl` for method definitions.

supportedtypes(ADT::Type{<:AbstractDataTransformer}, spec::SmallDict{String, Any}, _::DataSet) =
    supportedtypes(ADT, spec)

supportedtypes(ADT::Type{<:AbstractDataTransformer}, _::SmallDict{String, Any}) =
    supportedtypes(ADT)

(ADT::Type{<:AbstractDataTransformer})(dataset::DataSet, spec::Dict{String, Any}) =
    @advise fromspec(ADT, dataset, spec)

(ADT::Type{<:AbstractDataTransformer})(dataset::DataSet, spec::String) =
    ADT(dataset, Dict{String, Any}("driver" => spec))

"""
    fromspec(ADT::Type{<:AbstractDataTransformer}, dataset::DataSet, spec::Dict{String, Any})

Create an `ADT` of `dataset` according to `spec`.

`ADT` can either contain the driver name as a type parameter, or it will be read
from the `"driver"` key in `spec`.
"""
function fromspec(ADT::Type{<:AbstractDataTransformer}, dataset::DataSet, spec::Dict{String, Any})
    parameters = smallify(spec)
    driver = if ADT isa DataType
        first(ADT.parameters)
    elseif haskey(parameters, "driver")
        Symbol(lowercase(parameters["driver"]))
    else
        @warn "$ADT for $(sprint(show, dataset.name)) has no driver!"
        :MISSING
    end
    if !(ADT isa DataType)
        ADT = ADT{driver}
    end
    ttype = let spec_type = get(parameters, "type", nothing)
        if isnothing(spec_type)
            supportedtypes(ADT, parameters, dataset)
        elseif spec_type isa Vector
            parse.(QualifiedType, spec_type)
        elseif spec_type isa String
            [parse(QualifiedType, spec_type)]
        else
            @warn "Invalid ADT type '$spec_type', ignoring"
        end
    end
    if isempty(ttype)
        @warn """Could not find any types that $ADT of $(sprint(show, dataset.name)) supports.
                 Consider adding a 'type' parameter."""
    end
    priority = get(parameters, "priority", DEFAULT_DATATRANSFORMER_PRIORITY)
    delete!(parameters, "driver")
    delete!(parameters, "type")
    delete!(parameters, "priority")
    @advise dataset identity(
        ADT(dataset, ttype, priority,
            dataset_parameters(dataset, Val(:extract), parameters)))
end

# function (ADT::Type{<:AbstractDataTransformer})(collection::DataCollection, spec::Dict{String, Any})
#     @advise fromspec(ADT, collection, spec)
# end

DataStorage{driver}(dataset::Union{DataSet, DataCollection},
                    type::Vector{<:QualifiedType}, priority::Int,
                    parameters::SmallDict{String, Any}) where {driver} =
                        DataStorage{driver, typeof(dataset)}(dataset, type, priority, parameters)

# ---------------
# DataCollection
# ---------------

DataCollection(name::Union{String, Nothing}=nothing; path::Union{String, Nothing}=nothing) =
    DataCollection(LATEST_DATA_CONFIG_VERSION, name, uuid4(), String[],
                   SmallDict{String, Any}(), DataSet[], path,
                   AdviceAmalgamation(String[]), Main)

function DataCollection(spec::Dict{String, Any}; path::Union{String, Nothing}=nothing, mod::Module=Base.Main)
    plugins::Vector{String} = get(get(spec, "config", Dict("config" => Dict())), "plugins", String[])
    AdviceAmalgamation(plugins)(fromspec, DataCollection, spec; path, mod)
end

"""
    fromspec(::Type{DataCollection}, spec::Dict{String, Any};
             path::Union{String, Nothing}=nothing, mod::Module=Base.Main)

Create a `DataCollection` from `spec`.

The `path` and `mod` keywords are used as the values for the correspanding
fields in the DataCollection.
"""
function fromspec(::Type{DataCollection}, spec::Dict{String, Any};
                  path::Union{String, Nothing}=nothing, mod::Module=Base.Main)
    version = get(spec, "data_config_version", LATEST_DATA_CONFIG_VERSION)
    if version != LATEST_DATA_CONFIG_VERSION
        throw(CollectionVersionMismatch(version))
    end
    name = @something(get(spec, "name", nothing),
                      if !isnothing(path)
                          toml_name = path |> basename |> splitext |> first
                          if toml_name != "Data"
                              toml_name
                          else
                              basename(dirname(path))
                          end
                      end,
                      string(gensym("unnamed"))[3:end])
    uuid = UUID(@something get(spec, "uuid", nothing) begin
                    @info "Data collection '$(something(name, "<unnamed>"))' had no UUID, one has been generated."
                    uuid4()
                end)
    plugins::Vector{String} = get(spec, "plugins", String[])
    parameters = get(spec, "config", Dict{String, Any}()) |> smallify
    unavailible_plugins = setdiff(plugins, getproperty.(PLUGINS, :name))
    if length(unavailible_plugins) > 0
        @warn string("The ", join(unavailible_plugins, ", ", ", and "),
                     " plugin", if length(unavailible_plugins) == 1
                         " is" else "s are" end,
                     " not availible at the time of loading '$name'.",
                     "\n It is highly recommended that all plugins are loaded",
                     " prior to DataCollections.")
    end
    collection = DataCollection(version, name, uuid, plugins,
                                parameters, DataSet[], path,
                                AdviceAmalgamation(plugins),
                                mod)
    # Construct the data sets
    datasets = copy(spec)
    for reservedname in DATA_CONFIG_RESERVED_ATTRIBUTES[:collection]
        delete!(datasets, reservedname)
    end
    for (name, dspecs) in datasets
        for dspec in if dspecs isa Vector dspecs else [dspecs] end
            push!(collection.datasets, DataSet(collection, name, dspec))
        end
    end
    @advise identity(collection)
end

# ---------------
# DataSet
# ---------------

function DataSet(collection::DataCollection, name::String, spec::Dict{String, Any})
    @advise fromspec(DataSet, collection, name, spec)
end

"""
    fromspec(::Type{DataSet}, collection::DataCollection, name::String, spec::Dict{String, Any})

Create a `DataSet` for `collection` called `name`, according to `spec`.
"""
function fromspec(::Type{DataSet}, collection::DataCollection, name::String, spec::Dict{String, Any})
    uuid = UUID(@something get(spec, "uuid", nothing) begin
                    @info "Data set '$name' had no UUID, one has been generated."
                    uuid4()
                end)
    parameters = smallify(spec)
    for reservedname in DATA_CONFIG_RESERVED_ATTRIBUTES[:dataset]
        delete!(parameters, reservedname)
    end
    dataset = DataSet(collection, name, uuid,
                      dataset_parameters(collection, Val(:extract), parameters),
                      DataStorage[], DataLoader[], DataWriter[])
    for (attr, afield, atype) in [("storage", :storage, DataStorage),
                                  ("loader", :loaders, DataLoader),
                                  ("writer", :writers, DataWriter)]
        specs = get(spec, attr, Dict{String, Any}[]) |>
            s -> if s isa Vector s else [s] end
        for aspec::Union{String, Dict{String, Any}} in specs
            push!(getfield(dataset, afield), atype(dataset, aspec))
        end
        sort!(getfield(dataset, afield), by=a->a.priority)
    end
    @advise identity(dataset)
end
