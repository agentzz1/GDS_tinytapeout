## How it works

This design is a compact transformer-style inference block adapted to the Tiny Tapeout pin budget and scaled to the largest available user-macro size (`8x2` tiles).

### Datapath

The chip stores:

- one 8-element signed Q4.4 query vector
- four 8-element signed Q4.4 context vectors

After an execute command, the controller advances through four registered stages:

1. `PROJ`: fixed-weight query/key/value projections
2. `ATTN`: per-head attention score generation and approximate softmax weighting
3. `MIX`: output projection with residual add
4. `FFN`: feed-forward network with GELU approximation and final residual add

Each stage reuses a small multiply-accumulate datapath over many cycles. That keeps the design transformer-like while staying small enough to harden inside the `8x2` Tiny Tapeout area.

### Protocol

`ui_in[7:0]` carries the signed data byte. `uio_in` is interpreted as:

- `uio_in[1:0]`: slot selector / read bank
- `uio_in[4:2]`: feature index
- `uio_in[6:5]`: command
- `uio_in[7]`: strobe

Commands:

- `00`: write query feature
- `01`: write context feature for slot `0..3`
- `10`: read status, or execute when `feature_idx = 7` and `strobe = 1`
- `11`: read result/debug bank

Read banks:

- `0`: final output vector
- `1`: residual mix after attention
- `2`: projected query vector
- `3`: attention weights

### Status

With `cmd=10` and `strobe=0`, `uo_out` becomes a status byte:

- bit `7`: `done`
- bit `6`: `busy`
- bit `5`: high when read mode is selected
- bits `4:2`: current controller state

Because the engine is serialized, one inference takes a few hundred clock cycles instead of a handful of cycles from a fully unrolled datapath.

### Verification

The cocotb testbench mirrors the exact fixed-point math in Python, including:

- deterministic pseudo-weight generation
- projection scaling
- attention weight approximation
- GELU approximation
- residual and FFN stages

That lets the simulation check the hardware against a software reference for both final output and internal debug banks.

### Demo Board Testing

For real hardware bring-up on a Tiny Tapeout demo board, use the short lab guide in [uni_lab_demo.md](uni_lab_demo.md). It covers:

- Commander-based project selection and clock/reset bring-up
- a single fixed gold test vector
- an input-change test that should alter the final output
- a fallback smoke test if full silicon validation is not yet possible
