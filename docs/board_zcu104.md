# SIMTiX v2 on the ZCU104 (A53 host, DDR4)

The board build makes the accelerator a peripheral of the Zynq UltraScale+ PS:

```
Cortex-A53 --M_AXI_HPM0_FPD--> SmartConnect --AXI4-Lite--> simt_ps_top (0xA000_0000)
simt_accel --> l1_dcache --> axi_line_master --AXI4 128-bit--> S_AXI_HP0_FPD --> DDR4
```

| Window offset | Contents |
|---|---|
| `0x0000`–`0x00FF` | command / status registers (`REG_*` in `simtix_pkg.sv`) |
| `0x0100` / `0x0104` | L1 read hits / misses of the last kernel |
| `0x0108` | bit 0: an AXI error response was seen |
| `0x1000`–`0x1FFF` | kernel instruction RAM (1024 words); `REG_KERNEL_PC` is an offset into it |

Data buffers must lie below `0x4000_0000`: addresses with bits [31:30] = `01` are the
accelerator's scratchpad apertures. The HP0 port is not coherent with the A53
caches, so the host cleans its data cache before GO and invalidates it after DONE.
Writing GO also invalidates the L1.

## Build (on the PC)

1. Bitstream and hardware platform, from `fpga/` (launch Vivado from PowerShell):

   ```
   vivado -mode batch -source create_bd_ps.tcl -tclargs build
   ```

   writes `fpga/simtix_ps.xsa` and the reports in `fpga/reports_ps/`.

2. Host program (regenerate `kernels.h` only if a kernel changed):

   ```
   python sw/ps_host/gen_kernels.py
   vitis -s sw/ps_host/build_vitis.py
   ```

   builds `sw/ps_host/ws/ps_host/build/ps_host.elf`. Two gaps in a Vitis install
   without the Zynq UltraScale+ software components stop this step:

   - no `aarch64-none-elf-gcc`: install the Arm GNU Toolchain (14.2.rel1,
     `aarch64-none-elf`) and put its `bin` on `PATH`, or set `AARCH64_GCC_DIR`;
     the script defaults to `C:\toolchains\arm-gnu-14.2-aarch64-none-elf\bin`.
   - platform creation fails with "Application error processing RPC": the server
     is trying to copy QEMU files that were not installed. Creating the empty
     directories `Vitis\data\emulation\platforms\zynqmp\sw\{a53_linux,a53_standalone,r5_standalone}\qemu`
     is enough for a JTAG run.

## Run (in the lab)

1. Boot-mode switch SW6 to JTAG (all four ON); connect USB-JTAG and USB-UART;
   power on.
2. Open a terminal on the board's first USB-UART port at 115200 8N1.
3. From the repository root: `xsdb sw/ps_host/run_board.tcl` (`xsdb` is in `Vivado\bin`).

The program prints one CSV line per run and a final verdict:

```
BOARD,kernel,N,accel_cycles,accel_us,a53_us,l1_hits,l1_misses,errors
BOARD,reduce_shfl,1024,...
...
RESULT: PASS (0 errors)
```

`accel_cycles` is the accelerator's own cycle counter (100 MHz); `accel_us` is
the wall time from GO to DONE measured by the A53 (including register polling);
`a53_us` is the same computation on one A53 core.

After `reduce_shfl` and `histogram`, the application suite (`sw/ps_host/apps.c`,
the kernels of `kernels/apps/`) prints one row per application and size, with the
size in the `N` column: `gemm` (n x n FP32, n = 64, 256), `spmv` (rows, 16 nonzeros
at most per row), `stencil` (n x n, 4 sweeps), `kmeans` (points, 16 clusters),
`bfs` (vertices, degree 8) and `scan` (elements). Multi-launch applications
(stencil, BFS, scan) sum cycles and L1 counts over their launches, and `accel_us`
covers the first GO to the last DONE. The A53 baselines are ordinary sequential
codes (a queue for BFS, a running sum for scan, i-k-j GEMM), and every accelerator
output is compared exactly with them; the data lives in DDR4 at `0x1000_0000`.
