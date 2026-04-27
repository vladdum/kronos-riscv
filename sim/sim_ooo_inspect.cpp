// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// sim_ooo_inspect.cpp — Stage 5h placeholder for OoO state inspection hooks.
//
// Stage 6 (BOOM-style OoO) will introduce a reorder buffer, issue queue,
// load/store queue, and register alias table.  This file reserves the
// symbol convention so sim-side dumpers can read those structures via
// Verilator's --public-flat-rw without further RTL plumbing.
//
// Convention (Stage 6, future):
//   u_top.u_rob.*  — reorder buffer entries, head/tail pointers
//   u_top.u_iq.*   — issue queue entries, ready bits, age
//   u_top.u_lsq.*  — load/store queue entries, age, completion mask
//   u_top.u_rat.*  — register alias table (logical -> physical mapping)
//
// In Stage 5h these instances do not exist; this translation unit is empty
// other than this comment so the build compiles clean.  Stage 6 will fill
// in the inspector entry points and link them into sim_main.cpp via a
// conditional dispatch on a +ooo_dump=<path> Verilator plusarg.

namespace kronos_ooo_inspect {
    // Reserved namespace — no symbols defined yet.
}
