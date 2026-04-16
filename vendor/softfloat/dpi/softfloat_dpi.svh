// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// SystemVerilog DPI bindings to Berkeley SoftFloat 3e.
// Every function resets softfloat state before each call.

package softfloat_dpi_pkg;

  import "DPI-C" function void sf_reset();

  import "DPI-C" function int unsigned sf_f32_add(int unsigned a, int unsigned b, byte unsigned rm);
  import "DPI-C" function int unsigned sf_f32_sub(int unsigned a, int unsigned b, byte unsigned rm);
  import "DPI-C" function int unsigned sf_f32_mul(int unsigned a, int unsigned b, byte unsigned rm);
  import "DPI-C" function int unsigned sf_f32_mulAdd(int unsigned a, int unsigned b,
                                                      int unsigned c, byte unsigned rm);
  import "DPI-C" function longint unsigned sf_f64_add(longint unsigned a,
                                                      longint unsigned b, byte unsigned rm);
  import "DPI-C" function longint unsigned sf_f64_sub(longint unsigned a,
                                                      longint unsigned b, byte unsigned rm);
  import "DPI-C" function longint unsigned sf_f64_mul(longint unsigned a,
                                                      longint unsigned b, byte unsigned rm);
  import "DPI-C" function longint unsigned sf_f64_mulAdd(longint unsigned a,
                                                         longint unsigned b,
                                                         longint unsigned c, byte unsigned rm);

  import "DPI-C" function int          sf_f32_to_i32 (int unsigned a, byte unsigned rm);
  import "DPI-C" function int unsigned sf_f32_to_ui32(int unsigned a, byte unsigned rm);
  import "DPI-C" function longint          sf_f32_to_i64 (int unsigned a, byte unsigned rm);
  import "DPI-C" function longint unsigned sf_f32_to_ui64(int unsigned a, byte unsigned rm);
  import "DPI-C" function int unsigned sf_f64_to_f32(longint unsigned a, byte unsigned rm);
  // f32_to_f64 is exact (no rounding); rm parameter intentionally omitted.
  import "DPI-C" function longint unsigned sf_f32_to_f64(int unsigned a);

  import "DPI-C" function int unsigned sf_f32_div(int unsigned a, int unsigned b,
                                                   byte unsigned rm);
  import "DPI-C" function longint unsigned sf_f64_div(longint unsigned a,
                                                      longint unsigned b, byte unsigned rm);
  import "DPI-C" function int unsigned sf_f32_sqrt(int unsigned a, byte unsigned rm);
  import "DPI-C" function longint unsigned sf_f64_sqrt(longint unsigned a, byte unsigned rm);

  import "DPI-C" function byte unsigned sf_exceptions();

endpackage
