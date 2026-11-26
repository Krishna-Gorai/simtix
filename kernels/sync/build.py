"""
build.py -- assemble the v2 synchronisation kernels (rv32ima + custom-0 macros).

    python kernels/sync/build.py [--lanes L] [kernel ...]

For each kernel emits <name>.hex (one little-endian word per line) and
<name>.svh (`mem[at+k] = 32'h...;` lines, included by tests/tb_sync.sv).
--lanes L (4, 8 or 16; default 8) sets the warp width the kernels assume (-DLANES=L,
lanes.h); the 8-lane images land in kernels/sync, the others in kernels/sync/l<L>.
"""
import os, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
GCC = os.environ.get('RISCV_GCC', 'riscv-none-elf-gcc')
OBJCOPY = GCC.replace('gcc', 'objcopy')
KERNELS = ['shfl_test', 'reduce_shfl', 'reduce_all', 'reduce_block',
           'histogram', 'hist_shared', 'scan_warp', 'amo_test', 'amo_contend',
           '../reduce/reduce']   # the v1 reduce, timed beside reduce_shfl


def outdir(lanes):
    return HERE if lanes == 8 else os.path.join(HERE, 'l%d' % lanes)


def build(name, lanes=8):
    src = os.path.join(HERE, name + '.S')
    name = os.path.basename(name)            # outputs always land in kernels/sync[/l<L>]
    out = outdir(lanes)
    os.makedirs(out, exist_ok=True)
    elf, binf = (os.path.join(out, name + e) for e in ('.elf', '.bin'))
    subprocess.run([GCC, '-march=rv32ima', '-mabi=ilp32', '-nostdlib', '-nostartfiles',
                    '-Wl,-Ttext=0', '-I', HERE, '-DLANES=%d' % lanes, '-o', elf, src], check=True)
    subprocess.run([OBJCOPY, '-O', 'binary', elf, binf], check=True)
    data = open(binf, 'rb').read()
    words = [struct.unpack('<I', data[i:i + 4])[0] for i in range(0, len(data), 4)]
    assert len(words) <= 64, f'{name} exceeds its 64-word slot in tb_sync'
    with open(os.path.join(out, name + '.hex'), 'w', newline='\n') as f:
        f.writelines('%08x\n' % w for w in words)
    with open(os.path.join(out, name + '.svh'), 'w', newline='\n') as f:
        f.writelines("        mem[at+%d] = 32'h%08x;\n" % (k, w) for k, w in enumerate(words))
    os.remove(binf)
    print(f'{name} ({lanes} lanes): {len(words)} words')


if __name__ == '__main__':
    args, lanes = sys.argv[1:], 8
    if '--lanes' in args:
        i = args.index('--lanes')
        lanes = int(args[i + 1])
        del args[i:i + 2]
    for k in (args or KERNELS):
        build(k, lanes)
