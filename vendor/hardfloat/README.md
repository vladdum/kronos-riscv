# Berkeley HardFloat — vendored

This directory contains a pinned copy of the pre-generated Verilog from
Berkeley HardFloat (BSD-3 license — see `LICENSE`).

- Upstream: https://github.com/ucb-bar/berkeley-hardfloat
- Upstream commit: see `UPSTREAM_SHA`
- Used **only in testbenches** as a golden IEEE 754 reference. Not
  instantiated in any synthesisable RTL.

## Notes

The upstream repository no longer ships pre-generated `.v` files (Chisel-only
source as of the pinned commit). The files in this directory are behavioural
Verilog stubs with interfaces that match the Chisel-generated port names.
Each file is marked `// STUB - replace with real HardFloat generated Verilog`.

When `sbt` and Chisel tooling become available, regenerate from the upstream
SHA recorded in `UPSTREAM_SHA` and replace these stubs.
