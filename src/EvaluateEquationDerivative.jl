module EvaluateEquationDerivativeModule

import LoopVectorization: @turbo, indices
import ..EquationModule: Node
import ..OperatorEnumModule: OperatorEnum
import ..UtilsModule: @return_on_false2, is_bad_array, vals, @maybe_turbo
import ..EquationUtilsModule: count_constants, index_constants, NodeIndex
import ..EvaluateEquationModule: deg0_eval

function assert_autodiff_enabled(operators::OperatorEnum)
    if operators.diff_binops === nothing && operators.diff_unaops === nothing
        error(
            "Found no differential operators. Did you forget to set `enable_autodiff=true` when creating the `OperatorEnum`?",
        )
    end
end

"""
    eval_diff_tree_array(tree::Node{T}, cX::AbstractMatrix{T}, operators::OperatorEnum, direction::Int)

Compute the forward derivative of an expression, using a similar
structure and optimization to eval_tree_array. `direction` is the index of a particular
variable in the expression. e.g., `direction=1` would indicate derivative with
respect to `x1`.

# Arguments

- `tree::Node`: The expression tree to evaluate.
- `cX::AbstractMatrix{T}`: The data matrix, with each column being a data point.
- `operators::OperatorEnum`: The operators used to create the `tree`. Note that `operators.enable_autodiff`
    must be `true`. This is needed to create the derivative operations.
- `direction::Int`: The index of the variable to take the derivative with respect to.

# Returns

- `(evaluation, derivative, complete)::Tuple{AbstractVector{T}, AbstractVector{T}, Bool}`: the normal evaluation,
    the derivative, and whether the evaluation completed as normal (or encountered a nan or inf).
"""
function eval_diff_tree_array(
    tree::Node{T},
    cX::AbstractMatrix{T},
    operators::OperatorEnum,
    direction::Int;
    turbo::Bool=false,
)::Tuple{AbstractVector{T},AbstractVector{T},Bool} where {T<:Real}
    assert_autodiff_enabled(operators)
    # TODO: Implement quick check for whether the variable is actually used
    # in this tree. Otherwise, return zero.
    evaluation, derivative, complete = _eval_diff_tree_array(
        tree, cX, operators, direction; turbo=turbo
    )
    @return_on_false2 complete evaluation derivative
    return evaluation, derivative, !(is_bad_array(evaluation) || is_bad_array(derivative))
end
function eval_diff_tree_array(
    tree::Node{T1},
    cX::AbstractMatrix{T2},
    operators::OperatorEnum,
    direction::Int;
    turbo::Bool=false,
) where {T1<:Real,T2<:Real}
    T = promote_type(T1, T2)
    @warn "Warning: eval_diff_tree_array received mixed types: tree=$(T1) and data=$(T2)."
    tree = convert(Node{T}, tree)
    cX = convert(AbstractMatrix{T}, cX)
    return eval_diff_tree_array(tree, cX, operators, direction)
end

function _eval_diff_tree_array(
    tree::Node{T},
    cX::AbstractMatrix{T},
    operators::OperatorEnum,
    direction::Int;
    turbo::Bool,
)::Tuple{AbstractVector{T},AbstractVector{T},Bool} where {T<:Real}
    if tree.degree == 0
        diff_deg0_eval(tree, cX, operators, direction)
    elseif tree.degree == 1
        diff_deg1_eval(tree, cX, vals[tree.op], operators, direction; turbo=turbo)
    else
        diff_deg2_eval(tree, cX, vals[tree.op], operators, direction; turbo=turbo)
    end
end

function diff_deg0_eval(
    tree::Node{T}, cX::AbstractMatrix{T}, operators::OperatorEnum, direction::Int
)::Tuple{AbstractVector{T},AbstractVector{T},Bool} where {T<:Real}
    n = size(cX, 2)
    const_part = deg0_eval(tree, cX, operators)[1]
    derivative_part =
        ((!tree.constant) && tree.feature == direction) ? ones(T, n) : zeros(T, n)
    return (const_part, derivative_part, true)
end

function diff_deg1_eval(
    tree::Node{T},
    cX::AbstractMatrix{T},
    ::Val{op_idx},
    operators::OperatorEnum,
    direction::Int;
    turbo::Bool,
)::Tuple{AbstractVector{T},AbstractVector{T},Bool} where {T<:Real,op_idx}
    n = size(cX, 2)
    (cumulator, dcumulator, complete) = eval_diff_tree_array(
        tree.l, cX, operators, direction; turbo=turbo
    )
    @return_on_false2 complete cumulator dcumulator

    op = operators.unaops[op_idx]
    diff_op = operators.diff_unaops[op_idx]

    # TODO - add type assertions to get better speed:
    @maybe_turbo turbo for j in indices((cumulator, dcumulator), (1, 1))
        x = op(cumulator[j])::T
        dx = diff_op(cumulator[j])::T * dcumulator[j]

        cumulator[j] = x
        dcumulator[j] = dx
    end
    return (cumulator, dcumulator, true)
end

function diff_deg2_eval(
    tree::Node{T},
    cX::AbstractMatrix{T},
    ::Val{op_idx},
    operators::OperatorEnum,
    direction::Int;
    turbo::Bool,
)::Tuple{AbstractVector{T},AbstractVector{T},Bool} where {T<:Real,op_idx}
    n = size(cX, 2)
    (cumulator, dcumulator, complete) = eval_diff_tree_array(
        tree.l, cX, operators, direction
    )
    @return_on_false2 complete cumulator dcumulator
    (array2, dcumulator2, complete2) = eval_diff_tree_array(
        tree.r, cX, operators, direction
    )
    @return_on_false2 complete2 array2 dcumulator2

    op = operators.binops[op_idx]
    diff_op = operators.diff_binops[op_idx]

    @maybe_turbo turbo for j in indices(
        (cumulator, dcumulator, array2, dcumulator2), (1, 1, 1, 1)
    )
        x = op(cumulator[j], array2[j])

        first, second = diff_op(cumulator[j], array2[j])
        dx = first * dcumulator[j] + second * dcumulator2[j]

        cumulator[j] = x
        dcumulator[j] = dx
    end
    return (cumulator, dcumulator, true)
end

"""
    eval_grad_tree_array(tree::Node{T}, cX::AbstractMatrix{T}, operators::OperatorEnum; variable::Bool=false)

Compute the forward-mode derivative of an expression, using a similar
structure and optimization to eval_tree_array. `variable` specifies whether
we should take derivatives with respect to features (i.e., cX), or with respect
to every constant in the expression.

# Arguments

- `tree::Node{T}`: The expression tree to evaluate.
- `cX::AbstractMatrix{T}`: The data matrix, with each column being a data point.
- `operators::OperatorEnum`: The operators used to create the `tree`. Note that `operators.enable_autodiff`
    must be `true`. This is needed to create the derivative operations.
- `variable::Bool`: Whether to take derivatives with respect to features (i.e., `cX` - with `variable=true`),
    or with respect to every constant in the expression (`variable=false`).

# Returns

- `(evaluation, gradient, complete)::Tuple{AbstractVector{T}, AbstractMatrix{T}, Bool}`: the normal evaluation,
    the gradient, and whether the evaluation completed as normal (or encountered a nan or inf).
"""
function eval_grad_tree_array(
    tree::Node{T},
    cX::AbstractMatrix{T},
    operators::OperatorEnum;
    variable::Bool=false,
    turbo::Bool=false,
)::Tuple{AbstractVector{T},AbstractMatrix{T},Bool} where {T<:Real}
    assert_autodiff_enabled(operators)
    n = size(cX, 2)
    if variable
        n_gradients = size(cX, 1)
    else
        n_gradients = count_constants(tree)
    end
    index_tree = index_constants(tree, 0)
    return eval_grad_tree_array(
        tree, n, n_gradients, index_tree, cX, operators, Val(variable); turbo=turbo
    )
end

function eval_grad_tree_array(
    tree::Node{T},
    n::Int,
    n_gradients::Int,
    index_tree::NodeIndex,
    cX::AbstractMatrix{T},
    operators::OperatorEnum,
    ::Val{variable};
    turbo::Bool,
)::Tuple{AbstractVector{T},AbstractMatrix{T},Bool} where {T<:Real,variable}
    evaluation, gradient, complete = _eval_grad_tree_array(
        tree, n, n_gradients, index_tree, cX, operators, Val(variable); turbo=turbo
    )
    @return_on_false2 complete evaluation gradient
    return evaluation, gradient, !(is_bad_array(evaluation) || is_bad_array(gradient))
end

function eval_grad_tree_array(
    tree::Node{T1},
    cX::AbstractMatrix{T2},
    operators::OperatorEnum;
    variable::Bool=false,
    turbo::Bool=false,
) where {T1<:Real,T2<:Real}
    T = promote_type(T1, T2)
    return eval_grad_tree_array(
        convert(Node{T}, tree),
        convert(AbstractMatrix{T}, cX),
        operators;
        variable=variable,
        turbo=turbo,
    )
end

function _eval_grad_tree_array(
    tree::Node{T},
    n::Int,
    n_gradients::Int,
    index_tree::NodeIndex,
    cX::AbstractMatrix{T},
    operators::OperatorEnum,
    ::Val{variable};
    turbo::Bool,
)::Tuple{AbstractVector{T},AbstractMatrix{T},Bool} where {T<:Real,variable}
    if tree.degree == 0
        grad_deg0_eval(tree, n, n_gradients, index_tree, cX, operators, Val(variable))
    elseif tree.degree == 1
        grad_deg1_eval(
            tree,
            n,
            n_gradients,
            index_tree,
            cX,
            vals[tree.op],
            operators,
            Val(variable);
            turbo=turbo,
        )
    else
        grad_deg2_eval(
            tree,
            n,
            n_gradients,
            index_tree,
            cX,
            vals[tree.op],
            operators,
            Val(variable);
            turbo=turbo,
        )
    end
end

function grad_deg0_eval(
    tree::Node{T},
    n::Int,
    n_gradients::Int,
    index_tree::NodeIndex,
    cX::AbstractMatrix{T},
    operators::OperatorEnum,
    ::Val{variable},
)::Tuple{AbstractVector{T},AbstractMatrix{T},Bool} where {T<:Real,variable}
    const_part = deg0_eval(tree, cX, operators)[1]

    if variable == tree.constant
        return (const_part, zeros(T, n_gradients, n), true)
    end

    index = variable ? tree.feature : index_tree.constant_index
    derivative_part = zeros(T, n_gradients, n)
    derivative_part[index, :] .= one(T)
    return (const_part, derivative_part, true)
end

function grad_deg1_eval(
    tree::Node{T},
    n::Int,
    n_gradients::Int,
    index_tree::NodeIndex,
    cX::AbstractMatrix{T},
    ::Val{op_idx},
    operators::OperatorEnum,
    ::Val{variable};
    turbo::Bool,
)::Tuple{AbstractVector{T},AbstractMatrix{T},Bool} where {T<:Real,op_idx,variable}
    (cumulator, dcumulator, complete) = eval_grad_tree_array(
        tree.l, n, n_gradients, index_tree.l, cX, operators, Val(variable); turbo=turbo
    )
    @return_on_false2 complete cumulator dcumulator

    op = operators.unaops[op_idx]
    diff_op = operators.diff_unaops[op_idx]

    @maybe_turbo turbo for j in indices((cumulator, dcumulator), (1, 2))
        x = op(cumulator[j])::T
        dx = diff_op(cumulator[j])

        cumulator[j] = x
        for k in indices(dcumulator, 1)
            dcumulator[k, j] = dx * dcumulator[k, j]
        end
    end
    return (cumulator, dcumulator, true)
end

function grad_deg2_eval(
    tree::Node{T},
    n::Int,
    n_gradients::Int,
    index_tree::NodeIndex,
    cX::AbstractMatrix{T},
    ::Val{op_idx},
    operators::OperatorEnum,
    ::Val{variable};
    turbo::Bool,
)::Tuple{AbstractVector{T},AbstractMatrix{T},Bool} where {T<:Real,op_idx,variable}
    (cumulator1, dcumulator1, complete) = eval_grad_tree_array(
        tree.l, n, n_gradients, index_tree.l, cX, operators, Val(variable); turbo=turbo
    )
    @return_on_false2 complete cumulator1 dcumulator1
    (cumulator2, dcumulator2, complete2) = eval_grad_tree_array(
        tree.r, n, n_gradients, index_tree.r, cX, operators, Val(variable); turbo=turbo
    )
    @return_on_false2 complete2 cumulator1 dcumulator1

    op = operators.binops[op_idx]
    diff_op = operators.diff_binops[op_idx]

    @maybe_turbo turbo for j in indices(
        (cumulator1, cumulator2, dcumulator1, dcumulator2), (1, 1, 2, 2)
    )
        c1 = cumulator1[j]
        c2 = cumulator2[j]
        x = op(c1, c2)::T
        dx1, dx2 = diff_op(c1, c2)::Tuple{T,T}
        cumulator1[j] = x
        for k in indices((dcumulator1, dcumulator2), (1, 1))
            dcumulator1[k, j] = dx1 * dcumulator1[k, j] + dx2 * dcumulator2[k, j]
        end
    end

    return (cumulator1, dcumulator1, true)
end

end
