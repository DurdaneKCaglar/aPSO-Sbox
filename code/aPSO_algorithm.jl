using Random, Statistics, Distributed, Dates
using Base.Threads
using ProgressMeter

# Pre-computed lookup tables for performance
const PARITY_LUT = [count_ones(UInt8(i)) & 1 for i in 0:255]
const BIT_COUNT_LUT = [count_ones(UInt8(i)) for i in 0:255]

# Global variables for logging
const SWAP_LOG = String[]
const SWAP_LOG_LOCK = ReentrantLock()
const INITIAL_SBOX_FILE = "initial_sbox.txt"
const FINAL_SBOX_FILE = "final_sbox.txt"
const RESULTS_LOG_FILE = "optimization_results.txt"

# Thread-safe global best swap tracking
const CURRENT_STEP_ALL_MOVES = Dict{Int, Vector{Tuple{String, Any, Float64}}}()
const CURRENT_STEP_LOCK = ReentrantLock()
const GLOBAL_BEST_LOG_FILE = "global_best_swaps_only.log"
const DEBUG_SBOX_DIR = "debug_sboxes"

# Thread-safe particle move counters
const PARTICLE_MOVE_COUNTERS = Dict{Int, Dict{String, Int}}()
const COUNTERS_LOCK = ReentrantLock()

### Configuration
# Iteration configuration
const ITER = 200000
const SSIZE = 100

# Early stopping configuration
const EARLY_STOP_CHECK_AFTER = 10000   # Check after this iteration
const EARLY_STOP_NL_THRESHOLD = 111.5 # Stop if NL below this (poor performance)



# Create debug directory
function create_debug_directory()
    if !isdir(DEBUG_SBOX_DIR)
        mkdir(DEBUG_SBOX_DIR)
    end
end

# Save S-box at each step
function save_debug_sbox(sbox::Vector{UInt8}, step::Int, particle_id::Int, description::String)
    filename = joinpath(DEBUG_SBOX_DIR, "step_$(step)_particle_$(particle_id)_sbox.txt")
    
    open(filename, "w") do file
        println(file, "# $description")
        println(file, "# Step: $step, Particle: $particle_id")
        println(file, "# Generated on: $(now())")
        println(file, "")
        
        
        # Julia array format
        println(file, "debug_sbox = UInt8[")
        for i in 1:16
            start_idx = (i-1) * 16 + 1
            end_idx = i * 16
            row = sbox[start_idx:end_idx]
            formatted_row = join([lpad(string(val), 3) for val in row], ", ")
            if i < 16
                println(file, "    $formatted_row,")
            else
                println(file, "    $formatted_row")
            end
        end
        println(file, "]")
        
        # Single line format
        println(file, "")
        println(file, "# Single line format:")
        println(file, "[" * join(string.(sbox), ", ") * "]")
    end
end

# Thread-safe particle move recording
function record_particle_move(particle_id::Int, operation::String, indices::Any, improvement::Float64)
    lock(CURRENT_STEP_LOCK) do
        if !haskey(CURRENT_STEP_ALL_MOVES, particle_id)
            CURRENT_STEP_ALL_MOVES[particle_id] = Vector{Tuple{String, Any, Float64}}()
        end
        push!(CURRENT_STEP_ALL_MOVES[particle_id], (operation, indices, improvement))
    end
end

# Thread-safe particle counter initialization
function initialize_particle_counters(swarm_size::Int)
    lock(COUNTERS_LOCK) do
        empty!(PARTICLE_MOVE_COUNTERS)
        for i in 1:swarm_size
            PARTICLE_MOVE_COUNTERS[i] = Dict(
                "GUIDED_SWAP_TO_PBEST" => 0,
                "GUIDED_SWAP_TO_GBEST" => 0,
                "TRIPLE_SWAP" => 0,
                "RANDOM_SWAP" => 0,
                "TOTAL" => 0
            )
        end
    end
end

# Thread-safe counter increment
function increment_move_counter(particle_id::Int, move_type::String)
    lock(COUNTERS_LOCK) do
        if haskey(PARTICLE_MOVE_COUNTERS, particle_id)
            if haskey(PARTICLE_MOVE_COUNTERS[particle_id], move_type)
                PARTICLE_MOVE_COUNTERS[particle_id][move_type] += 1
            end
            PARTICLE_MOVE_COUNTERS[particle_id]["TOTAL"] += 1
        end
    end
end

# Thread-safe record with counter
function record_particle_move_with_counter(particle_id::Int, operation::String, indices::Any, improvement::Float64)
    record_particle_move(particle_id, operation, indices, improvement)
    increment_move_counter(particle_id, operation)
end

# Thread-safe global best logging
function log_global_best_all_moves(step::Int, particle_id::Int, global_improvement::Float64, sbox::Vector{UInt8})
    timestamp = string(now())
    
    moves = Vector{Tuple{String, Any, Float64}}()
    lock(CURRENT_STEP_LOCK) do
        if haskey(CURRENT_STEP_ALL_MOVES, particle_id)
            moves = copy(CURRENT_STEP_ALL_MOVES[particle_id])
        end
    end
    
    if !isempty(moves)
        open(GLOBAL_BEST_LOG_FILE, "a") do file
            println(file, "=" * "="^80)
            println(file, "$timestamp | Step $step | Particle $particle_id | GLOBAL BEST ACHIEVED!")
            println(file, "Global Improvement: $global_improvement")
            println(file, "All moves in this step:")
            
            for (i, (operation, indices, local_imp)) in enumerate(moves)
                println(file, "  Move $i: $operation | Indices: $indices | Local Improvement: $local_imp")
            end
            println(file, "=" * "="^80)
        end
    else
        log_entry = "$timestamp | Step $step | Particle $particle_id | NO_MOVES_RECORDED | Global: $global_improvement | STATUS: APPLIED ⚠️"
        open(GLOBAL_BEST_LOG_FILE, "a") do file
            println(file, log_entry)
        end
    end
    
    move_summary = if !isempty(moves)
        moves_count = length(moves)
        "Global Best S-box after $moves_count moves"
    else
        "Global Best S-box (no moves recorded)"
    end
    
    save_debug_sbox(sbox, step, particle_id, move_summary)
end

# Thread-safe step clearing
function clear_step_all_moves()
    lock(CURRENT_STEP_LOCK) do
        for key in keys(CURRENT_STEP_ALL_MOVES)
            empty!(CURRENT_STEP_ALL_MOVES[key])
        end
    end
end

# Function to save S-box to file
function save_sbox_to_file(sbox::Vector{UInt8}, filename::String, description::String)
    open(filename, "w") do file
        println(file, "# $description")
        println(file, "# Generated on: $(now())")
        println(file, "# Format: 16 values per line (256 total)")
        println(file, "")
        
        # Write as formatted array
        println(file, "sbox = UInt8[")
        for i in 1:16
            start_idx = (i-1) * 16 + 1
            end_idx = i * 16
            row = sbox[start_idx:end_idx]
            formatted_row = join([lpad(string(val), 3) for val in row], ", ")
            if i < 16
                println(file, "    $formatted_row,")
            else
                println(file, "    $formatted_row")
            end
        end
        println(file, "]")
        
        # Also save as comma-separated values for easy import
        println(file, "")
        println(file, "# Comma-separated format:")
        println(file, join(string.(sbox), ", "))
    end
end

# Function to initialize logging
function initialize_logging_with_counters(swarm_size::Int)
    create_debug_directory()
    
    open(GLOBAL_BEST_LOG_FILE, "w") do file
        println(file, "# Global Best Swaps Only - FIXED THREAD-SAFE DEBUG MODE")
        println(file, "# Started on: $(now())")
        println(file, "# Format: Timestamp | Step | Particle | Operation | Indices | Local | Global | Status")
        println(file, "# Note: Each global best S-box is saved in debug_sboxes/ directory")
        println(file, "# FIXED: Thread-safe implementation to prevent race conditions")
        println(file, "")
    end
    
    empty!(SWAP_LOG)
    clear_step_all_moves()
    initialize_particle_counters(swarm_size)
end

# Optimized Walsh transform using lookup tables
function walsh_transform_optimized(f::Vector{UInt8})
    n = length(f)
    W = zeros(Int16, n)
    
    @inbounds for w in 0:(n-1)
        sum_val = 0
        for x in 0:(n-1)
            parity_val = PARITY_LUT[(w & x) + 1]
            sum_val += (f[x+1] == parity_val) ? 1 : -1
        end
        W[w+1] = sum_val
    end
    
    return W
end

# Faster nonlinearity computation
function nonlinearity_of_boolean_function_fast(f::Vector{UInt8})
    W = walsh_transform_optimized(f)
    return (length(f) - maximum(abs.(W))) ÷ 2
end

# Optimized bitwise nonlinearity using views
function bitwise_nonlinearity_fast(sbox::Vector{UInt8})
    nl = Vector{Int}(undef, 8)
    
    @inbounds for bit in 0:7
        bit_vec = Vector{UInt8}(undef, 256)
        for i in 1:256
            bit_vec[i] = (sbox[i] >> bit) & 1
        end
        nl[bit+1] = nonlinearity_of_boolean_function_fast(bit_vec)
    end
    
    return nl
end

# Vectorized SAC with better memory access patterns
function basic_sac_vectorized_fast(sbox::Vector{UInt8})
    total_sac = 0
    
    @inbounds for i in 0:7
        bit_flip = UInt8(1 << i)
        
        for x in 0:255
            x_flipped = x ⊻ bit_flip
            y1 = sbox[x + 1]
            y2 = sbox[x_flipped + 1]
            diff = y1 ⊻ y2
            
            total_sac += BIT_COUNT_LUT[diff + 1]
        end
    end
    
    return total_sac / (256 * 64)
end

# Optimized DDT computation with better memory usage
function max_ddt_frequency_fast(sbox::Vector{UInt8})
    max_freq = 0
    counts = zeros(Int, 256)
    
    @inbounds for dx in 1:255
        fill!(counts, 0)
        
        for x in 0:255
            x_xor_dx = x ⊻ dx
            dy = sbox[x + 1] ⊻ sbox[x_xor_dx + 1]
            counts[dy + 1] += 1
        end
        
        freq = maximum(counts)
        max_freq = max(max_freq, freq)
    end
    
    return max_freq
end

# Optimized entropy calculation
function shannon_entropy_fast(sbox::Vector{UInt8})
    counts = zeros(Int, 256)
    
    @inbounds for val in sbox
        counts[val + 1] += 1
    end
    
    entropy = 0.0
    @inbounds for count in counts
        if count > 0
            prob = count / 256.0
            entropy -= prob * log2(prob)
        end
    end
    
    return entropy
end

# Faster bijective check using BitSet
function is_bijective(sbox::Vector{UInt8})
    seen = falses(256)
    @inbounds for val in sbox
        if seen[val + 1]
            return false
        end
        seen[val + 1] = true
    end
    return true
end

# Optimized evaluation function
function evaluate_sbox_fast(sbox::Vector{UInt8})
    if !is_bijective(sbox)
        return nothing
    end
    
    nl = bitwise_nonlinearity_fast(sbox)
    sac = basic_sac_vectorized_fast(sbox)
    ddt = max_ddt_frequency_fast(sbox)
    entropy = shannon_entropy_fast(sbox)
    
    return sum(nl), sac, ddt, entropy, copy(sbox)
end

# Particle structure with type stability
mutable struct AggressiveParticle
    position::Vector{UInt8}
    best_position::Vector{UInt8}
    best_score::Float64
    stagnation_count::Int
    id::Int
    
    function AggressiveParticle(initial_sbox::Vector{UInt8}, particle_id::Int)
        pos = copy(initial_sbox)
        score = sum(bitwise_nonlinearity_fast(pos))
        new(pos, copy(pos), score, 0, particle_id)
    end
end

# Optimized triple swap with fewer allocations and logging only beneficial swaps
function massive_triple_swap_batch!(position::Vector{UInt8}, num_trials::Int=50, step::Int=0, particle_id::Int=0)
    baseline_nl = sum(bitwise_nonlinearity_fast(position))
    best_improvement = 0
    best_swap = nothing
    
    test_position = similar(position)
    
    @inbounds for _ in 1:num_trials
        indices = randperm(256)[1:3]
        i, j, k = indices[1], indices[2], indices[3]
        
        copy!(test_position, position)
        test_position[i], test_position[j], test_position[k] = 
            test_position[k], test_position[i], test_position[j]
        
        new_nl = sum(bitwise_nonlinearity_fast(test_position))
        improvement = new_nl - baseline_nl
        
        if improvement > best_improvement
            best_improvement = improvement
            best_swap = (i, j, k)
        end
    end
    
    if best_swap !== nothing && best_improvement > 0
        i, j, k = best_swap
        @inbounds position[i], position[j], position[k] = 
            position[k], position[i], position[j]
        
        record_particle_move_with_counter(particle_id, "TRIPLE_SWAP", (i, j, k), Float64(best_improvement))
    end
    
    return position
end

# Updated guided swap - record ALL swaps separately (with target type)
function guided_swap_move_multiple!(position::Vector{UInt8}, target::Vector{UInt8}, max_swaps::Int=5, step::Int=0, particle_id::Int=0, target_type::String="UNKNOWN")
    diff_indices = Int[]
    @inbounds for i in 1:256
        if position[i] != target[i]
            push!(diff_indices, i)
        end
    end
    
    swaps_made = 0
    
    if !isempty(diff_indices)
        num_swaps = min(max_swaps, length(diff_indices))
        selected_indices = diff_indices[randperm(length(diff_indices))[1:num_swaps]]
        
        @inbounds for i in selected_indices
            target_value = target[i]
            j = findfirst(x -> x == target_value, position)
            if j !== nothing && i != j
                position[i], position[j] = position[j], position[i]
                swaps_made += 1
                
                if target_type == "→PBEST"
                    record_particle_move_with_counter(particle_id, "GUIDED_SWAP_TO_PBEST", (i, j), 0.0)
                elseif target_type == "→GBEST"
                    record_particle_move_with_counter(particle_id, "GUIDED_SWAP_TO_GBEST", (i, j), 0.0)
                else
                    record_particle_move_with_counter(particle_id, "GUIDED_SWAP", (i, j), 0.0)
                end
            end
        end
    end
    
    return swaps_made
end

# Updated random perturbations - record ALL swaps separately
function random_perturbations!(position::Vector{UInt8}, step::Int=0, particle_id::Int=0)
    swaps_made = 0
    
    if rand() < 0.3
        num_swaps = rand(1:5)
        @inbounds for _ in 1:num_swaps
            i, j = rand(1:256), rand(1:256)
            if i != j
                position[i], position[j] = position[j], position[i]
                swaps_made += 1
                
                record_particle_move_with_counter(particle_id, "RANDOM_SWAP", (i, j), 0.0)
            end
        end
    end
    return swaps_made
end

# Updated particle update - only record actual moves (with target type)
function update_particle_aggressive!(p::AggressiveParticle, global_best_position::Vector{UInt8}, 
                                   w_prob::Float64, c1_prob::Float64, c2_prob::Float64, step::Int)
    
    for _ in 1:3
        if rand() < c1_prob
            guided_swap_move_multiple!(p.position, p.best_position, 5, step, p.id, "→PBEST")
        end
            
        if rand() < c2_prob
            guided_swap_move_multiple!(p.position, global_best_position, 5, step, p.id, "→GBEST")
        end
    end
    
    if rand() < w_prob
        massive_triple_swap_batch!(p.position, 30, step, p.id)
    end
    
    random_perturbations!(p.position, step, p.id)
end

# NEW: Function to log progress to text file
function log_to_file(message::String)
    open(RESULTS_LOG_FILE, "a") do file
        println(file, message)
    end
end

# Modified PSO function with early stopping and progress bar
function pso_optimize_with_early_stopping(initial_sbox::Vector{UInt8}; 
                                        iterations::Int=100, 
                                        swarm_size::Int=20,
                                        w_prob::Float64=0.6, 
                                        c1_prob::Float64=0.8, 
                                        c2_prob::Float64=0.8)
    
    # Initialize results log file
    open(RESULTS_LOG_FILE, "w") do file
        println(file, "# S-box Optimization Results")
        println(file, "# Started on: $(now())")
        println(file, "# Parameters: iterations=$iterations, swarm_size=$swarm_size")
        println(file, "# Early stopping: Stop after $EARLY_STOP_CHECK_AFTER  steps if NL < $EARLY_STOP_NL_THRESHOLD")
        println(file, "")
    end
    
    # Initialize logging
    initialize_logging_with_counters(swarm_size)
    save_sbox_to_file(initial_sbox, INITIAL_SBOX_FILE, "Initial S-box before optimization")
    
    # Initialize swarm
    swarm = [AggressiveParticle(initial_sbox, i) for i in 1:swarm_size]
    global_best = swarm[argmax([p.best_score for p in swarm])]
    
    # Log initial state
    initial_avg_nl = round(global_best.best_score/8, digits=2)
    log_to_file("Initial NL: $initial_avg_nl")
    
    # Variables for tracking
    best_score_history = Float64[]
    improvement_count = 0
    early_stop = false
    stop_reason = ""
    
    # Create progress bar with custom description
    progress = Progress(iterations, 
                       desc="Optimizing S-box... ",
                       dt=0.1,  # Update every 0.1 seconds
                       barglyphs=BarGlyphs('|','█', ['▁' ,'▂' ,'▃' ,'▄' ,'▅' ,'▆', '▇'],' ','|'),
                       barlen=50,
                       color=:green)
    
    # Main optimization loop
    for step in 1:iterations
        improved = false
        old_global_best = global_best.best_score
        
        # Clear step moves
        clear_step_all_moves()
        
        # Update particles
        if Threads.nthreads() > 1
            Threads.@threads for i in 1:swarm_size
                update_particle_aggressive!(swarm[i], global_best.best_position, w_prob, c1_prob, c2_prob, step)
            end
        else
            for p in swarm
                update_particle_aggressive!(p, global_best.best_position, w_prob, c1_prob, c2_prob, step)
            end
        end
        
        # Evaluate particles
        for p in swarm
            result = evaluate_sbox_fast(p.position)
            if result !== nothing
                nl_sum, sac, ddt, entropy, sbox = result
                
                if nl_sum > p.best_score
                    p.best_score = nl_sum
                    p.best_position = copy(sbox)
                    p.stagnation_count = 0
                    improved = true
                else
                    p.stagnation_count += 1
                end
                
                if nl_sum > global_best.best_score
                    global_best.best_score = nl_sum
                    global_best.best_position = copy(sbox)
                    improvement_count += 1
                    
                    # Log improvement
                    avg_nl = round(nl_sum/8, digits=2)
                    log_message = "Step $step: NEW GLOBAL BEST - NL=$avg_nl, SAC=$(round(sac, digits=4)), DDT=$ddt, Entropy=$(round(entropy, digits=4))"
                    log_to_file(log_message)
                    
                    improvement = nl_sum - old_global_best
                    log_global_best_all_moves(step, p.id, Float64(improvement), sbox)
                    improved = true
                end
            end
        end
        
        # Adaptive parameters
        if !improved
            w_prob = min(0.9, w_prob + 0.05)
        else
            w_prob = max(0.3, w_prob - 0.02)
        end
        
        # Track best score
        push!(best_score_history, global_best.best_score)
        current_avg_nl = global_best.best_score / 8
        
        # Check early stopping condition after 1000 steps
        if step == EARLY_STOP_CHECK_AFTER
            if current_avg_nl < EARLY_STOP_NL_THRESHOLD
                early_stop = true
                stop_reason = "Early stop: NL ($(round(current_avg_nl, digits=2))) < $EARLY_STOP_NL_THRESHOLD after $EARLY_STOP_CHECK_AFTER steps"
                log_to_file("EARLY STOPPING: $stop_reason")
                # Update progress bar one final time before breaking
                showvalues = [
                    (:Step, step),
                    (:Iterations, iterations),
                    (:Status, "EARLY STOP"),
                    (:BestNL, round(current_avg_nl, digits=2)),
                    (:Reason, "NL < $EARLY_STOP_NL_THRESHOLD"),
                    (:Improvements, improvement_count),
                    (:Threads, Threads.nthreads()),
                    (:Particles, swarm_size)
                ]
                println("EARLY_STOP")
                next!(progress; showvalues=showvalues)
                break
            else
                log_to_file("Continuing optimization: NL ($(round(current_avg_nl, digits=2))) >= $EARLY_STOP_NL_THRESHOLD after $EARLY_STOP_CHECK_AFTER steps")
                # Update progress bar to show continuation
                showvalues = [
                    (:Step, step),
                    (:Iterations, iterations),
                    (:Status, "CONTINUING"),
                    (:BestNL, round(current_avg_nl, digits=2)),
                    (:Reason, "NL ≥ $EARLY_STOP_NL_THRESHOLD"),
                    (:Improvements, improvement_count),
                    (:Threads, Threads.nthreads()),
                    (:Particles, swarm_size)
                ]
                println("CONTINUING")
                next!(progress; showvalues=showvalues)
                continue
            end
        end
        

        # Update progress bar with detailed info
        avg_nl = round(current_avg_nl, digits=2)
        status = step <= EARLY_STOP_CHECK_AFTER ? "Pre-check" : "Continuing"
        showvalues = [
            (:Step, step),
            (:Iterations, iterations),
            (:InitialNL, initial_avg_nl),
            (:BestNL, avg_nl),
            (:NL_THRESHOLD, EARLY_STOP_NL_THRESHOLD),
            (:Status, status),
            (:Improvements, improvement_count),
            (:Threads, Threads.nthreads()),
            (:Particles, swarm_size)
        ]
        next!(progress; showvalues=showvalues)
    end
    
    # Finish progress bar
    finish!(progress)
    
    # Final logging
    final_avg_nl = round(global_best.best_score/8, digits=2)
    if !early_stop
        stop_reason = "Completed all $iterations iterations"
    end


    println("InitialNL, $initial_avg_nl")
    println("BestNL, $final_avg_nl")
    
    log_to_file("")
    log_to_file("OPTIMIZATION COMPLETED")
    log_to_file("Stop reason: $stop_reason")
    log_to_file("Final NL: $final_avg_nl")
    log_to_file("Total improvements: $improvement_count")
    log_to_file("Threads used: $(Threads.nthreads())")
    
    return global_best.best_position
end

# Thread-safe particle statistics
function save_particle_statistics()
    stats_file = "particle_move_statistics.txt"
    
    local_counters = Dict{Int, Dict{String, Int}}()
    lock(COUNTERS_LOCK) do
        local_counters = deepcopy(PARTICLE_MOVE_COUNTERS)
    end
    
    open(stats_file, "w") do file
        println(file, "# Particle Move Statistics - THREAD-SAFE VERSION")
        println(file, "# Generated on: $(now())")
        println(file, "")
        
        for particle_id in sort(collect(keys(local_counters)))
            counters = local_counters[particle_id]
            println(file, "Particle $particle_id:")
            println(file, "  PBEST Guided Swaps: $(counters["GUIDED_SWAP_TO_PBEST"])")
            println(file, "  GBEST Guided Swaps: $(counters["GUIDED_SWAP_TO_GBEST"])")
            println(file, "  Triple Swaps: $(counters["TRIPLE_SWAP"])")
            println(file, "  Random Swaps: $(counters["RANDOM_SWAP"])")
            println(file, "  TOTAL Moves: $(counters["TOTAL"])")
            println(file, "")
        end
        
        total_pbest = sum(p["GUIDED_SWAP_TO_PBEST"] for p in values(local_counters))
        total_gbest = sum(p["GUIDED_SWAP_TO_GBEST"] for p in values(local_counters))
        total_triple = sum(p["TRIPLE_SWAP"] for p in values(local_counters))
        total_random = sum(p["RANDOM_SWAP"] for p in values(local_counters))
        grand_total = sum(p["TOTAL"] for p in values(local_counters))
        
        println(file, "="^50)
        println(file, "OVERALL STATISTICS - THREAD-SAFE:")
        println(file, "Total PBEST Guided Swaps: $total_pbest")
        println(file, "Total GBEST Guided Swaps: $total_gbest")
        println(file, "Total Triple Swaps: $total_triple")
        println(file, "Total Random Swaps: $total_random")
        println(file, "GRAND TOTAL Moves: $grand_total")
        println(file, "")
        
        if grand_total > 0
            println(file, "Move distribution:")
            println(file, "- PBEST Guided: $(round(total_pbest/grand_total*100, digits=2))%")
            println(file, "- GBEST Guided: $(round(total_gbest/grand_total*100, digits=2))%")
            println(file, "- Triple Swaps: $(round(total_triple/grand_total*100, digits=2))%")
            println(file, "- Random Swaps: $(round(total_random/grand_total*100, digits=2))%")
        end
        
        println(file, "")
        println(file, "BUG FIXES APPLIED:")
        println(file, "✅ Thread-safe dictionary access with locks")
        println(file, "✅ Proper initialization of particle entries")
        println(file, "✅ Race condition prevention in multi-threading")
        println(file, "✅ KeyError: key not found - FIXED")
        println(file, "✅ Early stopping condition implemented")
    end
end


# Initial analysis function - mirrors the final analysis
function sbox_analyse_initial(sbox::Vector{UInt8})
    analysis_file = "initial_analysis.txt"
    
    if is_bijective(sbox)
        nl = bitwise_nonlinearity_fast(sbox)
        sac = basic_sac_vectorized_fast(sbox)
        ddt = max_ddt_frequency_fast(sbox)
        entropy = shannon_entropy_fast(sbox)
        
        # Save analysis to file
        open(analysis_file, "w") do file
            println(file, "INITIAL S-BOX ANALYSIS")
            println(file, "="^50)
            println(file, "Generated on: $(now())")
            println(file, "")
            println(file, "Average NL    => $(round(sum(nl)/8, digits=2))")
            println(file, "SAC           => $(round(sac, digits=6))")
            println(file, "DDT Max       => $ddt")
            println(file, "Entropy       => $(round(entropy, digits=6))")
            println(file, "Per-bit NL    => $nl")
            println(file, "Min NL        => $(minimum(nl))")
            println(file, "Max NL        => $(maximum(nl))")
            println(file, "="^50)
        end
        
        # Console output
        println("="^50)
        println("INITIAL S-BOX ANALYSIS")
        println("="^50)
        println("Average NL    => $(round(sum(nl)/8, digits=2))")
        println("SAC           => $(round(sac, digits=6))")
        println("DDT Max       => $ddt")
        println("Entropy       => $(round(entropy, digits=6))")
        println("Per-bit NL    => $nl")
        println("Min NL        => $(minimum(nl))")
        println("Max NL        => $(maximum(nl))")
        println("="^50)
        println("Initial analysis saved to $analysis_file")
        println()
        
        # Save initial S-box (if not already saved)
        save_sbox_to_file(sbox, INITIAL_SBOX_FILE, "Initial S-box before optimization")
        save_debug_sbox(sbox, 0, 0, "Initial S-box before any optimization")
        
    else
        error_msg = "ERROR: Initial S-box is not bijective!"
        println(error_msg)
        
        open(analysis_file, "w") do file
            println(file, error_msg)
            println(file, "Generated on: $(now())")
        end
    end
end


# Final analysis function
function sbox_analyse(sbox::Vector{UInt8})
    analysis_file = "final_analysis.txt"
    
    if is_bijective(sbox)
        nl = bitwise_nonlinearity_fast(sbox)
        sac = basic_sac_vectorized_fast(sbox)
        ddt = max_ddt_frequency_fast(sbox)
        entropy = shannon_entropy_fast(sbox)
        
        # Save analysis to file
        open(analysis_file, "w") do file
            println(file, "FINAL S-BOX ANALYSIS")
            println(file, "="^50)
            println(file, "Generated on: $(now())")
            println(file, "")
            println(file, "Average NL    => $(round(sum(nl)/8, digits=2))")
            println(file, "SAC           => $(round(sac, digits=6))")
            println(file, "DDT Max       => $ddt")
            println(file, "Entropy       => $(round(entropy, digits=6))")
            println(file, "Per-bit NL    => $nl")
            println(file, "Min NL        => $(minimum(nl))")
            println(file, "Max NL        => $(maximum(nl))")
            println(file, "="^50)
        end
        
        # Also log to results file
        log_to_file("")
        log_to_file("FINAL ANALYSIS:")
        log_to_file("Average NL: $(round(sum(nl)/8, digits=2))")
        log_to_file("SAC: $(round(sac, digits=6))")
        log_to_file("DDT Max: $ddt")
        log_to_file("Entropy: $(round(entropy, digits=6))")
        
        # Minimal console output
        println("Analysis complete. Results saved to $analysis_file")
        
        # Save final S-box
        save_sbox_to_file(sbox, FINAL_SBOX_FILE, "Final optimized S-box - THREAD-SAFE VERSION with Early Stopping")
        save_debug_sbox(sbox, 999999, 0, "FINAL optimized S-box - THREAD-SAFE with Early Stopping")
        save_particle_statistics()
        
    else
        error_msg = "ERROR: S-box is not bijective!"
        println(error_msg)
        log_to_file(error_msg)
        
        open(analysis_file, "w") do file
            println(file, error_msg)
            println(file, "Generated on: $(now())")
        end
    end
end

# Test S-box (converted to UInt8)
sbox3 = UInt8[142,107,195,243,214,98,27,78,183,37,8,208,222,132,248,225,166,3,4,45,216,174,244,87,83,217,163,19,154,249,11,44,149,49,145,71,192,93,116,240,85,82,180,137,186,167,100,156,140,69,247,96,76,43,161,21,151,77,90,84,191,201,15,164,131,10,0,146,207,53,65,109,34,67,119,148,24,125,135,80,178,205,255,64,177,73,187,150,220,212,219,231,95,199,252,122,23,18,91,189,55,89,7,121,33,94,143,111,210,235,159,182,102,108,86,152,160,105,13,232,138,230,224,211,110,51,185,157,196,127,14,162,175,234,42,59,209,246,203,6,79,226,63,70,179,176,39,92,120,200,106,253,193,206,126,99,56,22,36,112,158,239,172,16,31,223,74,20,66,250,155,221,245,118,2,134,124,113,130,238,41,184,75,28,47,48,26,114,169,136,117,17,147,188,228,241,233,68,168,103,30,139,72,25,29,202,165,141,1,40,197,213,35,170,128,198,46,38,5,251,153,115,104,218,12,229,242,190,129,32,88,236,171,237,61,52,57,81,101,9,254,60,227,215,173,97,58,181,133,144,194,123,204,62,54,50]

# Main execution with early stopping and minimal output
function main()
    println("S-box Optimization with Early Stopping")
    println("Condition: Stop after $EARLY_STOP_CHECK_AFTER steps if NL < $EARLY_STOP_NL_THRESHOLD")
    println("Starting optimization...")
    
    best_sbox = pso_optimize_with_early_stopping(
        sbox3,
        iterations = ITER,  # Maximum iterations
        swarm_size = SSIZE,
        w_prob=0.6,
        c1_prob=0.8,
        c2_prob=0.8
    )
    
    println("Running final analysis...")
    sbox_analyse(best_sbox)
    sbox_analyse_initial(sbox3)
    
    # println("All results saved to text files:")
    # println("- optimization_results.txt (main log)")
    # println("- final_analysis.txt (detailed analysis)")
    # println("- particle_move_statistics.txt (move statistics)")
    # println("- final_sbox.txt (optimized S-box)")
    # println("- global_best_swaps_only.log (detailed swap log)")
    # println("Optimization complete.")



end

# Run the optimization
main()