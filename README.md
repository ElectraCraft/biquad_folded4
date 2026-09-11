# biquad_folded4 — 4-Folded Biquad IIR Filter (RTL-to-GDSII, Open Source Flow)

A Direct Form II biquad IIR filter implemented with a **register-minimization / time-multiplexing** technique — one shared multiply-accumulate (MAC) datapath is reused across a 4-slot schedule per sample, rather than instantiating three separate multipliers. Taken end-to-end from RTL through a signed-off GDSII layout using an entirely open source toolchain.

## Architecture

```
H(z) = (b0 + b1·z⁻¹ + b2·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²)
```

Direct Form II: `w[n] = x[n] - a1·w[n-1] - a2·w[n-2]`, `y[n] = b0·w[n] + b1·w[n-1] + b2·w[n-2]`

Rather than three parallel multipliers, one shared MAC is time-multiplexed across 4 clock cycles ("slots") per input sample:

| Slot | Operation |
|---|---|
| 0 | Snapshot `w[n-1]`, `w[n-2]`; compute `-a1·w[n-1]` |
| 1 | Accumulate `-a2·w[n-2]` term |
| 2 | Form `w[n]` (saturating add), compute `b1·w[n-1]` |
| 3 | Form `y[n]` from the three descaled MAC terms (saturating add) |

Coefficients are fixed-point, Q8 format (scaled by 2⁸ = 256). All intermediate MAC results are saturated to 16 bits after descaling.

## Toolchain

| Stage | Tool |
|---|---|
| Simulation | Icarus Verilog (`iverilog`/`vvp`), GTKWave |
| Synthesis | Yosys |
| Place & route | OpenROAD, orchestrated via [LibreLane](https://github.com/librelane/librelane) |
| Physical verification | Magic (DRC), Netgen (LVS), KLayout (DRC cross-check, GDS view) |
| PDK | SkyWater sky130A (`sky130_fd_sc_hd` standard cell library) |

## Repository structure

```
biquad_folded4/
├── src/biquad_folded4.v       RTL
├── sim/tb_biquad_folded4.v    Testbench
├── config.json                 LibreLane flow configuration
├── docs/                       Results, notes, screenshots
└── README.md
```

(`runs/` — LibreLane's generated build output — is intentionally not tracked in git; regenerate with the command below.)

## Reproducing

**Simulate:**
```bash
cd sim
iverilog -o sim_out ../src/biquad_folded4.v tb_biquad_folded4.v && vvp sim_out
```

**Run the full RTL-to-GDSII flow** (inside the LibreLane environment, sky130 PDK auto-fetched on first run):
```bash
librelane --run-tag hd_lib_60ns ./config.json
```

## Verification

Correctness was established two independent ways before trusting any physical-design result built on top of it:

1. A **bit-accurate Python model** of the exact fixed-point datapath (matching the RTL's saturation/truncation arithmetic operation-for-operation), used to predict expected outputs.
2. **Icarus Verilog simulation** of the actual RTL against a corrected testbench — output matched the Python model exactly, sample for sample, on both an impulse response (`y[0] = 17`) and a step response (steady state = 249).

### Bugs found and fixed along the way

- **Missing saturation guard bit (`R_fb`)**: the slot-1 accumulation summed two already-saturated 16-bit MAC outputs directly into a 16-bit register with no extra bit, unlike the analogous `wn_full`/`yn_full` computations elsewhere in the same module, which correctly widen before saturating. Could silently wrap for high-Q coefficient sets. Fixed by applying the same widen-then-saturate pattern used elsewhere in the design.
- **Testbench frame/slot misalignment**: the sample-sending task waited for 5 clock edges per call instead of 4, silently drifting out of phase with the DUT's 4-cycle folded schedule after the first sample. Fixed, plus added a whitebox assertion so this class of bug can't silently regress.
- **Lint width-truncation warnings**: two internal wires were declared narrower than the combinational expressions assigned to them (harmless in practice, since the discarded bits were never read on the path actually used — confirmed via simulation), but corrected for a clean lint pass and clearer code.

## Physical implementation results

**Signoff run:** `hd_lib_60ns` — `sky130_fd_sc_hd`, 60 ns clock period (~16.7 MHz)

| Metric | Result |
|---|---|
| Clock period achieved | 60 ns (16.7 MHz), all 9 PVT corners |
| Worst-case setup slack | +8.75 ns (`max_ss_100C_1v60` corner) |
| Setup violations | 0, across all corners |
| DRC (Magic) | 0 errors |
| DRC (KLayout, cross-check) | 0 errors |
| LVS (Netgen) | 0 mismatches |
| Antenna violations | 0 |
| Die area | 111,711 µm² (~0.112 mm²) |
| Core utilization | 59.3% |
| Standard cell instance count | 19,383 |
| Total power | ~115.6 mW |

Clock period was arrived at empirically: an initial 20 ns target failed by ~11 ns at the slow/hot/low-voltage corner, traced to the shared MAC's combinational depth (a 16×16 signed multiply, with no hardened multiplier macro available in sky130). Clock relaxation was found to have diminishing returns as an isolated fix — see Future Work.

## Known limitations / future work

- **MAC combinational path is the real bottleneck.** The critical path runs through the shared multiply/shift/saturate logic. Pipelining it (registering the raw product, performing shift/saturate in a separate stage) would meaningfully raise the achievable frequency beyond what clock relaxation alone can reach — identified but not yet implemented.
- **Max slew violations (1377, across 6/9 corners) — characterized, not blocking.** Traced to `DEFAULT_MAX_TRAN`, a fixed 0.75 ns transition-time limit in the sky130_fd_sc_hd library, entirely decoupled from `CLOCK_PERIOD` — confirmed empirically, since violation count did not track clock relaxation the way setup slack did. Not a signoff-gating check.
- **One max-fanout violation**: the clock tree's root buffer (`clkbuf_0_clk`) drives 16 branches against the library's recommended limit of 10. Addressable via LibreLane's `CLOCK_BUFFER_FANOUT` variable in a future pass.
- Two floating *net* labels reported by the resizer (zero floating *pins* — likely dead-code remnants from an intentionally-unreachable default mux branch, not a real connectivity gap).

## License

*(add your preferred license, e.g. Apache-2.0, matching LibreLane's own licensing)*
