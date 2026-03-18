# TinyTransformer on Tiny Tapeout

This repository now implements a quantized transformer-style inference block sized for the maximum Tiny Tapeout user macro footprint (`8x2` tiles). The design accepts an 8-element query vector plus four 8-element context vectors over a serial command interface, then runs a MAC-reused inference pipeline with:

- fixed-weight multi-head attention
- output projection with residual connection
- feed-forward network with GELU approximation

The internal math is intentionally serialized so the design fits the ASIC floorplan instead of exploding into a fully unrolled matrix engine.

## Interface Summary

- `ui_in[7:0]`: signed Q4.4 payload byte
- `uio_in[1:0]`: context slot or read bank selector
- `uio_in[4:2]`: feature index `0..7`
- `uio_in[6:5]`: command
- `uio_in[7]`: write / execute strobe
- `uo_out[7:0]`: status word or readback data

Command encoding:

- `00`: load query feature
- `01`: load context feature
- `10`: status / execute (`feature_idx=7` with `strobe=1` starts inference)
- `11`: read bank

Read banks:

- `slot_sel=0`: final transformer output
- `slot_sel=1`: post-attention residual mix
- `slot_sel=2`: projected query vector
- `slot_sel=3`: attention weights

## Status Word

When `cmd=10` and `strobe=0`, `uo_out` exposes:

- `uo_out[7]`: done
- `uo_out[6]`: busy
- `uo_out[5]`: read mode marker
- `uo_out[4:2]`: pipeline stage

## Layout

- `src/project.v`: Tiny Tapeout wrapper and bus protocol
- `src/control.v`: 4-stage execution controller
- `src/datapath.v`: fixed-weight transformer datapath
- `test/transformer_test.py`: cocotb reference-model verification

## Demo Board Bring-up

This project now includes a noob-friendly demo path for a real Tiny Tapeout devkit:

- Browser bring-up in Tiny Tapeout Commander
- One fixed gold test vector with expected output
- One context update test that must change the output
- A fallback smoke test if the full vector demo does not work on first silicon

Use:

- [`docs/uni_lab_demo.md`](docs/uni_lab_demo.md) for the exact lab flow
- [`demo/tt_um_agentzz1_rtx8090_demo.py`](demo/tt_um_agentzz1_rtx8090_demo.py) for the Tiny Tapeout demoboard REPL script

The expected final output for the shipped gold vector is:

```text
[21, -9, 25, 4, -7, 8, 27, -11]
```

## References

- Tiny Tapeout: https://tinytapeout.com
- Local hardening guide: https://www.tinytapeout.com/guides/local-hardening/
- Datasheet notes: [docs/info.md](docs/info.md)
