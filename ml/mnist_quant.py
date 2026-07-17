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
def infer_int(xq):                             # xq: int8[784]  -> predicted digit
    acc1 = xq.astype(np.int32) @ W1q.astype(np.int32)          # [128] int32
    h = np.clip(np.round(acc1*M1), 0, 127).astype(np.int32)    # requant + ReLU -> int8[0,127]
    acc2 = h @ W2q.astype(np.int32)                            # [10] int32
    return acc2.argmax()
NIMG = 64
Xte_q = qx(Xte[:NIMG], Sx)
gold = np.array([infer_int(Xte_q[i]) for i in range(NIMG)])
int_acc_all = np.mean([infer_int(qx(Xte[i],Sx))==Yte[i] for i in range(len(Xte))])
print(f"      FP32 test acc = {fp_acc*100:.2f}%   INT8 test acc = {int_acc_all*100:.2f}%")
print(f"      golden {NIMG}-image subset acc = {(gold==Yte[:NIMG]).mean()*100:.2f}%")

np.savez(os.path.join(D,"mnist_int8.npz"),
         W1q=W1q, W2q=W2q, Sx=Sx, Sw1=Sw1, Sw2=Sw2, Sh=Sh, M1=np.float32(M1),
         Xte_q=Xte_q, labels=Yte[:NIMG], gold=gold)
print("      wrote ml/data/mnist_int8.npz  (W1q 784x128, W2q 128x10, %d test imgs)" % NIMG)
print("SUMMARY  FP32=%.2f%%  INT8=%.2f%%  M1=%.6g" % (fp_acc*100, int_acc_all*100, M1))
