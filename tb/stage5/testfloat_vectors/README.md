# TestFloat vectors

Regenerate with `tools/gen_testfloat_vectors.py`. Requires `testfloat_gen` from
berkeley-testfloat-3 on PATH.

Format (space-separated hex, no `0x` prefix):

    a b c expected rm flags

For 2-operand ops, `c` is omitted: `a b expected rm flags`.

The vector files are checked in so CI needs no network or TestFloat install.
