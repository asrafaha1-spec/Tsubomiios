// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

// Ported from Tsubomi by 125hz (ios/src/UpstreamMain.cpp, https://github.com/125hz/Tsubomi, GPL-2.0)

#include "ios_jit.h"
#include "../crash_report.h"

#include <cpu/functions.h>
#include <mem/functions.h>
#include <util/log.h>

#include <spdlog/spdlog.h>

#include <dlfcn.h>
#include <signal.h>
#include <sys/sysctl.h>
#include <sys/ucontext.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <cstdlib>

// csops() is a private syscall but is the standard way to read the code-signing status flags.
// CS_DEBUGGED stays set for the process lifetime once a debugger has attached and enabled JIT,
// whereas P_TRACED drops the moment StikDebug detaches.
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000u
#endif

// StikDebug universal.js "detach" call (x16 = 0). Ends the debug session once every executable
// region is prepared; the prepared regions stay executable. See StikJIT's INTEGRATION.md.
extern "C" __attribute__((noinline, optnone, naked)) void v3k_universal_jit_detach() {
    __asm__("mov x16, #0\n"
            "brk #0xf00d\n"
            "ret");
}

namespace ios {

namespace {

std::atomic_bool g_jit_pool_ready{ false };
std::atomic_bool g_unhandled_universal_jit_breakpoint{ false };

int os_major_version() {
    char version[32]{};
    size_t size = sizeof(version);
    if (sysctlbyname("kern.osproductversion", version, &size, nullptr, 0) != 0)
        return 0;
    return std::atoi(version);
}

// Several device deaths leave no trace in the log because they are not SEGV/BUS data faults
// (mem.cpp already logs those). Log the signal, PC and owning image, then re-raise with the
// default action so iOS still writes its crash report.
void fatal_signal_handler(int sig, siginfo_t *info, void *uct) {
    uintptr_t pc = 0;
#if defined(__aarch64__)
    if (uct) {
        auto *context = static_cast<ucontext_t *>(uct);
        pc = context->uc_mcontext->__ss.__pc;
        // oaknut asks StikDebug to prepare an iOS 26 executable mapping with BRK #0xf00d. If nothing
        // answers it, it arrives as SIGTRAP: return nullptr from the helper so the allocator throws
        // and the launch fails with an explanation instead of killing the app.
        constexpr std::uint32_t universal_jit_breakpoint = 0xD43E01A0;
        if (sig == SIGTRAP && pc != 0 && *reinterpret_cast<const std::uint32_t *>(pc) == universal_jit_breakpoint) {
            context->uc_mcontext->__ss.__x[0] = 0;
            context->uc_mcontext->__ss.__pc = pc + sizeof(std::uint32_t);
            g_unhandled_universal_jit_breakpoint.store(true, std::memory_order_relaxed);
            static constexpr char message[] = "Vita3K: no JIT script answered the universal JIT request.\n";
            write(STDERR_FILENO, message, sizeof(message) - 1);
            return;
        }
    }
#endif
    // Several threads can fault at once (they did in Madden NFL 13): only the first writes the crash
    // report and log line; the others wait here until it takes the process down
    static std::atomic_flag reporting = ATOMIC_FLAG_INIT;
    if (reporting.test_and_set()) {
        for (;;)
            pause();
    }
    Dl_info dl_info{};
    const char *image = "?";
    uintptr_t image_base = 0;
    if (pc && dladdr(reinterpret_cast<void *>(pc), &dl_info) && dl_info.dli_fname) {
        image = dl_info.dli_fname;
        image_base = reinterpret_cast<uintptr_t>(dl_info.dli_fbase);
    }
    ios::crash::write_signal(sig, pc, image, image_base ? pc - image_base : 0,
        info ? reinterpret_cast<uintptr_t>(info->si_addr) : 0);
    // Not async-signal-safe, but the process is dying anyway and this is the only way into the log
    LOG_CRITICAL("FATAL SIGNAL {}: PC=0x{:X} (image '{}' +0x{:X}) fault_addr=0x{:X}",
        sig, pc, image, image_base ? pc - image_base : 0,
        info ? reinterpret_cast<uintptr_t>(info->si_addr) : 0);
    if (auto logger = spdlog::default_logger())
        logger->flush();

    signal(sig, SIG_DFL);
    raise(sig);
}

} // namespace

void install_fatal_signal_logger() {
    // Run the handler on its own stack so a stack overflow can still be reported
    static std::array<char, SIGSTKSZ> alt_stack_storage;
    stack_t alt_stack{};
    alt_stack.ss_sp = alt_stack_storage.data();
    alt_stack.ss_size = alt_stack_storage.size();
    sigaltstack(&alt_stack, nullptr);

    struct sigaction sa{};
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sa.sa_sigaction = fatal_signal_handler;
    // SIGSEGV/SIGBUS belong to mem.cpp's guest-fault handler
    for (const int sig : { SIGABRT, SIGILL, SIGTRAP, SIGFPE })
        sigaction(sig, &sa, nullptr);
}

bool debugger_attached() {
    struct kinfo_proc info{};
    std::size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    return sysctl(mib, 4, &info, &size, nullptr, 0) == 0 && (info.kp_proc.p_flag & P_TRACED) != 0;
}

bool jit_capability_enabled() {
    uint32_t cs_flags = 0;
    return (csops(getpid(), CS_OPS_STATUS, &cs_flags, sizeof(cs_flags)) == 0 && (cs_flags & CS_DEBUGGED) != 0)
        || debugger_attached();
}

bool jit_pool_ready() {
    return g_jit_pool_ready.load(std::memory_order_relaxed);
}

bool jit_can_prepare() {
    if (jit_pool_ready() || !jit_capability_enabled())
        return false;
    return os_major_version() < 26 || debugger_attached();
}

// iOS 26 needs the debugger attached while the RX/RW region pool is prepared. CS_DEBUGGED survives a
// detach but is not enough to answer oaknut's request. Once the pool is complete, detaching is safe.
// Before iOS 26 the debugger flag alone is enough.
bool jit_available() {
    if (os_major_version() < 26)
        return jit_capability_enabled();
    return jit_pool_ready() || (jit_capability_enabled() && debugger_attached());
}

bool prepare_jit_pool() {
    if (jit_pool_ready())
        return true;

    // Reserve the guest address space first: the JIT mappings fragment it otherwise and memory
    // init later fails with ENOMEM
    if (!prereserve_guest_memory())
        LOG_CRITICAL("Could not prereserve guest memory");

    if (os_major_version() < 26) {
        // Classic debugger JIT: oaknut maps RWX itself, nothing to prepare
        g_jit_pool_ready = jit_capability_enabled();
        return jit_pool_ready();
    }

#if defined(__aarch64__)
    if (!debugger_attached()) {
        LOG_WARN("JIT pool not prepared: no debugger attached");
        return false;
    }

    g_unhandled_universal_jit_breakpoint.store(false, std::memory_order_relaxed);
    try {
        if (!prewarm_ios_jit_code_cache_pool()) {
            if (auto logger = spdlog::default_logger())
                logger->flush();
            return false;
        }
    } catch (const std::exception &error) {
        LOG_ERROR("iOS JIT region pool preparation failed: {}{}", error.what(),
            g_unhandled_universal_jit_breakpoint.load() ? " (no JIT script answered: use StikDebug's universal.js)" : "");
        return false;
    } catch (...) {
        LOG_ERROR("iOS JIT region pool preparation failed with an unknown exception");
        return false;
    }

    g_jit_pool_ready = true;

    // Let the debugger go. Vita3K handles guest memory faults itself, and with a debugger attached each
    // fault takes a round trip through StikDebug: slow, and the game dies if StikDebug is suspended.
    LOG_INFO("JIT region pool ready, detaching the JIT script");
    v3k_universal_jit_detach();
    for (int i = 0; i < 20 && debugger_attached(); i++)
        usleep(50 * 1000);
    LOG_INFO("Debugger attached after detach request: {}", debugger_attached() ? "yes" : "no");
    return true;
#else
    g_jit_pool_ready = true;
    return true;
#endif
}

int jit_pool_progress() {
#if defined(__aarch64__)
    return static_cast<int>(ios_jit_code_cache_pool_progress());
#else
    return 0;
#endif
}

int jit_pool_target() {
    // the code caches prepared at launch (fewer on low-memory devices): see cpu/functions.h
#if defined(__aarch64__)
    return static_cast<int>(ios_tiny_code_cache_count() + ios_small_code_cache_count() + ios_big_code_cache_count());
#else
    return static_cast<int>(IOS_TINY_CODE_CACHE_COUNT + IOS_SMALL_CODE_CACHE_COUNT + IOS_BIG_CODE_CACHE_COUNT);
#endif
}

int jit_pool_available() {
#if defined(__aarch64__)
    if (os_major_version() >= 26)
        return static_cast<int>(ios_jit_code_cache_pool_available(IOS_TINY_CODE_CACHE_SIZE)
            + ios_jit_code_cache_pool_available(IOS_SMALL_CODE_CACHE_SIZE)
            + ios_jit_code_cache_pool_available(IOS_BIG_CODE_CACHE_SIZE));
#endif
    return -1;
}

std::string jit_status_text() {
    if (jit_pool_ready())
        return "JIT ready.";
    if (!jit_capability_enabled())
        return "JIT is not enabled. Tap Enable JIT, or launch Vita3K from StikDebug or with \"Launch with JIT\" in LiveContainer.";
    if (g_unhandled_universal_jit_breakpoint.load())
        return "JIT attached, but nothing answered Vita3K's JIT requests. Tap Enable JIT (it brings Vita3K's own JIT script), or set StikDebug's universal.js as Vita3K's script.";
    if (!debugger_attached())
        return "StikDebug let go before JIT was ready. Tap Enable JIT to attach it again.";
    return "JIT is attached but not prepared yet.";
}

} // namespace ios
