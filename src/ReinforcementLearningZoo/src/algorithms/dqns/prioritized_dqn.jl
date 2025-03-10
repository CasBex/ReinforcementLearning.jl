export PrioritizedDQNLearner

import Random
using Functors: @functor
using LinearAlgebra: dot
using Flux
using Flux: gradient, params

Base.@kwdef mutable struct PrioritizedDQNLearner{A<:Union{Approximator,TargetNetwork}, R} <: AbstractLearner
    approximator::A
    loss_func::Any  # !!! here the loss func must return the loss before reducing over the batch dimension
    n::Int = 1
    γ::Float32 = 0.99f0
    β_priority::Float32 = 0.5f0
    rng::R = Random.default_rng()
    # for logging
    loss::Float32 = 0.0f0
end

RLCore.forward(L::PrioritizedDQNLearner, s::AbstractArray) = RLCore.forward(L.approximator, s)

@functor PrioritizedDQNLearner (approximator,)

function RLBase.optimise!(
    learner::PrioritizedDQNLearner,
    batch::Union{
        NamedTuple{(:key, :priority, SS′ART...)},
        NamedTuple{(:key, :priority, SS′L′ART...)}
    }
)
    A = learner.approximator
    Q = model(A)
    Qₜ = RLCore.target(A)
    γ = learner.γ
    β = learner.β_priority
    loss_func = learner.loss_func
    n = learner.n

    s, s′, a, r, t = map(x -> batch[x], SS′ART)
    batch_size = length(a)
    a = CartesianIndex.(a, 1:batch_size)
    k, p = batch.key, batch.priority
    p′ = similar(p)
    s, s′, a, r, t = send_to_device(device(Q), (s, s′, a, r, t))
    k, p, p′ = send_to_device(device(Q), (k, p, p′))

    w = 1.0f0 ./ ((p .+ 1.0f-10) .^ β)
    w ./= maximum(w)

    q′ =Qₜ(s′)

    if haskey(batch, :next_legal_actions_mask)
        q′ .+= ifelse.(batch[:next_legal_actions_mask], 0.0f0, typemin(Float32))
    end

    q′ₐ = dropdims(maximum(q′; dims=1), dims=1)

    G = r .+ γ^n .* (1 .- t) .* q′ₐ

    gs = gradient(params(A)) do
        qₐ = Q(s)[a]
        batch_losses = loss_func(G, qₐ)
        loss = dot(vec(w), vec(batch_losses)) * 1 // batch_size
        ignore_derivatives() do
            p′ .= vec((batch_losses .+ 1.0f-10) .^ β)
            learner.loss = loss
        end
        loss
    end

    RLBase.optimise!(A, gs)
    k, p′
end

function RLBase.optimise!(learner::PrioritizedDQNLearner, ::PostActStage, trajectory::Trajectory)
    for batch in trajectory
        k, p = RLBase.optimise!(learner, batch) |> send_to_host
        trajectory[:priority, k] = p
    end
end
