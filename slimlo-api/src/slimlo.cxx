/*
 * slimlo.cxx — SlimLO C API implementation
 *
 * Wraps LibreOfficeKit (LOKit) to provide a simple PDF conversion API.
 * LOKit handles all the heavy lifting: UNO bootstrap, document loading,
 * format detection, and PDF export.
 */

#define SLIMLO_BUILDING

#include "slimlo.h"

#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>

#ifdef _WIN32
  #include <io.h>
  #include <direct.h>
  #include <windows.h>
  #define unlink _unlink
#else
  #include <unistd.h>
  #include <sys/stat.h>
#endif

// LibreOfficeKit C++ header (thin wrapper over the C API)
#include <LibreOfficeKit/LibreOfficeKit.hxx>

// Version info (set at build time)
#ifndef SLIMLO_VERSION
#define SLIMLO_VERSION "0.1.0"
#endif

#ifndef LO_VERSION_STR
#define LO_VERSION_STR "unknown"
#endif

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

struct SlimLOInstance {
    lok::Office* office;
    std::string  resource_path;
    std::string  last_error;
    std::mutex   convert_mutex;  // LibreOffice is single-threaded
};

// Thread-local error message for pre-init errors
static thread_local std::string g_init_error;

// Global singleton guard (only one instance per process)
static std::mutex g_init_mutex;
static bool g_initialized = false;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void set_error(SlimLOHandle handle, const char* msg) {
    if (handle) {
        handle->last_error = msg ? msg : "";
    } else {
        g_init_error = msg ? msg : "";
    }
}

static void set_error(SlimLOHandle handle, const std::string& msg) {
    set_error(handle, msg.c_str());
}

// Convert a file path to a file:// URL
static std::string path_to_url(const char* path) {
#ifdef _WIN32
    char abs[_MAX_PATH];
    if (_fullpath(abs, path, _MAX_PATH)) {
        std::string p(abs);
        for (auto& c : p) if (c == '\\') c = '/';
        return "file:///" + p;
    }
    std::string p(path);
    for (auto& c : p) if (c == '\\') c = '/';
    return "file:///" + p;
#else
    std::string url = "file://";
    if (path[0] != '/') {
        char* abs = realpath(path, nullptr);
        if (abs) {
            url += abs;
            free(abs);
        } else {
            url += path;
        }
    } else {
        url += path;
    }
    return url;
#endif
}

// Map SlimLOFormat to LOKit format string (file extension, not filter name)
// LOKit's saveAs() maps extensions to internal filter names via aWriterExtensionMap etc.
static const char* get_pdf_filter(SlimLOFormat format) {
    (void)format;  // All document types export to "pdf" — LOKit selects the right filter
    return "pdf";
}

// Create a temporary file and return its path (empty string on failure)
static std::string make_temp_file() {
#ifdef _WIN32
    char tmp_dir[MAX_PATH];
    GetTempPathA(MAX_PATH, tmp_dir);
    char tmp_file[MAX_PATH];
    if (GetTempFileNameA(tmp_dir, "slo", 0, tmp_file) == 0)
        return "";
    return std::string(tmp_file);
#else
    char tmpl[] = "/tmp/slimlo_XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) return "";
    close(fd);
    return std::string(tmpl);
#endif
}

// Build PDF filter options string from SlimLOPdfOptions
static std::string build_filter_options(const SlimLOPdfOptions* options) {
    if (!options) return "";

    std::string opts;

    if (options->pdf_version != SLIMLO_PDF_DEFAULT) {
        // Map to SelectPdfVersion values:
        // 0 = PDF 1.7, 1 = PDF/A-1, 2 = PDF/A-2, 3 = PDF/A-3
        if (!opts.empty()) opts += ",";
        opts += "SelectPdfVersion=" + std::to_string(static_cast<int>(options->pdf_version));
    }

    if (options->jpeg_quality > 0 && options->jpeg_quality <= 100) {
        if (!opts.empty()) opts += ",";
        opts += "Quality=" + std::to_string(options->jpeg_quality);
    }

    if (options->dpi > 0) {
        if (!opts.empty()) opts += ",";
        opts += "MaxImageResolution=" + std::to_string(options->dpi);
    }

    if (options->tagged_pdf) {
        if (!opts.empty()) opts += ",";
        opts += "UseTaggedPDF=true";
    }

    if (options->page_range && options->page_range[0] != '\0') {
        if (!opts.empty()) opts += ",";
        opts += "PageRange=";
        opts += options->page_range;
    }

    return opts;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

SLIMLO_API SlimLOHandle slimlo_init(const char* resource_path) {
    std::lock_guard<std::mutex> lock(g_init_mutex);

    if (g_initialized) {
        g_init_error = "SlimLO already initialized (only one instance per process)";
        return nullptr;
    }

    if (!resource_path || resource_path[0] == '\0') {
        g_init_error = "resource_path is required";
        return nullptr;
    }

    // Initialize LibreOfficeKit
    // lok_cpp_init expects the path to the directory containing libmergedlo.
    // This differs by platform/layout:
    //   Linux flat:    resource_path/program/
    //   macOS flat:    resource_path/program/
    //   macOS .app:    resource_path/Frameworks/
    std::string base(resource_path);
    std::string program_path = base + "/program";

    // On macOS, check if Frameworks/ exists (indicates .app bundle layout)
#ifdef __APPLE__
    {
        struct stat st;
        std::string fw_path = base + "/Frameworks";
        if (stat(fw_path.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
            program_path = fw_path;
        }
    }
#endif

    lok::Office* office = lok::lok_cpp_init(program_path.c_str());
    if (!office) {
        g_init_error = "Failed to initialize LibreOfficeKit at: " + program_path;
        return nullptr;
    }

    auto* instance = new (std::nothrow) SlimLOInstance();
    if (!instance) {
        delete office;
        g_init_error = "Out of memory";
        return nullptr;
    }

    instance->office = office;
    instance->resource_path = resource_path;
    g_initialized = true;

    return instance;
}

SLIMLO_API void slimlo_destroy(SlimLOHandle handle) {
    if (!handle) return;

    std::lock_guard<std::mutex> lock(g_init_mutex);

    if (handle->office) {
        delete handle->office;
        handle->office = nullptr;
    }

    delete handle;
    g_initialized = false;
}

SLIMLO_API SlimLOError slimlo_convert_file(
    SlimLOHandle handle,
    const char* input_path,
    const char* output_path,
    SlimLOFormat format_hint,
    const SlimLOPdfOptions* options
) {
    if (!handle || !handle->office) {
        set_error(handle, "Not initialized");
        return SLIMLO_ERROR_NOT_INIT;
    }
    if (!input_path || !output_path) {
        set_error(handle, "input_path and output_path are required");
        return SLIMLO_ERROR_INVALID_ARGUMENT;
    }

    // Serialize — LibreOffice cannot do concurrent conversions
    std::lock_guard<std::mutex> lock(handle->convert_mutex);

    // Convert paths to file:// URLs
    std::string input_url = path_to_url(input_path);
    std::string output_url = path_to_url(output_path);

    // Handle password-protected documents
    const char* load_options = nullptr;
    std::string load_opts_str;
    if (options && options->password && options->password[0] != '\0') {
        load_opts_str = std::string("{\"Password\":{\"type\":\"string\",\"value\":\"")
                        + options->password + "\"}}";
        load_options = load_opts_str.c_str();
    }

    // Load document
    lok::Document* doc = handle->office->documentLoad(input_url.c_str(), load_options);
    if (!doc) {
        const char* err = handle->office->getError();
        set_error(handle, err ? err : "Failed to load document");
        return SLIMLO_ERROR_LOAD_FAILED;
    }

    // Build filter options
    std::string filter_options = build_filter_options(options);
    const char* filter_name = get_pdf_filter(format_hint);

    // Export to PDF
    bool success = doc->saveAs(output_url.c_str(), filter_name,
                               filter_options.empty() ? nullptr : filter_options.c_str());

    delete doc;

    if (!success) {
        const char* err = handle->office->getError();
        set_error(handle, err ? err : "Failed to export PDF");
        return SLIMLO_ERROR_EXPORT_FAILED;
    }

    handle->last_error.clear();
    return SLIMLO_OK;
}

SLIMLO_API SlimLOError slimlo_convert_buffer(
    SlimLOHandle handle,
    const uint8_t* input_data,
    size_t input_size,
    SlimLOFormat format_hint,
    const SlimLOPdfOptions* options,
    uint8_t** output_data,
    size_t* output_size
) {
    if (!handle || !handle->office) {
        set_error(handle, "Not initialized");
        return SLIMLO_ERROR_NOT_INIT;
    }
    if (!input_data || input_size == 0) {
        set_error(handle, "input_data and input_size are required");
        return SLIMLO_ERROR_INVALID_ARGUMENT;
    }
    if (!output_data || !output_size) {
        set_error(handle, "output_data and output_size are required");
        return SLIMLO_ERROR_INVALID_ARGUMENT;
    }
    if (format_hint == SLIMLO_FORMAT_UNKNOWN) {
        set_error(handle, "format_hint is required for buffer conversion");
        return SLIMLO_ERROR_INVALID_FORMAT;
    }

    *output_data = nullptr;
    *output_size = 0;

    // Write input to temporary file (LOKit doesn't support memory buffers directly)
    // TODO: Implement custom UCB provider for zero-copy memory conversion
    const char* ext = ".tmp";
    switch (format_hint) {
        case SLIMLO_FORMAT_DOCX: ext = ".docx"; break;
        case SLIMLO_FORMAT_XLSX: ext = ".xlsx"; break;
        case SLIMLO_FORMAT_PPTX: ext = ".pptx"; break;
        default: break;
    }

    std::string tmp_base = make_temp_file();
    if (tmp_base.empty()) {
        set_error(handle, "Failed to create temporary input file");
        return SLIMLO_ERROR_PERMISSION_DENIED;
    }

    // Append correct extension
    std::string tmp_input_path = tmp_base + ext;
    rename(tmp_base.c_str(), tmp_input_path.c_str());

    // Write input data
    {
        std::ofstream ofs(tmp_input_path, std::ios::binary);
        ofs.write(reinterpret_cast<const char*>(input_data), input_size);
        if (!ofs) {
            unlink(tmp_input_path.c_str());
            set_error(handle, "Failed to write temporary input file");
            return SLIMLO_ERROR_PERMISSION_DENIED;
        }
    }

    // Create temporary output file
    std::string tmp_out_base = make_temp_file();
    if (tmp_out_base.empty()) {
        unlink(tmp_input_path.c_str());
        set_error(handle, "Failed to create temporary output file");
        return SLIMLO_ERROR_PERMISSION_DENIED;
    }
    std::string tmp_output_path = tmp_out_base + ".pdf";
    rename(tmp_out_base.c_str(), tmp_output_path.c_str());

    // Convert
    SlimLOError err = slimlo_convert_file(handle, tmp_input_path.c_str(),
                                          tmp_output_path.c_str(),
                                          format_hint, options);

    // Clean up input
    unlink(tmp_input_path.c_str());

    if (err != SLIMLO_OK) {
        unlink(tmp_output_path.c_str());
        return err;
    }

    // Read output
    std::ifstream ifs(tmp_output_path, std::ios::binary | std::ios::ate);
    if (!ifs) {
        unlink(tmp_output_path.c_str());
        set_error(handle, "Failed to read converted PDF");
        return SLIMLO_ERROR_EXPORT_FAILED;
    }

    size_t size = ifs.tellg();
    ifs.seekg(0);

    uint8_t* buf = static_cast<uint8_t*>(malloc(size));
    if (!buf) {
        unlink(tmp_output_path.c_str());
        set_error(handle, "Out of memory");
        return SLIMLO_ERROR_OUT_OF_MEMORY;
    }

    ifs.read(reinterpret_cast<char*>(buf), size);
    unlink(tmp_output_path.c_str());

    *output_data = buf;
    *output_size = size;
    handle->last_error.clear();
    return SLIMLO_OK;
}

SLIMLO_API void slimlo_free_buffer(uint8_t* buffer) {
    free(buffer);
}

SLIMLO_API const char* slimlo_get_error_message(SlimLOHandle handle) {
    if (handle) {
        return handle->last_error.c_str();
    }
    return g_init_error.c_str();
}

SLIMLO_API const char* slimlo_version(void) {
    static std::string version_str =
        std::string("SlimLO ") + SLIMLO_VERSION +
        " (LibreOffice " + LO_VERSION_STR + ")";
    return version_str.c_str();
}
