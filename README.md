# Discrete Particle Swarm Optimization for Cryptographic Substitution Box Design in Permutation Spaces

## Description

This repository contains the complete implementation and experimental data accompanying the manuscript:

> Caglar, D. (2025). Discrete Particle Swarm Optimization for Cryptographic Substitution Box Design in Permutation Spaces. *PeerJ Computer Science*.

The code implements **Aggressive Particle Swarm Optimization (aPSO)**, a swap-based discrete PSO algorithm that operates natively in permutation space to optimise 8-bit (256-entry) cryptographic substitution boxes (S-boxes). Unlike continuous PSO variants, the algorithm uses permutation-preserving swap operators (guided swaps toward personal best and global best, triple cyclic swaps, and random perturbations) to search the 256! permutation space while maintaining bijectivity at every step.

---

## Repository Structure

```
Supplemental_Data_S1/
├── code/
│   └── aPSO_algorithm.jl       # Main Julia implementation of aPSO
├── results/
│   ├── Case_00_initial_sbox.txt
│   ├── Case_00_final_sbox.txt
│   ├── Case_01_initial_sbox.txt
│   ├── Case_01_final_sbox.txt
│   └── ... (Cases 00–10, initial and final S-boxes)
└── multiple_runs/
    ├── Case_0_#P100_97.25_to_111.5/
    │   ├── run01/  (initial_sbox.txt, final_sbox.txt)
    │   ├── run02/
    │   └── ... run20/
    └── ... (Cases 0–10, 20 independent runs each)
```

---

## Dataset Information

### results/
For each of the 11 experimental cases (Cases 0–10), two files are provided:
- `Case_XX_initial_sbox.txt` — the starting S-box fed to the optimiser
- `Case_XX_final_sbox.txt` — the best S-box found after optimisation

Each file contains a 256-entry permutation vector (integer values 0–255) representing an 8x8 S-box.

### multiple_runs/
Raw output from **20 independent optimisation runs** for each experimental case, supporting the statistical results (Mean NL, Worst NL, Best NL, Standard Deviation) reported in the manuscript. Folder names encode the configuration and nonlinearity range observed across runs:

- `#P100` — 100 particles
- `97.25_to_111.5` — initial NL of 97.25, best achieved NL of 111.5

Each `run_XX/` folder contains:
- `initial_sbox.txt` — starting S-box for that run
- `final_sbox.txt` — best S-box found in that run

---

## Code Information

**File:** `code/aPSO_algorithm.jl`

Julia implementation of the aPSO algorithm with the following components:

| Component | Description |
|---|---|
| `walsh_transform_optimized` | Walsh-Hadamard Transform for nonlinearity evaluation |
| `bitwise_nonlinearity_fast` | Coordinate nonlinearity across all 8 bit-planes |
| `max_ddt_frequency_fast` | Differential Distribution Table (DDT) maximum frequency |
| `basic_sac_vectorized_fast` | Strict Avalanche Criterion (SAC) evaluation |
| `guided_swap_move_multiple!` | Guided swap toward pbest or gbest |
| `massive_triple_swap_batch!` | Cyclic triple-swap exploration operator |
| `random_perturbations!` | Adaptive random perturbation for diversity |
| `update_particle_aggressive!` | Full particle update combining all operators |
| `pso_optimize_with_early_stopping` | Main PSO loop with adaptive parameters and early stopping |

The algorithm uses Julia's native multi-threading (`Threads.@threads`) for parallel particle evaluation.

---

## Requirements

- **Julia** >= 1.8 (tested on Julia 1.11.5)
- **Standard library packages** (no installation needed): `Random`, `Statistics`, `Distributed`, `Dates`, `Base.Threads`
- **Third-party package** (must be installed): `ProgressMeter`

Install the required package before running:

```julia
using Pkg
Pkg.add("ProgressMeter")
```

---

## Usage Instructions

### Step 1 — Set the initial S-box

Open `code/aPSO_algorithm.jl` and locate the `sbox3` variable near the end of the file (line ~832). Replace it with your own 256-element permutation vector (UInt8 values, each 0–255, all unique):

```julia
sbox3 = UInt8[142, 107, 195, 243, ...]  # your S-box here
```

### Step 2 — Configure algorithm parameters (optional)

At the top of the file, adjust the constants if needed:

```julia
const ITER = 200000     # maximum number of iterations
const SSIZE = 100       # swarm size (number of particles)
const EARLY_STOP_CHECK_AFTER = 10000    # check early stopping after this step
const EARLY_STOP_NL_THRESHOLD = 111.5  # stop early if NL below this value
```

### Step 3 — Run the algorithm

**Single-threaded:**
```bash
julia code/aPSO_algorithm.jl
```

**Multi-threaded (recommended — up to 16 threads):**
```bash
julia --threads 8 code/aPSO_algorithm.jl
```

### Step 4 — Check outputs

The algorithm produces the following output files in the working directory:

| File | Contents |
|---|---|
| `initial_sbox.txt` | Starting S-box with cryptographic analysis |
| `final_sbox.txt` | Best S-box found after optimisation |
| `initial_analysis.txt` | NL, SAC, DDT, Entropy of initial S-box |
| `final_analysis.txt` | NL, SAC, DDT, Entropy of optimised S-box |
| `optimization_results.txt` | Step-by-step improvement log |
| `global_best_swaps_only.log` | Detailed log of every global best update |
| `particle_move_statistics.txt` | Per-particle move type breakdown |
| `debug_sboxes/` | S-box snapshots at each global best update |

---

## Methodology

The aPSO algorithm adapts continuous PSO to discrete permutation space through four swap operators:

1. **Guided swap toward pbest** — moves the particle's permutation closer to its personal best by swapping mismatched positions (cognitive component, probability `c1`).
2. **Guided swap toward gbest** — moves toward the global best permutation (social component, probability `c2`).
3. **Triple cyclic swap** — rotates three randomly selected positions (i→j, j→k, k→i), exploring configurations unreachable by pairwise swaps (exploration component, probability `w`).
4. **Random perturbation** — applies a small number of random swaps with fixed probability 0.3 to maintain population diversity.

**Adaptive inertia:** The triple-swap probability `w` increases when no improvement is found (to promote exploration) and decreases when improvement occurs (to promote exploitation).

**Early stopping:** After a configurable number of iterations, the run is terminated if the best NL is below a threshold, preventing wasted computation on poor starting configurations.

**Fitness metric:** Coordinate nonlinearity — the minimum nonlinearity across all 8 bit-plane Boolean functions of the S-box. This matches the AES design criterion (coordinate NL = 112).

Parameter configurations for each experimental case are listed in Table 1 of the manuscript.

---

## Citations

If you use this code or data in your research, please cite:

```
Caglar, D. (2025). Discrete Particle Swarm Optimization for Cryptographic
Substitution Box Design in Permutation Spaces. PeerJ Computer Science.
```

---

## License

This code and data are made available under the **MIT License**.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated files, to deal in the software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the software, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

---

*Author: Durdane (Kocacoban) Caglar*
