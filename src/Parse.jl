module ParseModule

using ..NodeModule: AbstractExpressionNode, Node
using ..OperatorEnumModule: AbstractOperatorEnum
using ..OperatorEnumConstructionModule: empty_all_globals!
using ..ExpressionModule: AbstractExpression, Expression

"""
    @parse_expression(expr; operators, variable_names, node_type=Node, evaluate_on=[])

Parse a symbolic expression `expr` into a computational graph where nodes represent operations or variables.

## Arguments

- `expr`: An expression to parse into an `AbstractExpression`.

## Keyword Arguments

- `operators`: An instance of `OperatorEnum` specifying the available unary and binary operators.
- `variable_names`: A list of variable names as strings or symbols that are allowed in the expression.
- `evaluate_on`: A list of external functions to evaluate explicitly when encountered.
- `node_type`: The type of the nodes in the resulting expression tree. Defaults to `Node`.

## Usage

The macro is used to convert a high-level symbolic expression into a structured expression tree that can be manipulated or evaluated. Here are some examples of how to use `parse_expression`:

### Parsing from a custom operator

```julia
julia> my_custom_op(x, y) = x + y^3;

julia> operators = OperatorEnum(binary_operators=[+, -, *, my_custom_op], unary_operators=[sin]);

julia> ex = @parse_expression my_custom_op(x, sin(y) + 0.3) operators=operators variable_names=["x", "y"]
my_custom_op(x, sin(y) + 0.3)

julia> typeof(ex)
Expression{Float64, Node{Float64}, OperatorEnum{Tuple{typeof(+), typeof(-), typeof(*), typeof(my_custom_op)}, Tuple{typeof(sin)}}, Vector{String}}

julia> typeof(ex.tree)
Node{Float64}

julia> ex(ones(2, 1))
1-element Vector{Float64}:
 2.487286478935302
```

### Handling expressions with symbolic variable names

```julia
julia> ex = @parse_expression(
            cos(exp(α - 1)),
            operators=OperatorEnum(binary_operators=[-], unary_operators=[cos, exp]),
            variable_names=[:α],
            node_type=GraphNode
        )
cos(exp(α))

julia> typeof(ex.tree)
GraphNode{Float32}
```

### Using external functions and variables

```
julia> c = 5.0
5.0

julia> show_type(x) = (@show typeof(x); x);

julia> ex = @parse_expression(
           c * 2.5 - show_type(cos(x)),
           operators = OperatorEnum(; binary_operators=[*, -], unary_operators=[cos]),
           variable_names = [:x],
           evaluate_on = [show_type],
       )
typeof(x) = Node{Float32}
(5.0 * 2.5) - cos(x)
```
"""
macro parse_expression(ex, kws...)
    (; operators, variable_names, node_type, evaluate_on) = _parse_kws(kws)
    calling_module = __module__
    return esc(
        :($(parse_expression)(
            $(Meta.quot(ex));
            operators=$operators,
            variable_names=$variable_names,
            node_type=$node_type,
            evaluate_on=$evaluate_on,
            calling_module=$calling_module,
        )),
    )
end

function _parse_kws(kws)
    # Initialize default values for operators and variable_names
    operators = nothing
    variable_names = nothing
    node_type = Node
    evaluate_on = nothing

    # Iterate over keyword arguments to extract operators and variable_names
    for kw in kws
        if kw isa Symbol
            if kw == :operators
                operators = kw
                continue
            elseif kw == :variable_names
                variable_names = kw
                continue
            elseif kw == :node_type
                node_type = kw
                continue
            elseif kw == :evaluate_on
                evaluate_on = kw
                continue
            end
        elseif kw isa Expr && kw.head == :(=)
            if kw.args[1] == :operators
                operators = kw.args[2]
                continue
            elseif kw.args[1] == :variable_names
                variable_names = kw.args[2]
                continue
            elseif kw.args[1] == :node_type
                node_type = kw.args[2]
                continue
            elseif kw.args[1] == :evaluate_on
                evaluate_on = kw.args[2]
                continue
            end
        end
        throw(ArgumentError("Unrecognized argument: `$kw`"))
    end

    # Ensure that operators and variable_names are provided
    @assert operators !== nothing "The 'operators' keyword argument must be provided."
    @assert variable_names !== nothing "The 'variable_names' keyword argument must be provided."
    return (; operators, variable_names, node_type, evaluate_on)
end

"""Parse an expression Julia `Expr` object."""
function parse_expression(
    ex;
    calling_module,
    operators::AbstractOperatorEnum,
    variable_names::AbstractVector,
    node_type::Type{N}=Node,
    evaluate_on::Union{Nothing,AbstractVector}=nothing,
) where {N<:AbstractExpressionNode}
    empty_all_globals!()
    let variable_names = if eltype(variable_names) isa AbstractString
            variable_names
        else
            string.(variable_names)
        end
        tree = _parse_expression(
            ex, operators, variable_names, N, evaluate_on, calling_module
        )

        return Expression(tree, (; operators, variable_names))
    end
end

function _parse_expression(
    ex::Expr,
    operators::AbstractOperatorEnum,
    variable_names::AbstractVector{<:AbstractString},
    ::Type{N},
    evaluate_on::Union{Nothing,AbstractVector},
    calling_module,
) where {N<:AbstractExpressionNode}
    ex.head != :call && throw(
        ArgumentError(
            "Unrecognized expression type: `Expr(:$(ex.head), ...)`. " *
            "Please only a function call or a variable.",
        ),
    )
    args = ex.args
    func = try
        Core.eval(calling_module, first(ex.args))::Function
    catch
        throw(
            ArgumentError(
                "Failed to evaluate function `$(first(ex.args))` within `$(calling_module)`. " *
                "Make sure the function is defined in that module.",
            ),
        )
        () -> ()
    end
    return _parse_expression(
        func, args, operators, variable_names, N, evaluate_on, calling_module
    )
end
function _parse_expression(
    func::F,
    args,
    operators::AbstractOperatorEnum,
    variable_names::AbstractVector{<:AbstractString},
    ::Type{N},
    evaluate_on::Union{Nothing,AbstractVector},
    calling_module,
)::N where {F<:Function,N<:AbstractExpressionNode}
    if length(args) == 2 && func ∈ operators.unaops
        # Regular unary operator
        op = findfirst(==(func), operators.unaops)::Int
        return N(;
            op=op::Int,
            l=_parse_expression(
                args[2], operators, variable_names, N, evaluate_on, calling_module
            ),
        )
    elseif length(args) == 3 && func ∈ operators.binops
        # Regular binary operator
        op = findfirst(==(func), operators.binops)::Int
        return N(;
            op=op::Int,
            l=_parse_expression(
                args[2], operators, variable_names, N, evaluate_on, calling_module
            ),
            r=_parse_expression(
                args[3], operators, variable_names, N, evaluate_on, calling_module
            ),
        )
    elseif length(args) > 3 && func in (+, -, *) && func ∈ operators.binops
        # Either + or - but used with more than two arguments
        op = findfirst(==(func), operators.binops)::Int
        inner = N(;
            op=op::Int,
            l=_parse_expression(
                args[2], operators, variable_names, N, evaluate_on, calling_module
            ),
            r=_parse_expression(
                args[3], operators, variable_names, N, evaluate_on, calling_module
            ),
        )
        for arg in args[4:end]
            inner = N(;
                op=op::Int,
                l=inner,
                r=_parse_expression(
                    arg, operators, variable_names, N, evaluate_on, calling_module
                ),
            )
        end
        return inner
    elseif evaluate_on !== nothing && func in evaluate_on
        # External function
        func(
            map(
                arg -> _parse_expression(
                    arg, operators, variable_names, N, evaluate_on, calling_module
                ),
                args[2:end],
            )...,
        )
    else
        matching_s = let
            s = if length(args) == 2
                "`" * string(operators.unaops) * "`"
            elseif length(args) == 3
                "`" * string(operators.binops) * "`"
            else
                ""
            end
            if evaluate_on !== nothing
                if length(s) > 0
                    s *= " or " * "`" * string(evaluate_on) * "`"
                else
                    s *= "`" * string(evaluate_on) * "`"
                end
            end
            s
        end
        throw(
            ArgumentError(
                "Unrecognized operator: `$(func)` with no matches in $(matching_s). " *
                "If you meant to call an external function, please pass the function to the `evaluate_on` keyword argument.",
            ),
        )
        N()
    end
end
function _parse_expression(
    ex::Symbol,
    operators::AbstractOperatorEnum,
    variable_names::AbstractVector,
    ::Type{N},
    evaluate_on::Union{Nothing,AbstractVector},
    calling_module,
)::N where {N<:AbstractExpressionNode}
    i = findfirst(==(string(ex)), variable_names)
    if i !== nothing
        return N(; feature=i)
    else
        # If symbol not found in variable_names, then try interpolating
        evaluated = Core.eval(calling_module, ex)
        return _parse_expression(
            evaluated, operators, variable_names, N, evaluate_on, calling_module
        )
    end
end
function _parse_expression(
    val,
    ::AbstractOperatorEnum,
    ::AbstractVector,
    ::Type{N},
    ::Union{Nothing,AbstractVector},
    _,
)::N where {N<:AbstractExpressionNode}
    if val isa AbstractExpression
        throw(
            ArgumentError(
                "Cannot parse an expression as a value in another expression. " *
                "Instead, you should unpack it into the tree (and make sure they " *
                "have the same metadata where relevant).",
            ),
        )
    elseif val isa AbstractExpressionNode
        return val
    end
    return N(; val)
end

end
