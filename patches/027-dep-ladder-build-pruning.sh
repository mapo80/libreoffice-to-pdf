#!/bin/bash
# 027-dep-ladder-build-pruning.sh
# Apply step-gated build-time pruning rules for merged dependency ladder.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
DEP_STEP="${SLIMLO_DEP_STEP:-0}"

case "$DEP_STEP" in
    ''|*[!0-9]*)
        echo "ERROR: SLIMLO_DEP_STEP must be an integer >= 0 (got '$DEP_STEP')"
        exit 1
        ;;
esac

python3 - "$LO_SRC" "$DEP_STEP" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
dep_step = int(sys.argv[2])


def toggle_once(path: Path, old: str, new: str, enable: bool, label: str) -> bool:
    if not path.exists():
        # Platform-specific files (e.g. vcl/osx/) may not exist on other platforms.
        return False
    original = path.read_text(encoding="utf-8")
    text = original

    # Normalize first so every run is deterministic and reversible.
    if new in text:
        text = text.replace(new, old)

    if enable:
        if old not in text:
            # Pattern not found — may be a platform-specific file (e.g. vcl/osx/ on Linux)
            # or a pre-normalize step on a fresh checkout. Non-fatal; downstream gates
            # (assert-config-features.sh, deps allowlist) will catch real issues.
            print(f"WARN: expected block not found for {label} in {path} (skipping)")
            return False
        text = text.replace(old, new, 1)

    if text != original:
        path.write_text(text, encoding="utf-8")
        return True
    return False


changes = 0

# ---------- Always-on mergelib guards for WNT-conditional entries ----------
# These use $(if $(filter WNT,$(OS)),...) which contains makefile $ characters
# that break shell grep/awk/sed regex on MSYS2 Windows. Python str.replace()
# handles them as literal strings reliably across all platforms.

# avmediawin: conditional on AVMEDIA in Repository.mk but unconditional in
# merged list for WNT. Wrap with gb_Helper_optional so it's excluded when
# --disable-avmedia removes AVMEDIA from BUILD_TYPE.
changes += toggle_once(
    root / "solenv/gbuild/extensions/pre_MergedLibsList.mk",
    "\t$(if $(filter WNT,$(OS)),avmediawin) \\\n",
    "\t$(call gb_Helper_optional,AVMEDIA,$(if $(filter WNT,$(OS)),avmediawin)) \\\n",
    True,
    "pre_MergedLibsList avmediawin AVMEDIA guard",
)

# emser: embedserv module is stripped by patch 002 under ENABLE_SLIMLO,
# so emser must not stay in the merged list on Windows.
changes += toggle_once(
    root / "solenv/gbuild/extensions/pre_MergedLibsList.mk",
    "\t$(if $(filter WNT,$(OS)),emser) \\\n",
    "\t$(if $(ENABLE_SLIMLO),,$(if $(filter WNT,$(OS)),emser)) \\\n",
    True,
    "pre_MergedLibsList emser SLIMLO guard",
)

# Normalize older S01 variant that forced macOS sandbox (reverted now).
changes += toggle_once(
    root / "configure.ac",
    """    with_templates=no
    with_x=no
    ENABLE_WASM_STRIP_ACCESSIBILITY=TRUE
""",
    """    with_templates=no
    with_x=no
    if test "$_os" = "Darwin"; then
        enable_macosx_sandbox=yes
    fi
    ENABLE_WASM_STRIP_ACCESSIBILITY=TRUE
""",
    False,
    "S01 macOS sandbox in SlimLO block",
)

# S01: remove AppleRemote without enabling sandbox.
changes += toggle_once(
    root / "vcl/Library_vclplug_osx.mk",
    "$(eval $(call gb_Library_use_libraries,vclplug_osx,\\\n"
    "    AppleRemote \\\n"
    "))\n",
    "$(eval $(call gb_Library_use_libraries,vclplug_osx,\\\n"
    "    $(if $(ENABLE_SLIMLO),,AppleRemote) \\\n"
    "))\n",
    dep_step >= 1,
    "S01 vclplug_osx AppleRemote guard",
)

changes += toggle_once(
    root / "vcl/Library_vclplug_osx.mk",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "))\n",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DHAVE_FEATURE_MACOSX_SANDBOX=1) \\\n"
    "))\n",
    False,
    "S01 normalize old sandbox macro define",
)

changes += toggle_once(
    root / "vcl/Library_vclplug_osx.mk",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO=1) \\\n"
    "))\n",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_OPENGL=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO=1) \\\n"
    "))\n",
    False,
    "S01 normalize S02 no-opengl macro define",
)

changes += toggle_once(
    root / "vcl/Library_vclplug_osx.mk",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO=1) \\\n"
    "))\n",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_OPENGL=1) \\\n"
    "))\n",
    False,
    "S01 normalize legacy S02 no-opengl macro define (without ENABLE_SLIMLO define)",
)

changes += toggle_once(
    root / "vcl/Library_vclplug_osx.mk",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "))\n",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "))\n",
    False,
    "S01 normalize legacy no-apple block before enforcing ENABLE_SLIMLO define",
)

changes += toggle_once(
    root / "vcl/Library_vclplug_osx.mk",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "))\n",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO=1) \\\n"
    "))\n",
    dep_step >= 1,
    "S01 vclplug_osx force no-apple-remote macro define",
)

changes += toggle_once(
    root / "vcl/Library_vclplug_osx.mk",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "))\n",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO=1) \\\n"
    "))\n",
    dep_step >= 1,
    "S01 vclplug_osx normalize legacy no-apple block with ENABLE_SLIMLO define",
)

changes += toggle_once(
    root / "vcl/Library_vclplug_osx.mk",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO=1) \\\n"
    "))\n",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_OPENGL=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO=1) \\\n"
    "))\n",
    dep_step >= 2,
    "S02 vclplug_osx add no-opengl macro define",
)

changes += toggle_once(
    root / "vcl/Library_vclplug_osx.mk",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_OPENGL=1) \\\n"
    "))\n",
    "$(eval $(call gb_Library_add_defs,vclplug_osx,\\\n"
    "    -DMACOSX_BUNDLE_IDENTIFIER=\\\"$(MACOSX_BUNDLE_IDENTIFIER)\\\" \\\n"
    "    -DVCL_INTERNALS \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_APPLE_REMOTE=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_OPENGL=1) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO=1) \\\n"
    "))\n",
    dep_step >= 2,
    "S02 vclplug_osx normalize legacy no-opengl block with ENABLE_SLIMLO define",
)

changes += toggle_once(
    root / "vcl/osx/salinst.cxx",
    "#if !HAVE_FEATURE_MACOSX_SANDBOX\n"
    "    // Initialize Apple Remote\n",
    "#if !HAVE_FEATURE_MACOSX_SANDBOX && !defined(ENABLE_SLIMLO_NO_APPLE_REMOTE)\n"
    "    // Initialize Apple Remote\n",
    dep_step >= 1,
    "S01 salinst init AppleRemote guard",
)

changes += toggle_once(
    root / "vcl/osx/salinst.cxx",
    "#if !HAVE_FEATURE_MACOSX_SANDBOX\n"
    "    case AppleRemoteControlEvent: // Defined in <apple_remote/RemoteMainController.h>\n",
    "#if !HAVE_FEATURE_MACOSX_SANDBOX && !defined(ENABLE_SLIMLO_NO_APPLE_REMOTE)\n"
    "    case AppleRemoteControlEvent: // Defined in <apple_remote/RemoteMainController.h>\n",
    dep_step >= 1,
    "S01 salinst event AppleRemote guard",
)

changes += toggle_once(
    root / "vcl/osx/vclnsapp.mm",
    "#if !HAVE_FEATURE_MACOSX_SANDBOX\n"
    "- (void)applicationWillBecomeActive:(NSNotification *)pNotification\n",
    "#if !HAVE_FEATURE_MACOSX_SANDBOX && !defined(ENABLE_SLIMLO_NO_APPLE_REMOTE)\n"
    "- (void)applicationWillBecomeActive:(NSNotification *)pNotification\n",
    dep_step >= 1,
    "S01 vclnsapp AppleRemote methods guard",
)

changes += toggle_once(
    root / "Library_merged.mk",
    "\t$(if $(ENABLE_MACOSX_SANDBOX),,AppleRemote) \\\n",
    "\t$(if $(ENABLE_SLIMLO),,$(if $(ENABLE_MACOSX_SANDBOX),,AppleRemote)) \\\n",
    dep_step >= 1,
    "S01 merged AppleRemote guard",
)

changes += toggle_once(
    root / "RepositoryModule_host.mk",
    "\tapple_remote \\\n",
    "\t$(if $(ENABLE_SLIMLO),,apple_remote) \\\n",
    dep_step >= 1,
    "S01 module list AppleRemote guard",
)

changes += toggle_once(
    root / "Repository.mk",
    "\t\t$(if $(ENABLE_MACOSX_SANDBOX),, \\\n"
    "\t\t\tAppleRemote \\\n"
    "\t\t) \\\n",
    "\t\t$(if $(ENABLE_SLIMLO),,$(if $(ENABLE_MACOSX_SANDBOX),, \\\n"
    "\t\t\tAppleRemote \\\n"
    "\t\t)) \\\n",
    dep_step >= 1,
    "S01 Repository AppleRemote install guard",
)

# S02: disable OpenGL on macOS for SlimLO and avoid epoxy links.
changes += toggle_once(
    root / "configure.ac",
    """elif test "$_os" = "Darwin"; then
    # We use frameworks on macOS, no need for detail checks
    ENABLE_OPENGL_TRANSITIONS=TRUE
    AC_DEFINE(HAVE_FEATURE_OPENGL,1)
    ENABLE_OPENGL_CANVAS=TRUE
""",
    """elif test "$_os" = "Darwin"; then
    if test "$enable_slimlo" = "yes"; then
        :
    else
        # We use frameworks on macOS, no need for detail checks
        ENABLE_OPENGL_TRANSITIONS=TRUE
        AC_DEFINE(HAVE_FEATURE_OPENGL,1)
        ENABLE_OPENGL_CANVAS=TRUE
    fi
""",
    dep_step >= 2,
    "S02 configure macOS OpenGL gating",
)

# S02: also disable OpenGL on Windows for SlimLO.
# On Linux --disable-gui sets USING_X11=FALSE so OpenGL is skipped automatically.
# On Windows, HAVE_FEATURE_OPENGL is unconditional — gate it like macOS.
changes += toggle_once(
    root / "configure.ac",
    """elif test $_os = WINNT; then
    ENABLE_OPENGL_TRANSITIONS=TRUE
    AC_DEFINE(HAVE_FEATURE_OPENGL,1)
    ENABLE_OPENGL_CANVAS=TRUE
""",
    """elif test $_os = WINNT; then
    if test "$enable_slimlo" = "yes"; then
        :
    else
        ENABLE_OPENGL_TRANSITIONS=TRUE
        AC_DEFINE(HAVE_FEATURE_OPENGL,1)
        ENABLE_OPENGL_CANVAS=TRUE
    fi
""",
    dep_step >= 2,
    "S02 configure Windows OpenGL gating",
)

changes += toggle_once(
    root / "vcl/Library_vcl.mk",
    "$(eval $(call gb_Library_use_externals,vcl,\\\n"
    "    epoxy \\\n"
    "    $(if $(filter SKIA,$(BUILD_TYPE)),skia) \\\n"
    "))\n",
    "$(eval $(call gb_Library_use_externals,vcl,\\\n"
    "    $(if $(ENABLE_SLIMLO),,epoxy) \\\n"
    "    $(if $(filter SKIA,$(BUILD_TYPE)),skia) \\\n"
    "))\n",
    dep_step >= 2,
    "S02 vcl epoxy guard",
)

changes += toggle_once(
    root / "vcl/Library_vcl.mk",
    "    vcl/source/opengl/OpenGLContext \\\n"
    "    vcl/source/opengl/OpenGLHelper \\\n",
    "    $(if $(ENABLE_SLIMLO),,vcl/source/opengl/OpenGLContext) \\\n"
    "    $(if $(ENABLE_SLIMLO),,vcl/source/opengl/OpenGLHelper) \\\n",
    dep_step >= 2,
    "S02 vcl OpenGL source guard",
)

changes += toggle_once(
    root / "vcl/Library_vclplug_osx.mk",
    "$(eval $(call gb_Library_use_externals,vclplug_osx,\\\n"
    "    boost_headers \\\n"
    "    epoxy \\\n"
    "    harfbuzz \\\n"
    "    $(if $(filter SKIA,$(BUILD_TYPE)), \\\n"
    "        skia \\\n"
    "    ) \\\n"
    "))\n",
    "$(eval $(call gb_Library_use_externals,vclplug_osx,\\\n"
    "    boost_headers \\\n"
    "    $(if $(ENABLE_SLIMLO),,epoxy) \\\n"
    "    harfbuzz \\\n"
    "    $(if $(filter SKIA,$(BUILD_TYPE)), \\\n"
    "        skia \\\n"
    "    ) \\\n"
    "))\n",
    dep_step >= 2,
    "S02 vclplug_osx epoxy guard",
)

changes += toggle_once(
    root / "vcl/osx/salobj.cxx",
    "#include <vcl/opengl/OpenGLContext.hxx>\n"
    "#include <vcl/opengl/OpenGLHelper.hxx>\n"
    "#include <opengl/zone.hxx>\n",
    "#include <vcl/opengl/OpenGLContext.hxx>\n"
    "#include <opengl/zone.hxx>\n",
    dep_step >= 2,
    "S02 salobj remove OpenGLHelper include (epoxy header path)",
)

changes += toggle_once(
    root / "vcl/osx/salobj.cxx",
    "namespace {\n\nclass AquaOpenGLContext : public OpenGLContext\n",
    "#if !defined(ENABLE_SLIMLO_NO_OPENGL)\nnamespace {\n\nclass AquaOpenGLContext : public OpenGLContext\n",
    dep_step >= 2,
    "S02 salobj guard AquaOpenGLContext class",
)

changes += toggle_once(
    root / "vcl/osx/salobj.cxx",
    "#if !defined(ENABLE_SLIMLO)\nnamespace {\n\nclass AquaOpenGLContext : public OpenGLContext\n",
    "#if !defined(ENABLE_SLIMLO_NO_OPENGL)\nnamespace {\n\nclass AquaOpenGLContext : public OpenGLContext\n",
    dep_step >= 2,
    "S02 salobj normalize old guard macro",
)

changes += toggle_once(
    root / "vcl/osx/salobj.cxx",
    "#if !defined(ENABLE_SLIMLO)\n"
    "#if !defined(ENABLE_SLIMLO_NO_OPENGL)\n"
    "namespace {\n\n"
    "class AquaOpenGLContext : public OpenGLContext\n",
    "#if !defined(ENABLE_SLIMLO_NO_OPENGL)\n"
    "namespace {\n\n"
    "class AquaOpenGLContext : public OpenGLContext\n",
    dep_step >= 2,
    "S02 salobj normalize nested old/new guard macros",
)

if dep_step >= 2:
    salobj_path = root / "vcl/osx/salobj.cxx"
    salobj_text = salobj_path.read_text(encoding="utf-8")
    salobj_fixed = salobj_text.replace(
        "#if !defined(ENABLE_SLIMLO)\n#if !defined(ENABLE_SLIMLO_NO_OPENGL)\n",
        "#if !defined(ENABLE_SLIMLO_NO_OPENGL)\n",
    )
    if salobj_fixed != salobj_text:
        salobj_path.write_text(salobj_fixed, encoding="utf-8")
        changes += 1

changes += toggle_once(
    root / "vcl/osx/salobj.cxx",
    "OpenGLContext* AquaSalInstance::CreateOpenGLContext()\n"
    "{\n"
    "    OSX_SALDATA_RUNINMAIN_POINTER( CreateOpenGLContext(), OpenGLContext* )\n"
    "#if defined(ENABLE_SLIMLO)\n"
    "    return nullptr;\n"
    "#else\n"
    "    return new AquaOpenGLContext;\n"
    "#endif\n"
    "}\n",
    "OpenGLContext* AquaSalInstance::CreateOpenGLContext()\n"
    "{\n"
    "    OSX_SALDATA_RUNINMAIN_POINTER( CreateOpenGLContext(), OpenGLContext* )\n"
    "#if defined(ENABLE_SLIMLO_NO_OPENGL)\n"
    "    return nullptr;\n"
    "#else\n"
    "    return new AquaOpenGLContext;\n"
    "#endif\n"
    "}\n",
    dep_step >= 2,
    "S02 salobj pre-normalize old CreateOpenGLContext guard macro",
)

changes += toggle_once(
    root / "vcl/osx/salobj.cxx",
    "SAL_WNODEPRECATED_DECLARATIONS_POP\n"
    "}\n\n"
    "OpenGLContext* AquaSalInstance::CreateOpenGLContext()\n"
    "{\n"
    "    OSX_SALDATA_RUNINMAIN_POINTER( CreateOpenGLContext(), OpenGLContext* )\n"
    "    return new AquaOpenGLContext;\n"
    "}\n",
    "SAL_WNODEPRECATED_DECLARATIONS_POP\n"
    "}\n"
    "#endif\n\n"
    "OpenGLContext* AquaSalInstance::CreateOpenGLContext()\n"
    "{\n"
    "    OSX_SALDATA_RUNINMAIN_POINTER( CreateOpenGLContext(), OpenGLContext* )\n"
    "#if defined(ENABLE_SLIMLO_NO_OPENGL)\n"
    "    return nullptr;\n"
    "#else\n"
    "    return new AquaOpenGLContext;\n"
    "#endif\n"
    "}\n",
    dep_step >= 2,
    "S02 salobj guard OpenGLContext implementation",
)

changes += toggle_once(
    root / "vcl/osx/salobj.cxx",
    "OpenGLContext* AquaSalInstance::CreateOpenGLContext()\n"
    "{\n"
    "    OSX_SALDATA_RUNINMAIN_POINTER( CreateOpenGLContext(), OpenGLContext* )\n"
    "#if defined(ENABLE_SLIMLO)\n"
    "    return nullptr;\n"
    "#else\n"
    "    return new AquaOpenGLContext;\n"
    "#endif\n"
    "}\n",
    "OpenGLContext* AquaSalInstance::CreateOpenGLContext()\n"
    "{\n"
    "    OSX_SALDATA_RUNINMAIN_POINTER( CreateOpenGLContext(), OpenGLContext* )\n"
    "#if defined(ENABLE_SLIMLO_NO_OPENGL)\n"
    "    return nullptr;\n"
    "#else\n"
    "    return new AquaOpenGLContext;\n"
    "#endif\n"
    "}\n",
    dep_step >= 2,
    "S02 salobj normalize old CreateOpenGLContext guard macro",
)

changes += toggle_once(
    root / "vcl/osx/salobj.cxx",
    "    VCL_GL_INFO(\"OpenGLContext::ImplInit----start\");\n",
    "    // SlimLO S02: OpenGLHelper removed to avoid epoxy dependency.\n",
    dep_step >= 2,
    "S02 salobj remove VCL_GL_INFO usage",
)

# S03: remove RDF chain from merged/runtime surface.
changes += toggle_once(
    root / "solenv/gbuild/extensions/pre_MergedLibsList.mk",
    "\tunordf \\\n",
    "\t$(if $(ENABLE_SLIMLO),,unordf) \\\n",
    dep_step >= 3,
    "S03 pre_MergedLibsList unordf guard",
)

# Always normalize legacy S03 edit that removed unordf from Repository.mk,
# because that breaks unoxml/Library_unordf registration checks.
changes += toggle_once(
    root / "Repository.mk",
    "\tunordf \\\n",
    "\t$(if $(ENABLE_SLIMLO),,unordf) \\\n",
    False,
    "S03 normalize legacy Repository unordf guard",
)

# S04 (xmlsecurity/xsec) is intentionally not baseline-enforced.
# It must be introduced as an explicit dep step once baseline is stable.

# Normalize older S05 variant that removed cryptosign without stubbing symbols.
changes += toggle_once(
    root / "svl/Library_svl.mk",
    "    svl/source/crypto/cryptosign \\\n",
    "    $(if $(ENABLE_SLIMLO),,svl/source/crypto/cryptosign) \\\n",
    False,
    "S05 normalize legacy cryptosign drop-only guard",
)

# S05: replace cryptosign with a slim stub when ENABLE_SLIMLO.
# This keeps required symbols for PDF/signing call sites while avoiding NSS/curl codepaths.
changes += toggle_once(
    root / "svl/Library_svl.mk",
    "    svl/source/crypto/cryptosign \\\n",
    "    $(if $(ENABLE_SLIMLO),svl/source/crypto/cryptosign_stub,svl/source/crypto/cryptosign) \\\n",
    dep_step >= 5,
    "S05 svl cryptosign stub guard",
)

stub_source = """/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * This file is part of the LibreOffice project.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

#include <svl/cryptosign.hxx>
#include <svl/sigstruct.hxx>
#include <tools/stream.hxx>

namespace svl::crypto {

std::vector<unsigned char> DecodeHexString(std::string_view rHex)
{
    auto hex = [](char c) -> int {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return 10 + (c - 'a');
        if (c >= 'A' && c <= 'F')
            return 10 + (c - 'A');
        return -1;
    };

    if ((rHex.size() % 2) != 0)
        return {};

    std::vector<unsigned char> out;
    out.reserve(rHex.size() / 2);
    for (size_t i = 0; i < rHex.size(); i += 2)
    {
        int hi = hex(rHex[i]);
        int lo = hex(rHex[i + 1]);
        if (hi < 0 || lo < 0)
            return {};
        out.push_back(static_cast<unsigned char>((hi << 4) | lo));
    }
    return out;
}

bool Signing::Sign(OStringBuffer& rCMSHexBuffer)
{
    (void)rCMSHexBuffer;
    return false;
}

bool Signing::Verify(const std::vector<unsigned char>& /*aData*/, const bool /*bNonDetached*/,
                     const std::vector<unsigned char>& /*aSignature*/,
                     SignatureInformation& /*rInformation*/)
{
    return false;
}

bool Signing::Verify(SvStream& /*rStream*/,
                     const std::vector<std::pair<size_t, size_t>>& /*aByteRanges*/,
                     const bool /*bNonDetached*/,
                     const std::vector<unsigned char>& /*aSignature*/,
                     SignatureInformation& /*rInformation*/)
{
    return false;
}

void Signing::appendHex(sal_Int8 nInt, OStringBuffer& rBuffer)
{
    static constexpr char kHex[] = "0123456789ABCDEF";
    const unsigned char v = static_cast<unsigned char>(nInt);
    rBuffer.append(kHex[(v >> 4) & 0x0F]);
    rBuffer.append(kHex[v & 0x0F]);
}

bool CertificateOrName::Is() const
{
    return m_xCertificate.is() || !m_aName.isEmpty();
}

} // namespace svl::crypto

/* vim:set shiftwidth=4 softtabstop=4 expandtab: */
"""

stub_path = root / "svl/source/crypto/cryptosign_stub.cxx"
if not stub_path.exists() or stub_path.read_text(encoding="utf-8") != stub_source:
    stub_path.write_text(stub_source, encoding="utf-8")
    changes += 1

# S06: attempt to remove lcms2 from vcl externals in SlimLO.
changes += toggle_once(
    root / "vcl/Library_vcl.mk",
    "    lcms2 \\\n",
    "    $(if $(ENABLE_SLIMLO),,lcms2) \\\n",
    dep_step >= 6,
    "S06 vcl lcms2 guard",
)

changes += toggle_once(
    root / "vcl/Library_vcl.mk",
    "$(eval $(call gb_Library_add_defs,vcl,\\\n"
    "    -DVCL_DLLIMPLEMENTATION \\\n"
    "    -DDLLIMPLEMENTATION_UITEST \\\n"
    "    -DCUI_DLL_NAME=\\\"$(call gb_Library_get_runtime_filename,$(call gb_Library__get_name,cui))\\\" \\\n"
    "    -DTK_DLL_NAME=\\\"$(call gb_Library_get_runtime_filename,$(call gb_Library__get_name,tk))\\\" \\\n"
    "    $(if $(SYSTEM_LIBFIXMATH),-DSYSTEM_LIBFIXMATH) \\\n"
    "))\n",
    "$(eval $(call gb_Library_add_defs,vcl,\\\n"
    "    -DVCL_DLLIMPLEMENTATION \\\n"
    "    -DDLLIMPLEMENTATION_UITEST \\\n"
    "    -DCUI_DLL_NAME=\\\"$(call gb_Library_get_runtime_filename,$(call gb_Library__get_name,cui))\\\" \\\n"
    "    -DTK_DLL_NAME=\\\"$(call gb_Library_get_runtime_filename,$(call gb_Library__get_name,tk))\\\" \\\n"
    "    $(if $(SYSTEM_LIBFIXMATH),-DSYSTEM_LIBFIXMATH) \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO_NO_LCMS2=1) \\\n"
    "))\n",
    dep_step >= 6,
    "S06 vcl add no-lcms2 define",
)

changes += toggle_once(
    root / "vcl/source/gdi/pdfwriter_impl.cxx",
    "#include <lcms2.h>\n",
    "#if !defined(ENABLE_SLIMLO_NO_LCMS2)\n"
    "#include <lcms2.h>\n"
    "#endif\n",
    dep_step >= 6,
    "S06 pdfwriter_impl guard lcms2 include",
)

# Normalize legacy S06 variant that injected an early-return block
# without fully preprocessor-guarding downstream cms* symbol usage.
changes += toggle_once(
    root / "vcl/source/gdi/pdfwriter_impl.cxx",
    "sal_Int32 PDFWriterImpl::emitOutputIntent()\n"
    "{\n"
    "    if (m_nPDFA_Version == 0) // not PDFA\n"
    "        return 0;\n"
    "\n"
    "    //emit the sRGB standard profile, in ICC format, in a stream, per IEC61966-2.1\n",
    "sal_Int32 PDFWriterImpl::emitOutputIntent()\n"
    "{\n"
    "    if (m_nPDFA_Version == 0) // not PDFA\n"
    "        return 0;\n"
    "#if defined(ENABLE_SLIMLO_NO_LCMS2)\n"
    "    // SlimLO S06: no lcms2, skip ICC output intent generation.\n"
    "    return 0;\n"
    "#endif\n"
    "\n"
    "    //emit the sRGB standard profile, in ICC format, in a stream, per IEC61966-2.1\n",
    False,
    "S06 normalize legacy early-return block",
)

changes += toggle_once(
    root / "vcl/source/gdi/pdfwriter_impl.cxx",
    "sal_Int32 PDFWriterImpl::emitOutputIntent()\n"
    "{\n"
    "    if (m_nPDFA_Version == 0) // not PDFA\n"
    "        return 0;\n",
    "sal_Int32 PDFWriterImpl::emitOutputIntent()\n"
    "{\n"
    "    if (m_nPDFA_Version == 0) // not PDFA\n"
    "        return 0;\n"
    "#if !defined(ENABLE_SLIMLO_NO_LCMS2)\n",
    dep_step >= 6,
    "S06 pdfwriter_impl guard output intent body",
)

changes += toggle_once(
    root / "vcl/source/gdi/pdfwriter_impl.cxx",
    "    if ( !writeBuffer( aLine ) ) return 0;\n"
    "\n"
    "    return nOIObject;\n"
    "}\n",
    "    if ( !writeBuffer( aLine ) ) return 0;\n"
    "\n"
    "    return nOIObject;\n"
    "#else\n"
    "    // SlimLO S06: no lcms2, skip ICC output intent generation.\n"
    "    return 0;\n"
    "#endif\n"
    "}\n",
    dep_step >= 6,
    "S06 pdfwriter_impl add no-lcms2 fallback branch",
)

# S07: guard RDF-consuming code paths to allow removing the RDF stack
# (librdf, libraptor2, librasqal, libunordflo) from the runtime.
# Without these guards, rdf::URI::createKnown() throws DeploymentException
# when the UNO service is missing, crashing on DOCX files with bookmarks.

# S07: propagate ENABLE_SLIMLO define to sw module so #if guards compile correctly.
changes += toggle_once(
    root / "sw/Library_sw.mk",
    "$(eval $(call gb_Library_add_defs,sw,\\\n"
    "    -DSW_DLLIMPLEMENTATION \\\n"
    "\t-DSWUI_DLL_NAME=\\\"$(call gb_Library_get_runtime_filename,$(call gb_Library__get_name,swui))\\\" \\\n"
    "))\n",
    "$(eval $(call gb_Library_add_defs,sw,\\\n"
    "    -DSW_DLLIMPLEMENTATION \\\n"
    "\t-DSWUI_DLL_NAME=\\\"$(call gb_Library_get_runtime_filename,$(call gb_Library__get_name,swui))\\\" \\\n"
    "    $(if $(ENABLE_SLIMLO),-DENABLE_SLIMLO=1) \\\n"
    "))\n",
    dep_step >= 7,
    "S07 sw Library_sw.mk add ENABLE_SLIMLO define",
)

# S07a: porlay.cxx — getBookmarkColor() RDF guard
changes += toggle_once(
    root / "sw/source/core/text/porlay.cxx",
    "    try\n"
    "    {\n"
    "        SwDoc& rDoc = const_cast<SwDoc&>(rNode.GetDoc());\n"
    "        const rtl::Reference< SwXBookmark > xRef = SwXBookmark::CreateXBookmark(rDoc, pBookmark);\n"
    "        if (const SwDocShell* pShell = rDoc.GetDocShell())\n"
    "        {\n"
    "            rtl::Reference<SwXTextDocument> xModel = pShell->GetBaseModel();\n"
    "\n"
    "            static uno::Reference< uno::XComponentContext > xContext(\n"
    "                ::comphelper::getProcessComponentContext());\n"
    "\n"
    "            static uno::Reference< rdf::XURI > xODF_SHADING(\n"
    "                rdf::URI::createKnown(xContext, rdf::URIs::LO_EXT_SHADING), uno::UNO_SET_THROW);\n",
    "    try\n"
    "    {\n"
    "#if !defined(ENABLE_SLIMLO)\n"
    "        SwDoc& rDoc = const_cast<SwDoc&>(rNode.GetDoc());\n"
    "        const rtl::Reference< SwXBookmark > xRef = SwXBookmark::CreateXBookmark(rDoc, pBookmark);\n"
    "        if (const SwDocShell* pShell = rDoc.GetDocShell())\n"
    "        {\n"
    "            rtl::Reference<SwXTextDocument> xModel = pShell->GetBaseModel();\n"
    "\n"
    "            static uno::Reference< uno::XComponentContext > xContext(\n"
    "                ::comphelper::getProcessComponentContext());\n"
    "\n"
    "            static uno::Reference< rdf::XURI > xODF_SHADING(\n"
    "                rdf::URI::createKnown(xContext, rdf::URIs::LO_EXT_SHADING), uno::UNO_SET_THROW);\n",
    dep_step >= 7,
    "S07 porlay getBookmarkColor RDF guard open",
)

changes += toggle_once(
    root / "sw/source/core/text/porlay.cxx",
    "        }\n"
    "    }\n"
    "    catch (const lang::IllegalArgumentException&)\n"
    "    {\n"
    "    }\n"
    "\n"
    "    return c;\n"
    "}\n"
    "\n"
    "static OUString getBookmarkType",
    "        }\n"
    "#endif // !ENABLE_SLIMLO\n"
    "    }\n"
    "    catch (const lang::IllegalArgumentException&)\n"
    "    {\n"
    "    }\n"
    "\n"
    "    return c;\n"
    "}\n"
    "\n"
    "static OUString getBookmarkType",
    dep_step >= 7,
    "S07 porlay getBookmarkColor RDF guard close",
)

# S07b: porlay.cxx — getBookmarkType() RDF guard
changes += toggle_once(
    root / "sw/source/core/text/porlay.cxx",
    "    try\n"
    "    {\n"
    "        SwDoc& rDoc = const_cast<SwDoc&>(rNode.GetDoc());\n"
    "        const rtl::Reference< SwXBookmark > xRef = SwXBookmark::CreateXBookmark(rDoc, pBookmark);\n"
    "        if (const SwDocShell* pShell = rDoc.GetDocShell())\n"
    "        {\n"
    "            rtl::Reference<SwXTextDocument> xModel = pShell->GetBaseModel();\n"
    "\n"
    "            static uno::Reference< uno::XComponentContext > xContext(\n"
    "                ::comphelper::getProcessComponentContext());\n"
    "\n"
    "            static uno::Reference< rdf::XURI > xODF_PREFIX(\n"
    "                rdf::URI::createKnown(xContext, rdf::URIs::RDF_TYPE), uno::UNO_SET_THROW);\n",
    "    try\n"
    "    {\n"
    "#if !defined(ENABLE_SLIMLO)\n"
    "        SwDoc& rDoc = const_cast<SwDoc&>(rNode.GetDoc());\n"
    "        const rtl::Reference< SwXBookmark > xRef = SwXBookmark::CreateXBookmark(rDoc, pBookmark);\n"
    "        if (const SwDocShell* pShell = rDoc.GetDocShell())\n"
    "        {\n"
    "            rtl::Reference<SwXTextDocument> xModel = pShell->GetBaseModel();\n"
    "\n"
    "            static uno::Reference< uno::XComponentContext > xContext(\n"
    "                ::comphelper::getProcessComponentContext());\n"
    "\n"
    "            static uno::Reference< rdf::XURI > xODF_PREFIX(\n"
    "                rdf::URI::createKnown(xContext, rdf::URIs::RDF_TYPE), uno::UNO_SET_THROW);\n",
    dep_step >= 7,
    "S07 porlay getBookmarkType RDF guard open",
)

changes += toggle_once(
    root / "sw/source/core/text/porlay.cxx",
    "        }\n"
    "    }\n"
    "    catch (const lang::IllegalArgumentException&)\n"
    "    {\n"
    "    }\n"
    "\n"
    "    return sRet;\n"
    "}\n",
    "        }\n"
    "#endif // !ENABLE_SLIMLO\n"
    "    }\n"
    "    catch (const lang::IllegalArgumentException&)\n"
    "    {\n"
    "    }\n"
    "\n"
    "    return sRet;\n"
    "}\n",
    dep_step >= 7,
    "S07 porlay getBookmarkType RDF guard close",
)

# S07c: itrform2.cxx — meta portion RDF shading guard
changes += toggle_once(
    root / "sw/source/core/text/itrform2.cxx",
    "            if (xRet.is())\n"
    "            {\n"
    "                const SwDoc & rDoc = rInf.GetTextFrame()->GetDoc();\n"
    "                static uno::Reference< uno::XComponentContext > xContext(\n"
    "                    ::comphelper::getProcessComponentContext());\n"
    "\n"
    "                static uno::Reference< rdf::XURI > xODF_SHADING(\n"
    "                    rdf::URI::createKnown(xContext, rdf::URIs::LO_EXT_SHADING), uno::UNO_SET_THROW);\n",
    "            if (xRet.is())\n"
    "            {\n"
    "#if !defined(ENABLE_SLIMLO)\n"
    "                const SwDoc & rDoc = rInf.GetTextFrame()->GetDoc();\n"
    "                static uno::Reference< uno::XComponentContext > xContext(\n"
    "                    ::comphelper::getProcessComponentContext());\n"
    "\n"
    "                static uno::Reference< rdf::XURI > xODF_SHADING(\n"
    "                    rdf::URI::createKnown(xContext, rdf::URIs::LO_EXT_SHADING), uno::UNO_SET_THROW);\n",
    dep_step >= 7,
    "S07 itrform2 meta portion RDF guard open",
)

changes += toggle_once(
    root / "sw/source/core/text/itrform2.cxx",
    "                }\n"
    "            }\n"
    "            pPor = pMetaPor;\n",
    "                }\n"
    "#endif // !ENABLE_SLIMLO\n"
    "            }\n"
    "            pPor = pMetaPor;\n",
    dep_step >= 7,
    "S07 itrform2 meta portion RDF guard close",
)

print(f"    Patch 027 complete (SLIMLO_DEP_STEP={dep_step}, changed_blocks={changes})")
PY
