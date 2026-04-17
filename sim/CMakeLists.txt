cmake_minimum_required(VERSION 3.20)
project(raijin_sim LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ----------------------------------------------------------------------------
# Verilator provides its own CMake package. On MSYS2 it lands in the standard
# prefix; on Linux, distro package or the VERILATOR_ROOT env var.
#
# Note (MSYS2/Windows): verilator-config.cmake's find_program prefers
# share/verilator/bin/verilator_bin.exe, which is a Perl shim. CMake's
# `cmake -E env` wrapper cannot execute it via shebang on Windows and dies
# with a generic "unknown error". Force CMake to use the real binary in
# /ucrt64/bin instead by pre-seeding the VERILATOR_BIN cache var.
# ----------------------------------------------------------------------------
if(WIN32 AND NOT VERILATOR_BIN)
    find_program(_RAIJIN_VERILATOR_BIN
        NAMES verilator_bin.exe verilator_bin
        PATHS /ucrt64/bin /mingw64/bin C:/msys64/ucrt64/bin C:/msys64/mingw64/bin
        NO_DEFAULT_PATH
    )
    if(_RAIJIN_VERILATOR_BIN)
        set(VERILATOR_BIN "${_RAIJIN_VERILATOR_BIN}" CACHE FILEPATH
            "Path to the real Verilator binary" FORCE)
    endif()
endif()

find_package(verilator HINTS $ENV{VERILATOR_ROOT} REQUIRED)

# ----------------------------------------------------------------------------
# Static winpthread on Windows.
#
# verilate() pulls VERILATOR_MT_CFLAGS onto the target (verilator-config.cmake
# probes -pthread/-lpthread/-latomic and accumulates whatever the compiler
# accepts). On UCRT64 that resolves to dynamic libwinpthread.dll.a, which
# re-introduces the runtime DLL we are trying to eliminate.
#
# Override after find_package(verilator): swap the dynamic pthread for a
# -Bstatic libwinpthread sandwich. The closing -Bdynamic restores dynamic
# linking for the system libs (kernel32, advapi32, ...) appended after.
# ----------------------------------------------------------------------------
if(WIN32)
    set(VERILATOR_MT_CFLAGS "-Wl,-Bstatic" "-lwinpthread" "-latomic" "-Wl,-Bdynamic")
endif()

set(RTL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../raijin/rtl")

set(RTL_SOURCES
    ${RTL_DIR}/raijin_core.v
    ${RTL_DIR}/regfile.v
    ${RTL_DIR}/decoder.v
    ${RTL_DIR}/control.v
    ${RTL_DIR}/alu.v
    ${RTL_DIR}/branch_unit.v
    ${RTL_DIR}/pc_reg.v
    ${RTL_DIR}/imem.v
    ${RTL_DIR}/dmem.v
    ${RTL_DIR}/csr_file.v
    ${RTL_DIR}/uart_sim.v
    ${RTL_DIR}/m_unit.v
    ${RTL_DIR}/clint.v
)

# ----------------------------------------------------------------------------
# The shared library that C# will P/Invoke.
# On Windows this becomes raijin.dll + raijin.lib (import lib).
# On Linux  this becomes libraijin.so.
# ----------------------------------------------------------------------------
add_library(raijin SHARED
    raijin_api.cpp
    dpi_hooks.cpp
)

target_compile_definitions(raijin PRIVATE RAIJIN_BUILDING_DLL)

target_include_directories(raijin PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# ----------------------------------------------------------------------------
# Speed tuning. Doom on Raijin is strictly CPU-time bound, so every Verilator
# and compiler flag counts. The stack below targets the following:
#
#  - Verilator: -O3, --x-assign/--x-initial fast, --no-timing (we have no
#    delay/event constructs), --noassert (we have no $assert*). One big
#    translation unit (--output-split 0) so LTO can inline across internals.
#  - GCC: -O3 -flto=auto for cross-module inlining; -march=x86-64-v3 for
#    modern BMI2/AVX2 without the "native" portability footgun; no stack
#    protector or frame pointer for tight hot-path codegen; -fvisibility=hidden
#    so the DLL exports only what raijin_api.h advertises (helps LTO prune).
#  - Linker: --gc-sections + -O1 to strip dead code and shrink the DLL so
#    the host loader's per-crossing thunks stay cache-friendly.
#
# We explicitly do NOT enable --threads; for a design this small the
# partitioning barrier cost exceeds the parallel gain.
# ----------------------------------------------------------------------------
# -march=x86-64-v3 is an x86-only codegen flag (BMI2/AVX2). Apple Silicon
# and other non-x86 targets reject it outright, so only pass it on x86_64.
# On arm64 the default -O3 output already uses NEON + modern features.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
    set(RAIJIN_ARCH_FLAG "-march=x86-64-v3")
else()
    set(RAIJIN_ARCH_FLAG "")
endif()

set(RAIJIN_HOT_CFLAGS
    "-O3 -flto=auto ${RAIJIN_ARCH_FLAG}"
    "-fno-stack-protector -fomit-frame-pointer -fvisibility=hidden"
)
string(REPLACE ";" " " RAIJIN_HOT_CFLAGS "${RAIJIN_HOT_CFLAGS}")

# Dead-code stripping differs between linkers. GNU ld (Linux) / lld accept
# --gc-sections; Apple's ld64 uses -dead_strip. Pick the right one.
if(APPLE)
    set(RAIJIN_HOT_LDFLAGS "-Wl,-dead_strip -flto=auto")
else()
    set(RAIJIN_HOT_LDFLAGS "-Wl,--gc-sections -Wl,-O1 -flto=auto")
endif()

# Attach the Verilated model to the shared library.
verilate(raijin
    SOURCES      ${RTL_SOURCES}
    INCLUDE_DIRS ${RTL_DIR}
    TOP_MODULE   raijin_core
    PREFIX       Vraijin_core
    VERILATOR_ARGS
        -Wno-fatal
        -O3
        --x-assign fast
        --x-initial fast
        --no-timing
        --noassert
        # Keep the default output split so LTO gets more parallel LTRANS
        # partitions; a single giant TU hurts LTO parallelism on MSYS2.
        -CFLAGS  ${RAIJIN_HOT_CFLAGS}
        -LDFLAGS ${RAIJIN_HOT_LDFLAGS}
        # Each memory: 4194304 words = 16 MB. Doom's Z_Init asks for ~5 MB,
        # plus the 4 MB WAD blob, ~500 KB code, 256 KB stack.
        -GIMEM_DEPTH_WORDS=4194304
        -GDMEM_DEPTH_WORDS=4194304
)

# Apply the same hot flags to our own wrapper TU so raijin_api.cpp /
# dpi_hooks.cpp match the verilated code's optimization level. The arch
# flag and linker GC behaviour follow the same platform split as above.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
    target_compile_options(raijin PRIVATE
        -O3 -flto=auto -march=x86-64-v3
        -fno-stack-protector -fomit-frame-pointer
    )
else()
    target_compile_options(raijin PRIVATE
        -O3 -flto=auto
        -fno-stack-protector -fomit-frame-pointer
    )
endif()
if(APPLE)
    target_link_options(raijin PRIVATE
        -Wl,-dead_strip -flto=auto
    )
else()
    target_link_options(raijin PRIVATE
        -Wl,--gc-sections -Wl,-O1 -flto=auto
    )
endif()

# On Windows, statically link the GCC runtime so raijin.dll has zero
# external MinGW dependencies. The released zip then ships only
# raijin.exe + raijin.dll + programs/ + sdk/, no libstdc++-6 / libgcc_s /
# libwinpthread companion DLLs to forget. The static winpthread piece is
# done via the VERILATOR_MT_CFLAGS override above, since verilate() owns
# the pthread link.
if(WIN32)
    # --as-needed prevents the gcc driver's spec-appended -lpthread (dynamic
    # libwinpthread.dll.a) from leaving an unused IDATA entry in the DLL.
    # Without it raijin.dll keeps a libwinpthread-1.dll dependency even
    # though every pthread symbol was already resolved statically above.
    target_link_options(raijin PRIVATE
        -static-libgcc
        -static-libstdc++
        -Wl,--as-needed
    )
endif()

# Keep build artifacts in a tidy bin/ subdir so C# projects can copy from
# one known location regardless of platform.
set_target_properties(raijin PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
    OUTPUT_NAME              "raijin"
)
# On Windows: strip the MinGW "lib" prefix so we get raijin.dll instead of
# libraijin.dll. .NET's P/Invoke convention expects bare names on Windows.
# On Linux we want libraijin.so (the conventional "lib" prefix), which .NET's
# resolver also expects automatically.
if(WIN32)
    set_target_properties(raijin PROPERTIES PREFIX "")
endif()
