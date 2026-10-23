"""
build.py -- assemble the v2 application kernels (rv32imaf).

    python kernels/apps/build.py [name ...]

For each kernel emits <name>.hex (one little-endian word per line), which
tests/tb_apps.sv writes into the board top's instruction RAM.
"""
import os, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
GCC = os.environ.get('RISCV_GCC', 'riscv-none-elf-gcc')
OBJCOPY = GCC.replace('gcc', 'objcopy')
KERNELS = ['gemm', 'spmv', 'stencil', 'kmeans', 'bfs']


def build(name):
    src = os.path.join(HERE, name + '.S')
    elf, binf = (os.path.join(HERE, name + e) for e in ('.elf', '.bin'))
    subprocess.run([GCC, '-march=rv32imaf', '-mabi=ilp32', '-nostdlib', '-nostartfiles',
                    '-Wl,-Ttext=0', '-I', os.path.join(HERE, '..', 'sync'), '-o', elf, src],
                   check=True)
    subprocess.run([OBJCOPY, '-O', 'binary', elf, binf], check=True)
    data = open(binf, 'rb').read()
    words = [struct.unpack('<I', data[i:i + 4])[0] for i in range(0, len(data), 4)]
    with open(os.path.join(HERE, name + '.hex'), 'w', newline='\n') as f:
        f.writelines('%08x\n' % w for w in words)
    os.remove(binf)
    os.remove(elf)
    print(f'{name}: {len(words)} words')


if __name__ == '__main__':
    for k in (sys.argv[1:] or KERNELS):
        build(k)
