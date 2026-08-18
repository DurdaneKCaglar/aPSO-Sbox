Supplemental Data S1
====================
Article: Discrete Particle Swarm Optimization for Cryptographic Substitution Box Design in Permutation Spaces
Author:  Durdane (Kocacoban) Caglar
Journal: PeerJ Computer Science

CONTENTS
--------

code/
  aPSO_algorithm.jl
    Julia implementation of the Aggressive Particle Swarm Optimization (aPSO)
    algorithm used in all experimental cases. The algorithm uses swap-based
    permutation operators and adaptive stagnation control. Requires Julia 1.x.
    Parameter configurations for each case are described in Table 1 of the
    manuscript.

results/
  Case_00_initial_sbox.txt  /  Case_00_final_sbox.txt
  Case_01_initial_sbox.txt  /  Case_01_final_sbox.txt
  ...
  Case_10_initial_sbox.txt  /  Case_10_final_sbox.txt

    For each experimental case (Cases 0-10), two files are provided:
      - initial_sbox.txt : the starting S-box fed to the optimizer
      - final_sbox.txt   : the best S-box found after optimization

    Each file contains a 256-entry permutation vector representing an 8x8 S-box
    (integer values 0-255, one per line or space-separated).

multiple_runs/
  Case_0_#P100_97.25_to_111.5/
  Case_1_#P100_97.25_to_111.625/
  ...
  Case_10_#P200_105.0_to_111.75/

    Raw output from 20 independent optimization runs for each experimental case,
    supporting the statistical results (Mean NL, Worst NL, Best NL) reported in
    Table 2 of the manuscript. Each case folder contains:

      run01/ run02/ ... run20/

    Each run folder contains:
      - initial_sbox.txt : the starting S-box for that run
      - final_sbox.txt   : the best S-box found in that run

    The folder naming convention encodes the case configuration and the
    nonlinearity range observed across runs (e.g., "#P100_97.25_to_111.5"
    denotes 100 particles, initial mean NL of 97.25, best achieved NL of 111.5).

NOTES
-----
Cases 0-10 correspond to different algorithm configurations (particle count,
initialization strategy, chaotic map variant) as detailed in Section 4 of
the manuscript. All cases run the same core aPSO algorithm (aPSO_algorithm.jl)
with the parameters listed in Table 1.
