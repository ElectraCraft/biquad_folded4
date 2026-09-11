# sim/

Testbench and simulation output for functional verification.

- `tb_biquad_folded4.v` — drives impulse and step response tests, cross-checked against a bit-accurate Python golden model (results match exactly).

Run with: `iverilog -o sim_out ../src/biquad_folded4.v tb_biquad_folded4.v && vvp sim_out`
