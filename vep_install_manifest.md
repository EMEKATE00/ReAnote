# VEP Installation Manifest — Source Audit

- **Generated**: 2026-07-16 (live audit of the installation at the time)
- **Source machine**: installation at `/mnt/d/v4/annotation/` (WSL2)
- **Purpose**: serve as the exact baseline to reproduce `ReAnote/data/ensembl-vep/`
  and `ReAnote/data/.vep/` identically on any computer.
- **Scope**: does NOT cover `ReAnote/data/custom/` (ClinVar, gnomAD, RegulomeDB) —
  that's outside this audit and the installation it generates.

---

## 1. ensembl-vep version

Confirmed by running `vep --help` **inside the `phase4_env` conda
environment** (outside that environment, `perl vep --help` fails due to
unresolved Perl modules — see section 4).

```
ensembl              : 115.266b84d
ensembl-compara      : 115.ae48a7a
ensembl-funcgen      : 115.57f7061
ensembl-io           : 115.25061d3
ensembl-variation    : 115.b7c2637
ensembl-vep          : 115.2
```

`ensembl-vep/` git info:

| Field | Value |
|---|---|
| Remote | `https://github.com/Ensembl/ensembl-vep.git` |
| `git log -1 --oneline` | `2beada0d Subversion update (#1926)` |
| `git describe --tags` | `release/115.2` |

**Tag to use for the exact checkout: `release/115.2`**

---

## 2. Cache version / species / assembly

**3 caches** were found installed under `.vep/`, all `115_GRCh38`:

| Folder | Type | Size | Used by the current scripts? |
|---|---|---|---|
| `homo_sapiens/115_GRCh38` | standard (Ensembl) | 24G | No |
| `homo_sapiens_merged/115_GRCh38` | **merged** (Ensembl+RefSeq) | 26G | **Yes** |
| `homo_sapiens_refseq/115_GRCh38` | RefSeq | 24G | No |

Confirmed by grepping `phase4.sh` and `rute_1.sh`:

```
--offline --cache --dir_cache "$VEP_CACHE" \
--merged \
```

`VEP_CACHE` points to `.vep` (not a species subfolder); the `--merged` flag
is what makes VEP internally resolve to `homo_sapiens_merged/<version>_GRCh38`.
**Confirmed: the cache actually used by the pipeline is
`homo_sapiens_merged`, version `115`, assembly `GRCh38`.**

Relevant metadata from `homo_sapiens_merged/115_GRCh38/info.txt`:
- `source_gencode`: GENCODE 49
- `source_genebuild`: GENCODE49
- `source_refseq`: GCF_000001405.40-RS_2024_08
- `source_assembly`: GRCh38.p14
- `source_dbSNP`: 156
- `source_ClinVar`: 202502
- `source_gnomADe` / `source_gnomADg`: v4.1
- `regulatory`: 1 (includes the regulatory build)

> Note: the `homo_sapiens` (standard) and `homo_sapiens_refseq` caches
> exist on disk but **are not referenced by any current script**. They are
> not included in the Phase 1 install script unless otherwise confirmed —
> installing all three would mean ~74G extra with no known use.

---

## 3. Plugins present

### 3.1. Full list of `.pm` files in `Plugins/` (root)

26 files in the root + 4 in `Plugins/loftee/` (LoFtee's own
duplicates/variants) + 1 in `Plugins/Data/UTRannotator/`:

| File | Size (bytes) |
|---|---|
| AlphaMissense.pm | 10884 |
| BayesDel.pm | 4501 |
| CADD.pm | 8932 |
| Conservation.pm | 11858 |
| DosageSensitivity.pm | 5797 |
| EVE.pm | 5589 |
| GeneBe.pm | 6552 |
| LOEUF.pm | 7080 |
| LOVD.pm | 3773 |
| LoF.pm | 24382 |
| LoFtool.pm | 3126 |
| MaxEntScan.pm | 27442 |
| NMD.pm | 5831 |
| NearestGene.pm | 4928 |
| PhenotypeOrthologous.pm | 7331 |
| REVEL.pm | 7412 |
| SpliceAI.pm | 12666 |
| TissueExpression.pm | 3591 |
| UTRAnnotator.pm | 7444 |
| ancestral.pm | 2019 |
| context.pm | 1196 |
| dbNSFP.pm | 18483 |
| dbscSNV.pm | 6343 |
| mutfunc.pm | 12983 |
| pLI.pm | 6533 |
| satMutMPRA.pm | 8942 |

`Plugins/loftee/` subfolder (LoFtee-specific copies, not from the
`VEP_plugins` repo): `ancestral.pm`, `context.pm`, `LoF.pm`, `TissueExpression.pm`.

`Plugins/Data/UTRannotator/` subfolder: `UTRAnnotator.pm`.

### 3.2. ⚠️ Discrepancy found: `SpliceRegion.pm` does not exist

The `phase4.sh` and `rute_1.sh` scripts invoke `--plugin SpliceRegion`, but
**there is no `SpliceRegion.pm` in the current installation** (exhaustive
search under `.vep/Plugins/` found nothing). `SpliceRegion` is a standard
plugin from the `Ensembl/VEP_plugins` repo with no external data
dependencies (it only uses the transcript model), so a full clone of the
repo would resolve it automatically. **This is documented here as a
discrepancy to fix in Phase 1**, without speculating on why it's missing
upstream.

### 3.3. Real git origin of `Plugins/.git`

`Plugins/.git` is **not a clone of `Ensembl/VEP_plugins`** — it's a clone
of the LoFtee plugin:

| Field | Value |
|---|---|
| Remote | `https://github.com/konradjk/loftee.git` |
| `git log -1 --oneline` | `a46b502 Skip calculation of 50_BP_RULE and add NO_EXON_NUMBER flag...` |
| `git describe --tags` | `v1.0.4_GRCh38` |
| Location on disk | cloned directly into the root of `Plugins/`, with an additional copy in `Plugins/loftee/` |

Practical consequence: the loose `.pm` files in the root of `Plugins/`
(AlphaMissense, CADD, REVEL, SpliceAI, dbNSFP, etc.) **don't have a
verifiable git commit of their own** — they were copied individually from
`Ensembl/VEP_plugins`, not cloned as a repo. Ensembl's convention is that
`VEP_plugins`' tag matches the VEP version (`release/115`, equivalent to
`ensembl-vep`'s `115.2` tag). **The tag/branch matching version 115 of
`Ensembl/VEP_plugins` will be used as the source, and the resulting list of
`.pm` files will be compared against the table in 3.1 at the end of the
install (Phase 1, step 4) to detect any difference** (including the
current absence of `SpliceRegion.pm`).

`loftee` will be cloned separately from `konradjk/loftee.git` at tag
`v1.0.4_GRCh38`.

> Note: `LoF.pm`/`loftee` is present on disk but **doesn't appear invoked
> in `phase4.sh` or `rute_1.sh`** (there's no `--plugin LoF` in either).
> Its presence is documented but it is not confirmed that the current
> pipeline uses it.

---

## 4. Perl dependencies (CPAN modules)

### 4.1. Required by `ensembl-vep/cpanfile`

```
requires 'DBI';
requires 'Set::IntervalTree';
requires 'JSON';
requires 'Text::CSV';
recommends 'DBD::mysql', '<= 4.050';
recommends 'PerlIO::gzip';
recommends 'IO::Uncompress::Gunzip';
recommends 'Bio::DB::BigFile';
recommends 'Sereal';
recommends 'HTML::Lint';
recommends 'Capture::Tiny';
```

`INSTALL.pl` also manages installing `Bio::DB::HTS` (+ bundled htslib) as a
separate step (not via cpanfile), controllable with `--NO_HTSLIB`.

### 4.2. Real state in the functional environment (`conda activate phase4_env`, Perl 5.32.1)

Verified with `perl -M<Module> -e1` one at a time:

| Module | Status | Detected version |
|---|---|---|
| DBI | ✅ installed | 1.643 |
| DBD::mysql | ✅ installed | 4.050 (matches the cpanfile's `<= 4.050` pin) |
| Set::IntervalTree | ✅ installed | 0.12 |
| JSON | ✅ installed | 4.10 |
| Text::CSV | ✅ installed | 2.01 |
| PerlIO::gzip | ✅ installed | 0.20 |
| IO::Uncompress::Gunzip | ✅ installed | 2.214 |
| Bio::DB::BigFile | ✅ installed | 1.07 |
| Sereal | ✅ installed | 5.004 |
| HTML::Lint | ❌ not installed | — (only `recommends`, non-blocking) |
| Capture::Tiny | ✅ installed | 0.48 |
| Bio::DB::HTS | ✅ installed | 3.01 |
| Bio::DB::HTS::Faidx | ✅ installed | 3.01 |
| Archive::Zip | ❌ not installed | — (not referenced in `cpanfile`; non-blocking for this install) |

`samtools` (used by `phase2.sh`, not directly by VEP): `1.21`
(htslib 1.21), available in `phase4_env`.

**Conclusion**: the real functional install requires, at minimum, the 12
modules marked ✅. `HTML::Lint` and `Archive::Zip` aren't present and the
environment works correctly without them — they'll still be installed by
the Phase 1 script for completeness (they're `recommends`/standard
INSTALL.pl items) but aren't treated as blocking if their install fails.

---

## 5. Genomic reference used by VEP

Path: `reanote/referencias/hg38/` (inside `ReAnote/data/reanote/referencias/hg38/`)

| File | Size | Status |
|---|---|---|
| `Homo_sapiens_assembly38.fasta` | 3,249,912,778 bytes (3.1G) | ✅ exists |
| `Homo_sapiens_assembly38.fasta.fai` | 160,928 bytes | ✅ exists |
| `Homo_sapiens_assembly38.dict` | 581,712 bytes | ✅ exists |

**All three files VEP/WhatsHap need (`--fasta`, `--reference`) are already
complete and indexed.** No index is missing for what `phase4.sh`/`rute_1.sh`
(`--fasta "$REF_HG38"`) or WhatsHap (`--reference "$REF_HG38"`) use.

> Note: that folder also has the BWA indices (`.amb`, `.ann`, `.bwt`,
> `.pac`, `.sa`, `.0123`) used by `phase1.sh` for alignment — these aren't
> needed for VEP and aren't touched by the Phase 1 script, which only
> covers `ensembl-vep`/`.vep`. The FASTA and its `.fai`/`.dict` indices are
> covered because VEP needs them directly.

md5 of `Homo_sapiens_assembly38.fasta.fai` (for a quick cross-check without
having to hash the full 3.1G FASTA):
```
f76371b113734a56cde236bc0372de0a
```

---

## 6. Explicitly out of scope for this phase (NONE of this is downloaded)

Plugin data — heavy third-party downloads, all present in the source
installation under `.vep/Plugins/` but **excluded** from
`install_vep_engine.sh`:

| Resource | Source path | Size |
|---|---|---|
| CADD (snvs + indels) | `Plugins/CADD/` | 82G |
| dbNSFP 5.3a GRCh38 | `Plugins/Data/dbNSFP5.3a_grch38.gz` | 49G (51,902,142,316 bytes) |
| SpliceAI indel scores | `Plugins/Data/spliceai_scores.raw.indel.hg38.vcf.gz` | 65G (69,322,106,029 bytes) |
| EVE | `Plugins/EVE/` | 77G |
| SpliceAI SNV scores | `Plugins/Data/spliceai_scores.raw.snv.hg38.vcf.gz` | 27G (28,829,788,377 bytes) |
| Conservation (GERP/PhyloP/PhastCons bigwigs) | `Plugins/Conservation/` | 24G |
| REVEL | `Plugins/REVEL/` | 15G |
| mutfunc | `Plugins/mutfunc/` | 2.0G |
| AlphaMissense | `Plugins/AlphaMissense/` | 614M |
| dbscSNV 1.1 GRCh38 | `Plugins/Data/dbscSNV1.1_GRCh38.txt.gz` | 335M (351,249,789 bytes) |
| satMutMPRA | `Plugins/satMutMPRA/` | 2.8M |
| MaxEntScan (data) | `Plugins/Data/MaxEntScan/` | 4.1M |
| UTRAnnotator (data) | `Plugins/Data/UTRannotator/` | 9.8M |
| loftee_data | `Plugins/Data/loftee_data/` | (included in the Data block, not measured separately) |

**Approximate total of out-of-scope heavy data: ~300G+.**

These will be handled in a later, separate phase (heavy data migration via
`tar`/direct copy), as already anticipated by `ReAnote/README.md`. The
Phase 1 script (`install_vep_engine.sh`) leaves the corresponding folders
(`Plugins/CADD/`, `Plugins/Data/`, etc.) **empty/not created**, except for
the minimal substructure that already exists under
`ReAnote/data/.vep/Plugins/Data/` (an empty folder with `.gitkeep`).

`ReAnote/data/custom/` (ClinVar, gnomAD, RegulomeDB) is also never touched
— it's a data tree independent from the VEP plugins/cache one and
completely out of scope for this task.

---

## Actionable summary — values to fix in Phase 1

| Parameter | Confirmed value |
|---|---|
| `ensembl-vep` tag | `release/115.2` |
| Species | `homo_sapiens` |
| Assembly | `GRCh38` |
| Cache type | `merged` (confirmed by the `--merged` usage in the scripts) |
| Cache version | `115` |
| `VEP_plugins` tag (Ensembl) | matching release `115` — check the available tags on `Ensembl/VEP_plugins` at clone time, since there's no exact commit capturable from upstream (see 3.3) |
| `loftee` tag | `v1.0.4_GRCh38` (remote `konradjk/loftee.git`) — present upstream but not used by the current scripts; optional |
| Target FASTA | `Homo_sapiens_assembly38.fasta`, 3,249,912,778 bytes, with `.fai` (160,928 bytes) and `.dict` (581,712 bytes) |
| Discrepancy to resolve | `SpliceRegion.pm` missing upstream despite being invoked by the scripts — a full clone of `VEP_plugins` release 115 should include it |

## Decisions confirmed by the user (post manifest review)

1. **`VEP_plugins` source**: `https://github.com/Ensembl/VEP_plugins.git`
   will be cloned and checked out at the tag/branch matching release `115`
   (same versioning as `ensembl-vep`), instead of leaving it on `main`
   unpinned. The script will compare the resulting list of `.pm` files
   against the table in section 3.1 and warn about any difference.
2. **`SpliceRegion.pm`**: will be installed normally as part of the full
   `VEP_plugins` clone. This fixes the discrepancy found in 3.2 — the new
   installation ends up more complete than the audited source, with no
   risk, since `SpliceRegion` has no external data dependencies.
