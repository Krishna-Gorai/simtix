# A53 references on a ZCU102, without the accelerator

The lab's board is a ZCU102 (XCZU9EG), not the ZCU104 (XCZU7EV) the board design
targets. The XCZU9EG is not in Vivado ML Standard, so no SIMTiX bitstream can be
built for it without a license. This directory runs the A53 side of the
application suite on the ZCU102 anyway: the same sequential references as the
board host (`sw/ps_host/apps.c`), on the same input sets, with the board's power
monitors read over I2C. The SIMTiX side comes from simulation
(`sim/board_sim.py`).

Everything runs over the one JTAG cable (J2). No SD card, FSBL or Vivado-generated
`psu_init` is used.

## How it works

1. **PS bring-up** (`build_init.py`, `init/`, `run_init.tcl`). The ZCU102's
   processing-system initialisation (MIO, PLLs, clocks, DDR4 controller and PHY,
   peripherals, serdes) is U-Boot's
   `board/xilinx/zynqmp/zynqmp-zcu102-rev1.1/psu_init_gpl.c` (GPL-2.0+).
   `build_init.py` downloads it into `third_party/` (not committed; its URL and
   SHA-256 go to `third_party/zcu102-<rev>/SOURCE.txt`) and links it with
   `init/crt0.S` and `init/init_main.c` into a 17 KB program that runs from OCM
   with the MMU and caches off, so nothing touches DDR before it is up.
   `run_init.tcl` loads it on A53 #0, waits for the mailbox at `0xFFFF_F000`,
   tests DDR over the debug port and prints the APU clock.
2. **A53 program** (`build_a53.py`, `a53_main.c`, `run_a53.tcl`). `a53_main.c`
   with `apps.c` built `-DSIMTIX_A53_ONLY` (the accelerator phases are skipped)
   and `power.c` (ZCU102 monitor table), linked against the standalone A53 BSP of
   the ZCU104 board-host workspace (`sw/ps_host/ws`): the PS of the two devices is
   the same. Two board differences are handled in the program: the I2C0
   controller (not in the ZCU104 hardware description) and the system-counter
   frequency, which `run_a53.tcl` measures against the host clock over 10 s and
   passes in a mailbox (`0x0EF0_0000`). `xil_printf` is redirected
   (`--wrap=outbyte`) into a DDR buffer at `0x0E00_0000` that the script reads
   back. The program clears the arena (`0x1000_0000`, 256 MB) first and prints an
   FNV-1a hash of the arena after each application, so two builds can be shown to
   compute the same results.

## Running it

Board: boot-mode switch SW6 as found (SD boot is fine: the SD image leaves the PS
uninitialised), J2 (JTAG) to the PC, 12 V on J52, power on.

```
python sw/a53_zcu102/build_init.py rev1.1
python sw/a53_zcu102/build_a53.py O2          # -O2, the board host's build
python sw/a53_zcu102/build_a53.py O3          # -O3 -mcpu=cortex-a53 (NEON)
xsdb sw/a53_zcu102/run_init.tcl               # expect "DDR TEST PASSED", 1200.0 MHz
xsdb sw/a53_zcu102/run_a53.tcl O2             # -> docs/zcu102_a53_run_O2.txt
xsdb sw/a53_zcu102/run_a53.tcl O3             # -> docs/zcu102_a53_run_O3.txt
```

`xsdb` is `C:\Xilinx\xic\2025.1\Vivado\bin\xsdb.bat`; launch it from PowerShell
after `Remove-Item Env:\NoDefaultCurrentDirectoryInExePath`. After a power cycle,
run `run_init.tcl` again. Each A53 run takes about 2.5 minutes.

## Output

```
A53,<app>,<size>,<a53_us>,<arena_fnv1a>
POWERRAIL,<rail>,<mV>,<mW>
POWER,<app>,<size>,<phase>,<rail>,<mV>,<mW>,<samples>,<reps>,<ms>
```

Phases: `idle` (the A53 polls a memory word, as it polls the accelerator) and
`a53` (the A53 runs the reference), each repeated for 6 s. Rails are named by the
monitor's reference designator (`ps_u76` ... `pl_u75`); see
`docs/zcu102_a53.md` for the measured voltages and the results.

## Things that cost time (2026-10-28)

- Without a license Vivado cannot target the XCZU9EG (its device files are not
  installed; UG973 lists the ZU9 under Enterprise only).
- JTAG was invisible until Vivado's own Digilent runtime was installed:
  `C:\Xilinx\xic\2025.1\Vivado\data\xicom\cable_drivers\nt64\digilent\install_digilent.exe`
  as administrator (an older 2018 runtime was present).
- The ZCU102 UARTs (CP2108) need the Silicon Labs CP210x driver; Windows Update
  does not offer it. COM3 is the A53 console, COM6 the system controller.
- Reading DDR over JTAG before it is initialised wedges the debug port ("AXI AP
  transaction error"); only a power cycle clears it.
- psu_init's IOU_SCNTRS base frequency (93,843,752 Hz) is wrong for this board;
  the counter runs at IOPLL/16 = 94.79 MHz (measured).
- The BSP sets PMCR_EL0.D, so the cycle counter counts every 64th cycle; the
  program clears it before measuring the A53 clock.
- `outbyte` is defined inside the BSP's UART driver object, so it is wrapped,
  not overridden.
