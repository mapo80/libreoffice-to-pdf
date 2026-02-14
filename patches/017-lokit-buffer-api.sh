#!/bin/bash
# 017-lokit-buffer-api.sh
#
# Add buffer-based document load/save to the LibreOfficeKit C API.
# Uses LO's existing private:stream + SvMemoryStream infrastructure
# for cross-platform zero-disk-IO buffer conversion.
#
# Patches three files:
#   1. include/LibreOfficeKit/LibreOfficeKit.h  — extend vtable structs
#   2. include/LibreOfficeKit/LibreOfficeKit.hxx — C++ wrapper methods
#   3. desktop/source/lib/init.cxx              — implement functions + wire vtable
#
# Idempotent: safe to re-run.

set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

LOK_H="$LO_SRC/include/LibreOfficeKit/LibreOfficeKit.h"
LOK_HXX="$LO_SRC/include/LibreOfficeKit/LibreOfficeKit.hxx"
INIT_CXX="$LO_SRC/desktop/source/lib/init.cxx"

for f in "$LOK_H" "$LOK_HXX" "$INIT_CXX"; do
    if [ ! -f "$f" ]; then
        echo "    ERROR: $f not found"
        exit 1
    fi
done

CHANGED=0

# ==========================================================================
# Reset patched files to vanilla state (git checkout) so re-runs after
# patch logic changes (e.g. moving saveToBuffer to a different location)
# don't get tricked by stale idempotency guards.
# Only resets if git is available and the files are tracked.
# ==========================================================================
if git -C "$LO_SRC" rev-parse --git-dir >/dev/null 2>&1; then
    # Only reset headers — init.cxx is modified by other patches (011 etc.)
    git -C "$LO_SRC" checkout -- \
        include/LibreOfficeKit/LibreOfficeKit.h \
        include/LibreOfficeKit/LibreOfficeKit.hxx 2>/dev/null || true
fi

# ==========================================================================
# Part 1: LibreOfficeKit.h — add function pointers to vtable structs
# ==========================================================================

# 1a. Add documentLoadFromBuffer to _LibreOfficeKitClass
if ! grep -q 'documentLoadFromBuffer' "$LOK_H"; then
    echo "    017: Adding documentLoadFromBuffer to _LibreOfficeKitClass..."
    # Note: registerAnyInputCallback declaration spans TWO lines in the .h file:
    #   void (*registerAnyInputCallback)(LibreOfficeKit* pThis,
    #                                    LibreOfficeKitAnyInputCallback pCallback, void* pData);
    # So we match the function name and read through to the semicolon.
    awk '
    /registerAnyInputCallback/ && !added_office {
        print
        while ($0 !~ /;[[:space:]]*$/) {
            getline
            print
        }
        print ""
        print "    /// @see lok::Office::documentLoadFromBuffer"
        print "    /// SlimLO: load document from in-memory buffer via private:stream"
        print "    LibreOfficeKitDocument* (*documentLoadFromBuffer)("
        print "        LibreOfficeKit* pThis,"
        print "        const unsigned char* pBuffer, unsigned long nSize,"
        print "        const char* pFormat, const char* pOptions);"
        added_office = 1
        next
    }
    { print }
    ' "$LOK_H" > "$LOK_H.tmp" && mv "$LOK_H.tmp" "$LOK_H"
    CHANGED=1
else
    echo "    017: documentLoadFromBuffer already in LibreOfficeKit.h"
fi

# 1b. Add saveToBuffer to _LibreOfficeKitDocumentClass
# IMPORTANT: Insert after saveAs which is OUTSIDE #ifdef LOK_USE_UNSTABLE_API.
# setViewOption is inside #ifdef — inserting there makes saveToBuffer invisible
# to code that doesn't define LOK_USE_UNSTABLE_API.
if ! grep -q 'saveToBuffer' "$LOK_H"; then
    echo "    017: Adding saveToBuffer to _LibreOfficeKitDocumentClass..."
    awk '
    /int \(\*saveAs\)/ && !added_doc {
        print
        # saveAs spans multiple lines; read until semicolon
        while ($0 !~ /;[[:space:]]*$/) {
            getline
            print
        }
        print ""
        print "    /// @see lok::Document::saveToBuffer"
        print "    /// SlimLO: save document to in-memory buffer via private:stream"
        print "    int (*saveToBuffer)("
        print "        LibreOfficeKitDocument* pThis,"
        print "        unsigned char** ppBuffer, unsigned long* pSize,"
        print "        const char* pFormat, const char* pFilterOptions);"
        added_doc = 1
        next
    }
    { print }
    ' "$LOK_H" > "$LOK_H.tmp" && mv "$LOK_H.tmp" "$LOK_H"
    CHANGED=1
else
    echo "    017: saveToBuffer already in LibreOfficeKit.h"
fi

# ==========================================================================
# Part 2: LibreOfficeKit.hxx — add C++ wrapper methods
# ==========================================================================

# 2a. Add documentLoadFromBuffer to Office class
if ! grep -q 'documentLoadFromBuffer' "$LOK_HXX"; then
    echo "    017: Adding documentLoadFromBuffer to lok::Office..."
    awk '
    /registerAnyInputCallback.*pCallback.*pData\)/ && !added_office {
        # Print the current line and the next lines until we reach the closing brace
        print
        while ($0 !~ /^[[:space:]]*\}/) {
            getline
            print
        }
        print ""
        print "    /// Load document from in-memory buffer (SlimLO)"
        print "    inline Document* documentLoadFromBuffer("
        print "        const unsigned char* pBuffer, unsigned long nSize,"
        print "        const char* pFormat, const char* pOptions = nullptr)"
        print "    {"
        print "        LibreOfficeKitDocument* pDoc ="
        print "            mpThis->pClass->documentLoadFromBuffer(mpThis, pBuffer, nSize, pFormat, pOptions);"
        print "        if (pDoc == nullptr)"
        print "            return nullptr;"
        print "        return new Document(pDoc);"
        print "    }"
        added_office = 1
        next
    }
    { print }
    ' "$LOK_HXX" > "$LOK_HXX.tmp" && mv "$LOK_HXX.tmp" "$LOK_HXX"
    CHANGED=1
else
    echo "    017: documentLoadFromBuffer already in LibreOfficeKit.hxx Office"
fi

# 2b. Add saveToBuffer to Document class
# IMPORTANT: Insert after saveAs() which is OUTSIDE the #ifdef LOK_USE_UNSTABLE_API block.
# setViewOption is inside #ifdef LOK_USE_UNSTABLE_API — inserting there makes saveToBuffer
# invisible to code that doesn't define LOK_USE_UNSTABLE_API.
if ! grep -q 'saveToBuffer' "$LOK_HXX"; then
    echo "    017: Adding saveToBuffer to lok::Document..."
    awk '
    /bool saveAs\(.*pUrl.*pFormat/ && !added_doc {
        # Print the current line and the body lines until closing brace
        print
        while ($0 !~ /^[[:space:]]*\}/) {
            getline
            print
        }
        print ""
        print "    /// Save document to in-memory buffer (SlimLO)"
        print "    inline bool saveToBuffer("
        print "        unsigned char** ppBuffer, unsigned long* pSize,"
        print "        const char* pFormat, const char* pFilterOptions = nullptr)"
        print "    {"
        print "        return mpDoc->pClass->saveToBuffer(mpDoc, ppBuffer, pSize, pFormat, pFilterOptions) != 0;"
        print "    }"
        added_doc = 1
        next
    }
    { print }
    ' "$LOK_HXX" > "$LOK_HXX.tmp" && mv "$LOK_HXX.tmp" "$LOK_HXX"
    CHANGED=1
else
    echo "    017: saveToBuffer already in LibreOfficeKit.hxx Document"
fi

# ==========================================================================
# Part 3: init.cxx — implement functions + wire vtable
# ==========================================================================

# 3-pre. Add forward declarations alongside existing forward decls.
# init.cxx has forward declarations near the top (doc_saveAs at ~line 1124,
# lo_documentLoad at ~line 2684) that are referenced by vtable constructors
# before the function definitions appear. Our new functions need the same.
if ! grep -q 'doc_saveToBuffer' "$INIT_CXX"; then
    echo "    017: Adding forward declarations for buffer API functions..."

    # Forward decl for doc_saveToBuffer — after doc_saveAs forward decl
    awk '
    /^static int doc_saveAs[[:space:]]*\(/ && /;[[:space:]]*$/ && !added_fwd_doc {
        print
        print "static int doc_saveToBuffer(LibreOfficeKitDocument* pThis, unsigned char** ppBuffer, unsigned long* pSize, const char* pFormat, const char* pFilterOptions); // SlimLO"
        added_fwd_doc = 1
        next
    }
    { print }
    ' "$INIT_CXX" > "$INIT_CXX.tmp" && mv "$INIT_CXX.tmp" "$INIT_CXX"
fi

if ! grep -q 'lo_documentLoadFromBuffer' "$INIT_CXX"; then
    # Forward decl for lo_documentLoadFromBuffer — after lo_documentLoad forward decl
    # Note: the forward decl has extra spaces: "lo_documentLoad  (" (two spaces before paren)
    awk '
    /^static LibreOfficeKitDocument/ && /lo_documentLoad[[:space:]]*\(/ && /;[[:space:]]*$/ && !added_fwd_lo {
        print
        print "static LibreOfficeKitDocument* lo_documentLoadFromBuffer(LibreOfficeKit* pThis, const unsigned char* pBuffer, unsigned long nSize, const char* pFormat, const char* pOptions); // SlimLO"
        added_fwd_lo = 1
        next
    }
    { print }
    ' "$INIT_CXX" > "$INIT_CXX.tmp" && mv "$INIT_CXX.tmp" "$INIT_CXX"
fi

# 3a-cleanup: Remove old lo_documentLoadFromBuffer implementation if present.
# This allows the implementation to be re-inserted with corrections.
if grep -q '// SlimLO: Load document from in-memory buffer' "$INIT_CXX"; then
    echo "    017: Removing old lo_documentLoadFromBuffer for re-insertion..."
    awk '
    /^\/\/ SlimLO: Load document from in-memory buffer/ { skip = 1 }
    skip && /^}[[:space:]]*$/ { skip = 0; next }
    skip { next }
    { print }
    ' "$INIT_CXX" > "$INIT_CXX.tmp" && mv "$INIT_CXX.tmp" "$INIT_CXX"
fi

# 3a. Add lo_documentLoadFromBuffer implementation (before lo_documentLoad)
# Guard checks for the comment unique to the implementation (not the forward decl)
if ! grep -q '// SlimLO: Load document from in-memory buffer' "$INIT_CXX"; then
    echo "    017: Adding lo_documentLoadFromBuffer implementation..."

    # Find the line number of the lo_documentLoad DEFINITION (not forward decl).
    # The definition does NOT end with ';' — forward declarations do.
    # Use grep -n to find it, then head/tail to insert before it.
    LOAD_DEF_LINE=$(grep -n 'lo_documentLoad(' "$INIT_CXX" | grep -v 'FromBuffer\|LoadWithOptions\|;' | head -1 | cut -d: -f1)
    if [ -z "$LOAD_DEF_LINE" ]; then
        echo "    017: ERROR: Could not find lo_documentLoad definition in init.cxx"
        echo "    017: DEBUG: Lines containing lo_documentLoad:"
        grep -n 'lo_documentLoad' "$INIT_CXX" | head -20
        exit 1
    fi
    echo "    017: Found lo_documentLoad definition at line $LOAD_DEF_LINE"

    # Create the implementation as a temp file
    cat > "$INIT_CXX.impl_loadbuf" << 'IMPL_EOF'
// SlimLO: Load document from in-memory buffer via private:stream
static LibreOfficeKitDocument* lo_documentLoadFromBuffer(
    LibreOfficeKit* pThis,
    const unsigned char* pBuffer, unsigned long nSize,
    const char* pFormat, const char* pOptions)
{
    comphelper::ProfileZone aZone("lo_documentLoadFromBuffer");
    SolarMutexGuard aGuard;

    static int nDocumentIdCounter_buf = 0;
    LibLibreOffice_Impl* pLib = static_cast<LibLibreOffice_Impl*>(pThis);
    pLib->maLastExceptionMsg.clear();

    if (!pBuffer || nSize == 0)
    {
        pLib->maLastExceptionMsg = u"Buffer is null or empty"_ustr;
        return nullptr;
    }

    if (!xContext.is())
    {
        pLib->maLastExceptionMsg = u"ComponentContext is not available"_ustr;
        return nullptr;
    }

    uno::Reference<frame::XDesktop2> xComponentLoader = frame::Desktop::create(xContext);
    if (!xComponentLoader.is())
    {
        pLib->maLastExceptionMsg = u"ComponentLoader is not available"_ustr;
        return nullptr;
    }

    try
    {
        // Heap-allocate SvMemoryStream with a DATA COPY so it outlives this function.
        // The document's SfxMedium keeps a reference to the XInputStream and reads
        // from it during document destruction (SfxMedium::CreateTempFile in the
        // SfxObjectShell destructor). A stack-allocated stream would be destroyed
        // when this function returns, causing a use-after-free segfault.
        //
        // OSeekableInputStreamWrapper with bOwner=true takes ownership of the stream
        // and deletes it when the last UNO reference is released.
        // XSeekable is required — without it, loadComponentFromURL returns null.
        auto* pStream = new SvMemoryStream();
        pStream->WriteBytes(pBuffer, static_cast<std::size_t>(nSize));
        pStream->Seek(0);
        uno::Reference<io::XInputStream> xInput =
            new utl::OSeekableInputStreamWrapper(pStream, /*bOwner=*/true);

        // Map format string to FilterName
        OUString aFilterName;
        if (pFormat && pFormat[0] != 0)
        {
            OUString sFormat = OUString::createFromAscii(pFormat);
            if (sFormat.equalsIgnoreAsciiCase("docx"))
                aFilterName = u"MS Word 2007 XML"_ustr;
            else if (sFormat.equalsIgnoreAsciiCase("xlsx"))
                aFilterName = u"Calc MS Excel 2007 XML"_ustr;
            else if (sFormat.equalsIgnoreAsciiCase("pptx"))
                aFilterName = u"Impress MS PowerPoint 2007 XML"_ustr;
            else if (sFormat.equalsIgnoreAsciiCase("doc"))
                aFilterName = u"MS Word 97"_ustr;
            else if (sFormat.equalsIgnoreAsciiCase("xls"))
                aFilterName = u"MS Excel 97"_ustr;
            else if (sFormat.equalsIgnoreAsciiCase("ppt"))
                aFilterName = u"MS PowerPoint 97"_ustr;
            else if (sFormat.equalsIgnoreAsciiCase("odt"))
                aFilterName = u"writer8"_ustr;
            else if (sFormat.equalsIgnoreAsciiCase("ods"))
                aFilterName = u"calc8"_ustr;
            else if (sFormat.equalsIgnoreAsciiCase("odp"))
                aFilterName = u"impress8"_ustr;
        }

        // Build load arguments — same pattern as lo_documentLoadWithOptions
        // Use comphelper::makePropertyValue + Sequence (not MediaDescriptor)
        rtl::Reference<LOKInteractionHandler> const pInteraction(
            new LOKInteractionHandler("load"_ostr, pLib));

        std::vector<css::beans::PropertyValue> aProps{
            comphelper::makePropertyValue(u"InputStream"_ustr, xInput),
            comphelper::makePropertyValue(u"InteractionHandler"_ustr,
                uno::Reference<task::XInteractionHandler2>(pInteraction)),
            comphelper::makePropertyValue(u"MacroExecutionMode"_ustr,
                static_cast<sal_Int16>(css::document::MacroExecMode::NEVER_EXECUTE)),
            comphelper::makePropertyValue(u"AsTemplate"_ustr, false),
            comphelper::makePropertyValue(u"Silent"_ustr, true)
        };
        if (!aFilterName.isEmpty())
            aProps.push_back(comphelper::makePropertyValue(u"FilterName"_ustr, aFilterName));

        OutputDevice::StartTrackingFontMappingUse();

        const int nThisDocumentId = nDocumentIdCounter_buf++;
        SfxViewShell::SetCurrentDocId(ViewShellDocId(nThisDocumentId));
        uno::Reference<lang::XComponent> xComponent =
            xComponentLoader->loadComponentFromURL(
                u"private:stream"_ustr, u"_blank"_ustr, 0,
                comphelper::containerToSequence(aProps));

        auto aFontMappingUseData = OutputDevice::FinishTrackingFontMappingUse();
        (void)aFontMappingUseData;

        if (!xComponent.is())
        {
            pLib->maLastExceptionMsg = u"loadComponentFromURL returned an empty reference"_ustr;
            return nullptr;
        }

        return new LibLODocument_Impl(xComponent, nThisDocumentId);
    }
    catch (const uno::Exception& exception)
    {
        pLib->maLastExceptionMsg = "exception: " + exception.Message;
    }
    return nullptr;
}

IMPL_EOF

    # Insert the implementation before the lo_documentLoad definition
    head -n $((LOAD_DEF_LINE - 1)) "$INIT_CXX" > "$INIT_CXX.tmp"
    cat "$INIT_CXX.impl_loadbuf" >> "$INIT_CXX.tmp"
    tail -n +$LOAD_DEF_LINE "$INIT_CXX" >> "$INIT_CXX.tmp"
    mv "$INIT_CXX.tmp" "$INIT_CXX"
    rm -f "$INIT_CXX.impl_loadbuf"
    CHANGED=1
else
    echo "    017: lo_documentLoadFromBuffer already in init.cxx"
fi

# 3b. Add doc_saveToBuffer implementation (before doc_saveAs definition)
# Guard checks for the comment unique to the implementation (not the forward decl)
if ! grep -q '// SlimLO: Save document to in-memory buffer' "$INIT_CXX"; then
    echo "    017: Adding doc_saveToBuffer implementation..."

    # Find line number of doc_saveAs DEFINITION (not forward decl — no trailing ;)
    SAVEAS_DEF_LINE=$(grep -n 'doc_saveAs(' "$INIT_CXX" | grep -v 'doc_saveToBuffer\|;' | head -1 | cut -d: -f1)
    if [ -z "$SAVEAS_DEF_LINE" ]; then
        echo "    017: ERROR: Could not find doc_saveAs definition in init.cxx"
        echo "    017: DEBUG: Lines containing doc_saveAs:"
        grep -n 'doc_saveAs' "$INIT_CXX" | head -20
        exit 1
    fi
    echo "    017: Found doc_saveAs definition at line $SAVEAS_DEF_LINE"

    cat > "$INIT_CXX.impl_savebuf" << 'IMPL_EOF'
// SlimLO: Save document to in-memory buffer via private:stream
static int doc_saveToBuffer(
    LibreOfficeKitDocument* pThis,
    unsigned char** ppBuffer, unsigned long* pSize,
    const char* pFormat, const char* pFilterOptions)
{
    comphelper::ProfileZone aZone("doc_saveToBuffer");
    SolarMutexGuard aGuard;
    SetLastExceptionMsg();

    if (!ppBuffer || !pSize)
    {
        SetLastExceptionMsg(u"ppBuffer and pSize are required"_ustr);
        return false;
    }
    *ppBuffer = nullptr;
    *pSize = 0;

    LibLODocument_Impl* pDocument = static_cast<LibLODocument_Impl*>(pThis);
    uno::Reference<frame::XStorable> xStorable(pDocument->mxComponent, uno::UNO_QUERY_THROW);

    try
    {
        OUString sFormat = getUString(pFormat);

        // Determine output filter name from document type + format
        std::span<const ExtensionMap> pMap;
        switch (doc_getDocumentType(pThis))
        {
        case LOK_DOCTYPE_SPREADSHEET: pMap = aCalcExtensionMap; break;
        case LOK_DOCTYPE_PRESENTATION: pMap = aImpressExtensionMap; break;
        case LOK_DOCTYPE_DRAWING: pMap = aDrawExtensionMap; break;
        case LOK_DOCTYPE_TEXT: pMap = aWriterExtensionMap; break;
        default:
            SetLastExceptionMsg(u"Unsupported document type for buffer save"_ustr);
            return false;
        }

        OUString aFilterName;
        for (const auto& item : pMap)
        {
            if (sFormat.equalsIgnoreAsciiCaseAscii(item.extn))
            {
                aFilterName = item.filterName;
                break;
            }
        }
        if (aFilterName.isEmpty())
        {
            SetLastExceptionMsg(u"No output filter found for format"_ustr);
            return false;
        }

        // Create output stream
        SvMemoryStream aOutStream;
        uno::Reference<io::XOutputStream> xOut =
            new utl::OOutputStreamWrapper(aOutStream);

        // Build save descriptor
        MediaDescriptor aSaveMediaDescriptor;
        aSaveMediaDescriptor[u"OutputStream"_ustr] <<= xOut;
        aSaveMediaDescriptor[u"FilterName"_ustr] <<= aFilterName;

        // Parse filter options (same format as doc_saveAs)
        OUString aFilterOptions = getUString(pFilterOptions);
        if (!aFilterOptions.isEmpty())
        {
            comphelper::SequenceAsHashMap aFilterDataMap;
            if (!aFilterOptions.startsWith("{"))
                setFormatSpecificFilterData(sFormat, aFilterDataMap);

            // Parse comma-separated key=value pairs
            const uno::Sequence<OUString> aOptionSeq =
                comphelper::string::convertCommaSeparated(aFilterOptions);
            std::vector<OUString> aFilteredOptionVec;
            for (const auto& rOption : aOptionSeq)
                aFilteredOptionVec.push_back(rOption);

            auto aFilteredOptionSeq =
                comphelper::containerToSequence<OUString>(aFilteredOptionVec);
            aFilterOptions =
                comphelper::string::convertCommaSeparated(aFilteredOptionSeq);
            aSaveMediaDescriptor[MediaDescriptor::PROP_FILTEROPTIONS] <<= aFilterOptions;

            if (!aFilterDataMap.empty())
                aSaveMediaDescriptor[u"FilterData"_ustr] <<=
                    aFilterDataMap.getAsConstPropertyValueList();
        }

        // Save to private:stream
        xStorable->storeToURL(u"private:stream"_ustr,
            aSaveMediaDescriptor.getAsConstPropertyValueList());

        // Copy output to caller-allocated buffer
        std::size_t nOutSize = aOutStream.GetEndOfData();
        unsigned char* pOut = static_cast<unsigned char*>(malloc(nOutSize));
        if (!pOut)
        {
            SetLastExceptionMsg(u"Out of memory"_ustr);
            return false;
        }
        memcpy(pOut, aOutStream.GetData(), nOutSize);
        *ppBuffer = pOut;
        *pSize = static_cast<unsigned long>(nOutSize);
        return true;
    }
    catch (const uno::Exception& exception)
    {
        SetLastExceptionMsg("exception: " + exception.Message);
    }
    return false;
}

IMPL_EOF

    head -n $((SAVEAS_DEF_LINE - 1)) "$INIT_CXX" > "$INIT_CXX.tmp"
    cat "$INIT_CXX.impl_savebuf" >> "$INIT_CXX.tmp"
    tail -n +$SAVEAS_DEF_LINE "$INIT_CXX" >> "$INIT_CXX.tmp"
    mv "$INIT_CXX.tmp" "$INIT_CXX"
    rm -f "$INIT_CXX.impl_savebuf"
    CHANGED=1
else
    echo "    017: doc_saveToBuffer already in init.cxx"
fi

# 3c. Wire documentLoadFromBuffer into office vtable
if ! grep -q 'documentLoadFromBuffer.*=.*lo_documentLoadFromBuffer' "$INIT_CXX"; then
    echo "    017: Wiring documentLoadFromBuffer in office vtable..."
    awk '
    /registerAnyInputCallback.*=.*lo_registerAnyInputCallback/ && !wired_office {
        print
        print "        m_pOfficeClass->documentLoadFromBuffer = lo_documentLoadFromBuffer; // SlimLO"
        wired_office = 1
        next
    }
    { print }
    ' "$INIT_CXX" > "$INIT_CXX.tmp" && mv "$INIT_CXX.tmp" "$INIT_CXX"
    CHANGED=1
else
    echo "    017: documentLoadFromBuffer already wired in vtable"
fi

# 3d. Wire saveToBuffer into document vtable
if ! grep -q 'saveToBuffer.*=.*doc_saveToBuffer' "$INIT_CXX"; then
    echo "    017: Wiring saveToBuffer in document vtable..."
    awk '
    /setViewOption.*=.*doc_setViewOption/ && !wired_doc {
        print
        print "        m_pDocumentClass->saveToBuffer = doc_saveToBuffer; // SlimLO"
        wired_doc = 1
        next
    }
    { print }
    ' "$INIT_CXX" > "$INIT_CXX.tmp" && mv "$INIT_CXX.tmp" "$INIT_CXX"
    CHANGED=1
else
    echo "    017: saveToBuffer already wired in vtable"
fi

# ==========================================================================
# Verification
# ==========================================================================

FAIL=0

# Verify vtable struct in .h
if ! grep -q 'documentLoadFromBuffer' "$LOK_H"; then
    echo "    017: ERROR: documentLoadFromBuffer not in LibreOfficeKit.h"
    FAIL=1
fi
if ! grep -q 'saveToBuffer' "$LOK_H"; then
    echo "    017: ERROR: saveToBuffer not in LibreOfficeKit.h"
    FAIL=1
fi

# Verify C++ wrappers in .hxx
if ! grep -q 'documentLoadFromBuffer' "$LOK_HXX"; then
    echo "    017: ERROR: documentLoadFromBuffer not in LibreOfficeKit.hxx"
    FAIL=1
fi
if ! grep -q 'saveToBuffer' "$LOK_HXX"; then
    echo "    017: ERROR: saveToBuffer not in LibreOfficeKit.hxx"
    FAIL=1
fi

# Verify implementations in init.cxx
if ! grep -q 'lo_documentLoadFromBuffer' "$INIT_CXX"; then
    echo "    017: ERROR: lo_documentLoadFromBuffer not in init.cxx"
    FAIL=1
fi
if ! grep -q 'doc_saveToBuffer' "$INIT_CXX"; then
    echo "    017: ERROR: doc_saveToBuffer not in init.cxx"
    FAIL=1
fi

# Verify vtable wiring
if ! grep -q 'documentLoadFromBuffer.*=.*lo_documentLoadFromBuffer' "$INIT_CXX"; then
    echo "    017: ERROR: documentLoadFromBuffer not wired in office vtable"
    FAIL=1
fi
if ! grep -q 'saveToBuffer.*=.*doc_saveToBuffer' "$INIT_CXX"; then
    echo "    017: ERROR: saveToBuffer not wired in document vtable"
    FAIL=1
fi

if [ "$FAIL" -eq 1 ]; then
    exit 1
fi

if [ "$CHANGED" -eq 1 ]; then
    echo "    017: Patch applied successfully"
else
    echo "    017: Already fully patched"
fi
