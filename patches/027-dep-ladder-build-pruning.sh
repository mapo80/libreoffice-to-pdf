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
        print(f"ERROR: file not found for {label}: {path}")
        sys.exit(1)
    original = path.read_text(encoding="utf-8")
    text = original

    # Normalize first so every run is deterministic and reversible.
    if new in text:
        text = text.replace(new, old)

    if enable:
        if old not in text:
            print(f"ERROR: expected block not found for {label} in {path}")
            sys.exit(1)
        text = text.replace(old, new, 1)

    if text != original:
        path.write_text(text, encoding="utf-8")
        return True
    return False


changes = 0

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

changes += toggle_once(
    root / "Repository.mk",
    "\tunordf \\\n",
    "\t$(if $(ENABLE_SLIMLO),,unordf) \\\n",
    dep_step >= 3,
    "S03 Repository unordf guard",
)

# S04 (xmlsecurity/xsec) is intentionally not baseline-enforced.
# It must be introduced as an explicit dep step once baseline is stable.

# S05: hard-drop crypto signing path in svl for SlimLO.
changes += toggle_once(
    root / "svl/Library_svl.mk",
    "    svl/source/crypto/cryptosign \\\n",
    "    $(if $(ENABLE_SLIMLO),,svl/source/crypto/cryptosign) \\\n",
    dep_step >= 5,
    "S05 svl cryptosign guard",
)

# S06: attempt to remove lcms2 from vcl externals in SlimLO.
changes += toggle_once(
    root / "vcl/Library_vcl.mk",
    "    lcms2 \\\n",
    "    $(if $(ENABLE_SLIMLO),,lcms2) \\\n",
    dep_step >= 6,
    "S06 vcl lcms2 guard",
)

print(f"    Patch 027 complete (SLIMLO_DEP_STEP={dep_step}, changed_blocks={changes})")
PY
