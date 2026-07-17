#!/usr/bin/env python3
# mnist_quant.py — train a tiny MLP on MNIST, quantize to INT8, export weights +
# test data + an integer-exact golden reference for the SIMTiX MNIST demo (AI-4).
#
#   MLP: 784 -> 128 (ReLU) -> 10,  symmetric per-tensor INT8 quantization.
#   Outputs (ml/data/): weights/scales (.npy), a set of INT8 test images + labels,
#   and golden per-image argmax + accuracy from an INTEGER inference that the
#   accelerator must reproduce bit-for-bit.
import os, gzip, struct, urllib.request, numpy as np

HERE = os.path.dirname(os.path.abspath(__file__)); D = os.path.join(HERE, "data")
os.makedirs(D, exist_ok=True)
BASE = "https://ossci-datasets.s3.amazonaws.com/mnist/"
FILES = {"trX":"train-images-idx3-ubyte.gz","trY":"train-labels-idx1-ubyte.gz",
         "teX":"t10k-images-idx3-ubyte.gz","teY":"t10k-labels-idx1-ubyte.gz"}

def fetch(fn):
    p = os.path.join(D, fn)
    if not os.path.exists(p):
        print("  downloading", fn); urllib.request.urlretrieve(BASE+fn, p)
    return p
def load_images(fn):
    with gzip.open(fetch(fn)) as f:
        _,_ ,r,c = struct.unpack(">IIII", f.read(16))
        return np.frombuffer(f.read(), np.uint8).reshape(-1, r*c).astype(np.float32)
def load_labels(fn):
    with gzip.open(fetch(fn)) as f:
        f.read(8); return np.frombuffer(f.read(), np.uint8).astype(np.int64)

print("[1/4] loading MNIST ...")
Xtr = load_images(FILES["trX"])/255.0; Ytr = load_labels(FILES["trY"])
Xte = load_images(FILES["teX"])/255.0; Yte = load_labels(FILES["teY"])
print("      train", Xtr.shape, "test", Xte.shape)

print("[2/4] training 784->128->10 MLP (numpy SGD) ...")
rng = np.random.default_rng(0); H = 128
W1 = (rng.standard_normal((784,H))*np.sqrt(2/784)).astype(np.float32); b1 = np.zeros(H, np.float32)
W2 = (rng.standard_normal((H,10)) *np.sqrt(2/H)  ).astype(np.float32); b2 = np.zeros(10, np.float32)
def fwd(X):
    z1 = X@W1 + b1; a1 = np.maximum(0, z1); z2 = a1@W2 + b2; return z1,a1,z2
lr, EP, BS = 0.1, 8, 128; N = Xtr.shape[0]
for ep in range(EP):
    idx = rng.permutation(N)
    for i in range(0, N, BS):
        b = idx[i:i+BS]; X = Xtr[b]; y = Ytr[b]
        z1,a1,z2 = fwd(X)
        p = np.exp(z2-z2.max(1,keepdims=True)); p /= p.sum(1,keepdims=True)
        g2 = p; g2[np.arange(len(b)),y] -= 1; g2 /= len(b)
        dW2 = a1.T@g2; db2 = g2.sum(0)
        g1 = (g2@W2.T)*(z1>0); dW1 = X.T@g1; db1 = g1.sum(0)
        W1 -= lr*dW1; b1 -= lr*db1; W2 -= lr*dW2; b2 -= lr*db2
    acc = (fwd(Xte)[2].argmax(1)==Yte).mean()
    print(f"      epoch {ep+1}/{EP}  test acc = {acc*100:.2f}%")
fp_acc = (fwd(Xte)[2].argmax(1)==Yte).mean()

print("[3/4] symmetric per-tensor INT8 quantization ...")
def qscale(x, qmax): return (np.abs(x).max()/qmax) if np.abs(x).max()>0 else 1.0
Sx  = qscale(Xtr, 127.0)                       # input activation scale (folds ReLU>=0 too)
Sw1 = qscale(W1, 127.0); Sw2 = qscale(W2, 127.0)
def qw(w,s): return np.clip(np.round(w/s), -127, 127).astype(np.int8)
W1q, W2q = qw(W1,Sw1), qw(W2,Sw2)
# hidden activation scale from observed pre-requant range on a train subset
_,a1s,_ = fwd(Xtr[:4000]); Sh = qscale(a1s, 127.0)
M1 = (Sx*Sw1)/Sh                               # layer-1 requant multiplier (acc -> h int8)
def qx(x,s): return np.clip(np.round(x/s), -128, 127).astype(np.int8)

print("[4/4] integer-exact golden inference + export ...")
M1f = np.float32(M1)
def hidden_int(xq):                            # xq: int8[784] -> h int8[128] (post relu)
    acc1 = xq.astype(np.int32) @ W1q.astype(np.int32)          # [128] int32
    # requant + ReLU in FLOAT32 to match the hw kernel exactly (fcvt.s.w -> fmadd.s
    # -> fmin/fmax -> fcvt.w.s rne):  f32 multiply, round-half-even, clamp [0,127].
    f = acc1.astype(np.float32) * M1f
    return np.clip(np.rint(f), 0, 127).astype(np.int32)
def infer_int(xq):                             # xq: int8[784] -> predicted digit
    acc2 = hidden_int(xq) @ W2q.astype(np.int32)              # [10] int32
    return acc2.argmax()
NIMG = 64
Xte_q = qx(Xte[:NIMG], Sx)
gold = np.array([infer_int(Xte_q[i]) for i in range(NIMG)])
int_acc_all = np.mean([infer_int(qx(Xte[i],Sx))==Yte[i] for i in range(len(Xte))])
print(f"      FP32 test acc = {fp_acc*100:.2f}%   INT8 test acc = {int_acc_all*100:.2f}%")
print(f"      golden {NIMG}-image subset acc = {(gold==Yte[:NIMG]).mean()*100:.2f}%")

np.savez(os.path.join(D,"mnist_int8.npz"),
         W1q=W1q, W2q=W2q, Sx=Sx, Sw1=Sw1, Sw2=Sw2, Sh=Sh, M1=M1f,
         Xte_q=Xte_q, labels=Yte[:NIMG], gold=gold)
print("      wrote ml/data/mnist_int8.npz  (W1q 784x128, W2q 128x10, %d test imgs)" % NIMG)

# ── tb-loadable hex export (packed 4 int8 / word, little-endian) ─────────────────
def pack_words(a4):                            # a4: (..., K) int8 -> (..., K/4) uint32
    b = a4.astype(np.uint8).astype(np.uint32)
    return b[...,0::4] | (b[...,1::4]<<8) | (b[...,2::4]<<16) | (b[...,3::4]<<24)
def write_hex(name, words):
    with open(os.path.join(D,name),"w") as f:
        for w in np.asarray(words).reshape(-1): f.write("%08x\n" % (int(w)&0xFFFFFFFF))
# W packed [Kp][N]: word (kk*N + n) packs W[4kk..4kk+3][n]  (transpose so K is last)
def pack_weights(Wq):                          # Wq: (K, N) -> (Kp*N,) uint32
    K,Nn = Wq.shape; Kp=K//4
    wt = Wq.T.reshape(Nn, Kp, 4)               # [N][Kp][4]  (n, kk, byte)
    b = wt.astype(np.uint8).astype(np.uint32)
    wpk = b[...,0] | (b[...,1]<<8) | (b[...,2]<<16) | (b[...,3]<<24)   # [N][Kp]
    return wpk.T.reshape(-1)                    # [Kp][N] row-major -> word kk*N+n
write_hex("w1packed.hex", pack_weights(W1q))    # 196*128 = 25088 words
write_hex("w2packed.hex", pack_weights(W2q))    # 32*10   = 320   words
write_hex("images.hex",   pack_words(Xte_q))    # 64*196  = 12544 words (img i @ i*196)
import struct as _st
m1bits = _st.unpack("<I", _st.pack("<f", float(M1f)))[0]
write_hex("params.hex", [m1bits, 0])            # scale=M1, zero_point=0
write_hex("gold.hex",   gold.astype(np.uint32)) # 64 predicted digits
write_hex("labels.hex", Yte[:NIMG].astype(np.uint32))
print("      wrote hex: w1packed(25088) w2packed(320) images(12544) params gold labels")
print("SUMMARY  FP32=%.2f%%  INT8=%.2f%%  M1=%.6g  M1bits=0x%08X" %
      (fp_acc*100, int_acc_all*100, M1, m1bits))
