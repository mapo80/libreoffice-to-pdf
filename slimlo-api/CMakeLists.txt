cmake_minimum_required(VERSION 3.20)
project(slimlo VERSION 0.1.0 LANGUAGES CXX)

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
        # LibreOfficeKit headers
        ${INSTDIR}/../include
        # Fallback: headers in the source tree
        ${INSTDIR}/sdk/include
)

target_compile_definitions(slimlo PRIVATE
    SLIMLO_BUILDING
    SLIMLO_VERSION="${PROJECT_VERSION}"
    LO_VERSION_STR="${LO_VERSION_STR}"
)

# Link against LibreOfficeKit
# The merged library contains most of LO
find_library(MERGEDLO_LIB
    NAMES mergedlo
    PATHS ${INSTDIR}/program
    NO_DEFAULT_PATH
)

if(MERGEDLO_LIB)
    target_link_libraries(slimlo PRIVATE ${MERGEDLO_LIB})
else()
    message(WARNING "libmergedlo not found in ${INSTDIR}/program. "
                    "SlimLO will rely on runtime dlopen via LOKit.")
endif()

# LOKit uses dlopen internally
target_link_libraries(slimlo PRIVATE ${CMAKE_DL_LIBS})

# RPATH for finding LO libraries at runtime
set_target_properties(slimlo PROPERTIES
    BUILD_RPATH "${INSTDIR}/program"
    INSTALL_RPATH "$ORIGIN"
    VERSION ${PROJECT_VERSION}
    SOVERSION 0
)

# Install
install(TARGETS slimlo
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION bin
)
install(FILES include/slimlo.h DESTINATION include)
