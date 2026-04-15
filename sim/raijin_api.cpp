// ============================================================================
// raijin_api.cpp: extern "C" hourglass wrapper around the Verilated Raijin core.
//
// Phase 1 scope:
//   - Lifecycle (create / destroy / reset).
//   - load_hex: parse a $readmemh-format file into both IMEM and DMEM.
//   - step: run cycles, halt early when tohost goes non-zero.
//   - Introspection: PC, regfile, cycle count, instret (approx), DMEM read,
//     halted flag, tohost word.
//
// Conventions match raijin/dv/riscv_test_tb.v:
//   - 65536 words per memory (256 KB), set via Verilator -G defines.
//   - tohost at byte 0x1000 (word index 0x400) in DMEM.
//   - Both memories are loaded with the same image so instruction fetches
//     and data loads see one unified program image.
// ============================================================================

#include "raijin_api.h"

#include "Vraijin_core.h"
#include "Vraijin_core___024root.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

// Verilator's runtime references sc_time_stamp() as a SystemC fallback even
// when we drive time via VerilatedContext. A trivial stub satisfies the link.
double sc_time_stamp() { return 0; }

// Implemented in dpi_hooks.cpp.
extern "C" int  raijin_dpi_uart_drain(char* buf, int max);
extern "C" void raijin_dpi_uart_push(unsigned char c);
extern "C" void raijin_dpi_uart_flush(void);

namespace {
    constexpr uint32_t MEM_DEPTH_WORDS  = 4194304;   // 16 MB per memory (Doom with Z_Init)
    constexpr uint32_t TOHOST_WORD_INDEX = 0x400;    // byte 0x1000 / 4
} // namespace

struct RaijinSim {
    VerilatedContext* ctx = nullptr;
    Vraijin_core*     dut = nullptr;

    uint64_t cycle_count = 0;
    uint64_t instret     = 0;   // refined: cycles where the design committed work

    RaijinSim() {
        ctx = new VerilatedContext;
        dut = new Vraijin_core{ctx};
        dut->clk   = 0;
        dut->reset = 1;
        for (int i = 0; i < 4; ++i) tick();
        dut->reset = 0;
        cycle_count = 0;
        instret     = 0;
    }

    ~RaijinSim() {
        if (dut) { dut->final(); delete dut; dut = nullptr; }
        if (ctx) { delete ctx; ctx = nullptr; }
    }

    // One full clock cycle: low half then high half, eval after each.
    void tick() {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
        ctx->timeInc(1);
        ++cycle_count;
        ++instret;   // single-cycle CPU: one retire per cycle (close enough)
    }

    void hard_reset() {
        dut->reset = 1;
        for (int i = 0; i < 4; ++i) tick();
        dut->reset = 0;
        cycle_count = 0;
        instret     = 0;
        raijin_dpi_uart_flush();   // residual TX/RX bytes from the prior run
    }

    bool halted() const {
        return dut->rootp->raijin_core__DOT__dmem_inst__DOT__mem[TOHOST_WORD_INDEX] != 0;
    }

    uint32_t tohost() const {
        return dut->rootp->raijin_core__DOT__dmem_inst__DOT__mem[TOHOST_WORD_INDEX];
    }

    // Load a $readmemh-style file into both memories. Format: one 32-bit hex
    // word per line, starting at word 0. Blank lines and // comments tolerated.
    // @addr directives respected (address is a hex word index).
    int load_hex(const char* path) {
        std::FILE* fp = std::fopen(path, "r");
        if (!fp) return -1;

        // Wipe both memories so a partial program does not leave stale data.
        std::memset(&dut->rootp->raijin_core__DOT__imem_inst__DOT__mem, 0,
                    sizeof(dut->rootp->raijin_core__DOT__imem_inst__DOT__mem));
        std::memset(&dut->rootp->raijin_core__DOT__dmem_inst__DOT__mem, 0,
                    sizeof(dut->rootp->raijin_core__DOT__dmem_inst__DOT__mem));

        uint32_t addr = 0;
        char line[256];
        while (std::fgets(line, sizeof(line), fp)) {
            // Trim leading whitespace.
            char* p = line;
            while (*p == ' ' || *p == '\t') ++p;
            if (*p == '\0' || *p == '\n' || *p == '\r') continue;
            if (p[0] == '/' && p[1] == '/') continue;

            if (*p == '@') {
                addr = static_cast<uint32_t>(std::strtoul(p + 1, nullptr, 16));
                continue;
            }

            // Otherwise expect a hex word.
            uint32_t word = static_cast<uint32_t>(std::strtoul(p, nullptr, 16));
            if (addr >= MEM_DEPTH_WORDS) {
                std::fclose(fp);
                return -2;   // overflow
            }
            dut->rootp->raijin_core__DOT__imem_inst__DOT__mem[addr] = word;
            dut->rootp->raijin_core__DOT__dmem_inst__DOT__mem[addr] = word;
            ++addr;
        }
        std::fclose(fp);

        // After loading, hard reset so PC starts at 0 against the new program.
        hard_reset();
        return 0;
    }
};

extern "C" {

RAIJIN_API RaijinSim* raijin_create(void) {
    return new RaijinSim();
}

RAIJIN_API void raijin_destroy(RaijinSim* sim) {
    delete sim;
}

RAIJIN_API void raijin_reset(RaijinSim* sim) {
    if (sim) sim->hard_reset();
}

RAIJIN_API int raijin_load_hex(RaijinSim* sim, const char* path) {
    if (!sim || !path) return -1;
    return sim->load_hex(path);
}

RAIJIN_API uint64_t raijin_step(RaijinSim* sim, uint64_t max_cycles) {
    if (!sim) return 0;

    // Cache direct pointers into the verilated model's internals so the hot
    // loop avoids re-walking the accessor chain on every cycle.
    auto* dut      = sim->dut;
    auto* root     = dut->rootp;
    uint32_t* tohost_ptr = &root->raijin_core__DOT__dmem_inst__DOT__mem[TOHOST_WORD_INDEX];

    // Two eval()s per cycle: one at clk=0 to settle combinational, one at
    // clk=1 to fire the rising edge. We tried folding to a single eval()
    // (since the design is purely posedge) but it confused Verilator's
    // edge-detection — perfcounters went to zero even though the loop ran,
    // so the posedge FFs weren't actually triggering. Not worth chasing.
    constexpr uint64_t HALT_CHECK_MASK = 0xFF;

    uint64_t ran = 0;
    for (uint64_t i = 0; i < max_cycles; ++i) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
        ++ran;
        if (((ran & HALT_CHECK_MASK) == 0) && *tohost_ptr != 0) break;
    }
    sim->cycle_count += ran;
    sim->instret     += ran;
    sim->ctx->timeInc(ran);
    return ran;
}

RAIJIN_API int raijin_halted(RaijinSim* sim) {
    return (sim && sim->halted()) ? 1 : 0;
}

RAIJIN_API uint32_t raijin_tohost(RaijinSim* sim) {
    return sim ? sim->tohost() : 0;
}

RAIJIN_API uint32_t raijin_get_pc(RaijinSim* sim) {
    if (!sim) return 0;
    return sim->dut->rootp->raijin_core__DOT__pc_inst__DOT__pc;
}

RAIJIN_API void raijin_get_regs(RaijinSim* sim, uint32_t out[32]) {
    if (!sim) { std::memset(out, 0, 32 * sizeof(uint32_t)); return; }
    auto& regs = sim->dut->rootp->raijin_core__DOT__regfile_inst__DOT__registers;
    out[0] = 0;   // x0 is hardwired zero by spec
    for (int i = 1; i < 32; ++i) out[i] = regs[i];
}

RAIJIN_API void raijin_get_csrs(RaijinSim*, uint32_t out[8]) {
    // CSR file's storage is not yet exposed via public_flat_rd. Phase 5 will
    // add it (mstatus, mepc, mtvec, mcause, mtval, mscratch, mie, mip).
    std::memset(out, 0, 8 * sizeof(uint32_t));
}

RAIJIN_API void raijin_read_dmem(RaijinSim* sim, uint32_t byte_addr,
                                 uint8_t* buf, uint32_t len) {
    if (!sim || !buf) { if (buf) std::memset(buf, 0, len); return; }
    auto& mem = sim->dut->rootp->raijin_core__DOT__dmem_inst__DOT__mem;
    for (uint32_t i = 0; i < len; ++i) {
        uint32_t addr = byte_addr + i;
        uint32_t word_idx = addr >> 2;
        uint32_t byte_off = addr & 3;
        if (word_idx >= MEM_DEPTH_WORDS) { buf[i] = 0; continue; }
        uint32_t w = mem[word_idx];
        buf[i] = static_cast<uint8_t>((w >> (byte_off * 8)) & 0xFF);
    }
}

RAIJIN_API uint64_t raijin_cycle_count(RaijinSim* sim) {
    return sim ? sim->cycle_count : 0;
}

RAIJIN_API uint64_t raijin_instret(RaijinSim* sim) {
    return sim ? sim->instret : 0;
}

RAIJIN_API void raijin_get_class_counters(RaijinSim* sim, uint64_t out[RAIJIN_NUM_CLASS_COUNTERS]) {
    if (!sim) { std::memset(out, 0, RAIJIN_NUM_CLASS_COUNTERS * sizeof(uint64_t)); return; }
    auto* r = sim->dut->rootp;
    out[0] = r->raijin_core__DOT__cnt_mul;
    out[1] = r->raijin_core__DOT__cnt_branch_total;
    out[2] = r->raijin_core__DOT__cnt_branch_taken;
    out[3] = r->raijin_core__DOT__cnt_jump;
    out[4] = r->raijin_core__DOT__cnt_load;
    out[5] = r->raijin_core__DOT__cnt_store;
    out[6] = r->raijin_core__DOT__cnt_trap;
}

RAIJIN_API int raijin_uart_read(RaijinSim* sim, char* buf, int max) {
    if (!sim) return 0;
    return raijin_dpi_uart_drain(buf, max);
}

RAIJIN_API void raijin_uart_write(RaijinSim* sim, char c) {
    if (!sim) return;
    raijin_dpi_uart_push(static_cast<unsigned char>(c));
}

} // extern "C"
