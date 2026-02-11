# SlimLO Artifact Analysis — Librerie .so necessarie

## Panoramica

| Tipo | Conteggio | Dimensione |
|------|-----------|------------|
| Stub .so (21 bytes) | 82 | ~1.7 KB |
| Librerie reali | 55 | 181 MB |
| **Totale** | **137** | **~181 MB** |

Gli **stub** (21 bytes ciascuno) sono necessari: UNO controlla l'esistenza del file prima di cercare il simbolo in `libmergedlo.so`.

---

## Librerie reali per categoria

### 1. Merged lib (97 MB)

| Libreria | Dimensione | Descrizione |
|----------|------------|-------------|
| `libmergedlo.so` | 97.4 MB | ~150 moduli LO fusi: VCL, SFX, SVX, editeng, drawinglayer, configmgr, xmloff, toolkit, chart2, etc. |

### 2. Writer (25 MB)

| Libreria | Dimensione | Descrizione |
|----------|------------|-------------|
| `libswlo.so` | 19.5 MB | Modulo Writer (non-merged). Modello documento. |
| `libsw_writerfilterlo.so` | 3.1 MB | Filtro import OOXML per Writer (.docx parsing) |
| `libmswordlo.so` | 2.6 MB | Supporto formato MS Word (.doc + codice condiviso DOCX) |
| `libswdlo.so` | 67 KB | Writer document factory (UNO service) |

### 3. ICU — International Components for Unicode (36 MB)

| Libreria | Dimensione | Descrizione |
|----------|------------|-------------|
| `libicudata.so.77` | 30.4 MB | Dati locale/Unicode. Richiesto da libicuuc. |
| `libicui18n.so.77` | 3.5 MB | Internazionalizzazione (collation, formatting) |
| `libicuuc.so.77` | 2.1 MB | Operazioni Unicode comuni |

### 4. UNO Runtime (3 MB)

| Libreria | Dimensione | Descrizione |
|----------|------------|-------------|
| `libuno_cppuhelpergcc3.so.3` | 1.1 MB | UNO C++ helper |
| `libuno_sal.so.3` | 453 KB | System Abstraction Layer |
| `libunoidllo.so` | 387 KB | UNO IDL type support |
| `libuno_cppu.so.3` | 195 KB | UNO C++ binding runtime |
| `libstocserviceslo.so` | 195 KB | Standard Components (STOC) |
| `libbinaryurplo.so` | 196 KB | UNO Remote Protocol bridge |
| `libreflectionlo.so` | 260 KB | UNO type reflection |
| `libintrospectionlo.so` | 195 KB | UNO introspection service |
| `libreglo.so` | 131 KB | UNO type registry |
| `libstorelo.so` | 131 KB | UNO storage (rdb file reading) |
| `libinvocationlo.so` | 131 KB | UNO invocation service |
| `libinvocadaptlo.so` | 67 KB | UNO invocation adaptor |
| `libgcc3_uno.so` | 67 KB | UNO GCC3 C++ language bridge |
| `libaffine_uno_uno.so` | 66 KB | UNO affine bridge (same-thread) |
| `libunsafe_uno_uno.so` | 66 KB | UNO unsafe bridge (cross-thread) |
| `libuno_salhelpergcc3.so.3` | 67 KB | SAL helper |
| `libuno_purpenvhelpergcc3.so.3` | 66 KB | UNO purpose environment helper |
| `libbootstraplo.so` | 580 KB | Bootstrap services (component context, service manager) |
| `libiolo.so` | 325 KB | UNO I/O streams/pipes |

### 5. XML e Text Processing (2 MB)

| Libreria | Dimensione | Descrizione |
|----------|------------|-------------|
| `libxml2.so.16` | 1.3 MB | XML parsing. NEEDED da libmergedlo.so |
| `libsaxlo.so` | 516 KB | SAX XML parser service |
| `libxslt.so.1` | 261 KB | XSLT transformation |
| `libxmlreaderlo.so` | 66 KB | LO XML reader wrapper |

### 6. Rendering (3 MB)

| Libreria | Dimensione | Descrizione |
|----------|------------|-------------|
| `libcairo-lo.so.2` | 1.1 MB | Cairo 2D graphics (VCL headless backend) |
| `libcairocanvaslo.so` | 645 KB | LO canvas implementation via Cairo |
| `libpixman-1.so.0` | 643 KB | Pixel manipulation (dep di Cairo) |
| `liblcms2.so.2` | 400 KB | Color management (ICC profiles per PDF) |

### 7. Helpers e Infrastruttura (5 MB)

| Libreria | Dimensione | Descrizione |
|----------|------------|-------------|
| `libcomphelper.so` | 1.8 MB | Component helper utilities |
| `libsal_textenclo.so` | 1.6 MB | Text encoding conversion tables (codepages) |
| `libbasegfxlo.so` | 644 KB | Base graphics library |
| `libtllo.so` | 582 KB | Tools library |
| `libucbhelper.so` | 580 KB | UCB helper utilities |
| `libi18nlangtag.so` | 195 KB | Language tag handling |
| `liblangtag-lo.so.1` | 197 KB | BCP47 language tag library |
| `liblocaledata_en.so` | 450 KB | Dati locale inglese (number/date formatting) |

### 8. PDF Output (0.3 MB)

| Libreria | Dimensione | Descrizione |
|----------|------------|-------------|
| `libpdffilterlo.so` | 333 KB | Filtro export PDF. Essenziale. |

### 9. SlimLO API (0.1 MB)

| Libreria | Dimensione | Descrizione |
|----------|------------|-------------|
| `libslimlo.so.0.1.0` | 74 KB | C API wrapper per LOKit |
| `libslimlo.so.0` | symlink | |
| `libslimlo.so` | symlink | |

### 10. Dipendenze transitive (1.7 MB)

Richieste come NEEDED da `libmergedlo.so` — il dynamic linker rifiuta di caricare la merged lib senza di esse.

| Libreria | Dimensione | Descrizione |
|----------|------------|-------------|
| `librasqal-lo.so.3` | 520 KB | RDF query library |
| `libraptor2-lo.so.0` | 326 KB | RDF parser (Raptor2) |
| `librdf-lo.so.0` | 262 KB | Redland RDF library |
| `libloglo.so` | 196 KB | Logging service |
| `libcached1.so` | 323 KB | UCP cached content provider |
| `libstoragefdlo.so` | 67 KB | File-descriptor storage service |
| `libgraphicfilterlo.so` | 67 KB | Graphic filter (per immagini embedded) |
| `libucppkg1.so` | 260 KB | UCP package content provider |

### 11. Potenzialmente rimovibile (4.6 MB)

| Libreria | Dimensione | Descrizione | Note |
|----------|------------|-------------|------|
| `libcurl.so.4` | 4.6 MB | HTTP client | Mai usato per conversione locale. Ma è NEEDED da libmergedlo.so → non eliminabile senza patchelf o stub |

---

## Stub .so files (82 file, 21 bytes ciascuno)

Necessari per UNO component loading. Il codice effettivo è in `libmergedlo.so`.

```
libavmedialo.so       libconfigmgrlo.so    libembobj.so          libfsstoragelo.so
libbasctllo.so        libcppcanvaslo.so    libemboleobj.so       libfwklo.so
libbasprovlo.so       libctllo.so          libemfiolo.so         libguesslanglo.so
libcanvasfactorylo.so libdbtoolslo.so      libevtattlo.so        libhyphenlo.so
libcanvastoolslo.so   libdeployment.so     libfilterconfiglo.so  libi18npoollo.so
libchart2lo.so        libdeploymentmisclo.so libforlo.so          libi18nsearchlo.so
                      libdesktopbe1lo.so   libforuilo.so         libi18nutil.so
                      libdocmodello.so     libfps_officelo.so    liblnglo.so
                      libdrawinglayercorelo.so                   liblnthlo.so
                      libdrawinglayerlo.so                       liblocalebe1lo.so
                      libeditenglo.so                            ...
```

(Lista completa: 82 file. Aggiungono solo ~1.7 KB totali.)

---

## Catena di dipendenze DOCX→PDF

```
libslimlo.so
  └→ libmergedlo.so (LOKit entry point)
       ├→ libxml2.so.16, libxslt.so.1 (XML)
       ├→ libicuuc.so.77, libicui18n.so.77, libicudata.so.77 (Unicode)
       ├→ libcairo-lo.so.2 → libpixman-1.so.0 (rendering)
       ├→ liblcms2.so.2 (color management)
       ├→ libcurl.so.4 (HTTP, non usato ma NEEDED)
       ├→ librdf-lo.so.0 → libraptor2-lo.so.0, librasqal-lo.so.3 (RDF, non usato ma NEEDED)
       └→ libuno_sal.so.3, libuno_cppu.so.3, etc. (UNO runtime)

  Caricati dinamicamente da UNO:
       ├→ libswlo.so (Writer document model)
       ├→ libsw_writerfilterlo.so (DOCX import)
       ├→ libmswordlo.so (MS Word format)
       ├→ libpdffilterlo.so (PDF export)
       ├→ libsal_textenclo.so (text encodings)
       ├→ liblocaledata_en.so (English locale)
       ├→ libcairocanvaslo.so (canvas rendering)
       └→ 82 stub .so → fallback a libmergedlo.so
```

---

## Ottimizzazioni possibili

### 1. ICU Data Filter (risparmio ~25-28 MB) — ALTA priorita

`libicudata.so.77` contiene dati per **tutti** i locale del mondo (30.4 MB).
Per conversione DOCX→PDF servono solo i locale europei/inglesi.

**Approccio**: ricostruire ICU con un file di filtro personalizzato:
```json
{
  "localeFilter": {
    "filterType": "language",
    "includelist": ["en", "de", "fr", "it", "es", "pt", "nl"]
  }
}
```
**Risultato atteso**: 30 MB → ~2-5 MB.
**Difficolta**: Alta — richiede custom ICU build nel Dockerfile.

### 2. Stub libcurl.so.4 (risparmio ~4.6 MB) — MEDIA priorita

`libcurl.so.4` è NEEDED da `libmergedlo.so` ma mai usato per conversione locale.

**Opzioni**:
- `patchelf --remove-needed libcurl.so.4 libmergedlo.so` (rapido, fragile)
- Creare uno stub .so con 9 simboli no-op (curl_easy_init, etc.)
- Ricostruire senza i moduli UCB HTTP (--disable-online-update + strip ucpdav1)

### 3. Stub RDF stack (risparmio ~1.1 MB) — BASSA priorita

`librdf-lo.so.0` + `libraptor2-lo.so.0` + `librasqal-lo.so.3` sono NEEDED ma usati solo per metadati ODF.

**Opzioni**: come libcurl — patchelf o stub con ~64 simboli no-op.

### Riepilogo potenziale

| Azione | Risparmio | Da → A | Difficolta |
|--------|-----------|--------|------------|
| ICU data filter | ~25-28 MB | 191 → ~163 MB | Alta |
| Stub libcurl | ~4.6 MB | → ~159 MB | Media |
| Stub RDF stack | ~1.1 MB | → ~158 MB | Bassa |
| **Totale** | **~31-34 MB** | **191 → ~158 MB** | |

---

## Librerie assenti (correttamente escluse)

Le seguenti librerie non-merged sono state correttamente escluse dagli artefatti:
- `libsclo.so` (Calc)
- `libsdlo.so` (Impress)
- `libscuilo.so` (Calc UI)
- `libsduilo.so` (Impress UI)
- `libswuilo.so` (Writer UI)
- `libvbaswobjlo.so` (VBA Writer)
- `libvbaobjlo.so` (VBA Calc)
- `libscfiltlo.so` (Calc filters)
- `libcuilo.so` (Common UI dialogs)
