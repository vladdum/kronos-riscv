// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <cstdint>
extern "C" {
#include "softfloat.h"
}

extern "C" {

static inline void apply_rm(uint8_t rm) {
  softfloat_roundingMode = rm;
}
static inline void reset_flags() { softfloat_exceptionFlags = 0; }

void sf_reset(void) {
  softfloat_detectTininess = softfloat_tininess_afterRounding;
  softfloat_exceptionFlags = 0;
}

uint32_t sf_f32_add(uint32_t a, uint32_t b, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float32_t fa = {a}, fb = {b};
  return f32_add(fa, fb).v;
}
uint32_t sf_f32_sub(uint32_t a, uint32_t b, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float32_t fa = {a}, fb = {b};
  return f32_sub(fa, fb).v;
}
uint32_t sf_f32_mul(uint32_t a, uint32_t b, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float32_t fa = {a}, fb = {b};
  return f32_mul(fa, fb).v;
}
uint32_t sf_f32_mulAdd(uint32_t a, uint32_t b, uint32_t c, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float32_t fa = {a}, fb = {b}, fc = {c};
  return f32_mulAdd(fa, fb, fc).v;
}
uint64_t sf_f64_add(uint64_t a, uint64_t b, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float64_t fa = {a}, fb = {b};
  return f64_add(fa, fb).v;
}
uint64_t sf_f64_sub(uint64_t a, uint64_t b, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float64_t fa = {a}, fb = {b};
  return f64_sub(fa, fb).v;
}
uint64_t sf_f64_mul(uint64_t a, uint64_t b, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float64_t fa = {a}, fb = {b};
  return f64_mul(fa, fb).v;
}
uint64_t sf_f64_mulAdd(uint64_t a, uint64_t b, uint64_t c, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float64_t fa = {a}, fb = {b}, fc = {c};
  return f64_mulAdd(fa, fb, fc).v;
}
int32_t  sf_f32_to_i32 (uint32_t a, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float32_t fa = {a};
  return f32_to_i32(fa, rm, true);
}
uint32_t sf_f32_to_ui32(uint32_t a, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float32_t fa = {a};
  return f32_to_ui32(fa, rm, true);
}
int64_t  sf_f32_to_i64 (uint32_t a, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float32_t fa = {a};
  return f32_to_i64(fa, rm, true);
}
uint64_t sf_f32_to_ui64(uint32_t a, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float32_t fa = {a};
  return f32_to_ui64(fa, rm, true);
}
uint32_t sf_f64_to_f32(uint64_t a, uint8_t rm) {
  reset_flags(); apply_rm(rm);
  float64_t fa = {a};
  return f64_to_f32(fa).v;
}
uint64_t sf_f32_to_f64(uint32_t a) {
  reset_flags();
  float32_t fa = {a};
  return f32_to_f64(fa).v;
}
uint8_t sf_exceptions(void) {
  return (uint8_t)softfloat_exceptionFlags;
}

} // extern "C"
