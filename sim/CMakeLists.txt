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
    find_program(VERILATOR_BIN
        NAMES verilator_bin.exe verilator_bin
        PATHS /ucrt64/bin /mingw64/bin C:/msys64/ucrt64/bin C:/msys64/mingw64/bin
        NO_DEFAULT_PATH
    )
endif()

find_package(verilator HINTS $ENV{VERILATOR_ROOT} REQUIRED)

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
set(RAIJIN_HOT_CFLAGS
    "-O3 -flto=auto -march=x86-64-v3"
    "-fno-stack-protector -fomit-frame-pointer -fvisibility=hidden"
)
string(REPLACE ";" " " RAIJIN_HOT_CFLAGS "${RAIJIN_HOT_CFLAGS}")

set(RAIJIN_HOT_LDFLAGS "-Wl,--gc-sections -Wl,-O1 -flto=auto")

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
# dpi_hooks.cpp match the verilated code's optimization level.
target_compile_options(raijin PRIVATE
    -O3 -flto=auto -march=x86-64-v3
    -fno-stack-protector -fomit-frame-pointer
)
target_link_options(raijin PRIVATE
    -Wl,--gc-sections -Wl,-O1 -flto=auto
)

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
