// ara_ps_tb.cpp - Verilator driver of ara_ps_tb (after Ara's tb/verilator/ara_tb.cpp):
// preloads the ELF given with "-l ram,<elf>,elf" into the DDR model i_ddr, which
// stands for the DDR window that Ara sees at 0x8000_0000.
#include <fstream>
#include <iostream>

#include "verilated_toplevel.h"
#include "verilator_memutil.h"
#include "verilator_sim_ctrl.h"

int main(int argc, char **argv) {
  ara_ps_tb *tb = new ara_ps_tb;

  VerilatorMemUtil memutil;
  VerilatorSimCtrl &simctrl = VerilatorSimCtrl::GetInstance();
  simctrl.SetTop(tb, &tb->clk_i, &tb->rst_ni,
                 VerilatorSimCtrlFlags::ResetPolarityNegative);

  MemAreaLoc ddr = {.base = 0x80000000, .size = 0x00100000};
  memutil.RegisterMemoryArea("ram", "TOP.ara_ps_tb.i_ddr", 64, &ddr);
  simctrl.RegisterExtension(&memutil);

  simctrl.SetInitialResetDelay(5);
  simctrl.SetResetDuration(5);

  bool exit_app = false;
  int ret_code = simctrl.ParseCommandArgs(argc, argv, exit_app);
  if (exit_app) return ret_code;

  std::cout << "Simulation of ara_ps_wrap (board configuration)" << std::endl;
  simctrl.RunSimulation();
  return tb->dut().exit_o >> 1;
}
