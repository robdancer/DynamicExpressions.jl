"""Test if we can create a multi-expression expression type."""

using Test
using DynamicExpressions
using DynamicExpressions: DynamicExpressions as DE
using DynamicExpressions: Metadata

struct MultiScalarExpression{T,TREES<:NamedTuple,D<:NamedTuple} <: AbstractExpression{T}
    trees::TREES
    metadata::Metadata{D}

    """
    Create a multi-expression expression type.

    The `tree_factory` is a function that takes the trees by keyword argument,
    and stitches them together into a single tree (for printing or evaluation).
    """
    function MultiScalarExpression(
        trees::NamedTuple; tree_factory::F, operators, variable_names
    ) where {F<:Function}
        T = eltype(first(values(trees)))
        @assert all(t -> eltype(t) == T, values(trees))
        metadata = (; tree_factory, operators, variable_names)
        return new{T,typeof(trees),typeof(metadata)}(trees, Metadata(metadata))
    end
end

operators = OperatorEnum(; binary_operators=[+, -, *, /], unary_operators=[sin, cos, exp])
variable_names = ["a", "b", "c"]

ex1 = @parse_expression(c * 2.5 - cos(a), operators, variable_names)
ex2 = @parse_expression(b * b * b + c / 0.2, operators, variable_names)

multi_ex = MultiScalarExpression(
    (; f=ex1.tree, g=ex2.tree);
    tree_factory=(; f, g) -> Node(; op=1, l=f, r=g),
    # TODO: Can we build the tree factory from another expression maybe?
    # TODO: Can we have a custom evaluation routine here, to enable aggregations in the middle part?
    operators,
    variable_names,
)

# Verify that the unimplemented methods raise an error
if VERSION >= v"1.9"
    @test_throws "`get_operators` function must be implemented for" DE.get_operators(
        multi_ex, nothing
    )
    @test_throws "`get_variable_names` function must be implemented for" DE.get_variable_names(
        multi_ex, nothing
    )
    @test_throws "`get_tree` function must be implemented for" DE.get_tree(multi_ex)
    @test_throws "`copy` function must be implemented for" copy(multi_ex)
    @test_throws "`hash` function must be implemented for" hash(multi_ex, UInt(0))
    @test_throws "`==` function must be implemented for" multi_ex == multi_ex
end

tree_factory(f::F, trees) where {F} = f(; trees...)
function DE.get_tree(ex::MultiScalarExpression)
    # `tree_factory` should stitch the nodes together
    return tree_factory(ex.metadata.tree_factory, ex.trees)
end
function DE.get_operators(ex::MultiScalarExpression, operators)
    return operators === nothing ? ex.metadata.operators : operators
end
function DE.get_variable_names(ex::MultiScalarExpression, variable_names)
    return variable_names === nothing ? ex.metadata.variable_names : variable_names
end

s = sprint((io, ex) -> show(io, MIME"text/plain"(), ex), multi_ex)

@test s == "((c * 2.5) - cos(a)) + (((b * b) * b) + (c / 0.2))"

s = sprint((io, ex) -> print_tree(io, ex), multi_ex)

@test s == "((c * 2.5) - cos(a)) + (((b * b) * b) + (c / 0.2))\n"
