set -e
W=/mnt/c/work/ara; A=$HOME/ara_wsl/ara
mkdir -p $HOME/ara_wsl; rm -rf $A
clone_at () {  # src dst : clone src and check out src's HEAD commit (detached)
  sha=$(git -C "$1" rev-parse HEAD)
  git clone -q --no-checkout "$1" "$2"
  git -C "$2" fetch -q "$1" HEAD
  git -C "$2" -c advice.detachedHead=false checkout -q "$sha"
  echo "$(basename $2) @ ${sha:0:10}"
}
clone_at $W $A
mkdir -p $A/hardware/deps
for d in $(ls $W/hardware/deps); do clone_at $W/hardware/deps/$d $A/hardware/deps/$d; done
cd $A/hardware/deps/cva6 && git submodule update -q --init --recursive && echo "cva6 submodules ok"
cd $A/hardware/deps/tech_cells_generic && git apply ../../patches/0001-tech-cells-generic-sram.patch && echo "patch ok"
cd $A; for f in config/default.mk hardware/tb/dpi/elfloader.cc; do ls -l $f | cut -c1-10,40-; done
mkdir -p $HOME/ara_deps/root && (cd $HOME/ara_deps && apt-get download libelf-dev) && dpkg -x $HOME/ara_deps/libelf-dev_*.deb $HOME/ara_deps/root && ls $HOME/ara_deps/root/usr/include
python3 /mnt/c/work/SIMTiX-v2/baselines/ara/flist_wsl.py
echo SETUP_DONE
