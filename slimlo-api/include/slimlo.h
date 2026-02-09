/*
 * slimlo.h — SlimLO PDF Conversion Library
 *
 * Minimal C API for converting OOXML documents (docx, xlsx, pptx) to PDF.
 * Built on top of LibreOffice's rendering engine via LibreOfficeKit.
 *
 * Thread safety: LibreOffice is single-threaded for document processing.
 * All conversion calls are serialized internally via mutex.
 * For concurrent conversions, use multiple processes.
 *
 * Usage:
 *   SlimLOHandle h = slimlo_init("/path/to/slimlo/resources");
 *   SlimLOError err = slimlo_convert_file(h, "input.docx", "output.pdf",
 *                                          SLIMLO_FORMAT_UNKNOWN, NULL);
 *   slimlo_destroy(h);
 */

#ifndef SLIMLO_H
#define SLIMLO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Library export/import macros */
#ifdef _WIN32
  #ifdef SLIMLO_BUILDING
    #define SLIMLO_API __declspec(dllexport)
  #else
    #define SLIMLO_API __declspec(dllimport)
  #endif
#else
  #ifdef SLIMLO_BUILDING
    #define SLIMLO_API __attribute__((visibility("default")))
  #else
    #define SLIMLO_API
  #endif
#endif

/* Opaque handle to the SlimLO instance */
typedef struct SlimLOInstance* SlimLOHandle;

/* Error codes */
typedef enum {
    SLIMLO_OK                      = 0,
    SLIMLO_ERROR_INIT_FAILED       = 1,
    SLIMLO_ERROR_LOAD_FAILED       = 2,
    SLIMLO_ERROR_EXPORT_FAILED     = 3,
    SLIMLO_ERROR_INVALID_FORMAT    = 4,
    SLIMLO_ERROR_FILE_NOT_FOUND    = 5,
    SLIMLO_ERROR_OUT_OF_MEMORY     = 6,
    SLIMLO_ERROR_PERMISSION_DENIED = 7,
    SLIMLO_ERROR_ALREADY_INIT      = 8,
    SLIMLO_ERROR_NOT_INIT          = 9,
    SLIMLO_ERROR_INVALID_ARGUMENT  = 10,
    SLIMLO_ERROR_UNKNOWN           = 99
} SlimLOError;

/* Input format hint (auto-detected if UNKNOWN) */
typedef enum {
    SLIMLO_FORMAT_UNKNOWN = 0,
    SLIMLO_FORMAT_DOCX    = 1,
    SLIMLO_FORMAT_XLSX    = 2,
    SLIMLO_FORMAT_PPTX    = 3
} SlimLOFormat;

/* PDF version for output */
typedef enum {
    SLIMLO_PDF_DEFAULT = 0,
    SLIMLO_PDF_A1      = 1,
    SLIMLO_PDF_A2      = 2,
    SLIMLO_PDF_A3      = 3
} SlimLOPdfVersion;

/* PDF conversion options */
typedef struct {
    SlimLOPdfVersion pdf_version;   /* PDF version (0 = default) */
    int              jpeg_quality;  /* JPEG quality 1-100 (0 = default 90) */
    int              dpi;           /* Resolution (0 = default 300) */
    int              tagged_pdf;    /* 0 = no, 1 = yes */
    const char*      page_range;    /* Page range, e.g. "1-3" (NULL = all) */
    const char*      password;      /* Document password (NULL = none) */
} SlimLOPdfOptions;

/**
 * Initialize the SlimLO library. Call once per process.
 *
 * @param resource_path  Path to the directory containing SlimLO resources
 *                       (the extracted output/ directory from the build).
 *                       If NULL, tries to auto-detect from library location.
 * @return Handle on success, NULL on failure.
 *         Call slimlo_get_error_message(NULL) for details on failure.
 */
SLIMLO_API SlimLOHandle slimlo_init(const char* resource_path);

/**
 * Destroy the SlimLO instance and free all resources.
 *
 * @param handle  Handle from slimlo_init(). Safe to call with NULL.
 */
SLIMLO_API void slimlo_destroy(SlimLOHandle handle);

/**
 * Convert a document file to PDF.
 *
 * @param handle       Handle from slimlo_init().
 * @param input_path   Path to input document (.docx, .xlsx, .pptx).
 * @param output_path  Path for output PDF file.
 * @param format_hint  Format hint (SLIMLO_FORMAT_UNKNOWN for auto-detect).
 * @param options      PDF options (NULL for defaults).
 * @return SLIMLO_OK on success, error code on failure.
 */
SLIMLO_API SlimLOError slimlo_convert_file(
    SlimLOHandle handle,
    const char* input_path,
    const char* output_path,
    SlimLOFormat format_hint,
    const SlimLOPdfOptions* options
);

/**
 * Convert a document from memory buffer to PDF in memory.
 *
 * @param handle       Handle from slimlo_init().
 * @param input_data   Input document bytes.
 * @param input_size   Size of input data.
 * @param format_hint  Format hint (required for buffer conversion).
 * @param options      PDF options (NULL for defaults).
 * @param output_data  Receives pointer to allocated PDF bytes.
 *                     Caller must free with slimlo_free_buffer().
 * @param output_size  Receives size of output PDF data.
 * @return SLIMLO_OK on success, error code on failure.
 */
SLIMLO_API SlimLOError slimlo_convert_buffer(
    SlimLOHandle handle,
    const uint8_t* input_data,
    size_t input_size,
    SlimLOFormat format_hint,
    const SlimLOPdfOptions* options,
    uint8_t** output_data,
    size_t* output_size
);

/**
 * Free a buffer allocated by slimlo_convert_buffer().
 *
 * @param buffer  Pointer returned via output_data. Safe to call with NULL.
 */
SLIMLO_API void slimlo_free_buffer(uint8_t* buffer);

/**
 * Get the last error message (thread-local).
 *
 * @param handle  Handle from slimlo_init(), or NULL for init errors.
 * @return Error message string. Valid until next SlimLO call on same thread.
 *         Returns empty string if no error.
 */
SLIMLO_API const char* slimlo_get_error_message(SlimLOHandle handle);

/**
 * Get the library version string.
 *
 * @return Version string in format "SlimLO X.Y.Z (LibreOffice A.B.C.D)".
 */
SLIMLO_API const char* slimlo_version(void);

#ifdef __cplusplus
}
#endif

#endif /* SLIMLO_H */
