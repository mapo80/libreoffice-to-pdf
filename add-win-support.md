# Setup Windows ARM64 VM + supporto build Windows ARM64/x64

## Context
La build Windows nel CI fallisce su `external/harfbuzz` (patch 020, meson MSVC path conversion). Serve un ambiente locale Windows per iterare velocemente. La VM è Windows 11 ARM64 su VMware Fusion (Apple Silicon), con VS 2022 già installato.

Obiettivo: supporto ARM64 nativo come target primario, con x64 come target secondario.

**Buona notizia**: LibreOffice supporta Windows ARM64 upstream dal 24.8 (`CPUNAME=AARCH64`, `PLATFORMID=windows_aarch64`). NASM non serve per ARM64 (solo per x86/x64 SIMD in libjpeg-turbo). OpenSSL ha supporto nativo ARM64 (`VC-WIN64-ARM`).

## Piano

### 1. Creare `scripts/setup-windows-msys2.sh`
Script bash da eseguire nella shell MSYS2 per configurare l'ambiente di build. Idempotente (safe da rieseguire).

```
a) Installa pacchetti base MSYS2:
   autoconf automake bison flex gperf libtool make patch pkg-config
   zip unzip wget perl python3 python-setuptools findutils git

b) Installa pacchetti MinGW64:
   mingw-w64-x86_64-pkgconf (serve per LO configure indipendentemente dall'arch target)
   mingw-w64-x86_64-nasm (solo se architettura host è x86_64 — skip su ARM64)

c) Crea wrapper /usr/local/bin/pkgconf-2.4.3.exe (LO si aspetta questo nome esatto)

d) Crea symlink wslpath → cygpath (LO gbuild lo usa per conversione path)

e) Verifica tutti i tool installati
```

**File**: `scripts/setup-windows-msys2.sh`

### 2. Creare `scripts/windows-build.sh`
Wrapper che configura l'ambiente e lancia `build.sh`. Da eseguire in MSYS2 shell.

```
a) Detect architettura: uname -m → aarch64 o x86_64
   (su Windows ARM64 MSYS2, uname -m riporta l'arch della macchina)

b) Setta variabili d'ambiente:
   - CHERE_INVOKING=1, MSYS=winsymlinks:native
   - PKG_CONFIG=/usr/local/bin/pkgconf-2.4.3.exe
   - Unset MSYSTEM, WSL, UCRTVersion

c) Trova cl.exe via vswhere.exe:
   - ARM64: cerca VC.Tools.ARM64 o arm64 nel path
   - x64: cerca VC.Tools.x86.x64

d) Trova Windows python.exe (NON MSYS2 python):
   - Cerca in: /c/Users/*/AppData/Local/Programs/Python/*/python.exe
   - Fallback: /c/Python*/python.exe, python.exe nel PATH

e) NASM: esporta solo se architettura è x86_64 (skip su ARM64)

f) ICU_DATA_FILTER_FILE: converte con cygpath -m

g) Lancia scripts/build.sh

h) In caso di errore: stampa log diagnostici
   (ICU config.log, harfbuzz meson-log.txt, etc.)
```

**File**: `scripts/windows-build.sh`

### 3. Modificare `scripts/build.sh` — rendere NASM condizionale
Il check NASM attuale (righe 191-203) fallisce su ARM64 perché NASM non esiste. Serve renderlo condizionale sull'architettura.

**Modifica** in `scripts/build.sh` (righe 191-203):
```bash
# Prima: NASM obbligatorio su tutti i Windows
# Dopo: NASM obbligatorio solo su x86/x86_64 Windows
if [ "$PLATFORM" = "windows" ]; then
    WIN_ARCH="$(uname -m 2>/dev/null || echo unknown)"
    case "$WIN_ARCH" in
        x86_64|i686)
            # NASM required for x86/x64 SIMD (libjpeg-turbo)
            NASM_BIN="${NASM:-}"
            ...existing logic...
            ;;
        aarch64|arm64)
            echo "    ARM64 detected — NASM not required"
            ;;
    esac
fi
```

### 4. Modificare `scripts/build.sh` — migliorare ricerca Python per VM locale
Aggiungere path di ricerca Python per installazioni locali (non solo CI hosted tool cache).

**Modifica** in `scripts/build.sh` (righe 163-178):
```bash
# Aggiungere ai candidati:
/c/Users/*/AppData/Local/Programs/Python/Python3*/python.exe
/c/Program\ Files/Python3*/python.exe
```

### 5. Creare `scripts/windows-debug-harfbuzz.sh`
Script per debuggare isolatamente il problema harfbuzz senza ricompilare tutto LO.

```
a) Sorgente LO già clonata e configurata (prerequisito: almeno un run di windows-build.sh fino a configure)
b) Applica/riapplica solo patch 020
c) Esegue: make ExternalProject_harfbuzz 2>&1 | tee harfbuzz-build.log
d) Se fallisce, cerca e stampa:
   - Il file meson cross-compile generato (workdir/ExternalProject/harfbuzz/...)
   - I valori effettivi di gb_CC, gb_CXX dal makefile
   - Il meson-log.txt completo
   - Il path di cl.exe usato e se è raggiungibile da Windows python
e) Suggerisce fix basati sull'errore trovato
```

**File**: `scripts/windows-debug-harfbuzz.sh`

### 6. Opzionale: `SlimLO-windows-arm64.conf`
Se servono flags diversi per ARM64 vs x64. Verificare dopo il primo tentativo di build se la configurazione attuale funziona su ARM64 senza modifiche. `SlimLO-windows.conf` attuale è architecture-agnostic, quindi probabilmente funziona già.

Se serve, `build.sh` sceglierà il config in base all'architettura:
```bash
case "$PLATFORM-$WIN_ARCH" in
    windows-aarch64) DISTRO_CONF="SlimLO-windows-arm64.conf" ;;
    windows-*)       DISTRO_CONF="SlimLO-windows.conf" ;;
esac
```

### File da creare/modificare

| File | Azione | Descrizione |
|------|--------|-------------|
| `scripts/setup-windows-msys2.sh` | **Nuovo** | Setup pacchetti MSYS2 + wrapper tools |
| `scripts/windows-build.sh` | **Nuovo** | Wrapper build con auto-detect arch + env setup |
| `scripts/windows-debug-harfbuzz.sh` | **Nuovo** | Debug isolato harfbuzz meson |
| `scripts/build.sh` | **Modifica** | NASM condizionale su arch, Python path migliorati |

### File esistenti rilevanti (non modificati)
- [patches/020-fix-harfbuzz-meson-msvc-path.sh](patches/020-fix-harfbuzz-meson-msvc-path.sh) — patch da debuggare
- [distro-configs/SlimLO-windows.conf](distro-configs/SlimLO-windows.conf) — config Windows (arch-agnostic)
- [.github/workflows/build-windows.yml](.github/workflows/build-windows.yml) — CI reference

## Workflow di utilizzo

```
# 1. Nella VM Windows, installa MSYS2 da msys2.org (se non installato)

# 2. Apri MSYS2 shell (MSYS, non MINGW64)
./scripts/setup-windows-msys2.sh     # una volta sola

# 3. Prima build completa
./scripts/windows-build.sh           # auto-detect ARM64, ~2-4 ore

# 4. Se harfbuzz fallisce, debug isolato
./scripts/windows-debug-harfbuzz.sh  # mostra cross-file, log meson, etc.

# 5. Fix patch 020, riprova solo harfbuzz
./scripts/windows-debug-harfbuzz.sh  # iterazione veloce (~1 min)

# 6. Build completa dopo fix
./scripts/windows-build.sh           # incrementale, solo ricompila il necessario
```

## Verifica
1. `setup-windows-msys2.sh` completa senza errori, tutti i tool verificati
2. `windows-build.sh` su ARM64: configure riconosce `CPUNAME=AARCH64`, NASM skip
3. `windows-debug-harfbuzz.sh`: mostra il cross-file meson e il log di errore
4. Build completa produce `output/program/mergedlo.dll` per l'architettura corretta
5. `dumpbin /headers mergedlo.dll` mostra `machine (AA64)` per ARM64
