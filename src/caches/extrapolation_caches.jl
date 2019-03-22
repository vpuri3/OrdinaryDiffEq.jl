@cache mutable struct RichardsonEulerCache{uType,rateType,arrayType,dtType,uNoUnitsType} <: OrdinaryDiffEqMutableCache
  u::uType
  uprev::uType
  tmp::uType
  k::rateType
  utilde::uType
  atmp::uNoUnitsType
  fsalfirst::rateType
  dtpropose::dtType
  T::arrayType
  cur_order::Int
  work::dtType
  A::Int
  step_no::Int
end

@cache mutable struct RichardsonEulerConstantCache{dtType,arrayType} <: OrdinaryDiffEqConstantCache
  dtpropose::dtType
  T::arrayType
  cur_order::Int
  work::dtType
  A::Int
  step_no::Int
end

function alg_cache(alg::RichardsonEuler,u,rate_prototype,uEltypeNoUnits,uBottomEltypeNoUnits,tTypeNoUnits,uprev,uprev2,f,t,dt,reltol,p,calck,::Type{Val{true}})
  tmp = similar(u)
  utilde = similar(u)
  k = zero(rate_prototype)
  fsalfirst = zero(rate_prototype)
  cur_order = max(alg.init_order, alg.min_order)
  dtpropose = zero(dt)
  T = fill(zeros(eltype(u), size(u)), (alg.max_order, alg.max_order))
  work = zero(dt)
  A = one(Int)
  atmp = similar(u,uEltypeNoUnits)
  step_no = zero(Int)
  RichardsonEulerCache(u,uprev,tmp,k,utilde,atmp,fsalfirst,dtpropose,T,cur_order,work,A,step_no)
end

function alg_cache(alg::RichardsonEuler,u,rate_prototype,uEltypeNoUnits,uBottomEltypeNoUnits,tTypeNoUnits,uprev,uprev2,f,t,dt,reltol,p,calck,::Type{Val{false}})
  dtpropose = zero(dt)
  cur_order = max(alg.init_order, alg.min_order)
  T = fill(zero(eltype(u)), (alg.max_order, alg.max_order))
  work = zero(dt)
  A = one(Int)
  step_no = zero(Int)
  RichardsonEulerConstantCache(dtpropose,T,cur_order,work,A,step_no)
end

@cache mutable struct ExtrapolationMidpointDeuflhardConstantCache{QType} <: OrdinaryDiffEqConstantCache
  # Values that are mutated
  Q::Vector{QType} # Storage for stepsize scaling factors. Q[n] contains information for extrapolation order (n + alg.n_min - 1)
  n_curr::Int64 # Storage for the current extrapolation order
  n_old::Int64 # Storage for the extrapolation order n_curr before perfom_step! changes the latter

  # Constant values
  subdividing_sequence::Array{BigInt,1}
  stage_number::Array{Int,1} # Stage_number[n] contains information for extrapolation order (n + alg.n_min - 1)
  # Weights and Scaling factors for extrapolation operators
  extrapolation_weights::Array{Rational{BigInt},2}
  extrapolation_scalars::Array{Rational{BigInt},1}
  # Weights and scaling factors for internal extrapolation operators (used for error estimate)
  extrapolation_weights_2::Array{Rational{BigInt},2}
  extrapolation_scalars_2::Array{Rational{BigInt},1}
end

function alg_cache(alg::ExtrapolationMidpointDeuflhard,u,rate_prototype,uEltypeNoUnits,uBottomEltypeNoUnits,tTypeNoUnits,uprev,uprev2,f,t,dt,reltol,p,calck,::Type{Val{false}})
  @unpack n_min, n_init, n_max = alg

  QType = tTypeNoUnits <: Integer ? typeof(qmin_default(alg)) : tTypeNoUnits # Cf. DiffEqBase.__init in solve.jl
  Q = fill(zero(QType),n_max - n_min + 1)

  n_curr = n_init

  n_old = n_init

  # Initialize subdividing_sequence:
  if alg.sequence_symbol == :harmonic
      subdividing_sequence = [BigInt(n+1) for n = 0:n_max]
  elseif alg.sequence_symbol == :romberg
      subdividing_sequence = [BigInt(2)^n for n = 0:n_max]
  else # sequence_symbol == :bulirsch
      subdividing_sequence = [n==0 ? BigInt(1) : (isodd(n) ? BigInt(2)^Int64(n/2 + 0.5) : 3BigInt(2^Int64(n/2 - 1))) for n = 0:n_max]
  end

  # Compute stage numbers
  stage_number = [2sum(Int64.(subdividing_sequence[1:n+1])) - n for n = n_min:n_max]

  # Compute nodes corresponding to subdividing_sequence
  nodes = BigInt(1) .// subdividing_sequence .^ 2

  # Compute barycentric weights for internal extrapolation operators
  extrapolation_weights_2 = zeros(Rational{BigInt}, n_max, n_max)
  extrapolation_weights_2[1,:] = ones(Rational{BigInt}, 1, n_max)
  for n = 2:n_max
      distance = nodes[2:n] .- nodes[n+1]
      extrapolation_weights_2[1:(n-1), n] = extrapolation_weights_2[1:n-1, n-1] .// distance
      extrapolation_weights_2[n, n] = 1 // prod(-distance)
  end

  # Compute barycentric weights for extrapolation operators
  extrapolation_weights = zeros(Rational{BigInt}, n_max+1, n_max+1)
  for n = 1:n_max
      extrapolation_weights[n+1, (n+1) : (n_max+1)] = extrapolation_weights_2[n, n:n_max] // (nodes[n+1] - nodes[1])
      extrapolation_weights[1, n] = 1 // prod(nodes[1] .- nodes[2:n])
  end
  extrapolation_weights[1, n_max+1] = 1 // prod(nodes[1] .- nodes[2:n_max+1])

  # Rescale barycentric weights to obtain weights of 1. Barycentric Formula
  for m = 1:(n_max+1)
      extrapolation_weights[1:m, m] = - extrapolation_weights[1:m, m] .// nodes[1:m]
      if 2 <= m
          extrapolation_weights_2[1:m-1, m-1] = -extrapolation_weights_2[1:m-1, m-1] .// nodes[2:m]
      end
  end

  # Compute scaling factors for internal extrapolation operators
  extrapolation_scalars_2 = ones(Rational{BigInt}, n_max)
  extrapolation_scalars_2[1] = -nodes[2]
  for n = 1:(n_max-1)
      extrapolation_scalars_2[n+1] = -extrapolation_scalars_2[n] * nodes[n+2]
  end

  # Compute scaling factors for extrapolation operators
  extrapolation_scalars = -nodes[1] * [BigInt(1); extrapolation_scalars_2]

  # Initialize the constant cache
  ExtrapolationMidpointDeuflhardConstantCache(Q, n_curr, n_old, subdividing_sequence, stage_number, extrapolation_weights, extrapolation_scalars, extrapolation_weights_2, extrapolation_scalars_2)
end

@cache mutable struct ExtrapolationMidpointDeuflhardCache{uType,uNoUnitsType,rateType,dtType,QType} <: OrdinaryDiffEqMutableCache
  u::uType
  uprev::uType
  utilde::uType
  tmp::uType
  atmp::uNoUnitsType
  k::rateType
  fsalfirst::rateType
  proposed_extrapolation_order::Int
  constant_cache::ExtrapolationMidpointDeuflhardConstantCache
end

function alg_cache(alg::ExtrapolationMidpointDeuflhard,u,rate_prototype,uEltypeNoUnits,uBottomEltypeNoUnits,tTypeNoUnits,uprev,uprev2,f,t,dt,reltol,p,calck,::Type{Val{true}})
  utilde = similar(u)
  tmp = similar(u)
  atmp = similar(u,uEltypeNoUnits)
  k = zero(rate_prototype)
  fsalfirst = zero(rate_prototype)
  proposed_extrapolation_order = alg.n_init # order of first step is set by user
  constant_cache = alg_cache(alg,u,rate_prototype,uEltypeNoUnits,uBottomEltypeNoUnits,tTypeNoUnits,uprev,uprev2,f,t,dt,reltol,p,calck,Val{false})
  ExtrapolationMidpointDeuflhardCache(u,uprev,utilde,tmp,atmp,k,fsalfirst,proposed_extrapolation_order,constant_cache)
end
