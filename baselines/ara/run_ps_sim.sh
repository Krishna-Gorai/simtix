# Run a program on the board-wrapper model: run_ps_sim.sh <elf (Windows-mounted path)> <log>
# extra arguments after <log> go to the model, e.g. +TMO=3000000 (host timeout, cycles)
M=$HOME/ara_wsl/build_ps_5020
cd $M && { date; time ./Vara_ps_tb -l ram,$1,elf "${@:3}"; echo "SIM EXIT $?"; date; echo SIM_DONE; } > $2 2>&1
