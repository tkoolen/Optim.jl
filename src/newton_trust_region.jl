#
# Check whether we are in the "hard case".
#
# Args:
#  H_eigv: The eigenvalues of H, low to high
#  qg: The inner product of the eigenvalues and the gradient in the same order
#
# Returns:
#  hard_case: Whether it is a candidate for the hard case
#  lambda_1_multiplicity: The number of times the lowest eigenvalue is repeated,
#                         which is only correct if hard_case is true.
function check_hard_case_candidate(H_eigv, qg)
    @assert length(H_eigv) == length(qg)
    if H_eigv[1] >= 0
        # The hard case is only when the smallest eigenvalue is negative.
        return false, 1
    end
    hard_case = true
    lambda_index = 1
    hard_case_check_done = false
    while !hard_case_check_done
        if lambda_index > length(H_eigv)
            hard_case_check_done = true
        elseif abs(H_eigv[1] - H_eigv[lambda_index]) > 1e-10
            # The eigenvalues are reported in order.
            hard_case_check_done = true
        else
            if abs(qg[lambda_index]) > 1e-10
                hard_case_check_done = true
                hard_case = false
            end
            lambda_index += 1
        end
    end

    hard_case, lambda_index - 1
end

# Choose a point in the trust region for the next step using
# the interative (nearly exact) method of section 4.3 of Nocedal and Wright.
# This is appropriate for Hessians that you factorize quickly.
#
# Args:
#  gr: The gradient
#  H:  The Hessian
#  delta:  The trust region size, ||s|| <= delta
#  s: Memory allocated for the step size, updated in place
#  tolerance: The convergence tolerance for root finding
#  max_iters: The maximum number of root finding iterations
#
# Returns:
#  m - The numeric value of the quadratic minimization.
#  interior - A boolean indicating whether the solution was interior
#  lambda - The chosen regularizing quantity
#  hard_case - Whether or not it was a "hard case" as described by N&W
#  reached_solution - Whether or not a solution was reached (as opposed to
#      terminating early due to max_iters)
function solve_tr_subproblem!{T}(gr::Vector{T},
                                 H::Matrix{T},
                                 delta::T,
                                 s::Vector{T};
                                 tolerance=1e-10,
                                 max_iters=5)
    n = length(gr)
    delta_sq = delta^2

    @assert n == length(s)
    @assert (n, n) == size(H)
    @assert max_iters >= 1

    # Note that currently the eigenvalues are only sorted if H is perfectly
    # symmetric.  (Julia issue #17093)
    H_eig = eigfact(Symmetric(H))
    min_H_ev, max_H_ev = H_eig[:values][1], H_eig[:values][n]
    H_ridged = copy(H)

    # Cache the inner products between the eigenvectors and the gradient.
    qg = Array(T, n)
    for i=1:n
        qg[i] = vecdot(H_eig[:vectors][:, i], gr)
    end

    # Function 4.39 in N&W
    function p_sq_norm(lambda, min_i)
        p_sum = 0.
        for i = min_i:n
            p_sum += qg[i]^2 / (lambda + H_eig[:values][i])^2
        end
        p_sum
    end

    # These values describe the outcome of the subproblem.  They will be
    # set below and returned at the end.
    interior = true
    hard_case = false
    reached_solution = true

    if min_H_ev >= 1e-8 && p_sq_norm(0.0, 1) <= delta_sq
        # No shrinkage is necessary: -(H \ gr) is the minimizer
        interior = true
        reached_solution = true
        s[:] = -(H_eig[:vectors] ./ H_eig[:values]') * H_eig[:vectors]' * gr
        lambda = 0.0
    else
        interior = false

        # The hard case is when the gradient is orthogonal to all
        # eigenvectors associated with the lowest eigenvalue.
        hard_case_candidate, min_H_ev_multiplicity =
            check_hard_case_candidate(H_eig[:values], qg)

        # Solutions smaller than this lower bound on lambda are not allowed:
        # they don't ridge H enough to make H_ridge PSD.
        lambda_lb = -min_H_ev + max(1e-8, 1e-8 * (max_H_ev - min_H_ev))
        lambda = lambda_lb

        hard_case = false
        if hard_case_candidate
            # The "hard case". lambda is taken to be -min_H_ev and we only need
            # to find a multiple of an orthogonal eigenvector that lands the
            # iterate on the boundary.

            # Formula 4.45 in N&W
            p_lambda2 = p_sq_norm(lambda, min_H_ev_multiplicity + 1)
            if p_lambda2 > delta_sq
                # Then we can simply solve using root finding.
                # Set a starting point between the minimum and largest eigenvalues.
                lambda = lambda_lb + 0.01 * (max_H_ev - lambda_lb)
            else
                hard_case = true
                reached_solution = true

                tau = sqrt(delta_sq - p_lambda2)

                # I don't think it matters which eigenvector we pick so take
                # the first.
                for i=1:n
                    s[i] = tau * H_eig[:vectors][i, 1]
                    for k=(min_H_ev_multiplicity + 1):n
                        s[i] = s[i] +
                               qg[k] * H_eig[:vectors][i, k] / (H_eig[:values][k] + lambda)
                    end
                end
            end
        end

        if !hard_case
            # Algorithim 4.3 of N&W, with s insted of p_l for consistency with
            # Optim.jl

            for i=1:n
                H_ridged[i, i] = H[i, i] + lambda
            end

            reached_solution = false
            for iter in 1:max_iters
                lambda_previous = lambda

                # Version 0.5 requires an exactly symmetric matrix, but
                # version 0.4 does not have this function signature for chol().
                R = VERSION < v"0.5-" ? chol(H_ridged): chol(Hermitian(H_ridged))
                s[:] = -R \ (R' \ gr)
                q_l = R' \ s
                norm2_s = vecdot(s, s)
                lambda_update = norm2_s * (sqrt(norm2_s) - delta) / (delta * vecdot(q_l, q_l))
                lambda += lambda_update

                # Check that lambda is not less than lambda_lb, and if so, go
                # half the way to lambda_lb.
                if lambda < (lambda_lb + 1e-8)
                    lambda = 0.5 * (lambda_previous - lambda_lb) + lambda_lb
                end

                for i=1:n
                    H_ridged[i, i] = H[i, i] + lambda
                end

                if abs(lambda - lambda_previous) < tolerance
                    reached_solution = true
                    break
                end
            end
        end
    end

    m = vecdot(gr, s) + 0.5 * vecdot(s, H * s)

    return m, interior, lambda, hard_case, reached_solution
end

immutable NewtonTrustRegion{T <: Real} <: Optimizer
    initial_delta::T
    delta_hat::T
    eta::T
    rho_lower::T
    rho_upper::T
end

NewtonTrustRegion(; initial_delta::Real = 1.0,
                    delta_hat::Real = 100.0,
                    eta::Real = 0.1,
                    rho_lower::Real = 0.25,
                    rho_upper::Real = 0.75) =
                    NewtonTrustRegion(initial_delta, delta_hat, eta, rho_lower, rho_upper)


type NewtonTrustRegionState{T}
    @add_generic_fields()
    x_previous::Array{T}
    g::Array{T}
    g_previous::Array{T}
    f_x_previous::T
    s::Array{T}
    H
    hard_case
    reached_subproblem_solution
    interior
    delta::T
    lambda
    eta
    rho
    d
end

function initial_state{T}(method::NewtonTrustRegion, options, d, initial_x::Array{T})
      n = length(initial_x)
    # Maintain current gradient in gr
    @assert(method.delta_hat > 0, "delta_hat must be strictly positive")
    @assert(0 < method.initial_delta < method.delta_hat, "delta must be in (0, delta_hat)")
    @assert(0 <= method.eta < method.rho_lower, "eta must be in [0, rho_lower)")
    @assert(method.rho_lower < method.rho_upper, "must have rho_lower < rho_upper")
    @assert(method.rho_lower >= 0.)
    # Keep track of trust region sizes
    delta = copy(method.initial_delta)

    # Record attributes of the subproblem in the trace.
    hard_case = false
    reached_subproblem_solution = true
    interior = true
    lambda = NaN
    g = Array(T, n)
    f_x_previous, f_x = NaN, d.fg!(initial_x, g)
    f_calls, g_calls = 1, 1
    H = Array(T, n, n)
    d.h!(initial_x, H)
    h_calls = 1

    NewtonTrustRegionState("Newton's Method (Trust Region)", # Store string with model name in state.method
                         length(initial_x),
                         copy(initial_x), # Maintain current state in state.x
                         f_x, # Store current f in state.f_x
                         f_calls, # Track f calls in state.f_calls
                         g_calls, # Track g calls in state.g_calls
                         h_calls,
                         copy(initial_x), # Maintain current state in state.x_previous
                         g, # Store current gradient in state.g
                         copy(g), # Store previous gradient in state.g_previous
                         T(NaN), # Store previous f in state.f_x_previous
                         similar(initial_x), # Maintain current search direction in state.s
                         H,
                         hard_case,
                         reached_subproblem_solution,
                         interior,
                         T(delta),
                         lambda,
                         method.eta, # eta
                         0., # state.rho
                         d) # Maintain a cache for line search results in state.lsr
end


function update_state!{T}(d, state::NewtonTrustRegionState{T}, method::NewtonTrustRegion)


    # Find the next step direction.
    m, state.interior, state.lambda, state.hard_case, state.reached_subproblem_solution =
        solve_tr_subproblem!(state.g, state.H, state.delta, state.s)

    # Maintain a record of previous position
    copy!(state.x_previous, state.x)

    # Update current position
    for i in 1:state.n
        @inbounds state.x[i] = state.x[i] + state.s[i]
    end

    # Update the function value and gradient
    copy!(state.g_previous, state.g)
    state.f_x_previous, state.f_x = state.f_x, d.fg!(state.x, state.g)
    state.f_calls, state.g_calls = state.f_calls + 1, state.g_calls + 1

    # Update the trust region size based on the discrepancy between
    # the predicted and actual function values.  (Algorithm 4.1 in N&W)
    f_x_diff = state.f_x_previous - state.f_x
    if abs(m) <= eps(T)
        # This should only happen when the step is very small, in which case
        # we should accept the step and assess_convergence().
        state.rho = 1.0
    elseif m > 0
        # This can happen if the trust region radius is too large and the
        # Hessian is not positive definite.  We should shrink the trust
        # region.
        state.rho = method.rho_lower - 1.0
    else
        state.rho = f_x_diff / (0 - m)
    end

    if state.rho < method.rho_lower
        state.delta *= 0.25
    elseif (state.rho > method.rho_upper) && (!state.interior)
        state.delta = min(2 * state.delta, method.delta_hat)
    else
        # else leave delta unchanged.
    end

    if state.rho <= state.eta
        # The improvement is too small and we won't take it.

        # If you reject an interior solution, make sure that the next
        # delta is smaller than the current step.  Otherwise you waste
        # steps reducing delta by constant factors while each solution
        # will be the same.
        x_diff = state.x - state.x_previous
        delta = 0.25 * sqrt(vecdot(x_diff, x_diff))

        state.f_x = state.f_x_previous
        copy!(state.x, state.x_previous)
        copy!(state.g, state.g_previous)
    end

    false
end