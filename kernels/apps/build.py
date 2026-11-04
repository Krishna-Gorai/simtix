"""
build.py -- assemble the v2 application kernels (rv32imaf).

    python kernels/apps/build.py [--lanes L] [--out DIR] [name ...]

For each kernel emits <name>.hex (one little-endian word per line), which
tests/tb_apps.sv writes into the board top's instruction RAM. --lanes assembles
for an accelerator of L lanes (lanes.h; default 8, the .hex files kept here);
--out puts the images elsewhere (default: this directory).
"""
import argparse, os, struct, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
GCC = os.environ.get('RISCV_GCC', 'riscv-none-elf-gcc')
OBJCOPY = GCC.replace('gcc', 'objcopy')
KERNELS = ['gemm', 'spmv', 'stencil', 'kmeans', 'bfs', 'scan', 'scan_add', 'mlp', 'gemm_rb',
           'scan_seg', 'scan_segadd', 'stencil_rb', 'kmeans_u', 'zbtest', 'spmv_z']


def build(name, lanes, out):
    src = os.path.join(HERE, name + '.S')
    elf, binf = (os.path.join(out, name + e) for e in ('.elf', '.bin'))
    subprocess.run([GCC, '-march=rv32imaf_zba_zbb_zicond', '-mabi=ilp32', '-nostdlib', '-nostartfiles',
                    f'-DLANES={lanes}', '-Wl,-Ttext=0', '-I', os.path.join(HERE, '..', 'sync'),
                    '-o', elf, src], check=True)
    subprocess.run([OBJCOPY, '-O', 'binary', elf, binf], check=True)
    data = open(binf, 'rb').read()
    words = [struct.unpack('<I', data[i:i + 4])[0] for i in range(0, len(data), 4)]
    with open(os.path.join(out, name + '.hex'), 'w', newline='\n') as f:
        f.writelines('%08x\n' % w for w in words)
    os.remove(binf)
    os.remove(elf)
    print(f'{name}: {len(words)} words')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--lanes', type=int, default=8)
    ap.add_argument('--out', default=HERE)
    ap.add_argument('names', nargs='*')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    for k in (args.names or KERNELS):
        build(k, args.lanes, os.path.abspath(args.out))
