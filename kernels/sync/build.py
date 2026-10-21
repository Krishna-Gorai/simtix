"""
build.py -- assemble the v2 synchronisation kernels (rv32ima + custom-0 macros).

    python kernels/sync/build.py

For each kernel emits <name>.hex (one little-endian word per line) and
<name>.svh (`mem[at+k] = 32'h...;` lines, included by tests/tb_sync.sv).
"""
import os, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
GCC = os.environ.get('RISCV_GCC', 'riscv-none-elf-gcc')
OBJCOPY = GCC.replace('gcc', 'objcopy')
KERNELS = ['shfl_test', 'reduce_shfl', 'reduce_all', 'reduce_block',
           'histogram', 'hist_shared', 'scan_warp', 'amo_test',
           '../reduce/reduce']   # the v1 reduce, timed beside reduce_shfl


def build(name):
    src = os.path.join(HERE, name + '.S')
    name = os.path.basename(name)            # outputs always land in kernels/sync
    elf, binf = (os.path.join(HERE, name + e) for e in ('.elf', '.bin'))
    subprocess.run([GCC, '-march=rv32ima', '-mabi=ilp32', '-nostdlib', '-nostartfiles',
                    '-Wl,-Ttext=0', '-I', HERE, '-o', elf, src], check=True)
    subprocess.run([OBJCOPY, '-O', 'binary', elf, binf], check=True)
    data = open(binf, 'rb').read()
    words = [struct.unpack('<I', data[i:i + 4])[0] for i in range(0, len(data), 4)]
    with open(os.path.join(HERE, name + '.hex'), 'w', newline='\n') as f:
        f.writelines('%08x\n' % w for w in words)
    with open(os.path.join(HERE, name + '.svh'), 'w', newline='\n') as f:
        f.writelines("        mem[at+%d] = 32'h%08x;\n" % (k, w) for k, w in enumerate(words))
    os.remove(binf)
    print(f'{name}: {len(words)} words')


if __name__ == '__main__':
    for k in (sys.argv[1:] or KERNELS):
        build(k)
