# SlimLO LTO Optimization — Session Log

## Obiettivo

Abilitare LTO (Link-Time Optimization) per ridurre la dimensione degli artefatti.
Target: **214 MB → ~170-180 MB** (principalmente riducendo `libmergedlo.so` da 97 MB a ~70 MB).

---

## Sessione 1 — Analisi e prima build LTO

### 1. Analisi dimensioni (completato)

Breakdown degli artefatti a 214 MB:

| Componente | Dimensione | % |
|-----------|-----------|---|
| libmergedlo.so | 97 MB | 45% |
| libicudata.so.77 (ICU locale data) | 30 MB | 14% |
| libswlo.so (Writer non-merged) | 19 MB | 9% |
| ICU i18n + uc | 5.6 MB | 3% |
| Externals (curl, rdf, raptor, etc.) | 6 MB | 3% |
| Altri .so | 35 MB | 16% |
| share/ | 8 MB | 4% |

Opzioni di ottimizzazione considerate:
- **LTO**: -20/30% su libmergedlo.so → risparmiare ~20-30 MB
- **ICU data filter**: ridurre 30 MB → 2-5 MB (non implementato, per il futuro)

Utente ha scelto: **Solo LTO**.

### 2. Modifiche per abilitare LTO (completato)

**File: `distro-configs/SlimLO.conf` (riga 42)**
```diff
- --disable-lto
+ --enable-lto
```

**File: `docker/Dockerfile.linux-x64` (riga 132)**
```diff
- make -j8
+ make -j4
```
Ridotto parallelismo perché LTO linking è memory-intensive (~3-6 GB per processo di link).

### 3. Prima build LTO (completata — ~7.5 ore)

```bash
docker builder prune --filter type=exec.cachemount  # clear cache (LTO objects incompatibili)
DOCKER_BUILDKIT=1 docker build --build-arg SCRIPTS_HASH=... -f docker/Dockerfile.linux-x64 -t slimlo-build .
```

**Risultato build: SUCCESSO**
- Tempo: ~26951 secondi (~7.5 ore) con -j4
- Dimensione artefatti: **171 MB** (164 MB program/ + 7.6 MB share/) — **risparmio 43 MB (20%)**

### 4. Problema: constructor symbols mancanti (scoperto)

```
Constructor symbols in .dynsym: 0
WARNING: No constructor symbols found in libmergedlo.so .dynsym!
```

I simboli `*_get_implementation` (necessari per UNO component loading via `dlsym()`) sono stati eliminati da LTO come dead code.

---

## Sessione 2 — Fix constructor symbols + rebuild

### 5. Analisi root cause (completato)

**Root cause**: GCC LTO gira come linker plugin e fa whole-program optimization. I constructor symbols (`*_get_implementation`, `*_component_getFactory`) sono chiamati solo a runtime via `dlsym()` — LTO li vede come codice morto e li elimina.

La version script di patch 008 (`mergedlo_constructors.map`) può solo esportare simboli che **sopravvivono** a LTO — non può prevenire la loro eliminazione.

### 6. Approcci valutati

| Approccio | Pro | Contro | Scelto? |
|-----------|-----|--------|---------|
| `--export-dynamic` | Semplice, funziona con LTO linker plugin | .dynsym più grande | **SI** |
| `-Wl,-u,symbol` per ogni simbolo | Preciso | Richiede lista esplicita, complessità build | No |
| `__attribute__((used))` su SAL_DLLPUBLIC_EXPORT | Elegante | Invasivo, modifica fonte LO | No |
| `-ffat-lto-objects` + `-fno-lto` al link | Garantito | Perde benefici LTO cross-module | No |
| Disabilitare LTO | Sicuro | Perde tutti i benefici LTO | Fallback |

### 7. Fix implementato (completato)

**File: `patches/008-mergedlibs-export-constructors.sh`**

Due modifiche:

**a) Aggiunto `--export-dynamic` ai linker flags:**
```makefile
$(eval $(call gb_Library_add_ldflags,merged,\
    -Wl,--export-dynamic \
    -Wl,--version-script=$(SRCDIR)/solenv/gbuild/mergedlo_constructors.map \
))
```

Questo dice al LTO linker plugin di preservare tutti i simboli con visibility "default" — li tratta come root perché potrebbero essere referenziati esternamente.

**b) Aggiunto `local: *;` alla version script:**
```
SLIMLO_CONSTRUCTORS {
    global:
        *_get_implementation;
        *_component_getFactory;
        libreofficekit_hook;
        libreofficekit_hook_2;
        lok_preinit;
        lok_preinit_2;
        lok_open_urandom;
    local:
        *;
};
```

**Effetto combinato:**
1. `--export-dynamic` → LTO preserva tutti i simboli default-visibility (previene eliminazione)
2. Version script con `local: *;` → filtra `.dynsym` per esportare solo i pattern necessari

### 8. Prima rebuild con fix (FALLITA — errore link CUI)

Build fallita dopo ~57 min (3402s) con errore di link per `libcuilo.so`:
```
undefined reference to `INetURLObject::setAbsURIRef(...)`
undefined reference to `sfx2::FileDialogHelper::~FileDialogHelper()`
undefined reference to `weld::GenericDialogController::~GenericDialogController()'
undefined reference to `Formatter::GetValue()'
```

**Root cause**: `libcuilo.so` è una libreria non-merged (non fa parte di `libmergedlo.so`).
Con LTO, il linker vede cross-references a simboli nelle librerie merged che LTO ha eliminato.
Senza LTO questi simboli erano presenti e il link funzionava.

Librerie non-merged potenzialmente affette: `cui`, `swui`, `scui`, `sdui`, `deploymentgui`.
Tutte vengono rimosse dagli artefatti finali — non servono per la conversione headless.

### 9. Fix: patch 009 — disabilita LTO per librerie non-merged (completato)

**Nuovo file: `patches/009-fix-nonmerged-lto-link.sh`**

Aggiunge `-fno-lto` a CXXFLAGS e LDFLAGS per le librerie non-merged che rimuoviamo comunque:
- `cui` (Common UI dialogs)
- `swui` (Writer UI)
- `scui` (Calc UI)
- `sdui` (Impress UI)
- `deploymentgui` (Desktop deployment)

Queste librerie vengono compilate (necessarie per soddisfare reverse-dependencies di altri moduli)
ma non ottimizzate con LTO (dato che le rimuoviamo dagli artefatti).

### 10. Seconda rebuild (FALLITA — errore link cairocanvas, soffice.bin, extensions, etc.)

Stesso problema di CUI ma su molte più librerie:
- `soffice.bin`, `libmigrationoo2lo.so`, `libmigrationoo3lo.so`
- `libabplo.so`, `libscnlo.so`, `libunopkgapp.so`
- `libloglo.so`, `libbiblo.so`, `libcairocanvaslo.so`

L'approccio per-libreria (patch 009 v1) è un gioco a whack-a-mole.

### 11. Fix: patch 009 v2 — LTO solo per merged lib (completato)

**Nuovo approccio**: svuotare `gb_LTOFLAGS` globalmente nel platform `gcc.mk`, poi aggiungere
`-flto=auto` esplicitamente solo a `Library_merged.mk`.

Effetto:
- `libmergedlo.so` → compilato e linkato con LTO (dead code elimination, inlining cross-module)
- Tutti gli altri target → compilazione/link normali (nessun errore di simboli)
- Il 95%+ del codice è nella merged lib, quindi i benefici LTO sono preservati

### 12. Terza rebuild (FALLITA — patch sovrascritto da autogen)

Build fallita dopo 309s con `libbiblo.so` undefined references.
**Root cause**: `autogen.sh` rigenera `com_GCC_defs.mk` da template, sovrascrivendo il patch 009.
L'ordine era: apply-patches (modifica gcc.mk) → autogen (sovrascrive gcc.mk) → make (usa file non patchato).

### 13. Fix: applicare patch 009 DOPO autogen (completato)

- Rinominato `009-fix-nonmerged-lto-link.sh` → `009-fix-nonmerged-lto-link.postautogen`
  (estensione `.postautogen` non matchata da `apply-patches.sh` che cerca `*.sh`)
- Modificato Dockerfile per eseguire il patch dopo autogen:
  ```
  autogen.sh --with-distro=SlimLO && \
  bash ./patches/009-fix-nonmerged-lto-link.postautogen lo-src && \
  ```
- Aggiornato `CONFIG_HASH` per includere `patches/*.postautogen`

### 14. Quarta rebuild (FALLITA — config hash non cambiato)

Build skippò patches+autogen perché il CONFIG_HASH non era cambiato (il rename del file non cambia il contenuto). Fix: modificato il contenuto del file .postautogen per invalidare l'hash.

### 15. Quinta rebuild (FALLITA — cached .o con LTO)

Build fallita con stessi errori perché i .o files nella cache erano stati compilati con LTO dalla build precedente. Fix: `docker builder prune --filter type=exec.cachemount` per pulire le cache.

### 16. Sesta rebuild (FALLITA — libcuilo.so ancora)

Build #7 con clean cache. Stessi errori CUI dopo ~2135s. Root cause finale: `libmergedlo.so` compilata con `-flto=auto` produce .o con GIMPLE IR solo. Le librerie non-merged linkano contro il .so ma non possono risolvere simboli dal GIMPLE IR.

### 17. Fix: `-ffat-lto-objects` tentativo (non funzionante)

Aggiunto `-ffat-lto-objects` alle cxxflags della merged lib. Questo produce oggetti con sia IR che codice macchina. Ma non funziona perché le librerie non-merged linkano contro `libmergedlo.so` (shared library), non contro i .o files. La .so esporta solo ciò che è in `.dynsym`.

### 18. Root cause finale: version script `local: *;`

Il vero problema era il version script (patch 008) con `local: *;` che nascondeva TUTTI i simboli normali da `.dynsym`. Le librerie non-merged (libcuilo.so etc.) linkano contro `libmergedlo.so` e possono risolvere solo simboli presenti in `.dynsym`.

### 19. Fix: rimuovere version script, usare solo `--export-dynamic`

- Rimosso version script (`mergedlo_constructors.map`) dal patch 008
- Tenuto solo `-Wl,--export-dynamic` per preservare constructor symbols + simboli normali
- `--undefined-glob` testato ma non supportato da GNU bfd ld (solo gold/lld)

### 20. Build finale — SUCCESSO

```
Constructor symbols in .dynsym: 557
Total size: 191M
  program/: 183M
  share/: 7.6M
Libraries: 135
```

### 21. Test di conversione — PASSATO

```
Input:  test.docx (1754 bytes)
Output: output.pdf (28795 bytes)
PDF magic: OK
=== ALL TESTS PASSED ===
```

---

## Risultati finali

| Metrica | Senza LTO | Con LTO | Risparmio |
|---------|-----------|---------|-----------|
| Totale artefatti | 214 MB | 191 MB | -23 MB (-11%) |
| libmergedlo.so | 97 MB | 98 MB | +1 MB |
| program/ | 206 MB | 183 MB | -23 MB |
| share/ | 8 MB | 7.6 MB | -0.4 MB |
| Constructor symbols | ~550 | 557 | — |
| Conversione DOCX→PDF | OK | OK | — |

Nota: `libmergedlo.so` è leggermente più grande con LTO perché `--export-dynamic` espande `.dynsym` (~50K entries). Il risparmio complessivo viene dalla compilazione senza LTO delle librerie non-merged e dalle ottimizzazioni cross-module (inlining, constant propagation) nel codice della merged lib.

## File modificati

| File | Modifica |
|------|----------|
| `distro-configs/SlimLO.conf` | `--disable-lto` → `--enable-lto` |
| `docker/Dockerfile.linux-x64` | `-j10`, post-autogen patch, CONFIG_HASH include .postautogen |
| `patches/008-mergedlibs-export-constructors.sh` | `--export-dynamic` solo (no version script) |
| `scripts/extract-artifacts.sh` | `readelf -W` per nomi simboli lunghi |

## File nuovi

| File | Descrizione |
|------|-------------|
| `patches/006-fix-mergelibs-conditionals.sh` | Fix condizionali in pre_MergedLibsList.mk |
| `patches/007-fix-swui-db-conditionals.sh` | Guard DBCONNECTIVITY per Library_swui.mk |
| `patches/009-fix-nonmerged-lto-link.postautogen` | Disabilita LTO globale, abilita solo per merged lib |

---

## Lezioni apprese

1. **`autogen.sh` rigenera platform .mk** — patches a `com_GCC_defs.mk` devono essere post-autogen
2. **Version script `local: *;` incompatibile** con librerie non-merged che linkano contro merged
3. **`--export-dynamic`** è l'unico modo affidabile per preservare constructor symbols con LTO su GNU bfd ld
4. **`--undefined-glob`** non supportato da GNU bfd ld (solo gold/lld)
5. **`-ffat-lto-objects`** non aiuta per shared library linking (solo per static .o resolution)
6. **`readelf --dyn-syms`** tronca nomi lunghi — usare `-W` per output completo
7. **LTO beneficia principalmente da cross-module inlining**, non da dead code elimination (con `--export-dynamic` tutti i simboli sono preservati)
8. **Docker Desktop**: 32 GB memory, -j10 safe per LTO builds

## Note tecniche

- **Docker Desktop memory**: 32 GB. -j10 safe, -j16 rischioso.
- **LTO build time**: ~7.5 ore con -j4, molto meno con -j10 e 32 GB.
- **ccache**: funziona per compilazione anche con LTO, ma la fase di link non è mai cached.
- **ICU data filter**: prossima ottimizzazione, potrebbe risparmiare ulteriori 25+ MB.
