// ============================================================================
// dpi_hooks.cpp: DPI-C functions called from the Verilated RTL.
//
// MVP scope: a single global ring buffer for UART TX bytes. Single-user is the
// design point right now; when we move to multi-session each connection will
// own its own RaijinSim and this buffer becomes per-instance via TLS or a
// scoped registry.
// ============================================================================

#include <cstdint>
#include <deque>
#include <mutex>

namespace {
    constexpr std::size_t MAX_BUFFERED = 1u << 20;   // 1 MiB cap

    std::mutex                 g_tx_mutex;
    std::deque<char>           g_tx_buf;

    std::mutex                 g_rx_mutex;
    std::deque<unsigned char>  g_rx_buf;
}

extern "C" {

// ---- TX path: RTL pushes via DPI; host drains via raijin_dpi_uart_drain ----

void raijin_uart_tx(unsigned char c) {
    std::lock_guard<std::mutex> lk(g_tx_mutex);
    g_tx_buf.push_back(static_cast<char>(c));
    while (g_tx_buf.size() > MAX_BUFFERED) g_tx_buf.pop_front();
}

int raijin_dpi_uart_drain(char* buf, int max) {
    if (!buf || max <= 0) return 0;
    std::lock_guard<std::mutex> lk(g_tx_mutex);
    int n = 0;
    while (n < max && !g_tx_buf.empty()) {
        buf[n++] = g_tx_buf.front();
        g_tx_buf.pop_front();
    }
    return n;
}

// ---- RX path: host pushes via raijin_dpi_uart_push; RTL pulls via DPI ----

void raijin_dpi_uart_push(unsigned char c) {
    std::lock_guard<std::mutex> lk(g_rx_mutex);
    g_rx_buf.push_back(c);
    while (g_rx_buf.size() > MAX_BUFFERED) g_rx_buf.pop_front();
}

int raijin_uart_rx_avail(void) {
    std::lock_guard<std::mutex> lk(g_rx_mutex);
    return g_rx_buf.empty() ? 0 : 1;
}

int raijin_uart_rx_pop(void) {
    std::lock_guard<std::mutex> lk(g_rx_mutex);
    if (g_rx_buf.empty()) return 0;
    unsigned char c = g_rx_buf.front();
    g_rx_buf.pop_front();
    return c;
}

/* ---- Used by raijin_reset / raijin_load_hex to wipe both queues so a
 *      fresh run never sees residual bytes from the previous one.   ---- */
void raijin_dpi_uart_flush(void) {
    {   std::lock_guard<std::mutex> lk(g_tx_mutex); g_tx_buf.clear(); }
    {   std::lock_guard<std::mutex> lk(g_rx_mutex); g_rx_buf.clear(); }
}

} // extern "C"
