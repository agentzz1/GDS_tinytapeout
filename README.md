# GDS TinyTapeout

This repository captures a Tiny Tapeout digital-design experiment built on the Wokwi-based submission template. The goal is to explore a compact chip-oriented workflow that links project metadata, pin planning, simulation, and fabrication-style repository structure.

## Why This Repository Exists

- to learn the Tiny Tapeout submission flow end to end
- to work within a constrained digital-design footprint
- to bridge software-oriented iteration habits with ASIC-style project packaging

## Repository Layout

- `info.yaml` - project metadata, pinout, and tapeout configuration
- `src/` - design sources
- `test/` - verification and test assets
- `docs/` - project notes and datasheet content

## Current Status

- Tiny Tapeout template scaffolded and connected to the project metadata flow
- design documentation and pin descriptions are being refined
- repository structure kept intact for simulation and build automation

## Relevance

This project complements my FPGA and hardware-software background by forcing a smaller, more fabrication-oriented mindset: constrained interfaces, explicit pin planning, and a cleaner separation between metadata, design sources, and verification assets.

## Resources

- Tiny Tapeout: https://tinytapeout.com
- Local hardening guide: https://www.tinytapeout.com/guides/local-hardening/
- Documentation entrypoint: [docs/info.md](docs/info.md)
