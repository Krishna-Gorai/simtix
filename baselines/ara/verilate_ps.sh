# Verilate the board wrapper ara_ps_wrap with its testbench ara_ps_tb (2 lanes, VLEN 2048,
# FP64/32/16 = the board configuration), Verilator 5.020, as verilate_2l.sh
export VERILATOR_ROOT=$HOME/v2/v5020/root/usr/share/verilator; export PATH=$HOME/v2/v5020/root/usr/bin:$PATH
R=/mnt/c/work/SIMTiX-v2/baselines/ara; A=$HOME/ara_wsl/ara; H=$A/hardware; M=$HOME/ara_wsl/build_ps_5020
LOG=/mnt/c/work/ara/verilate_ps_5020.log
rm -rf $M; mkdir -p $M; cd $H
{ date; verilator --version
time verilator -f $HOME/ara_wsl/flist_2l.f $R/rtl/ara_ps_top.sv $R/rtl/ara_ps_wrap.v $R/tb/ara_ps_tb.sv \
  -O3 --hierarchical \
  -Wno-fatal -Wno-PINCONNECTEMPTY -Wno-BLKANDNBLK -Wno-CASEINCOMPLETE -Wno-CMPCONST -Wno-LATCH \
  -Wno-LITENDIAN -Wno-UNOPTFLAT -Wno-UNPACKED -Wno-UNSIGNED -Wno-WIDTH -Wno-WIDTHCONCAT \
  -Wno-ENUMVALUE -Wno-COMBDLY \
  tb/verilator/waiver.vlt --Mdir $M -Itb/dpi \
  -CFLAGS "-DTOPLEVEL_NAME=ara_ps_tb" -CFLAGS "-DNR_LANES=2" \
  -CFLAGS -I$H/tb/verilator/lowrisc_dv_verilator_memutil_dpi/cpp \
  -CFLAGS -I$H/tb/verilator/lowrisc_dv_verilator_memutil_verilator/cpp \
  -CFLAGS -I$H/tb/verilator/lowrisc_dv_verilator_simutil_verilator/cpp \
  -CFLAGS -I$HOME/ara_deps/root/usr/include \
  -LDFLAGS "-L/usr/lib/x86_64-linux-gnu -l:libelf.so.1" \
  --exe $H/tb/verilator/lowrisc_dv_verilator_memutil_dpi/cpp/*.cc \
  $H/tb/verilator/lowrisc_dv_verilator_memutil_verilator/cpp/*.cc \
  $H/tb/verilator/lowrisc_dv_verilator_simutil_verilator/cpp/*.cc \
  $R/tb/ara_ps_tb.cpp --cc --top-module ara_ps_tb 2>&1 | grep -v '^%Warning' | grep -v '^ *:' | tail -40
echo "VERILATOR EXIT ${PIPESTATUS[0]}"
cd $M && time make -j2 -f Vara_ps_tb.mk 2>&1 | tail -25
echo "MAKE EXIT ${PIPESTATUS[0]}"; ls -la $M/Vara_ps_tb; date; echo VERILATE_DONE
} > $LOG 2>&1
