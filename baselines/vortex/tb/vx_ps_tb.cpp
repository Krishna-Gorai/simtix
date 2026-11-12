// vx_ps_tb.cpp - Verilator testbench of the board wrapper vortex_ps_top (Vortex 3.0 as a
// ZCU102 PS peripheral).
//
//   vx_ps_tb -k kernel.vxbin -m apps.manifest [-c case] [-b threads] [-s seed]
//
// The A53 is replaced by this program and talks to the wrapper only through its
// AXI4-Lite host registers, exactly as the board host will: it loads the .vxbin and
// each case's DDR image into the DDR model (the A53 writes DDR directly), programs the
// KMU DCRs, pulses START, waits for STATUS.busy to clear, flushes Vortex's write-back
// L1 (DCR read of VX_DCR_BASE_CACHE_FLUSH) and compares every word of the .gold file.
//
// The DDR model (behind the wrapper's AXI4 master, DDR byte addresses) stalls every
// channel at random, answers reads of different IDs out of order, and commits a
// write's data only when it sends the write's B response, so a read that overtook an
// unanswered write would see stale data (the PS interconnect may do both).
#include "Vvortex_ps_top.h"
#include "verilated.h"
#include <VX_types.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <map>
#include <random>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

#include "common.h"   // kernel_arg_t, APP_ (baselines/vortex/simtix_apps)

// Called by Vortex's DPI trace hooks (each Vortex simulator defines it): no tracing.
bool sim_trace_enabled() { return false; }
void sim_trace_enable(bool) {}

namespace {

const uint32_t DDR_BASE_IMG = 0x10000000u;   // address base of gen_apps images
const uint32_t DDR_WIN      = 0x40000000u;   // wrapper parameter DDRBase
const uint32_t VX_BUF       = 0x10000000u;   // Vortex address of a case's image (identity window)
const uint32_t VX_ARGS      = 0x00010000u;   // Vortex address of the kernel_arg_t

// Vortex address -> DDR byte address (vortex_ps_top to_ddr).
uint32_t to_ddr(uint32_t a) {
  uint32_t r = a >> 28, off = a & 0x0FFFFFFFu;
  if (r == 0x1) return a;                       // the host's arena: identity
  uint32_t w = (r == 0x0) ? 0 : (r == 0x8) ? 1 : (r == 0xF) ? 2 : 3;
  return DDR_WIN + (w << 28) + off;
}

// ── DDR model storage ────────────────────────────────────────────────────────────
std::map<uint32_t, std::vector<uint8_t>> pages;          // 4 KB pages
uint8_t* byte_at(uint32_t a) {
  auto& p = pages[a >> 12];
  if (p.empty()) p.assign(4096, 0);
  return &p[a & 4095];
}
void mem_write32(uint32_t a, uint32_t v) { std::memcpy(byte_at(a), &v, 4); }
uint32_t mem_read32(uint32_t a) { uint32_t v; std::memcpy(&v, byte_at(a), 4); return v; }
void vx_write32(uint32_t va, uint32_t v) { mem_write32(to_ddr(va), v); }
uint32_t vx_read32(uint32_t va) { return mem_read32(to_ddr(va)); }

// ── Simulation ───────────────────────────────────────────────────────────────────
Vvortex_ps_top* top;
std::mt19937 rng(1);
uint64_t cycle = 0;
const int DWB = 16;                               // AXI data bytes (128 bits)

struct WrBurst { uint64_t id; uint32_t addr; uint32_t beats; uint32_t size; };
struct WrDone  { uint64_t id; std::vector<std::pair<uint32_t, uint8_t>> bytes; uint64_t due; bool committed; };
struct RdBurst { uint64_t id; uint32_t addr; uint32_t beats; uint32_t size; uint32_t sent; uint64_t due; };

std::deque<WrBurst> aw_q;                         // accepted AWs waiting for their W beats
std::vector<std::pair<uint32_t, uint8_t>> w_bytes;
std::deque<std::vector<std::pair<uint32_t, uint8_t>>> w_q;   // complete W bursts without their AW yet
uint32_t w_beat = 0;
std::deque<WrDone> b_q;                           // writes waiting for B (data uncommitted)
std::vector<RdBurst> r_q;                         // accepted ARs
int r_cur = -1;                                   // burst being returned
bool rand_bit(int pct) { return (int)(rng() % 100) < pct; }

void ddr_model_comb() {
  top->m_awready = rand_bit(70);
  top->m_wready  = rand_bit(70);
  top->m_arready = rand_bit(70);
}

void ddr_model_edge() {
  // AW
  if (top->m_awvalid && top->m_awready)
    aw_q.push_back({(uint64_t)top->m_awid, top->m_awaddr, (uint32_t)top->m_awlen + 1u, 1u << top->m_awsize});
  // W: beats as offsets in their burst; a burst pairs with the AWs in order (AXI lets
  // the data of a write come before its address)
  if (top->m_wvalid && top->m_wready) {
    for (int i = 0; i < DWB; ++i)
      if ((top->m_wstrb >> i) & 1)
        w_bytes.push_back({w_beat * DWB + i, (uint8_t)(top->m_wdata[i / 4] >> (8 * (i % 4)))});
    ++w_beat;
    if (top->m_wlast) { w_q.push_back(w_bytes); w_bytes.clear(); w_beat = 0; }
  }
  while (!aw_q.empty() && !w_q.empty()) {
    uint32_t base = aw_q.front().addr & ~uint32_t(DWB - 1);
    std::vector<std::pair<uint32_t, uint8_t>> bytes;
    for (auto& wb : w_q.front()) bytes.push_back({base + wb.first, wb.second});
    b_q.push_back({aw_q.front().id, bytes, cycle + 2 + rng() % 40, false});
    aw_q.pop_front(); w_q.pop_front();
  }
  // B: commit the data now, in order (Vortex writes all carry ID 0)
  if (top->m_bvalid && top->m_bready) { b_q.pop_front(); }
  // AR
  if (top->m_arvalid && top->m_arready)
    r_q.push_back({(uint64_t)top->m_arid, top->m_araddr, (uint32_t)top->m_arlen + 1u, 1u << top->m_arsize, 0, cycle + 4 + rng() % 30});
  // R beat accepted
  if (top->m_rvalid && top->m_rready) {
    auto& r = r_q[r_cur];
    if (++r.sent == r.beats) { r_q.erase(r_q.begin() + r_cur); r_cur = -1; }
  }
}

void ddr_model_drive() {
  // B
  if (!b_q.empty() && b_q.front().due <= cycle) {
    auto& wd = b_q.front();
    if (!wd.committed) { for (auto& wb : wd.bytes) *byte_at(wb.first) = wb.second; wd.committed = true; }
    top->m_bvalid = 1; top->m_bid = b_q.front().id; top->m_bresp = 0;
  } else {
    top->m_bvalid = 0;
  }
  // R: pick a burst (different IDs may overtake; same ID in order)
  if (r_cur < 0 && !r_q.empty() && rand_bit(80)) {
    std::vector<int> ok;
    for (int i = 0; i < (int)r_q.size(); ++i) {
      if (r_q[i].due > cycle) continue;
      bool older_same = false;
      for (int j = 0; j < i; ++j) if (r_q[j].id == r_q[i].id) older_same = true;
      if (!older_same) ok.push_back(i);
    }
    if (!ok.empty()) r_cur = ok[rng() % ok.size()];
  }
  if (r_cur >= 0) {
    auto& r = r_q[r_cur];
    uint32_t a = (r.addr & ~uint32_t(DWB - 1)) + r.sent * DWB;
    for (int k = 0; k < DWB / 4; ++k) top->m_rdata[k] = mem_read32(a + 4 * k);
    top->m_rvalid = 1; top->m_rid = r.id; top->m_rresp = 0;
    top->m_rlast = (r.sent + 1 == r.beats);
  } else {
    top->m_rvalid = 0; top->m_rlast = 0;
  }
}

void tick() {
  ddr_model_drive();
  ddr_model_comb();
  top->clk = 0; top->eval();
  ddr_model_edge();
  top->clk = 1; top->eval();
  ++cycle;
}

// ── Host AXI4-Lite master ────────────────────────────────────────────────────────
void reg_wr(uint32_t a, uint32_t v) {
  top->s_awaddr = a; top->s_wdata = v; top->s_wstrb = 0xF;
  top->s_awvalid = 1; top->s_wvalid = 1; top->s_bready = 1;
  while (true) { top->eval(); bool go = top->s_awready; tick(); if (go) break; }
  top->s_awvalid = 0; top->s_wvalid = 0;
  while (!top->s_bvalid) tick();
  tick();
  top->s_bready = 0;
}
uint32_t reg_rd(uint32_t a) {
  top->s_araddr = a; top->s_arvalid = 1; top->s_rready = 1;
  while (true) { top->eval(); bool go = top->s_arready; tick(); if (go) break; }
  top->s_arvalid = 0;
  while (!top->s_rvalid) tick();
  uint32_t v = top->s_rdata;
  tick();
  top->s_rready = 0;
  return v;
}

enum { R_CTRL = 0x00, R_START = 0x04, R_STATUS = 0x08, R_DCRA = 0x0C, R_DCRW = 0x10,
       R_DCRR = 0x14, R_DCRD = 0x18, R_BCYC_LO = 0x1C, R_BCYC_HI = 0x20, R_INFO = 0x24,
       R_NAR = 0x28, R_NAW = 0x2C, R_NR = 0x30, R_NB = 0x34, R_ERRADDR = 0x38 };

void dcr_wr(uint32_t a, uint32_t v) { reg_wr(R_DCRA, a); reg_wr(R_DCRW, v); }
uint64_t busycyc() { uint32_t lo = reg_rd(R_BCYC_LO); return ((uint64_t)reg_rd(R_BCYC_HI) << 32) | lo; }
bool wait_idle(uint64_t limit) {
  for (uint64_t n = 0; n < limit; n += 64) {
    if (!(reg_rd(R_STATUS) & 1)) return true;
    for (int i = 0; i < 48; ++i) tick();
  }
  return false;
}

// ── Manifest (as baselines/vortex/simtix_apps/main.cpp) ─────────────────────────
const uint32_t PTR_FIELDS[APP_COUNT] = { 0x007, 0x01f, 0x003, 0x1ef, 0x017, 0x007, 0x003, 0x007,
                                         0x007, 0x007, 0x007, 0x001, 0x00f,
                                         0x007, 0x007, 0x00f, 0x007, 0x003, 0x007, 0x003, 0x003, 0x007,
                                         0x003, 0x003, 0x0ff, 0x05f };
const char* const APP_NAMES[APP_COUNT] = { "gemm", "spmv", "stencil", "kmeans", "bfs", "scan",
                                           "scan_add", "mlp", "conv8", "embag", "hashj", "mandel", "swat",
                                           "pathfinder", "bp_forward", "bp_adjust", "hotspot_rd", "nn", "hotspot3d", "gauss_fan1", "gauss_fan2", "kmeans_rd",
                                           "axpy_rv", "jacobi_rv", "bs_rv", "lavamd_rv" };
struct Launch { std::string tag; uint32_t slot, param, threads, blk; int app; };
struct Case   { std::string name, mem, gold; std::vector<Launch> launches; bool ok = true; };

std::string host_path(std::string p) {
  if (p.size() > 2 && p[1] == ':' && (p[2] == '/' || p[2] == '\\')) {
    std::string r = "/mnt/"; r += (char)std::tolower((unsigned char)p[0]); r += p.substr(2);
    for (auto& ch : r) if (ch == '\\') ch = '/';
    return r;
  }
  return p;
}

std::vector<Case> read_manifest(const char* path) {
  std::ifstream f(path);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", path); std::exit(1); }
  std::vector<Case> cases;
  std::map<uint32_t, int> slot_app;
  std::string line;
  while (std::getline(f, line)) {
    std::istringstream s(line);
    std::string kw; s >> kw;
    if (kw == "KERNEL") {
      uint32_t slot; std::string p; s >> slot >> p;
      std::string n = p.substr(p.find_last_of("/\\") + 1);
      n = n.substr(0, n.rfind('.'));
      int app = -1;
      for (int i = 0; i < APP_COUNT; ++i) if (n == APP_NAMES[i]) app = i;
      slot_app[slot] = app;
    } else if (kw == "CASE") { cases.emplace_back(); s >> cases.back().name; }
    else if (kw == "MEM")  { std::string p; s >> p; cases.back().mem  = host_path(p); }
    else if (kw == "GOLD") { std::string p; s >> p; cases.back().gold = host_path(p); }
    else if (kw == "LAUNCH") {
      Launch l; s >> l.tag >> l.slot >> std::hex >> l.param >> std::dec >> l.threads >> l.blk;
      auto it = slot_app.find(l.slot);
      l.app = (it == slot_app.end()) ? -1 : it->second;
      if (l.app < 0) cases.back().ok = false;
      cases.back().launches.push_back(l);
    }
  }
  return cases;
}

std::vector<uint32_t> read_image(const std::string& path) {
  std::ifstream f(path);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", path.c_str()); std::exit(1); }
  std::vector<uint32_t> img; std::string tok; size_t i = 0;
  while (f >> tok) {
    if (tok[0] == '@') { i = std::stoul(tok.substr(1), nullptr, 16); continue; }
    if (i >= img.size()) img.resize(i + 1, 0);
    img[i++] = (uint32_t)std::stoul(tok, nullptr, 16);
  }
  img.resize((img.size() + 15) & ~size_t(15), 0);
  return img;
}

// ── .vxbin ──────────────────────────────────────────────────────────────────────
uint32_t img_base = 0, main_pc = 0;
void load_vxbin(const char* path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", path); std::exit(1); }
  std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
  uint64_t min_vma, max_vma;
  std::memcpy(&min_vma, &b[0], 8); std::memcpy(&max_vma, &b[8], 8);
  size_t footer = 0;
  main_pc = (uint32_t)min_vma;
  if (b.size() >= 28 && std::memcmp(&b[b.size() - 8], "VXSYMTAB", 8) == 0) {
    uint32_t n; std::memcpy(&n, &b[b.size() - 12], 4);
    const uint8_t* ent = &b[b.size() - 12 - 16 * n];
    size_t blob_end = 0;                     // the name blob precedes the entries
    for (uint32_t i = 0; i < n; ++i) {
      uint32_t off; uint16_t len;
      std::memcpy(&off, ent + 16 * i, 4); std::memcpy(&len, ent + 16 * i + 4, 2);
      blob_end = std::max(blob_end, (size_t)off + len);
    }
    footer = 12 + 16 * n + blob_end;
    const uint8_t* blob = &b[b.size() - footer];
    for (uint32_t i = 0; i < n; ++i) {
      uint32_t off; uint16_t len; uint64_t pc;
      std::memcpy(&off, ent + 16 * i, 4); std::memcpy(&len, ent + 16 * i + 4, 2); std::memcpy(&pc, ent + 16 * i + 8, 8);
      if (std::string((const char*)blob + off, len) == "main") main_pc = (uint32_t)pc;
    }
  }
  size_t bin = b.size() - 16 - footer;
  for (uint64_t a = min_vma; a < max_vma; a += 4) {
    uint32_t w = 0;
    size_t o = a - min_vma;
    if (o < bin) std::memcpy(&w, &b[16 + o], std::min<size_t>(4, bin - o));
    vx_write32((uint32_t)a, w);
  }
  img_base = (uint32_t)min_vma;
  std::printf("vxbin %s: image 0x%08x-0x%08x, main at 0x%08x\n", path, (unsigned)min_vma, (unsigned)max_vma, main_pc);
}

int run_case(const Case& c, uint32_t nt, uint32_t block_override) {
  std::vector<uint32_t> img = read_image(c.mem);
  auto reloc = [&](uint32_t a) { return a - DDR_BASE_IMG + VX_BUF; };
  for (const auto& l : c.launches) {
    uint32_t w = (l.param - DDR_BASE_IMG) / 4;
    for (uint32_t i = 0; i < 32; ++i)
      if (PTR_FIELDS[l.app] >> i & 1) img[w + i] = reloc(img[w + i]);
  }
  for (size_t i = 0; i < img.size(); ++i) vx_write32(VX_BUF + 4 * (uint32_t)i, img[i]);

  uint64_t total = 0, flush_total = 0;
  for (const auto& l : c.launches) {
    uint32_t block = nt << l.blk;
    if (block_override && l.app != APP_SCAN) block = std::min(block_override, l.threads);
    vx_write32(VX_ARGS + 0, (uint32_t)l.app);
    vx_write32(VX_ARGS + 4, reloc(l.param));
    vx_write32(VX_ARGS + 8, l.threads);
    dcr_wr(VX_DCR_KMU_STARTUP_ADDR0, img_base);  dcr_wr(VX_DCR_KMU_STARTUP_ADDR1, 0);
    dcr_wr(VX_DCR_KMU_KERNEL_ENTRY0, main_pc);   dcr_wr(VX_DCR_KMU_KERNEL_ENTRY1, 0);
    dcr_wr(VX_DCR_KMU_STARTUP_ARG0, VX_ARGS);    dcr_wr(VX_DCR_KMU_STARTUP_ARG1, 0);
    dcr_wr(VX_DCR_KMU_BLOCK_DIM_X, block);       dcr_wr(VX_DCR_KMU_BLOCK_DIM_Y, 1);
    dcr_wr(VX_DCR_KMU_BLOCK_DIM_Z, 1);
    dcr_wr(VX_DCR_KMU_GRID_DIM_X, (l.threads + block - 1) / block); dcr_wr(VX_DCR_KMU_GRID_DIM_Y, 1);  // t >= threads skipped
    dcr_wr(VX_DCR_KMU_GRID_DIM_Z, 1);
    dcr_wr(VX_DCR_KMU_LMEM_SIZE, l.app == APP_SCAN ? (block / nt) * 4 : 0);
    dcr_wr(VX_DCR_KMU_BLOCK_SIZE, block);
    dcr_wr(VX_DCR_KMU_WARP_STEP_X, nt % block);  dcr_wr(VX_DCR_KMU_WARP_STEP_Y, 0);
    dcr_wr(VX_DCR_KMU_WARP_STEP_Z, 0);
    dcr_wr(VX_DCR_KMU_CLUSTER_DIM_X, 1); dcr_wr(VX_DCR_KMU_CLUSTER_DIM_Y, 1); dcr_wr(VX_DCR_KMU_CLUSTER_DIM_Z, 1);
    uint64_t b0 = busycyc();
    reg_wr(R_START, 1);
    if (!wait_idle(200000000ull)) { std::printf("TIMEOUT %s %s\n", c.name.c_str(), l.tag.c_str()); std::exit(3); }
    uint64_t b1 = busycyc();
    // flush the write-back L1 (core 0); the DCR read answers once the flush is done
    reg_wr(R_DCRA, VX_DCR_BASE_CACHE_FLUSH); reg_wr(R_DCRR, 0);
    while (!(reg_rd(R_STATUS) & 2)) for (int i = 0; i < 16; ++i) tick();
    if (!wait_idle(10000000ull)) { std::printf("TIMEOUT flush %s\n", c.name.c_str()); std::exit(3); }
    uint64_t b2 = busycyc();
    total += b1 - b0; flush_total += b2 - b1;
    std::printf("PSCSV,vortex,%s,%s,%u,%llu,%llu\n", c.name.c_str(), l.tag.c_str(), l.threads,
                (unsigned long long)(b1 - b0), (unsigned long long)(b2 - b1));
  }
  uint32_t st = reg_rd(R_STATUS);
  if (st & 4) std::printf("ADDRESS OUTSIDE THE WINDOWS: 0x%08x\n", reg_rd(R_ERRADDR));

  std::ifstream g(c.gold);
  if (!g) { std::fprintf(stderr, "cannot open %s\n", c.gold.c_str()); std::exit(1); }
  int errors = 0, checked = 0;
  std::string si, sv;
  while (g >> si >> sv) {
    size_t i = std::stoul(si, nullptr, 16);
    uint32_t want = (uint32_t)std::stoul(sv, nullptr, 16);
    ++checked;
    uint32_t got = vx_read32(VX_BUF + 4 * (uint32_t)i);
    if (got != want) {
      if (errors < 8) std::printf("  [FAIL] %s word %zx: got %08x want %08x\n", c.name.c_str(), i, got, want);
      ++errors;
    }
  }
  std::printf("%s %s: %d words checked, %d wrong, %llu cycles + %llu flush\n", errors ? "FAIL" : "PASS",
              c.name.c_str(), checked, errors, (unsigned long long)total, (unsigned long long)flush_total);
  return errors + ((st & 4) ? 1 : 0);
}

} // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  const char *kfile = "kernel.vxbin", *manifest = nullptr, *only = nullptr;
  uint32_t block_override = 0;
  int opt;
  while ((opt = getopt(argc, argv, "k:m:c:b:s:")) != -1) {
    switch (opt) {
      case 'k': kfile = optarg; break;
      case 'm': manifest = optarg; break;
      case 'c': only = optarg; break;
      case 'b': block_override = (uint32_t)std::atoi(optarg); break;
      case 's': rng.seed((unsigned)std::atoi(optarg)); break;
      default: return 2;
    }
  }
  if (!manifest) { std::fprintf(stderr, "-m <apps.manifest> required\n"); return 2; }

  top = new Vvortex_ps_top;
  top->aresetn = 0; top->s_awvalid = 0; top->s_wvalid = 0; top->s_arvalid = 0;
  top->s_bready = 0; top->s_rready = 0;
  for (int i = 0; i < 20; ++i) tick();
  top->aresetn = 1;
  for (int i = 0; i < 20; ++i) tick();

  uint32_t info = reg_rd(R_INFO);
  uint32_t nt = (info >> 8) & 0xFF;
  std::printf("INFO %08x: %u warps x %u threads, %u core(s)\n", info, (info >> 16) & 0xFF, nt, info & 0xFF);
  load_vxbin(kfile);
  reg_wr(R_CTRL, 1);                       // reset Vortex for a while, then release it
  for (int i = 0; i < 64; ++i) tick();
  reg_wr(R_CTRL, 0);
  for (int i = 0; i < 64; ++i) tick();

  int errors = 0, ran = 0;
  for (const auto& c : read_manifest(manifest)) {
    if (only && c.name != only) continue;
    if (!c.ok) { std::printf("SKIP %s\n", c.name.c_str()); continue; }
    errors += run_case(c, nt, block_override);
    ++ran;
  }
  std::printf("AXI handshakes AR %u AW %u R %u B %u, %llu cycles\n", reg_rd(R_NAR), reg_rd(R_NAW),
              reg_rd(R_NR), reg_rd(R_NB), (unsigned long long)cycle);
  std::printf(errors || !ran ? "VX_PS_TB: FAIL\n" : "VX_PS_TB: PASS\n");
  top->final();
  delete top;
  return errors ? 1 : 0;
}
