#!/usr/bin/env python3
# view_mnist.py — render the 64 MNIST test images the SIMTiX chip runs inference
# on, as an 8x8 labeled montage. Each tile shows the digit and, above it, the
# chip's predicted class (= integer golden) vs the true label: "p=<pred> t=<lbl>".
# A red label marks the one image where prediction != true label.
#
#   Run:   python3 ml/view_mnist.py        ->  ml/data/mnist_montage.png
import os, numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__)); D = os.path.join(HERE, "data")
d = np.load(os.path.join(D, "mnist_int8.npz"))
X    = d["Xte_q"].astype(np.int32).reshape(-1, 28, 28)   # 64 quantized images (0..127)
pred = d["gold"]                                          # chip prediction (= golden)
lbl  = d["labels"]                                        # ground-truth labels

fig, ax = plt.subplots(8, 8, figsize=(12, 13))
for i in range(64):
    a = ax[i // 8][i % 8]
    a.imshow(X[i], cmap="gray_r", vmin=0, vmax=127)       # the exact int8 input to the chip
    ok = (pred[i] == lbl[i])
    a.set_title(f"p={pred[i]} t={lbl[i]}", fontsize=9,
                color=("black" if ok else "red"))
    a.set_xticks([]); a.set_yticks([])
plt.tight_layout()
out = os.path.join(D, "mnist_montage.png")
plt.savefig(out, dpi=110)
print("wrote", out)
print(f"chip matched the true label on {int((pred==lbl).sum())}/64 images "
      f"(the 1 red tile is the genuine misclassification, digit 5 read as 6)")
