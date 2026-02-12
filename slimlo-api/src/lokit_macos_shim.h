/*
 * lokit_macos_shim.h — Force-included before all source files on macOS.
 *
 * LibreOfficeKitInit.h has "#error LibreOfficeKit is not supported on macOS"
 * guarded by TARGET_OS_IPHONE == 0 && TARGET_OS_OSX == 1. This is a policy
 * check, not a technical limitation — LOKit works fine via dlopen on macOS.
 *
 * We include TargetConditionals.h first (so the system values are set),
 * then override the relevant macros to bypass the #error.
 */
#ifndef LOKIT_MACOS_SHIM_H
#define LOKIT_MACOS_SHIM_H

#ifdef __APPLE__
#include <TargetConditionals.h>

#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1

#undef TARGET_OS_OSX
#define TARGET_OS_OSX 0
#endif

#endif /* LOKIT_MACOS_SHIM_H */
