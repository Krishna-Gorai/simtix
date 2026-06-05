# M12 — CPU-side input loading (host populates the working set at runtime)

Through M11 the A/B operand arrays lived in the shared memory's synthesizable
`initial` block — the data was simply *there* at power-up. That is fine for a
self-checking demo, but it hides the most characteristic act of a heterogeneous
SoC: the **host CPU preparing the input data** in shared memory before kicking off
the accelerator. M12 makes the host do exactly that.

## What changed

- **`cpu_driver_rom.sv`** — the driver program gains a **store-loop preamble**
  (14 instructions) that runs before anything else. It writes the operands into
  shared memory at runtime:

  ```
  A[i] = 10  + i      @ 0x300 + 4i
  B[i] = 100 + 2i     @ 0x340 + 4i      for i = 0..7
  ```

  a plain RV32I loop (`sw` to ascending pointers, increment the running operand
  values, `bne` back) — hand-assembled and bit-verified like the rest of the ROM.
  Only then does it program the command block (`kernel_pc/base_a/b/c/N`), set `GO`,
  poll `DONE`, read `C[0..7]` back, sum them, and publish the result.

- **`shared_mem.sv`** — the A/B preload is **removed** from `init_word()`. Now only
  the kernel code (`0x200`, the accelerator's program memory) and a `0xdeadbeef`
  poison for `C` (`0x380`) are initialised; everything else, including the A/B
  apertures, powers up as `0`. So if the host's store loop did *not* run correctly,
  `A = B = 0` and the result would be `0`, not `964` — the passing test now
  **proves** the CPU populated the working set, rather than reading back data the
  memory happened to contain.

## Result

`tb_chip_top` (drives only `clk`/`rst`) still gets the right answer:

```
[tb_chip_top] PASS: chip computed result = 964 in ~198 cycles
```

The cycle count rises from ~114 (M10/M11) to ~198 because the host now executes the
8-iteration input-loading loop before launching the accelerator — that delta *is*
the CPU doing the data movement. Full regression stays green (7/7 lints, 6/6 tests).

The data flow is now the complete heterogeneous-SoC story end to end:

```
CPU writes A,B  ->  shared memory  ->  CPU programs+launches accel over MMIO
   ->  accel reads A,B / computes / writes C  ->  CPU reads C back, sums, publishes
```

## Reproduce

```
make -C sim test-chip      # result=964, now with the host loading the inputs
```
