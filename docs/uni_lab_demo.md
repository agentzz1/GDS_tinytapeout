# Uni Lab Demo Guide

This project can be demonstrated on a Tiny Tapeout demo board without any ASIC-specific tooling. The goal is not a deep silicon characterization run. The goal is a clean 10-minute lab demo that answers four questions:

1. Can the board see and enable the project?
2. Do `reset`, `clock`, and status bits react sanely?
3. Does one fixed test vector produce a stable output?
4. Does changing one context byte change the output?

## What To Use

- Tiny Tapeout demo board + breakout board with the shuttle that contains `tt_um_agentzz1_rtx8090`
- Browser for `https://commander.tinytapeout.com/`
- The board-side helper script: [`demo/tt_um_agentzz1_rtx8090_demo.py`](../demo/tt_um_agentzz1_rtx8090_demo.py)

The browser is only used for bring-up. The actual vector loading is much easier through the helper script because this design uses a raw byte-wide command bus rather than UART or SPI.

## Fast Bring-up In Commander

1. Plug the Tiny Tapeout demo board into USB.
2. Open `https://commander.tinytapeout.com/` in Chrome, Edge, Brave, or Opera.
3. Connect to the board and select `tt_um_agentzz1_rtx8090`.
4. Set the project clock to `100 kHz` or `1 MHz`.
5. Toggle reset once.

Success criteria:

- The board connects cleanly.
- The project can be selected.
- Reset and clock control do not cause obviously unstable behavior.

If bring-up already fails here, stop and use that as the demo result: the board path needs work before the transformer test can be attempted.

## Board Script Workflow

Load [`demo/tt_um_agentzz1_rtx8090_demo.py`](../demo/tt_um_agentzz1_rtx8090_demo.py) onto the demo board filesystem, then open the board REPL and run:

```python
import tt_um_agentzz1_rtx8090_demo as demo
demo.run_all()
```

The script runs three stages:

- `run_smoke()`: idle -> busy -> done state transition
- `run_gold()`: fixed end-to-end vector test, then repeat to confirm reproducibility
- `run_change()`: modify one context byte and confirm the final output changes

If you only want the simplest possible lab flow, run these one by one:

```python
demo.run_smoke()
demo.run_gold()
demo.run_change()
```

## Gold Test Vectors

The lab demo uses one fixed data set that matches the cocotb reference test.

Query:

```text
[16, -8, 20, 4, -12, 8, 24, -16]
```

Context slots:

```text
[12, -4, 8, 0, -8, 16, 4, -12]
[-16, 8, -4, 12, 20, -8, 0, 4]
[4, 20, -12, 8, -4, 12, -16, 16]
[8, 0, 16, -8, 12, -4, 20, -12]
```

Expected final output from read bank `0`:

```text
[21, -9, 25, 4, -7, 8, 27, -11]
```

The script runs the same execute sequence twice. Both runs should return the same final output.

## Change Test

After the gold test, modify one byte:

- Context slot `2`
- Feature index `5`
- New value `-20`

Expected final output after the update:

```text
[17, -3, 25, -3, -4, 5, 31, -15]
```

This is the most convincing live demo step because it shows that:

- the context memory really updates,
- the compute path runs again,
- and the result depends on the loaded data.

## Fallback Demo

If the full gold test does not work on the lab hardware, the fallback demo is still valid:

1. Select the project on the board.
2. Show that reset and clock control work.
3. Read status before and after `execute`.
4. Use the `run_smoke()` result as the primary demo artifact.

That still proves:

- the correct project is reachable on the shuttle,
- the Tiny Tapeout project MUX is selecting the intended design,
- and the board can drive the project inputs and read project outputs.

## Interface Summary

The helper script drives the exact RTL interface:

- `ui_in[7:0]`: payload byte
- `uio_in[1:0]`: context slot or read bank
- `uio_in[4:2]`: feature index
- `uio_in[6:5]`: command
- `uio_in[7]`: strobe
- `uo_out[7:0]`: status or readback byte

Commands:

- `00`: write query byte
- `01`: write context byte
- `10`: read status or trigger execute
- `11`: read result bank

Status bits:

- bit `7`: `done`
- bit `6`: `busy`
