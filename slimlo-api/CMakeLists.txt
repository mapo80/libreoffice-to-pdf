cmake_minimum_required(VERSION 3.20)
project(slimlo VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# LibreOffice install directory (instdir from the build)
set(INSTDIR "" CACHE PATH "Path to LibreOffice instdir (from the build)")

if(NOT INSTDIR AND DEFINED ENV{INSTDIR})
    set(INSTDIR "$ENV{INSTDIR}")
endif()

if(NOT INSTDIR)
    message(FATAL_ERROR "INSTDIR must be set to the LibreOffice instdir path. "
                        "Use -DINSTDIR=/path/to/lo-src/instdir")
endif()

# SlimLO shared library
add_library(slimlo SHARED
    src/slimlo.cxx
)

target_include_directories(slimlo
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
    PRIVATE
        # LibreOfficeKit headers — path varies by platform:
        # Linux:  instdir/../include
        # macOS:  instdir/LibreOffice.app/Contents/../../.. → lo-src/include
        ${INSTDIR}/../include
        ${INSTDIR}/../../../include
        # Fallback: SDK headers
        ${INSTDIR}/sdk/include
)

target_compile_definitions(slimlo PRIVATE
    SLIMLO_BUILDING
    SLIMLO_VERSION="${PROJECT_VERSION}"
    LO_VERSION_STR="${LO_VERSION_STR}"
)

# On macOS, LibreOfficeKitInit.h has #error "not supported on macOS".
# LOKit works fine via dlopen — the #error is an upstream policy check.
# We bypass it by force-including a shim header that redefines the macros.
if(APPLE)
    target_compile_options(slimlo PRIVATE
        -include "${CMAKE_CURRENT_SOURCE_DIR}/src/lokit_macos_shim.h"
    )
endif()

# Link against LibreOfficeKit
# The merged library contains most of LO
if(APPLE)
    set(LO_LIB_DIR "${INSTDIR}/Frameworks")
else()
    set(LO_LIB_DIR "${INSTDIR}/program")
endif()

find_library(MERGEDLO_LIB
    NAMES mergedlo
    PATHS ${LO_LIB_DIR}
    NO_DEFAULT_PATH
)

if(MERGEDLO_LIB)
    target_link_libraries(slimlo PRIVATE ${MERGEDLO_LIB})
else()
    message(WARNING "libmergedlo not found in ${LO_LIB_DIR}. "
                    "SlimLO will rely on runtime dlopen via LOKit.")
endif()

# LOKit uses dlopen internally (not needed on Windows — uses LoadLibrary)
if(NOT WIN32)
    target_link_libraries(slimlo PRIVATE ${CMAKE_DL_LIBS})
endif()

# RPATH and SOVERSION (Unix only — Windows uses PATH / side-by-side)
if(NOT WIN32)
    set_target_properties(slimlo PROPERTIES
        BUILD_RPATH "${LO_LIB_DIR}"
        VERSION ${PROJECT_VERSION}
        SOVERSION 0
    )
    if(APPLE)
        set_target_properties(slimlo PROPERTIES INSTALL_RPATH "@loader_path")
    else()
        set_target_properties(slimlo PROPERTIES INSTALL_RPATH "$ORIGIN")
    endif()
endif()

# SlimLO worker executable (used by .NET SDK for out-of-process conversion)
add_executable(slimlo_worker
    src/slimlo_worker.c
    src/cjson/cJSON.c
)

target_include_directories(slimlo_worker PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(slimlo_worker PRIVATE slimlo)

# On macOS, the worker uses CoreText to register custom fonts at the process
# level (SAL_FONTPATH alone doesn't work with the osx VCL backend).
if(APPLE)
    target_link_libraries(slimlo_worker PRIVATE
        "-framework CoreText"
        "-framework CoreFoundation"
    )
endif()

if(NOT WIN32)
    set_target_properties(slimlo_worker PROPERTIES
        BUILD_RPATH "${LO_LIB_DIR}"
    )
    if(APPLE)
        set_target_properties(slimlo_worker PROPERTIES INSTALL_RPATH "@loader_path")
    else()
        set_target_properties(slimlo_worker PROPERTIES INSTALL_RPATH "$ORIGIN")
    endif()
endif()

# Install
install(TARGETS slimlo slimlo_worker
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION bin
)
install(FILES include/slimlo.h DESTINATION include)
