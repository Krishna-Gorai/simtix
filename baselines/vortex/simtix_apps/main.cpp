// SIMTiX application suite on Vortex: the host side.
//
//   simtix_apps -m <apps.manifest> [-c <case>] [-b <threads>] [-k kernel.vxbin]
//
// Replays the cases sim/gen_apps.py writes for tests/tb_apps.sv: each case's DDR4
// image is copied into one device buffer, the address fields of every parameter
// block are moved from the image's base (0x1000_0000) to the buffer's, the case's
// launches run in order, and every word of the .gold file is compared. One APPCSV
// line per launch gives its cycles and retired (warp) instructions; a line per case
// gives the case totals.
//
// Blocks have the shape tb_apps uses (2^blk warps) unless -b gives the threads per
// block for the launches without a barrier (all but scan, whose 32-thread blocks
// are part of the algorithm). A Vortex block holds at most the core's hardware
// threads; at 4 warps, 8- and 32-thread blocks differ by under 1%.
#include <vortex2.h>
#include <VX_types.h>
#include "common.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

#define CHECK(expr) do { \
    vx_result_t _r = (expr); \
    if (_r != VX_SUCCESS) { \
        std::fprintf(stderr, "FAIL %s:%d: '%s' returned %s\n", \
                     __FILE__, __LINE__, #expr, vx_result_string(_r)); \
        std::exit(1); \
    } \
} while (0)

namespace {

const uint32_t DDR_BASE = 0x10000000u;

// Bit i set: word i of the kernel's parameter block is an address (kernels/apps/*.S).
const uint32_t PTR_FIELDS[APP_COUNT] = {
  0x007,   // gemm     A B C | K log2N
  0x01f,   // spmv     rowptr col val x y
  0x003,   // stencil  in out | log2W S c0 c1
  0x1ef,   // kmeans   px py cx cy | K | assign sumx sumy cnt
  0x017,   // bfs      rowptr col level | L | flag
  0x007,   // scan     in out bsum
  0x003,   // scan_add out bscan
  0x007,   // mlp      x W out | Kp log2Npad scale zp mode
  0x007,   // conv8    X Wt Out | Cw log2Cout log2(W/4) scale zp Wp
  0x007,   // embag    T idx out | K log2D
  0x007,   // hashj    slot keys out | 32-s mask
  0x001,   // mandel   out | log2W x0 y0 dx dy M
  0x00f,   // swat     T Q B out | Lt S stride
  0x007,   // pathfinder src dst wall | cols
  0x007,   // bp_forward in w ps
  0x00f,   // bp_adjust  in w ow ed | m
  0x007,   // hotspot_rd Tin Tout Pw | log2n rx1 ry1 rz1 amb sdc
  0x003,   // nn         loc dist | lat lng
  0x007,   // hotspot3d  Tin Tout Pw | log2n nz cc ce cn ct sdc amb
  0x003,   // gauss_fan1 a m | n t
  0x003,   // gauss_fan2 a m | n t
  0x007,   // kmeans_rd  f c membership | N K F
  0x003,   // axpy_rv    dx dy | a
  0x003,   // jacobi_rv  A B | log2n 0.2f
  0x0ff,   // bs_rv      S K r v T type price C
  0x05f,   // lavamd_rv  rv qv fv nn nei | a2 | C
};

// Kernel file names (kernels/apps/<name>.hex) in APP_ order.
const char* const APP_NAMES[APP_COUNT] = {
  "gemm", "spmv", "stencil", "kmeans", "bfs", "scan", "scan_add", "mlp",
  "conv8", "embag", "hashj", "mandel", "swat",
  "pathfinder", "bp_forward", "bp_adjust", "hotspot_rd", "nn", "hotspot3d", "gauss_fan1", "gauss_fan2", "kmeans_rd",
  "axpy_rv", "jacobi_rv", "bs_rv", "lavamd_rv",
};

struct Launch { std::string tag; uint32_t slot, param, threads, blk; int app; };
struct Case   { std::string name, mem, gold; std::vector<Launch> launches; bool ok = true; };

const char* kernel_file = "kernel.vxbin";
const char* manifest    = nullptr;
const char* only_case   = nullptr;
uint32_t    block_override = 0;     // -b: threads per block without a barrier

// The manifest is written on Windows: C:/x/y -> /mnt/c/x/y.
std::string host_path(std::string p) {
  if (p.size() > 2 && p[1] == ':' && (p[2] == '/' || p[2] == '\\')) {
    std::string r = "/mnt/";
    r += (char)std::tolower((unsigned char)p[0]);
    r += p.substr(2);
    for (auto& ch : r) if (ch == '\\') ch = '/';
    return r;
  }
  return p;
}

std::vector<Case> read_manifest(const char* path) {
  std::ifstream f(path);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", path); std::exit(1); }
  std::vector<Case> cases;
  std::map<uint32_t, int> slot_app;     // instruction-RAM slot -> APP_ (-1: no Vortex port)
  std::string line;
  while (std::getline(f, line)) {
    std::istringstream s(line);
    std::string kw;
    s >> kw;
    if (kw == "KERNEL") {               // KERNEL <slot> <path>/<name>.hex
      uint32_t slot; std::string p;
      s >> slot >> p;
      std::string n = p.substr(p.find_last_of("/\\") + 1);
      n = n.substr(0, n.rfind('.'));
      int app = -1;
      for (int i = 0; i < APP_COUNT; ++i) if (n == APP_NAMES[i]) app = i;
      slot_app[slot] = app;
    }
    else if (kw == "CASE") { cases.emplace_back(); s >> cases.back().name; }
    else if (kw == "MEM")  { std::string p; s >> p; cases.back().mem  = host_path(p); }
    else if (kw == "GOLD") { std::string p; s >> p; cases.back().gold = host_path(p); }
    else if (kw == "LAUNCH") {
      Launch l;
      s >> l.tag >> l.slot >> std::hex >> l.param >> std::dec >> l.threads >> l.blk;
      auto it = slot_app.find(l.slot);
      l.app = (it == slot_app.end()) ? -1 : it->second;
      if (l.app < 0) cases.back().ok = false;
      cases.back().launches.push_back(l);
    }
  }
  return cases;
}

// $readmemh image: "@<word index>" lines and one hex word per line. Word i is at
// DDR_BASE + 4*i.
std::vector<uint32_t> read_image(const std::string& path) {
  std::ifstream f(path);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", path.c_str()); std::exit(1); }
  std::vector<uint32_t> img;
  std::string tok;
  size_t i = 0;
  while (f >> tok) {
    if (tok[0] == '@') { i = std::stoul(tok.substr(1), nullptr, 16); continue; }
    if (i >= img.size()) img.resize(i + 1, 0);
    img[i++] = (uint32_t)std::stoul(tok, nullptr, 16);
  }
  img.resize((img.size() + 7) & ~size_t(7), 0);   // whole 32-byte lines
  return img;
}

uint64_t mpm(vx_device_h dev, uint32_t csr) {
  uint64_t v = 0;
  CHECK(vx_device_mpm_query(dev, VX_DCR_MPM_CLASS_BASE, csr, 0, &v));
  return v;
}

// A counter's growth over a launch (it may also restart per launch).
uint64_t delta(uint64_t before, uint64_t after) { return (after >= before) ? after - before : after; }

int run_case(vx_device_h dev, vx_queue_h q, vx_kernel_h kern, uint32_t nt, const Case& c) {
  std::vector<uint32_t> img = read_image(c.mem);
  const uint64_t bytes = img.size() * 4;

  vx_buffer_h buf = nullptr;
  CHECK(vx_buffer_create(dev, bytes, VX_MEM_READ_WRITE, &buf));
  uint64_t base64 = 0;
  CHECK(vx_buffer_address(buf, &base64));
  const uint32_t base = (uint32_t)base64;
  auto reloc = [&](uint32_t a) { return a - DDR_BASE + base; };

  for (const auto& l : c.launches) {
    uint32_t w = (l.param - DDR_BASE) / 4;
    for (uint32_t i = 0; i < 32; ++i)
      if (PTR_FIELDS[l.app] >> i & 1) img[w + i] = reloc(img[w + i]);
  }
  CHECK(vx_enqueue_write(q, buf, 0, img.data(), bytes, 0, nullptr, nullptr));
  CHECK(vx_queue_finish(q, VX_TIMEOUT_INFINITE));

  uint64_t total = 0, total_ins = 0;
  for (const auto& l : c.launches) {
    uint32_t block = nt << l.blk;
    if (block_override && l.app != APP_SCAN)
      block = std::min(block_override, l.threads);
    if (l.app == APP_SCAN && l.threads % block) {   // scan's blocks are part of the algorithm
      std::fprintf(stderr, "%s: %u threads is not a whole number of %u-thread blocks\n",
                   l.tag.c_str(), l.threads, block);
      std::exit(1);
    }
    kernel_arg_t arg{ (uint32_t)l.app, reloc(l.param), l.threads };
    vx_launch_info_t li{};
    li.struct_size  = sizeof(li);
    li.kernel       = kern;
    li.args_host    = &arg;
    li.args_size    = sizeof(arg);
    li.ndim         = 1;
    li.grid_dim[0]  = (l.threads + block - 1) / block;   // kernel_main skips t >= threads
    li.block_dim[0] = block;
    li.lmem_size    = (l.app == APP_SCAN) ? (block / nt) * 4 : 0;

    uint64_t c0 = mpm(dev, VX_CSR_MCYCLE), i0 = mpm(dev, VX_CSR_MINSTRET);
    vx_event_h ev = nullptr;
    CHECK(vx_enqueue_launch(q, &li, 0, nullptr, &ev));
    CHECK(vx_event_wait_value(ev, 1, VX_TIMEOUT_INFINITE));
    vx_event_release(ev);
    uint64_t cyc = delta(c0, mpm(dev, VX_CSR_MCYCLE));
    uint64_t ins = delta(i0, mpm(dev, VX_CSR_MINSTRET));
    total += cyc;
    total_ins += ins;
    std::printf("APPCSV,vortex,%s,%s,%u,%llu,%llu\n", c.name.c_str(), l.tag.c_str(), l.threads,
                (unsigned long long)cyc, (unsigned long long)ins);
  }

  std::vector<uint32_t> out(img.size());
  CHECK(vx_enqueue_read(q, out.data(), buf, 0, bytes, 0, nullptr, nullptr));
  CHECK(vx_queue_finish(q, VX_TIMEOUT_INFINITE));
  vx_buffer_release(buf);

  std::ifstream g(c.gold);
  if (!g) { std::fprintf(stderr, "cannot open %s\n", c.gold.c_str()); std::exit(1); }
  int errors = 0, checked = 0;
  std::string si, sv;
  while (g >> si >> sv) {
    size_t i = std::stoul(si, nullptr, 16);
    uint32_t want = (uint32_t)std::stoul(sv, nullptr, 16);
    ++checked;
    if (i >= out.size() || out[i] != want) {
      if (errors < 8)
        std::printf("  [FAIL] %s word %zx: got %08x want %08x\n", c.name.c_str(), i,
                    i < out.size() ? out[i] : 0u, want);
      ++errors;
    }
  }
  std::printf("APPCSV,vortex,%s,total,%d,%llu,%llu\n", c.name.c_str(), checked,
              (unsigned long long)total, (unsigned long long)total_ins);
  std::printf("%s %s: %d words checked, %d wrong, %llu cycles\n", errors ? "FAIL" : "PASS",
              c.name.c_str(), checked, errors, (unsigned long long)total);
  return errors;
}

} // namespace

int main(int argc, char** argv) {
  int opt;
  while ((opt = getopt(argc, argv, "m:c:b:k:h")) != -1) {
    switch (opt) {
      case 'm': manifest    = optarg; break;
      case 'c': only_case   = optarg; break;
      case 'b': block_override = (uint32_t)std::atoi(optarg); break;
      case 'k': kernel_file = optarg; break;
      default:
        std::printf("Usage: -m <apps.manifest> [-c <case>] [-b <threads>] [-k kernel.vxbin]\n");
        return opt == 'h' ? 0 : -1;
    }
  }
  if (!manifest) { std::fprintf(stderr, "-m <apps.manifest> is required\n"); return -1; }

  vx_device_h dev = nullptr;
  CHECK(vx_device_open(0, &dev));
  vx_queue_info_t qi = { sizeof(qi), nullptr, VX_QUEUE_PRIORITY_NORMAL, 0 };
  vx_queue_h q = nullptr;
  CHECK(vx_queue_create(dev, &qi, &q));
  uint64_t nt = 0, nw = 0;
  CHECK(vx_device_query(dev, VX_CAPS_NUM_THREADS, &nt));
  CHECK(vx_device_query(dev, VX_CAPS_NUM_WARPS, &nw));
  std::printf("vortex: %llu warps x %llu threads\n", (unsigned long long)nw,
              (unsigned long long)nt);

  vx_module_h mod = nullptr;
  vx_kernel_h kern = nullptr;
  CHECK(vx_module_load_file(dev, kernel_file, &mod));
  CHECK(vx_module_get_kernel(mod, "main", &kern));

  int errors = 0, ran = 0;
  for (const auto& c : read_manifest(manifest)) {
    if (only_case && c.name != only_case) continue;
    if (!c.ok) { std::printf("SKIP %s: a kernel without a Vortex port\n", c.name.c_str()); continue; }
    errors += run_case(dev, q, kern, (uint32_t)nt, c);
    ++ran;
  }

  vx_kernel_release(kern);
  vx_module_release(mod);
  vx_queue_release(q);
  vx_device_dump_perf(dev, stdout);
  vx_device_release(dev);

  if (!ran) { std::printf("no case matched\nFAILED!\n"); return 1; }
  std::printf(errors ? "FAILED!\n" : "PASSED!\n");
  return errors ? 1 : 0;
}
