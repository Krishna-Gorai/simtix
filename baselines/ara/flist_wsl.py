import os
A = os.path.expanduser('~/ara_wsl/ara')
src = open('/mnt/c/work/ara/flist_2l_win.f').read().splitlines()
out, missing = [], []
for l in src:
    B = chr(92); l = l.strip().replace('C:' + B + 'work' + B + 'ara', A).replace(B, '/')
    out.append(l)
    p = l.split('+incdir+')[-1] if l.startswith('+incdir+') else (None if l.startswith('+') else l)
    if p and not os.path.exists(p): missing.append(p)
open(os.path.expanduser('~/ara_wsl/flist_2l.f'), 'w').write('\n'.join(out) + '\n')
print(len(out), 'lines;', len(missing), 'missing', missing[:5]); print(out[0])
