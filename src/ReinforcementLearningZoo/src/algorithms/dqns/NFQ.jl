export NFQ

using Flux
using Functors: @functor

"""
    NFQ{A<:AbstractApproximator, F, R} <: AbstractLearner
    NFQ(action_space::AbstractVector, approximator::A, num_iterations::Integer epochs::Integer, loss_function::F, rng::R, γ::Float32) where {A, F, R}
Neural Fitted Q-iteration as implemented in [1]

# Keyword arguments
- `action_space::AbstractVector` Action space of the environment (necessary in the optimise! step)
- `approximator::A` Q-function approximator (typically a neural network)
- `num_iterations::Integer` number of value iteration iterations in FQI loop (i.e. the outer loop)
- `epochs::Integer` number of epochs to train neural network per iteration
- `loss_function::F` loss function of the NN
- `rng::R` random number generator
- `γ::Float32` discount rate

# References
[1] Riedmiller, M. (2005). Neural Fitted Q Iteration – First Experiences with a Data Efficient Neural Reinforcement Learning Method. In: Gama, J., Camacho, R., Brazdil, P.B., Jorge, A.M., Torgo, L. (eds) Machine Learning: ECML 2005. ECML 2005. Lecture Notes in Computer Science(), vol 3720. Springer, Berlin, Heidelberg. https://doi.org/10.1007/11564096_32
"""
Base.@kwdef struct NFQ{A, R, F} <: AbstractLearner
    action_space::AbstractVector
    approximator::A
    num_iterations::Integer = 20
    epochs::Integer = 100
    loss_function::F = mse
    rng::R = Random.default_rng()
    γ::Float32 = 0.9f0
end

@functor NFQ (approximator,)

RLCore.forward(L::NFQ, s::AbstractArray) = RLCore.forward(L.approximator, s)

function RLCore.forward(learner::NFQ, env::AbstractEnv)
    as = action_space(env)
    return vcat(repeat(state(env), inner=(1, length(as))), transpose(as)) |> x -> send_to_device(device(learner.approximator), x) |> x->RLCore.forward(learner, x) |> send_to_host |> vec 
end

function RLBase.optimise!(learner::NFQ, ::PostEpisodeStage, trajectory::Trajectory)
    Q = learner.approximator
    γ = learner.γ
    loss_func = learner.loss_function
    as = learner.action_space
    las = length(as)
    batch = ReinforcementLearningTrajectories.StatsBase.sample(trajectory)
    
    (s, a, r, ss) = batch[[:state, :action, :reward, :next_state]]
    a = Float32.(a)
    s, a, r, ss = map(x->send_to_device(device(Q), x), (s, a, r, ss))
    for i = 1:learner.num_iterations
        # Make an input x samples x |action space| array -- Q --> samples x |action space| -- max --> samples
        G = r .+ γ .* (cat(repeat(ss, inner=(1, 1, las)), reshape(repeat(as, outer=(1, size(ss, 2))), (1, size(ss, 2), las)), dims=1) |> x -> maximum(RLCore.forward(Q, x), dims=3) |> vec)
        for _ = 1:learner.epochs
            Flux.train!((x, y) -> loss_func(RLCore.forward(Q, x), y), params(Q.model), [(vcat(s, a), transpose(G))], Q.optimiser)
        end
    end
end
