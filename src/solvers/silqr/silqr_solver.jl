export
    iLQRSolverOptions,
    iLQRSolver


@with_kw mutable struct iLQRStats{T}
    iterations::Int = 0
    cost::Vector{T} = [0.]
    dJ::Vector{T} = [0.]
    gradient::Vector{T} = [0.]
    dJ_zero_counter::Int = 0
end

function reset!(stats::iLQRStats, N=0)
    stats.iterations = 0
    stats.cost = zeros(N)
    stats.dJ = zeros(N)
    stats.gradient = zeros(N)
    stats.dJ_zero_counter = 0
end


"""$(TYPEDEF)
Solver options for the iterative LQR (iLQR) solver.
$(FIELDS)
"""
@with_kw mutable struct iLQRSolverOptions{T} <: AbstractSolverOptions{T}
    # Options

    "Print summary at each iteration."
    verbose::Bool=false

    "Live plotting."
    live_plotting::Symbol=:off # :state, :control

    "dJ < ϵ, cost convergence criteria for unconstrained solve or to enter outerloop for constrained solve."
    cost_tolerance::T = 1.0e-4

    "gradient type: :todorov, :feedforward."
    gradient_type::Symbol = :todorov

    "gradient_norm < ϵ, gradient norm convergence criteria."
    gradient_norm_tolerance::T = 1.0e-5

    "iLQR iterations."
    iterations::Int = 300

    "restricts the total number of times a forward pass fails, resulting in regularization, before exiting."
    dJ_counter_limit::Int = 10

    "use square root method backward pass for numerical conditioning."
    square_root::Bool = false

    "forward pass approximate line search lower bound, 0 < line_search_lower_bound < line_search_upper_bound."
    line_search_lower_bound::T = 1.0e-8

    "forward pass approximate line search upper bound, 0 < line_search_lower_bound < line_search_upper_bound < ∞."
    line_search_upper_bound::T = 10.0

    "maximum number of backtracking steps during forward pass line search."
    iterations_linesearch::Int = 20

    # Regularization
    "initial regularization."
    bp_reg_initial::T = 0.0

    "regularization scaling factor."
    bp_reg_increase_factor::T = 1.6

    "maximum regularization value."
    bp_reg_max::T = 1.0e8

    "minimum regularization value."
    bp_reg_min::T = 1.0e-8

    "type of regularization- control: () + ρI, state: (S + ρI); see Synthesis and Stabilization of Complex Behaviors through Online Trajectory Optimization."
    bp_reg_type::Symbol = :control

    "additive regularization when forward pass reaches max iterations."
    bp_reg_fp::T = 10.0

    # square root backward pass options:
    "type of matrix inversion for bp sqrt step."
    bp_sqrt_inv_type::Symbol = :pseudo

    "initial regularization for square root method."
    bp_reg_sqrt_initial::T = 1.0e-6

    "regularization scaling factor for square root method."
    bp_reg_sqrt_increase_factor::T = 10.0

    # Solver Numerical Limits
    "maximum cost value, if exceded solve will error."
    max_cost_value::T = 1.0e8

    "maximum state value, evaluated during rollout, if exceded solve will error."
    max_state_value::T = 1.0e8

    "maximum control value, evaluated during rollout, if exceded solve will error."
    max_control_value::T = 1.0e8

    log_level::Base.CoreLogging.LogLevel = InnerLoop
end


"""$(TYPEDEF)
iLQR is an unconstrained indirect method for trajectory optimization that parameterizes only the controls and enforces strict dynamics feasibility at every iteration by simulating forward the dynamics with an LQR feedback controller.
The main algorithm consists of two parts:
1) a backward pass that uses Differential Dynamic Programming to compute recursively a quadratic approximation of the cost-to-go, along with linear feedback and feed-forward gain matrices, `K` and `d`, respectively, for an LQR tracking controller, and
2) a forward pass that uses the gains `K` and `d` to simulate forward the full nonlinear dynamics with feedback.
"""
struct iLQRSolver{T,I<:QuadratureRule,L,O,n,m,L1,D,F,E1,E2,A} <: UnconstrainedSolver{T}
    # Model + Objective
    model::L
    obj::O

    # Problem info
    x0::SVector{n,T}
    xf::SVector{n,T}
    tf::T
    N::Int

    opts::iLQRSolverOptions{T}
    stats::iLQRStats{T}

    # Primal Duals
    Z::Vector{KnotPoint{T,n,m,L1}}
    Z̄::Vector{KnotPoint{T,n,m,L1}}

    # Data variables
    # K::Vector{SMatrix{m,n̄,T,L2}}  # State feedback gains (m,n,N-1)
    K::Vector{A}  # State feedback gains (m,n,N-1)
    d::Vector{SVector{m,T}} # Feedforward gains (m,N-1)

    ∇F::Vector{D} # discrete dynamics jacobian (block) (n,n+m+1,N)
    G::Vector{F}  # state difference jacobian (n̄, n)

    S::E1  # Optimal cost-to-go expansion trajectory
    Q::E2  # cost-to-go expansion trajectory

    ρ::Vector{T} # Regularization
    dρ::Vector{T} # Regularization rate of change

    grad::Vector{T} # Gradient

    logger::SolverLogger

    function iLQRSolver{T,I}(model::L, obj::O, x0, xf, tf, N, opts, stats,
            Z::Vector{KnotPoint{T,n,m,L1}}, Z̄, K::Vector{A}, d,
            ∇F::Vector{D}, G::Vector{F}, S::E1, Q::E2, ρ, dρ, grad,
            logger) where {T,I,L,O,n,m,L1,D,F,E1,E2,A}
        new{T,I,L,O,n,m,L1,D,F,E1,E2,A}(model, obj, x0, xf, tf, N, opts, stats, Z, Z̄, K, d,
            ∇F, G, S, Q, ρ, dρ, grad, logger)
    end
end

function iLQRSolver(prob::Problem{I,T}, opts=iLQRSolverOptions()) where {I,T}

    # Init solver statistics
    stats = iLQRStats{T}() # = Dict{Symbol,Any}(:timer=>TimerOutput())

    # Init solver results
    n,m,N = size(prob)
    n̄ = state_diff_size(prob.model)

    x0 = SVector{n}(prob.x0)
    xf = SVector{n}(prob.xf)

    Z = prob.Z
    # Z̄ = Traj(n,m,Z[1].dt,N)
    Z̄ = copy(prob.Z)

    if m*n̄ > MAX_ELEM
		K  = [zeros(T,m,n̄) for k = 1:N-1]
	else
		K  = [@SMatrix zeros(T,m,n̄) for k = 1:N-1]
	end
    d  = [@SVector zeros(T,m)   for k = 1:N-1]

	if n*(n+m+1) > MAX_ELEM
		∇F = [zeros(T,n,n+m+1) for k = 1:N-1]
	else
		∇F = [@SMatrix zeros(T,n,n+m+1) for k = 1:N-1]
	end
    ∇F = [@SMatrix zeros(T,n,n+m+1) for k = 1:N-1]
    G = [state_diff_jacobian(prob.model, x0) for k = 1:N]

    S = CostExpansion(n̄,m,N)
    Q = CostExpansion(n,m,N)


    ρ = zeros(T,1)
    dρ = zeros(T,1)

    grad = zeros(T,N-1)

    logger = default_logger(opts.verbose)

    solver = iLQRSolver{T,I}(prob.model, prob.obj, x0, xf, prob.tf, N, opts, stats,
        Z, Z̄, K, d, ∇F, G, S, Q, ρ, dρ, grad, logger)

    reset!(solver)
    return solver
end

AbstractSolver(prob::Problem, opts::iLQRSolverOptions) = iLQRSolver(prob, opts)

function reset!(solver::iLQRSolver{T}, reset_stats=true) where T
    if reset_stats
        reset!(solver.stats, solver.opts.iterations)
    end
    solver.ρ[1] = 0.0
    solver.dρ[1] = 0.0
    return nothing
end

Base.size(solver::iLQRSolver{T,I,L,O,n,m}) where {T,I,L,O,n,m} = n,m,solver.N
@inline get_trajectory(solver::iLQRSolver) = solver.Z
@inline get_objective(solver::iLQRSolver) = solver.obj
@inline get_model(solver::iLQRSolver) = solver.model
@inline get_initial_state(solver::iLQRSolver) = solver.x0

function cost(solver::iLQRSolver, Z=solver.Z)
    cost!(solver.obj, Z)
    return sum(get_J(solver.obj))
end