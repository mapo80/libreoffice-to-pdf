/*
 * slimlo_worker.c — Out-of-process worker for SlimLO PDF conversion.
 *
 * This executable is spawned by the .NET SDK's WorkerProcess class.
 * It reads length-prefixed JSON commands from stdin, performs PDF
 * conversions via the slimlo C API, captures stderr diagnostics,
 * and writes length-prefixed JSON responses to stdout.
 *
 * Protocol:
 *   Each message is framed as: [4-byte LE uint32 length][UTF-8 JSON]
 *
 * Lifecycle:
 *   1. Read "init" message → set SAL_FONTPATH → call slimlo_init()
 *   2. Loop: read "convert" → convert → capture stderr → write result
 *   3. On "quit" or stdin EOF → slimlo_destroy() → exit
 */

#include "slimlo.h"
#include "cjson/cJSON.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifdef _WIN32
  #include <io.h>
  #include <fcntl.h>
  #include <windows.h>
  /* MSVC does not define ssize_t (POSIX type) */
  #include <BaseTsd.h>
  typedef SSIZE_T ssize_t;
  #define PIPE_READ  _read
  #define PIPE_WRITE _write
  #define DUP        _dup
  #define DUP2       _dup2
  #define FILENO     _fileno
  #define PIPE(fds)  _pipe(fds, 65536, _O_BINARY)
  #define PATH_SEP   ";"
#else
  #include <unistd.h>
  #include <fcntl.h>
  #include <errno.h>
  #define PIPE_READ  read
  #define PIPE_WRITE write
  #define DUP        dup
  #define DUP2       dup2
  #define FILENO     fileno
  #define PIPE(fds)  pipe(fds)
  #define PATH_SEP   ":"
#endif

#ifdef __APPLE__
  #include <dirent.h>
  #include <CoreFoundation/CoreFoundation.h>
  #include <CoreText/CoreText.h>
#endif

/* Maximum stderr capture buffer: 256 KB per conversion */
#define STDERR_BUF_SIZE (256 * 1024)

/* Maximum message size: 256 MB (documents can be large for buffer conversions) */
#define MAX_MSG_SIZE (256 * 1024 * 1024)

/* --------------------------------------------------------------------------
 * Binary I/O helpers
 * -------------------------------------------------------------------------- */

static int set_binary_mode(FILE* f) {
#ifdef _WIN32
    return _setmode(FILENO(f), _O_BINARY) != -1;
#else
    (void)f;
    return 1;
#endif
}

/* Read exactly n bytes from file descriptor. Returns 0 on success, -1 on error/EOF. */
static int read_exact(int fd, void* buf, size_t n) {
    char* p = (char*)buf;
    size_t remaining = n;
    while (remaining > 0) {
        ssize_t r = PIPE_READ(fd, p, (unsigned int)remaining);
        if (r <= 0) return -1;
        p += r;
        remaining -= (size_t)r;
    }
    return 0;
}

/* Write exactly n bytes to file descriptor. Returns 0 on success, -1 on error. */
static int write_exact(int fd, const void* buf, size_t n) {
    const char* p = (const char*)buf;
    size_t remaining = n;
    while (remaining > 0) {
        ssize_t w = PIPE_WRITE(fd, p, (unsigned int)remaining);
        if (w <= 0) return -1;
        p += w;
        remaining -= (size_t)w;
    }
    return 0;
}

/* --------------------------------------------------------------------------
 * Message framing: [4-byte LE uint32 length][payload]
 * -------------------------------------------------------------------------- */

static int stdin_fd;
static int stdout_fd;

/* Read a length-prefixed message from stdin. Caller must free() the returned buffer.
 * Returns NULL on EOF or error. Sets *out_len to the message length. */
static char* read_message(size_t* out_len) {
    uint32_t len;
    if (read_exact(stdin_fd, &len, 4) != 0)
        return NULL;

    if (len > MAX_MSG_SIZE)
        return NULL;

    char* buf = (char*)malloc(len + 1);
    if (!buf) return NULL;

    if (read_exact(stdin_fd, buf, len) != 0) {
        free(buf);
        return NULL;
    }
    buf[len] = '\0';
    *out_len = len;
    return buf;
}

/* Write a length-prefixed message to stdout. Returns 0 on success. */
static int write_message(const char* data, size_t len) {
    uint32_t wire_len = (uint32_t)len;
    if (write_exact(stdout_fd, &wire_len, 4) != 0)
        return -1;
    if (write_exact(stdout_fd, data, len) != 0)
        return -1;
    return 0;
}

/* Send a JSON object as a message. Frees the cJSON object. */
static int send_json(cJSON* json) {
    char* str = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);
    if (!str) return -1;
    int rc = write_message(str, strlen(str));
    free(str);
    return rc;
}

/* --------------------------------------------------------------------------
 * Stderr capture
 * -------------------------------------------------------------------------- */

static int stderr_pipe[2] = {-1, -1};
static int saved_stderr = -1;
static char stderr_buf[STDERR_BUF_SIZE];

static void stderr_capture_start(void) {
    if (PIPE(stderr_pipe) != 0) return;
    saved_stderr = DUP(2);
    DUP2(stderr_pipe[1], 2);

    /* Make the read end non-blocking */
#ifndef _WIN32
    int flags = fcntl(stderr_pipe[0], F_GETFL, 0);
    if (flags >= 0)
        fcntl(stderr_pipe[0], F_SETFL, flags | O_NONBLOCK);
#endif
}

static void stderr_capture_stop(void) {
    if (saved_stderr >= 0) {
        fflush(stderr);
        DUP2(saved_stderr, 2);
#ifdef _WIN32
        _close(saved_stderr);
#else
        close(saved_stderr);
#endif
        saved_stderr = -1;
    }
    if (stderr_pipe[1] >= 0) {
#ifdef _WIN32
        _close(stderr_pipe[1]);
#else
        close(stderr_pipe[1]);
#endif
        stderr_pipe[1] = -1;
    }
}

/* Read captured stderr into buffer. Returns the number of bytes read. */
static size_t stderr_capture_read(void) {
    if (stderr_pipe[0] < 0) return 0;

    fflush(stderr);

    /* Close write end first so read can see EOF */
    if (stderr_pipe[1] >= 0) {
        DUP2(saved_stderr, 2);  /* restore stderr before closing write end */
#ifdef _WIN32
        _close(stderr_pipe[1]);
#else
        close(stderr_pipe[1]);
#endif
        stderr_pipe[1] = -1;
    }

    size_t total = 0;
    while (total < STDERR_BUF_SIZE - 1) {
        ssize_t r = PIPE_READ(stderr_pipe[0], stderr_buf + total,
                              (unsigned int)(STDERR_BUF_SIZE - 1 - total));
        if (r <= 0) break;
        total += (size_t)r;
    }
    stderr_buf[total] = '\0';

#ifdef _WIN32
    _close(stderr_pipe[0]);
#else
    close(stderr_pipe[0]);
#endif
    stderr_pipe[0] = -1;

    if (saved_stderr >= 0) {
#ifdef _WIN32
        _close(saved_stderr);
#else
        close(saved_stderr);
#endif
        saved_stderr = -1;
    }

    return total;
}

/* --------------------------------------------------------------------------
 * Diagnostic parsing from stderr lines
 * -------------------------------------------------------------------------- */

static cJSON* parse_diagnostics(const char* stderr_text) {
    cJSON* arr = cJSON_CreateArray();
    if (!stderr_text || !*stderr_text) return arr;

    const char* line = stderr_text;
    while (*line) {
        const char* eol = strchr(line, '\n');
        size_t line_len = eol ? (size_t)(eol - line) : strlen(line);

        /* Skip empty lines */
        if (line_len > 0) {
            /* Check for font warnings:
             * Pattern: warn:fonts:N:... or warn:vcl.fonts:N:... */
            int is_font = 0;
            int is_warn = 0;

            if (strstr(line, "warn:") && line_len > 5) {
                is_warn = 1;
                if (strstr(line, ":fonts:") || strstr(line, ":vcl.fonts:"))
                    is_font = 1;
            }

            if (is_warn) {
                cJSON* diag = cJSON_CreateObject();
                cJSON_AddStringToObject(diag, "severity", "warning");
                cJSON_AddStringToObject(diag, "category", is_font ? "font" : "general");

                /* Extract font name from patterns like:
                 * Could not select font "FontName"
                 * "FontName" was substituted with "OtherFont" */
                char* font_name = NULL;
                char* sub_font = NULL;

                if (is_font) {
                    const char* quote1 = NULL;
                    /* Look for "Could not select font" pattern */
                    const char* p = strstr(line, "Could not select font");
                    if (!p) p = strstr(line, "Could not find font");
                    if (!p) p = strstr(line, "not available");
                    if (p) {
                        quote1 = strchr(p, '"');
                    } else {
                        /* Generic: find first quoted string after the warn: prefix */
                        const char* after_warn = strstr(line, ":fonts:");
                        if (after_warn) quote1 = strchr(after_warn + 7, '"');
                    }

                    if (quote1) {
                        const char* quote2 = strchr(quote1 + 1, '"');
                        if (quote2 && quote2 > quote1 + 1) {
                            size_t name_len = (size_t)(quote2 - quote1 - 1);
                            font_name = (char*)malloc(name_len + 1);
                            if (font_name) {
                                memcpy(font_name, quote1 + 1, name_len);
                                font_name[name_len] = '\0';
                            }
                        }

                        /* Look for substitution: "OtherFont" after "substitut" */
                        if (quote2) {
                            const char* sub = strstr(quote2, "substitut");
                            if (!sub) sub = strstr(quote2, "replaced");
                            if (!sub) sub = strstr(quote2, "using");
                            if (sub) {
                                const char* sq1 = strchr(sub, '"');
                                if (sq1) {
                                    const char* sq2 = strchr(sq1 + 1, '"');
                                    if (sq2 && sq2 > sq1 + 1) {
                                        size_t slen = (size_t)(sq2 - sq1 - 1);
                                        sub_font = (char*)malloc(slen + 1);
                                        if (sub_font) {
                                            memcpy(sub_font, sq1 + 1, slen);
                                            sub_font[slen] = '\0';
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                /* Build message from the line (strip the warn:...: prefix) */
                char msg_buf[1024];
                const char* msg_start = line;
                /* Skip "warn:category:N:" prefix to get the actual message */
                int colon_count = 0;
                for (const char* c = line; c < line + line_len && colon_count < 3; c++) {
                    if (*c == ':') {
                        colon_count++;
                        if (colon_count == 3)
                            msg_start = c + 1;
                    }
                }
                /* Skip leading whitespace */
                while (msg_start < line + line_len && *msg_start == ' ')
                    msg_start++;

                size_t msg_len = line_len - (size_t)(msg_start - line);
                if (msg_len >= sizeof(msg_buf)) msg_len = sizeof(msg_buf) - 1;
                memcpy(msg_buf, msg_start, msg_len);
                msg_buf[msg_len] = '\0';

                cJSON_AddStringToObject(diag, "message", msg_buf);

                if (font_name) {
                    cJSON_AddStringToObject(diag, "font", font_name);
                    free(font_name);
                }
                if (sub_font) {
                    cJSON_AddStringToObject(diag, "substituted_with", sub_font);
                    free(sub_font);
                }

                cJSON_AddItemToArray(arr, diag);
            }
        }

        if (!eol) break;
        line = eol + 1;
    }

    return arr;
}

/* --------------------------------------------------------------------------
 * macOS CoreText font registration
 *
 * On macOS, LibreOffice's VCL uses CoreText for font enumeration, which
 * ignores SAL_FONTPATH. We register custom fonts at the process level via
 * CTFontManagerRegisterFontsForURL so CoreText (and thus LO) can find them.
 * -------------------------------------------------------------------------- */

#ifdef __APPLE__
static int has_font_extension(const char* name) {
    size_t len = strlen(name);
    if (len < 4) return 0;
    const char* ext = name + len - 4;
    if (strcasecmp(ext, ".ttf") == 0) return 1;
    if (strcasecmp(ext, ".otf") == 0) return 1;
    if (strcasecmp(ext, ".ttc") == 0) return 1;
    return 0;
}

static void register_fonts_coretext(const char* dir_path) {
    DIR* d = opendir(dir_path);
    if (!d) return;

    struct dirent* entry;
    while ((entry = readdir(d)) != NULL) {
        if (!has_font_extension(entry->d_name)) continue;

        /* Build full path */
        char full_path[4096];
        snprintf(full_path, sizeof(full_path), "%s/%s", dir_path, entry->d_name);

        CFStringRef path_str = CFStringCreateWithCString(
            kCFAllocatorDefault, full_path, kCFStringEncodingUTF8);
        if (!path_str) continue;

        CFURLRef url = CFURLCreateWithFileSystemPath(
            kCFAllocatorDefault, path_str, kCFURLPOSIXPathStyle, false);
        CFRelease(path_str);
        if (!url) continue;

        CFErrorRef error = NULL;
        CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, &error);
        if (error) CFRelease(error);
        CFRelease(url);
    }
    closedir(d);
}
#endif

/* --------------------------------------------------------------------------
 * Command handlers
 * -------------------------------------------------------------------------- */

static SlimLOHandle g_handle = NULL;

static int handle_init(cJSON* msg) {
    cJSON* rp = cJSON_GetObjectItem(msg, "resource_path");
    if (!rp || !cJSON_IsString(rp)) {
        cJSON* resp = cJSON_CreateObject();
        cJSON_AddStringToObject(resp, "type", "error");
        cJSON_AddStringToObject(resp, "message", "Missing resource_path in init message");
        return send_json(resp);
    }

    /* Set SAL_FONTPATH if font_paths provided */
    cJSON* fp = cJSON_GetObjectItem(msg, "font_paths");
    if (fp && cJSON_IsArray(fp) && cJSON_GetArraySize(fp) > 0) {
        /* Build colon/semicolon-separated path string */
        size_t total_len = 0;
        int count = cJSON_GetArraySize(fp);
        for (int i = 0; i < count; i++) {
            cJSON* item = cJSON_GetArrayItem(fp, i);
            if (cJSON_IsString(item))
                total_len += strlen(cJSON_GetStringValue(item)) + 1;
        }

        char* font_path = (char*)malloc(total_len + 1);
        if (font_path) {
            font_path[0] = '\0';
            for (int i = 0; i < count; i++) {
                cJSON* item = cJSON_GetArrayItem(fp, i);
                if (cJSON_IsString(item)) {
                    if (font_path[0] != '\0')
                        strcat(font_path, PATH_SEP);
                    strcat(font_path, cJSON_GetStringValue(item));
                }
            }
#ifdef _WIN32
            _putenv_s("SAL_FONTPATH", font_path);
#else
            setenv("SAL_FONTPATH", font_path, 1);
#endif
            free(font_path);
        }

#ifdef __APPLE__
        /* On macOS, SAL_FONTPATH alone is not enough — the osx VCL backend
         * uses CoreText for font enumeration, which ignores SAL_FONTPATH.
         * Register each font file with CoreText at the process level. */
        for (int i = 0; i < count; i++) {
            cJSON* item = cJSON_GetArrayItem(fp, i);
            if (cJSON_IsString(item))
                register_fonts_coretext(cJSON_GetStringValue(item));
        }
#endif
    }

    /* Initialize SlimLO */
    g_handle = slimlo_init(rp->valuestring);

    cJSON* resp = cJSON_CreateObject();
    if (g_handle) {
        cJSON_AddStringToObject(resp, "type", "ready");
        const char* ver = slimlo_version();
        cJSON_AddStringToObject(resp, "version", ver ? ver : "unknown");
    } else {
        cJSON_AddStringToObject(resp, "type", "error");
        const char* err = slimlo_get_error_message(NULL);
        cJSON_AddStringToObject(resp, "message", err ? err : "Failed to initialize");
    }
    return send_json(resp);
}

static int handle_convert(cJSON* msg) {
    cJSON* id_json = cJSON_GetObjectItem(msg, "id");
    int id = id_json && cJSON_IsNumber(id_json) ? id_json->valueint : 0;

    cJSON* input = cJSON_GetObjectItem(msg, "input");
    cJSON* output = cJSON_GetObjectItem(msg, "output");
    cJSON* format_json = cJSON_GetObjectItem(msg, "format");

    if (!input || !cJSON_IsString(input) || !output || !cJSON_IsString(output)) {
        cJSON* resp = cJSON_CreateObject();
        cJSON_AddStringToObject(resp, "type", "result");
        cJSON_AddNumberToObject(resp, "id", id);
        cJSON_AddBoolToObject(resp, "success", 0);
        cJSON_AddNumberToObject(resp, "error_code", SLIMLO_ERROR_INVALID_ARGUMENT);
        cJSON_AddStringToObject(resp, "error_message", "Missing input or output path");
        cJSON_AddItemToObject(resp, "diagnostics", cJSON_CreateArray());
        return send_json(resp);
    }

    int format = format_json && cJSON_IsNumber(format_json) ? format_json->valueint : 0;

    /* Parse options */
    SlimLOPdfOptions opts;
    memset(&opts, 0, sizeof(opts));
    const SlimLOPdfOptions* opts_ptr = NULL;

    cJSON* options = cJSON_GetObjectItem(msg, "options");
    if (options && cJSON_IsObject(options)) {
        cJSON* pv = cJSON_GetObjectItem(options, "pdf_version");
        if (pv && cJSON_IsNumber(pv)) opts.pdf_version = (SlimLOPdfVersion)pv->valueint;

        cJSON* jq = cJSON_GetObjectItem(options, "jpeg_quality");
        if (jq && cJSON_IsNumber(jq)) opts.jpeg_quality = jq->valueint;

        cJSON* dpi = cJSON_GetObjectItem(options, "dpi");
        if (dpi && cJSON_IsNumber(dpi)) opts.dpi = dpi->valueint;

        cJSON* tp = cJSON_GetObjectItem(options, "tagged_pdf");
        if (tp) opts.tagged_pdf = cJSON_IsTrue(tp) ? 1 : 0;

        cJSON* pr = cJSON_GetObjectItem(options, "page_range");
        if (pr && cJSON_IsString(pr)) opts.page_range = pr->valuestring;

        cJSON* pw = cJSON_GetObjectItem(options, "password");
        if (pw && cJSON_IsString(pw)) opts.password = pw->valuestring;

        opts_ptr = &opts;
    }

    /* Start stderr capture */
    stderr_capture_start();

    /* Perform conversion */
    SlimLOError err = slimlo_convert_file(
        g_handle,
        input->valuestring,
        output->valuestring,
        (SlimLOFormat)format,
        opts_ptr
    );

    /* Capture stderr and restore */
    stderr_capture_stop();
    size_t stderr_len = stderr_capture_read();

    /* Parse diagnostics from captured stderr */
    cJSON* diagnostics = parse_diagnostics(stderr_len > 0 ? stderr_buf : NULL);

    /* Build response */
    cJSON* resp = cJSON_CreateObject();
    cJSON_AddStringToObject(resp, "type", "result");
    cJSON_AddNumberToObject(resp, "id", id);

    if (err == SLIMLO_OK) {
        cJSON_AddBoolToObject(resp, "success", 1);
        cJSON_AddNullToObject(resp, "error_code");
        cJSON_AddNullToObject(resp, "error_message");
    } else {
        cJSON_AddBoolToObject(resp, "success", 0);
        cJSON_AddNumberToObject(resp, "error_code", (int)err);
        const char* errmsg = slimlo_get_error_message(g_handle);
        cJSON_AddStringToObject(resp, "error_message", errmsg ? errmsg : "Conversion failed");
    }

    cJSON_AddItemToObject(resp, "diagnostics", diagnostics);

    return send_json(resp);
}

static int handle_convert_buffer(cJSON* msg) {
    cJSON* id_json = cJSON_GetObjectItem(msg, "id");
    int id = id_json && cJSON_IsNumber(id_json) ? id_json->valueint : 0;

    cJSON* format_json = cJSON_GetObjectItem(msg, "format");
    int format = format_json && cJSON_IsNumber(format_json) ? format_json->valueint : 0;

    cJSON* data_size_json = cJSON_GetObjectItem(msg, "data_size");
    if (!data_size_json || !cJSON_IsNumber(data_size_json)) {
        cJSON* resp = cJSON_CreateObject();
        cJSON_AddStringToObject(resp, "type", "buffer_result");
        cJSON_AddNumberToObject(resp, "id", id);
        cJSON_AddBoolToObject(resp, "success", 0);
        cJSON_AddNumberToObject(resp, "error_code", SLIMLO_ERROR_INVALID_ARGUMENT);
        cJSON_AddStringToObject(resp, "error_message", "Missing data_size in convert_buffer");
        cJSON_AddItemToObject(resp, "diagnostics", cJSON_CreateArray());
        return send_json(resp);
    }

    size_t data_size = (size_t)cJSON_GetNumberValue(data_size_json);

    /* Parse options (same as handle_convert) */
    SlimLOPdfOptions opts;
    memset(&opts, 0, sizeof(opts));
    const SlimLOPdfOptions* opts_ptr = NULL;

    cJSON* options = cJSON_GetObjectItem(msg, "options");
    if (options && cJSON_IsObject(options)) {
        cJSON* pv = cJSON_GetObjectItem(options, "pdf_version");
        if (pv && cJSON_IsNumber(pv)) opts.pdf_version = (SlimLOPdfVersion)pv->valueint;

        cJSON* jq = cJSON_GetObjectItem(options, "jpeg_quality");
        if (jq && cJSON_IsNumber(jq)) opts.jpeg_quality = jq->valueint;

        cJSON* dpi = cJSON_GetObjectItem(options, "dpi");
        if (dpi && cJSON_IsNumber(dpi)) opts.dpi = dpi->valueint;

        cJSON* tp = cJSON_GetObjectItem(options, "tagged_pdf");
        if (tp) opts.tagged_pdf = cJSON_IsTrue(tp) ? 1 : 0;

        cJSON* pr = cJSON_GetObjectItem(options, "page_range");
        if (pr && cJSON_IsString(pr)) opts.page_range = pr->valuestring;

        cJSON* pw = cJSON_GetObjectItem(options, "password");
        if (pw && cJSON_IsString(pw)) opts.password = pw->valuestring;

        opts_ptr = &opts;
    }

    /* Read the binary document frame (second length-prefixed frame) */
    size_t frame_len = 0;
    char* doc_buf = read_message(&frame_len);
    if (!doc_buf) {
        cJSON* resp = cJSON_CreateObject();
        cJSON_AddStringToObject(resp, "type", "buffer_result");
        cJSON_AddNumberToObject(resp, "id", id);
        cJSON_AddBoolToObject(resp, "success", 0);
        cJSON_AddNumberToObject(resp, "error_code", SLIMLO_ERROR_INVALID_ARGUMENT);
        cJSON_AddStringToObject(resp, "error_message", "Failed to read document data frame");
        cJSON_AddItemToObject(resp, "diagnostics", cJSON_CreateArray());
        return send_json(resp);
    }

    if (frame_len != data_size) {
        free(doc_buf);
        cJSON* resp = cJSON_CreateObject();
        cJSON_AddStringToObject(resp, "type", "buffer_result");
        cJSON_AddNumberToObject(resp, "id", id);
        cJSON_AddBoolToObject(resp, "success", 0);
        cJSON_AddNumberToObject(resp, "error_code", SLIMLO_ERROR_INVALID_ARGUMENT);
        cJSON_AddStringToObject(resp, "error_message", "Data frame size mismatch");
        cJSON_AddItemToObject(resp, "diagnostics", cJSON_CreateArray());
        return send_json(resp);
    }

    /* Start stderr capture */
    stderr_capture_start();

    /* Perform buffer conversion */
    uint8_t* pdf_buf = NULL;
    size_t pdf_size = 0;
    SlimLOError err = slimlo_convert_buffer(
        g_handle,
        (const uint8_t*)doc_buf, frame_len,
        (SlimLOFormat)format,
        opts_ptr,
        &pdf_buf, &pdf_size
    );

    free(doc_buf);

    /* Capture stderr and restore */
    stderr_capture_stop();
    size_t stderr_len = stderr_capture_read();

    /* Parse diagnostics from captured stderr */
    cJSON* diagnostics = parse_diagnostics(stderr_len > 0 ? stderr_buf : NULL);

    /* Build response */
    cJSON* resp = cJSON_CreateObject();
    cJSON_AddStringToObject(resp, "type", "buffer_result");
    cJSON_AddNumberToObject(resp, "id", id);

    if (err == SLIMLO_OK && pdf_buf) {
        cJSON_AddBoolToObject(resp, "success", 1);
        cJSON_AddNumberToObject(resp, "data_size", (double)pdf_size);
        cJSON_AddNullToObject(resp, "error_code");
        cJSON_AddNullToObject(resp, "error_message");
    } else {
        cJSON_AddBoolToObject(resp, "success", 0);
        cJSON_AddNumberToObject(resp, "error_code", (int)err);
        const char* errmsg = slimlo_get_error_message(g_handle);
        cJSON_AddStringToObject(resp, "error_message", errmsg ? errmsg : "Buffer conversion failed");
    }

    cJSON_AddItemToObject(resp, "diagnostics", diagnostics);

    /* Send JSON response frame */
    int rc = send_json(resp);
    if (rc != 0) {
        slimlo_free_buffer(pdf_buf);
        return rc;
    }

    /* Send binary PDF frame (only on success) */
    if (err == SLIMLO_OK && pdf_buf) {
        rc = write_message((const char*)pdf_buf, pdf_size);
        slimlo_free_buffer(pdf_buf);
        return rc;
    }

    return 0;
}

/* --------------------------------------------------------------------------
 * Main loop
 * -------------------------------------------------------------------------- */

int main(void) {
    /* Set stdin/stdout to binary mode for length-prefixed protocol */
    set_binary_mode(stdin);
    set_binary_mode(stdout);

    stdin_fd = FILENO(stdin);
    stdout_fd = FILENO(stdout);

    /* Suppress LibreOffice GUI dialogs in headless mode.
     * On macOS, the SVP plugin is not available — the Quartz (osx) backend
     * is the only VCL plugin, so we must NOT set SAL_USE_VCLPLUGIN.
     * On Linux, use the SVP (headless) backend. */
#ifndef __APPLE__
  #ifdef _WIN32
    _putenv_s("SAL_USE_VCLPLUGIN", "svp");
  #else
    setenv("SAL_USE_VCLPLUGIN", "svp", 0);  /* Don't override if already set */
  #endif
#endif

    /* On macOS, LOKit must use "unipoll" mode to run VCL initialization on
     * the calling thread. Without this, LOKit spawns a background thread for
     * VCL init, but the Quartz backend creates NSWindow objects which MUST
     * be on the main thread — causing an NSInternalInconsistencyException. */
#ifdef __APPLE__
    setenv("SAL_LOK_OPTIONS", "unipoll", 0);
#endif

    /* Enable font-related logging so stderr capture can detect warnings.
     * Don't override if already set by the parent process. */
#ifdef _WIN32
    if (!getenv("SAL_LOG"))
        _putenv_s("SAL_LOG", "+WARN.vcl.fonts+INFO.vcl+WARN.vcl");
#else
    setenv("SAL_LOG", "+WARN.vcl.fonts+INFO.vcl+WARN.vcl", 0);
#endif

    /* Main message loop */
    for (;;) {
        size_t msg_len = 0;
        char* raw = read_message(&msg_len);
        if (!raw) break;  /* EOF or error — parent closed pipe */

        cJSON* msg = cJSON_Parse(raw);
        free(raw);

        if (!msg) {
            /* Invalid JSON — send error and continue */
            cJSON* resp = cJSON_CreateObject();
            cJSON_AddStringToObject(resp, "type", "error");
            cJSON_AddStringToObject(resp, "message", "Invalid JSON message");
            send_json(resp);
            continue;
        }

        cJSON* type = cJSON_GetObjectItem(msg, "type");
        if (!type || !cJSON_IsString(type)) {
            cJSON_Delete(msg);
            continue;
        }

        const char* type_str = type->valuestring;

        if (strcmp(type_str, "init") == 0) {
            int rc = handle_init(msg);
            cJSON_Delete(msg);
            if (rc != 0) break;
            /* If init failed, we can still accept quit but not convert */
        } else if (strcmp(type_str, "convert") == 0) {
            if (!g_handle) {
                cJSON* resp = cJSON_CreateObject();
                cJSON_AddStringToObject(resp, "type", "result");
                cJSON_AddBoolToObject(resp, "success", 0);
                cJSON_AddNumberToObject(resp, "error_code", SLIMLO_ERROR_NOT_INIT);
                cJSON_AddStringToObject(resp, "error_message", "Worker not initialized");
                cJSON_AddItemToObject(resp, "diagnostics", cJSON_CreateArray());
                send_json(resp);
                cJSON_Delete(msg);
                continue;
            }
            int rc = handle_convert(msg);
            cJSON_Delete(msg);
            if (rc != 0) break;
        } else if (strcmp(type_str, "convert_buffer") == 0) {
            if (!g_handle) {
                cJSON* resp = cJSON_CreateObject();
                cJSON_AddStringToObject(resp, "type", "buffer_result");
                cJSON_AddBoolToObject(resp, "success", 0);
                cJSON_AddNumberToObject(resp, "error_code", SLIMLO_ERROR_NOT_INIT);
                cJSON_AddStringToObject(resp, "error_message", "Worker not initialized");
                cJSON_AddItemToObject(resp, "diagnostics", cJSON_CreateArray());
                send_json(resp);
                cJSON_Delete(msg);
                continue;
            }
            int rc = handle_convert_buffer(msg);
            cJSON_Delete(msg);
            if (rc != 0) break;
        } else if (strcmp(type_str, "quit") == 0) {
            cJSON_Delete(msg);
            break;
        } else {
            cJSON_Delete(msg);
        }
    }

    /* Cleanup */
    if (g_handle) {
        slimlo_destroy(g_handle);
        g_handle = NULL;
    }

    return 0;
}
