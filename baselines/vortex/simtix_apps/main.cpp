// SIMTiX application suite on Vortex: the host side.
//
//   simtix_apps -m <apps.manifest> [-c <case>] [-k kernel.vxbin]
//
// Replays the cases sim/gen_apps.py writes for tests/tb_apps.sv: each case's DDR4
// image is copied into one device buffer, the address fields of every parameter
// block are moved from the image's base (0x1000_0000) to the buffer's, the case's
// launches run in order with the block shape tb_apps uses (2^blk warps per block),
// and every word of the .gold file is compared. One APPCSV line per launch gives
// its cycles; a line per case gives the case total.
#include <vortex2.h>
#include <VX_types.h>
#include "common.h"

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
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
};

struct Launch { std::string tag; uint32_t slot, param, threads, blk; };
struct Case   { std::string name, mem, gold; std::vector<Launch> launches; };

const char* kernel_file = "kernel.vxbin";
const char* manifest    = nullptr;
const char* only_case   = nullptr;

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
  std::string line;
  while (std::getline(f, line)) {
    std::istringstream s(line);
    std::string kw;
    s >> kw;
    if (kw == "CASE") { cases.emplace_back(); s >> cases.back().name; }
    else if (kw == "MEM")  { std::string p; s >> p; cases.back().mem  = host_path(p); }
    else if (kw == "GOLD") { std::string p; s >> p; cases.back().gold = host_path(p); }
    else if (kw == "LAUNCH") {
      Launch l;
      s >> l.tag >> l.slot >> std::hex >> l.param >> std::dec >> l.threads >> l.blk;
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

uint64_t mcycle(vx_device_h dev) {
  uint64_t v = 0;
  CHECK(vx_device_mpm_query(dev, VX_DCR_MPM_CLASS_BASE, VX_CSR_MCYCLE, 0, &v));
  return v;
}

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
      if (PTR_FIELDS[l.slot] >> i & 1) img[w + i] = reloc(img[w + i]);
  }
  CHECK(vx_enqueue_write(q, buf, 0, img.data(), bytes, 0, nullptr, nullptr));
  CHECK(vx_queue_finish(q, VX_TIMEOUT_INFINITE));

  uint64_t total = 0;
  for (const auto& l : c.launches) {
    const uint32_t block = nt << l.blk;
    if (l.threads % block) {
      std::fprintf(stderr, "%s: %u threads is not a whole number of %u-thread blocks\n",
                   l.tag.c_str(), l.threads, block);
      std::exit(1);
    }
    kernel_arg_t arg{ l.slot, reloc(l.param), l.threads };
    vx_launch_info_t li{};
    li.struct_size  = sizeof(li);
    li.kernel       = kern;
    li.args_host    = &arg;
    li.args_size    = sizeof(arg);
    li.ndim         = 1;
    li.grid_dim[0]  = l.threads / block;
    li.block_dim[0] = block;
    li.lmem_size    = (l.slot == APP_SCAN) ? (block / nt) * 4 : 0;

    uint64_t c0 = mcycle(dev);
    vx_event_h ev = nullptr;
    CHECK(vx_enqueue_launch(q, &li, 0, nullptr, &ev));
    CHECK(vx_event_wait_value(ev, 1, VX_TIMEOUT_INFINITE));
    vx_event_release(ev);
    uint64_t c1 = mcycle(dev);
    uint64_t cyc = (c1 >= c0) ? c1 - c0 : c1;     // the counter may restart per launch
    total += cyc;
    std::printf("APPCSV,vortex,%s,%s,%u,%llu\n", c.name.c_str(), l.tag.c_str(), l.threads,
                (unsigned long long)cyc);
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
  std::printf("APPCSV,vortex,%s,total,%d,%llu\n", c.name.c_str(), checked,
              (unsigned long long)total);
  std::printf("%s %s: %d words checked, %d wrong, %llu cycles\n", errors ? "FAIL" : "PASS",
              c.name.c_str(), checked, errors, (unsigned long long)total);
  return errors;
}

} // namespace

int main(int argc, char** argv) {
  int opt;
  while ((opt = getopt(argc, argv, "m:c:k:h")) != -1) {
    switch (opt) {
      case 'm': manifest    = optarg; break;
      case 'c': only_case   = optarg; break;
      case 'k': kernel_file = optarg; break;
      default:
        std::printf("Usage: -m <apps.manifest> [-c <case>] [-k kernel.vxbin]\n");
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
