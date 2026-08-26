# Installing the Data — Complete Guide

> This is the long, detailed reference for reconstructing everything under
> `ReAnote/data/` and `ReAnote/engine/` from scratch on a brand-new
> computer, with no portable disk to copy from. If you already have the
> portable disk, you don't need any of this — see the main
> [`README.md`](README.md) instead.

**Status: work in progress.** This is a first template built from the real
audit already done on this project (see
[`vep_install_manifest.md`](vep_install_manifest.md) and
[`scripts/setup/`](scripts/setup/)) plus Ensembl's official documentation.
It will keep growing and getting filled in with more detail over time.

---

## Table of contents

1. [Why this exists: the portable-disk design](#1-why-this-exists-the-portable-disk-design)
2. [Versions to target](#2-versions-to-target)
3. [The folder structure everything expects](#3-the-folder-structure-everything-expects)
4. [Installing VEP itself](#4-installing-vep-itself)
5. [The VEP cache](#5-the-vep-cache)
6. [Installing plugins](#6-installing-plugins)
7. [Custom annotation tracks (`--custom`)](#7-custom-annotation-tracks---custom)
8. [Plugins vs. custom tracks: which to use for what](#8-plugins-vs-custom-tracks-which-to-use-for-what)
9. [Packaged runtime environments: how and why](#9-packaged-runtime-environments-how-and-why)
10. [Open items / not yet covered](#10-open-items--not-yet-covered)

---

## 1. Why this exists: the portable-disk design

ReAnote was built with one specific constraint in mind: **the whole
pipeline, including every reference dataset and annotation source VEP
needs, has to live and run from a single portable external hard drive**,
without installing or copying anything onto each computer's local disk.
That constraint shapes almost every design decision documented in this
file:

- **Everything lives under `data/` and `engine/` on the disk itself**, not
  under `$HOME` or any system path — so the exact same disk works
  identically on any computer it's plugged into, with no per-machine setup
  beyond installing WSL2 once (see the main `README.md`).
- **The runtime environments are pre-resolved and packaged** (`engine/*.sqfs`
  / `*.tar.gz`, see [section 9](#9-packaged-runtime-environments-how-and-why))
  instead of relying on `conda install` at use time, so a brand-new
  computer with no internet access can still run a re-annotation the
  moment the disk is connected.
- **Every dataset that VEP needs (cache, plugin data, custom tracks like
  ClinVar/gnomAD) is downloaded once and stored on the disk**, never
  fetched at runtime — VEP always runs with `--offline`.
- The tradeoff of this design is size: the fully-populated `data/` folder
  is on the order of a terabyte (see [section 6](#6-installing-plugins) and
  [section 7](#7-custom-annotation-tracks---custom) for the breakdown by
  resource). That's the price of true portability — no dataset is ever
  re-downloaded or re-resolved per machine.

This document exists because **that data can't be committed to the GitHub
repository** (GitHub isn't built for hundreds of GB of genomic data). What
*is* in the repository is all the code: `reanotar.sh`, the phase scripts,
the GUI, and — critically — the installation scripts under
[`scripts/setup/`](scripts/setup/) that know how to rebuild `data/` from
scratch, using only public/official download sources. This guide documents
what those scripts do and why, and adds any detail they don't already cover
in their own comments.

---

## 2. Versions to target

Before installing anything, these are the exact versions this project was
built and validated against. Deviating from them (e.g. a newer VEP cache
release) means re-validating the whole pipeline — see
[`README.md`](README.md#exact-versions-used-in-the-reference-installation)
for the full table including the base system (WSL, PowerShell, RStudio)
and the `gatk_env` tool versions (GATK, BWA, samtools, Java).

| Component | Version to install |
|---|---|
| `ensembl-vep` | `115.2` (git tag `release/115.2`) |
| Ensembl Core API (`ensembl`, `ensembl-variation`, `ensembl-io`, `ensembl-funcgen`) | branch `release/115` |
| `Ensembl/VEP_plugins` | branch `release/115` (Ensembl versions this repo by branch, not by git tag — see [section 6](#6-installing-plugins)) |
| VEP cache | `homo_sapiens_merged`, version `115`, assembly `GRCh38` (GRCh38.p14) |
| Reference FASTA | `Homo_sapiens_assembly38.fasta` (Broad's hg38 reference, same one GATK uses) |
| CADD | `v1.6` (deliberately, not the current v1.7 — see [section 6](#6-installing-plugins)) |
| Perl | `5.32.1` |

The full rationale for each of these — why this exact tag, what was
verified and how — is in [`vep_install_manifest.md`](vep_install_manifest.md).

---

## 3. The folder structure everything expects

Every script in this project (`reanotar.sh`, `phase1-4.sh`, `rute_1.sh`,
and the `scripts/setup/*.sh` installers) locates the disk automatically at
runtime (see `detect_reanote_base()` in each script) and then expects a
**fixed folder layout relative to that root** — none of the paths are
configurable via a config file, they're hardcoded relative to
`ReAnote/data/`. Reconstructing this exact structure is what makes a
from-scratch installation actually work with the existing scripts, no
changes needed.

```
ReAnote/                                    # root: detected automatically under /mnt/*/ReAnote or /media/*/ReAnote
├── reanotar.sh
├── scripts/
│   ├── phase1.sh … phase4.sh
│   ├── rute_1.sh
│   └── setup/
│       ├── bootstrap_environment.sh        # entry point for a brand-new machine
│       ├── install_vep_engine.sh           # Steps 1-7: VEP + core API + cache + plugin .pm files + FASTA
│       ├── install_annotation_sources.sh   # ClinVar, mutfunc, UTRAnnotator, AlphaMissense, Conservation, CADD
│       ├── verify_vep_engine.sh            # read-only post-install check against the audited manifest
│       └── phase4_env.yml                  # conda environment spec (fallback path, no internet-free packaging)
├── engine/
│   ├── phase4_env.sqfs / .tar.gz           # packaged runtime env: vep, filter_vep, bcftools, samtools, whatshap, vcfanno
│   └── gatk_env.sqfs / .tar.gz             # packaged runtime env: gatk, bwa, samtools, tabix, bgzip, picard, java
├── data/
│   ├── ensembl-vep/                        # cloned at tag release/115.2, .git stripped (see section 4)
│   │   └── filter_vep                      # invoked by absolute path, NOT the conda package's copy
│   ├── ensembl/                            # Core API repo #1 — Bio::EnsEMBL::Registry
│   ├── ensembl-variation/                  # Core API repo #2 — Bio::EnsEMBL::Variation::*
│   ├── ensembl-io/                         # Core API repo #3 — Bio::EnsEMBL::IO::*
│   ├── ensembl-funcgen/                    # Core API repo #4 — Bio::EnsEMBL::Funcgen::*
│   ├── .vep/                               # --dir_cache root
│   │   ├── homo_sapiens_merged/115_GRCh38/ # the actual cache VEP resolves via --merged (see section 5)
│   │   └── Plugins/                        # --dir_plugins root
│   │       ├── *.pm                        # plugin Perl modules (from VEP_plugins, see section 6)
│   │       ├── CADD/                       # plugin DATA (heavy, downloaded separately — section 6)
│   │       ├── Conservation/               # GERP/phyloP/phastCons bigwigs (section 6)
│   │       ├── Alphamissense/
│   │       ├── mutfunc/
│   │       └── Data/                       # data used directly by some plugins (SpliceAI, MaxEntScan, dbNSFP, dbscSNV, UTRAnnotator)
│   ├── reanote/
│   │   └── referencias/
│   │       └── hg38/
│   │           ├── Homo_sapiens_assembly38.fasta(.fai/.dict)   # reference FASTA + indices (section 4)
│   │           ├── Homo_sapiens_assembly38.dbsnp138.vcf        # used by gatk_env's phase1-3.sh (BQSR, genotyping)
│   │           ├── Mills_and_1000G_gold_standard.indels.hg38.vcf.gz  # used by phase1.sh (BQSR)
│   │           └── hg19ToHg38.over.chain                       # used by reanotar.sh liftover
│   └── custom/                             # --custom annotation sources (section 7)
│       ├── clinvar/clinvar_chr.vcf.gz      # NCBI ClinVar, chromosome-renamed and re-indexed
│       ├── gnomad/v4.1/genomes/…           # gnomAD v4.1 genomes, NOT covered by install_annotation_sources.sh yet
│       ├── gnomad/v4.1/exomes/…            # gnomAD v4.1 exomes, same
│       └── regulomedb/*.bed.gz             # RegulomeDB ranking + score tracks
├── input/                                  # user's own data, not part of this guide
└── outputs/                                # pipeline outputs, not part of this guide
```

A few structural points worth calling out explicitly:

- **`data/ensembl-vep/`, `data/ensembl/`, `data/ensembl-variation/`,
  `data/ensembl-io/`, and `data/ensembl-funcgen/` are five SEPARATE git
  clones**, all required. `ensembl-vep` alone is not enough to run
  `vep --help` successfully — it only ships its own `modules/`, not the
  4 Core API repos that provide `Bio::EnsEMBL::Registry` and friends. See
  [section 4](#4-installing-vep-itself) for why, and the exact
  `PERL5LIB`/`PERL5OPT` values that make this resolve.
- **None of `data/ensembl*/` may ever contain an active `.git` directory**
  on the portable disk itself. This isn't a style preference — the
  portable disk is mounted via 9p/drvfs under WSL2, which doesn't support
  the `chmod` syscall at all, and git cannot function as an active
  repository without it (not even `git status` is reliable). The install
  scripts clone and check out each release in a **native Linux temp
  directory** first, verify the checkout is clean there, and only then
  `rsync` the working tree (without `.git/`) onto the portable disk. See
  `install_release_via_native_tmp()` in
  [`install_vep_engine.sh`](scripts/setup/install_vep_engine.sh) for the
  full implementation and reasoning.
- **`data/.vep/Plugins/` mixes two different kinds of content** that must
  not be confused: the plugin *code* (`.pm` files, small, from the
  `VEP_plugins` repo) and the plugin *data* (huge files like CADD's 82G of
  score tables) which are downloaded completely separately, from different
  sources, some of them not automatable at all. See
  [section 6](#6-installing-plugins).

---

## 4. Installing VEP itself

### 4.1. Official installer vs. this project's approach

Ensembl's official installation method is `perl INSTALL.pl` (bundled
inside the `ensembl-vep` repo), documented at
[jun2026.archive.ensembl.org/info/docs/tools/vep/script/vep_download.html](https://jun2026.archive.ensembl.org/info/docs/tools/vep/script/vep_download.html).
Its most relevant flags:

| Flag | Purpose |
|---|---|
| `--AUTO` / `-a` | Non-interactive mode. Combine letters: `a` (API + Bio::DB::HTS), `l` (Bio::DB::HTS only), `c` (cache), `f` (FASTA), `p` (plugins) |
| `--CACHEDIR` / `-c` | Cache install location (default: `~/.vep`) |
| `--PLUGINSDIR` / `-r` | Plugin install location (default: `Plugins/` inside the cache dir) |
| `--SPECIES` / `-s` | e.g. `homo_sapiens_merged` for the merged cache |
| `--ASSEMBLY` / `-y` | Required when a species has more than one assembly, e.g. `GRCh38` |
| `--CACHE_VERSION` | Pin a specific cache release instead of the latest |
| `--NO_HTSLIB` / `-l` | Skip `Bio::DB::HTS`/htslib, fall back to `Bio::DB::Fasta` (not used here — we want the fast Faidx path) |
| `--PLUGINS` / `-g` | Comma-separated plugin list, or `all` |
| `--NO_UPDATE` / `-n` | Skip the startup check against `api.github.com` for the latest release |
| `--USE_HTTPS_PROTO` | Force HTTPS instead of FTP for downloads |
| `--GITHUBTOKEN` | Authenticate GitHub API calls to raise the 60 req/hour unauthenticated rate limit |

**This project does NOT run `INSTALL.pl` end-to-end.** Two real problems
were hit during the original setup, both documented with their exact
diagnosis in
[`install_vep_engine.sh`](scripts/setup/install_vep_engine.sh):

1. **FTP is blocked on the target network.** `INSTALL.pl`'s cache
   downloader uses `Net::FTP` (port 21) unless `--USE_HTTPS_PROTO` is
   passed, which itself requires `HTML::TableExtract` (not guaranteed
   installed). Rather than fight that dependency chain, the cache is
   fetched directly over HTTPS from Ensembl's FTP-mirrored HTTPS endpoint
   (see [section 5](#5-the-vep-cache)).
2. **`git` cannot run as an active repository on the portable disk** (the
   9p/drvfs chmod issue described in [section 3](#3-the-folder-structure-everything-expects)).
   `INSTALL.pl` itself doesn't clone git repos directly for the API (it
   downloads release tarballs), but this project's approach of cloning
   `ensembl-vep` and the 4 Core API repos at an exact tag *does* need git,
   and needs it to run somewhere that supports `chmod` — hence the
   native-temp-dir-then-rsync pattern.

So instead, `install_vep_engine.sh` reimplements the equivalent of
`INSTALL.pl --AUTO l` (Faidx/htslib only — **is** run via `perl
INSTALL.pl --AUTO l --NO_UPDATE`, this part of the official installer
works fine) plus its own logic for everything else (git releases, cache,
plugins, FASTA). If you're setting this up somewhere WITHOUT the 9p/drvfs
constraint (e.g. a native Linux server, not a portable disk under WSL2),
running the official `INSTALL.pl --AUTO acfp --SPECIES
homo_sapiens_merged --ASSEMBLY GRCh38 --PLUGINS all` in one go is a
perfectly valid alternative — just make sure the resulting versions match
[section 2](#2-versions-to-target).

### 4.2. What `install_vep_engine.sh` actually does, step by step

Run as: `bash scripts/setup/install_vep_engine.sh` (needs `phase4_env`
active first — see [section 9](#9-packaged-runtime-environments-how-and-why)
or run it via `bootstrap_environment.sh`, which activates the environment
automatically). It is fully idempotent: safe to re-run after a failure,
each step checks whether its result already exists before doing anything.

1. **Clone `ensembl-vep` at tag `release/115.2`** into `data/ensembl-vep/`
   via the native-temp-dir-then-rsync pattern (no `.git` left on the
   portable disk; the installed tag is recorded in a plain-text marker
   file `.reanote_release_tag` for later verification).
2. **Clone the 4 Core API repos** (`ensembl`, `ensembl-variation`,
   `ensembl-io`, `ensembl-funcgen`) at branch `release/115` — same major
   version as the VEP tag, but Ensembl versions these 4 repos by branch,
   not by exact git tag. Export `PERL5LIB` pointing at all 4 `modules/`
   subfolders — `vep`'s own `use lib` only adds its own `modules/`, not
   these.
3. **Export `PERL5OPT="-MBio::DB::HTS::Tabix"`** — without preloading this
   module, `vep` dies with `Attempt to reload Bio/DB/HTS/Tabix.pm
   aborted`, caused by a load-order recursion bug between
   `Bio::EnsEMBL::VEP::AnnotationSource::File` and ensembl-io's
   `VCF4Tabix.pm` when both are loaded without going through the official
   `INSTALL.pl` flow.
4. **Install required + recommended Perl/CPAN modules** via `cpanm`: `DBI`,
   `Set::IntervalTree`, `JSON`, `Text::CSV` (required), plus
   `DBD::mysql@4.050` (pinned — newer versions aren't compatible),
   `PerlIO::gzip`, `IO::Uncompress::Gunzip`, `Bio::DB::BigFile`, `Sereal`,
   `HTML::Lint`, `Capture::Tiny` (recommended, non-blocking if they fail).
5. **Run `perl INSTALL.pl --AUTO l --NO_UPDATE`** inside `ensembl-vep/`,
   which installs `Bio::DB::HTS`/htslib (Faidx) — the one piece of the
   official installer this project does use directly. `--NO_UPDATE` skips
   the `api.github.com` version-check call, which can hit GitHub's 60
   req/hour unauthenticated rate limit and abort the whole script (see
   `GITHUB_TOKEN` below).
6. **Download and extract the VEP cache** — see [section 5](#5-the-vep-cache).
7. **Clone `VEP_plugins` and copy the `.pm` files** — see
   [section 6](#6-installing-plugins).
8. **Download the reference FASTA + `.fai`/`.dict`** from Broad's public
   GCS mirror (`storage.googleapis.com/gcp-public-data--broad-references`)
   — the older `genomics-public-data` bucket stopped being anonymously
   accessible (403), same file though (identical bytes/md5).

**Optional: `GITHUB_TOKEN`.** If set in the environment, `INSTALL.pl`
picks it up natively (via its `read_config_from_environment()`, no flag
needed from this script) and authenticates its own `api.github.com` calls,
raising the rate limit above 60 req/hour unauthenticated. Only needs
public read access. Never written to disk, only inherited as a process
environment variable.

### 4.3. Post-install verification

`bash scripts/setup/verify_vep_engine.sh` — read-only, checks everything
against the values audited in
[`vep_install_manifest.md`](vep_install_manifest.md): `vep --version`
output, the `.reanote_release_tag` markers, the exact list of `.pm` plugin
files (flags anything missing or unexpectedly extra), the cache's
`species`/`assembly` fields from its own `info.txt`, and file sizes for
the FASTA + indices. Exits non-zero if any check fails, printing a
pass/fail summary at the end.

### 4.4. GATK resource files — NOT covered by any current script

**Gap found during this extraction pass, not previously flagged
anywhere.** `data/reanote/referencias/hg38/` on the reference disk holds
three more files that `gatk_env`'s scripts need (`phase1.sh`,
`phase2.sh`/`phase3.sh` via `reanotar.sh`, and `liftover`), on top of the
FASTA + indices [section 4.2](#42-what-install_vep_engineshsh-actually-does-step-by-step)
already installs — **none of these three are downloaded by
`install_vep_engine.sh` or any other script in this project**:

| File | Confirmed size on disk | Used by |
|---|---|---|
| `Homo_sapiens_assembly38.dbsnp138.vcf` (+ `.idx`) | **~10.9G** | `phase1.sh` (BQSR), `phase3.sh` (GenotypeGVCFs `-D`) |
| `Mills_and_1000G_gold_standard.indels.hg38.vcf.gz` (+ `.tbi`) | ~20.7M | `phase1.sh` (BQSR known-sites) |
| `hg19ToHg38.over.chain` | ~607K | `reanotar.sh liftover` (GATK `LiftoverVcf -CHAIN`) |

These are all standard, well-known files from the **Broad GATK resource
bundle** (public, no login required) — not something specific to this
project's own processing, unlike ClinVar
([section 7.4](#74-clinvar-why-it-needs-reprocessing-before-use-as-a-custom-track)).
They should be downloadable directly from Broad's public GCS bucket, the
same one `install_vep_engine.sh` already uses for the reference FASTA
itself (`GATK_FASTA_BASE_URL =
storage.googleapis.com/gcp-public-data--broad-references/hg38/v0` — see
[`install_vep_engine.sh`](scripts/setup/install_vep_engine.sh)), i.e. the
same base URL with `Homo_sapiens_assembly38.dbsnp138.vcf(.idx)`,
`Mills_and_1000G_gold_standard.indels.hg38.vcf.gz(.tbi)` in place of the
FASTA name. The liftover chain file is Broad's own
`hg19ToHg38.over.chain`, also part of the standard bundle. **These exact
URLs were not re-verified with `curl -I` before writing this** (unlike
every other URL in this document, which was) — do that before adding them
to `install_vep_engine.sh`, following the same `resumable_download()`
pattern already used for the FASTA.

md5 of the chain file present on the reference disk, for cross-checking
once re-downloaded:
```
9267c9fef79b54962da8efadd0ddf6b6  hg19ToHg38.over.chain
```

---

## 5. The VEP cache

VEP's cache is what lets it run fully `--offline` without hitting the
Ensembl database over the network for every variant — it's a pre-built,
indexed local copy of the transcript/gene models for a species+assembly.

### 5.1. Why the `merged` cache specifically

Three cache types exist per species+assembly: `homo_sapiens` (Ensembl gene
set only), `homo_sapiens_refseq` (RefSeq only), and
`homo_sapiens_merged` (Ensembl **and** RefSeq combined, ~26G vs. ~24G for
either alone). ReAnote's scripts (`phase4.sh`, `rute_1.sh`) explicitly pass
`--merged` to `vep`, which makes it resolve internally to
`homo_sapiens_merged/<version>_GRCh38` under whatever `--dir_cache` points
to — **this is the only cache type actually used**; the other two aren't
installed to avoid ~48G of unused disk space.

### 5.2. Where it comes from and how to get it

Official cache tarballs are published per-release at Ensembl's FTP/HTTPS
mirror, following the pattern:

```
https://ftp.ensembl.org/pub/release-<version>/variation/indexed_vep_cache/<species>_<type>_vep_<version>_<assembly>.tar.gz
```

For this project's exact target (release 115, human, merged, GRCh38):

```
https://ftp.ensembl.org/pub/release-115/variation/indexed_vep_cache/homo_sapiens_merged_vep_115_GRCh38.tar.gz
```

Confirmed size at time of writing: **27,845,183,833 bytes (~25.9G)**. This
is downloaded via plain HTTPS with `curl`, not FTP — see
[section 4.1](#41-official-installer-vs-this-projects-approach) for why.
`install_vep_engine.sh`'s `resumable_download()` helper supports resuming
an interrupted download (`curl -C -`) and verifies the final byte count
against the expected size before accepting it as valid.

Extract it directly into `data/.vep/` (not into a species subfolder — the
tarball already contains the `homo_sapiens_merged/115_GRCh38/` path
internally):

```bash
tar -xzf homo_sapiens_merged_vep_115_GRCh38.tar.gz -C ReAnote/data/.vep/
```

### 5.3. Verifying it's the right one

After extracting, `data/.vep/homo_sapiens_merged/115_GRCh38/info.txt`
should report (among other fields):

```
species                homo_sapiens
assembly               GRCh38.p14
source_gencode         GENCODE 49
source_refseq          GCF_000001405.40-RS_2024_08
source_dbSNP           156
source_ClinVar         202502
source_gnomADe/g       v4.1
```

If any of these differ, either a different cache release was downloaded by
mistake, or the release version in `install_vep_engine.sh` needs updating
to match a newer target — in which case, re-validate the whole pipeline
against the new version before switching over in production.

---

## 6. Installing plugins

VEP plugins are Perl modules that hook into the annotation process to
extend, filter, or add extra scores/predictions to each variant. Official
source: [github.com/Ensembl/VEP_plugins](https://github.com/Ensembl/VEP_plugins).
Official docs:
[jun2026.archive.ensembl.org/info/docs/tools/vep/script/vep_plugins.html](https://jun2026.archive.ensembl.org/info/docs/tools/vep/script/vep_plugins.html).

Invocation syntax (used identically by `phase4.sh` and `rute_1.sh`):

```
--plugin PluginName,param1=value1,param2=value2
```

Some plugins take no parameters (`--plugin NMD`, `--plugin SpliceRegion`),
some take a single required file path (`--plugin
AlphaMissense,file=/path/to/AlphaMissense_hg38.tsv.gz`), and some take
several (`--plugin CADD,snvs=...,indels=...`).

### 6.1. Two completely separate things: plugin *code* vs. plugin *data*

This is the single most important distinction in this whole document.
**The `.pm` file is not the data the plugin needs to actually do anything.**

- **Plugin code** (`.pm` files): small (a few KB to ~27KB each), pure Perl,
  all come from the same `VEP_plugins` repo, all installed the same way
  (clone + copy — see 6.2 below).
- **Plugin data**: wildly different per plugin — ranging from a 2.4MB text
  file (UTRAnnotator) to an 82G set of tabix-indexed score tables (CADD).
  Comes from completely different sources per plugin (Zenodo, Ensembl's own
  FTP, university servers, gated academic registration forms...), and
  **is not part of the `VEP_plugins` repo at all**.

Confusing these two is the most common way to think "the plugin is
installed" when in fact only the empty shell is — the plugin will error
out at runtime with a missing-file error the moment VEP tries to use it.

### 6.2. Installing the plugin code (`.pm` files)

Unlike `ensembl-vep`, **`Ensembl/VEP_plugins` does not publish git tags** —
it versions each release as a branch (`release/115`, `release/116`, ...),
resolved against `--heads` not `--tags`. `install_vep_engine.sh`'s
`resolve_plugins_tag()` handles this resolution automatically, with a
fallback that picks the most recent matching branch/tag if the exact
`release/115` name isn't found.

Same native-temp-dir-then-rsync pattern as `ensembl-vep` itself (no active
`.git` on the portable disk). Only the `.pm` files at the repo root are
copied into `data/.vep/Plugins/` — subfolders like `Plugins/Data/` (which
holds actual data for some plugins, see below) are deliberately not
touched by this copy step, so re-running it never overwrites real data
with an empty upstream placeholder.

The exact list of 22 `.pm` files this project installs and verifies
against is documented in
[`vep_install_manifest.md`](vep_install_manifest.md#31-full-list-of-pm-files-in-plugins-root) —
including one deliberately-fixed discrepancy (`SpliceRegion.pm` was
missing from the original audited installation despite being invoked by
the scripts; a full `VEP_plugins` clone includes it with no extra
dependencies, so it's included going forward).

**Note on `loftee`:** the `LoF.pm` plugin and its `loftee` companion
scripts (from a *different* repo, `konradjk/loftee.git`, tag
`v1.0.4_GRCh38`) are present in the originally-audited installation but
are **not invoked by any current script** (no `--plugin LoF` anywhere in
`phase4.sh`/`rute_1.sh`). `install_vep_engine.sh` has an
`INSTALL_LOFTEE=false` flag (default) that skips it entirely — flip it to
`true` if a future workflow needs it.

### 6.3. Installing plugin data — what's automated vs. what isn't

`install_annotation_sources.sh` automates the plugins/custom sources that
have a **stable, directly-downloadable URL with no login wall**. Everything
else needs manual, one-time human intervention (account creation, form
submission, etc.) — that data then has to be copied onto the disk by hand
once obtained.

**Automated (run `bash scripts/setup/install_annotation_sources.sh`):**

| Resource | Size | Source | License note |
|---|---|---|---|
| mutfunc | ~2.0G | `ftp.ensembl.org/pub/current_variation/mutfunc/` | — |
| UTRAnnotator | ~2.4MB | GitHub (`ImperialCardioGenetics/UTRannotator`) | MIT |
| AlphaMissense | ~614M | Zenodo (`zenodo.org/records/10813168`) | CC BY 4.0 |
| Conservation (GERP) | ~9.6G | `ftp.ensembl.org` release-115 compara track | — |
| Conservation (phyloP100way) | ~9.9G | UCSC (`hgdownload.soe.ucsc.edu`) | — |
| Conservation (phastCons100way) | ~5.9G | UCSC (`hgdownload.soe.ucsc.edu`) | — |
| CADD v1.6 (SNVs + indels, GRCh38) | ~87G + ~1.2G | `krishna.gs.washington.edu` | **Free for non-commercial use only** — see [cadd.gs.washington.edu](https://cadd.gs.washington.edu/) for commercial licensing |

Note on CADD: the pipeline specifically targets **v1.6**, not the current
v1.7 — this is intentional, not an oversight. `phase4.sh`/`rute_1.sh`
reference `gnomad.genomes.r3.0.indel.tsv.gz`, which is v1.6's indel file
name; v1.7 uses gnomAD r4.0 under a different file name. Upgrading to v1.7
would need re-validating the whole annotation output, not just swapping a
URL.

**NOT automated — requires manual action:**

| Resource | Why it can't be automated | Where to get it |
|---|---|---|
| SpliceAI | Requires an Illumina BaseSpace account + the authenticated `bs` CLI | [basespace.illumina.com](https://basespace.illumina.com) |
| dbNSFP | Requires registration with an institutional email (Google Form); the distributed file also needs reconstruction from per-chromosome tables | [dbnsfp.org/download](http://www.dbnsfp.org) |
| dbscSNV | Same registration/ecosystem as dbNSFP | distributed alongside dbNSFP |
| REVEL | No account, but restricted to non-commercial use; no stable direct-download URL | [sites.google.com/site/revelgenomics/downloads](https://sites.google.com/site/revelgenomics/downloads) |
| satMutMPRA | The public endpoint returns 401 — it's an interactive Shiny app, not a file server | [kircherlab.bihealth.org](https://kircherlab.bihealth.org) |
| MaxEntScan | Origin server was unreachable at audit time (`ERR_CONNECT_FAIL`) | `hollywood.mit.edu` — retry later, or look for a mirror |
| EVE | The public endpoint only exposes raw alignments (MSAs), not the variant-scores VCF the plugin needs — requires non-trivial reconstruction | [evemodel.org](https://evemodel.org) |

Once obtained by hand, each of these goes under
`data/.vep/Plugins/<PluginName>/` or `data/.vep/Plugins/Data/`, matching
the exact filename `phase4.sh`/`rute_1.sh` expect in their `--plugin`
invocations (see those scripts for the exact expected paths per plugin).

---

## 7. Custom annotation tracks (`--custom`)

### 7.1. Syntax

`phase4.sh`/`rute_1.sh` target **VEP 115.x**, which uses the *positional*
`--custom` syntax (not the newer named-parameter syntax introduced in VEP
116+):

```
--custom <file>,<short_name>,<format>,<type>,<coord_flag>,<field1>,<field2>,...
```

Example used in this project (ClinVar):

```
--custom "$CLINVAR_FILE",ClinVar,vcf,exact,0,CLNSIG,CLNSIGCONF,CLNREVSTAT,CLNDN,ALLELEID,CLNSIGINCL
```

| Position | Meaning | ClinVar example |
|---|---|---|
| file | Path to the annotation source (bgzipped + tabix-indexed) | `clinvar_chr.vcf.gz` |
| short_name | Prefix used for the resulting INFO fields | `ClinVar` |
| format | `vcf`, `bed`, `bigwig`, `gff`, `gtf` | `vcf` |
| type | `exact` (coordinates must match precisely) or `overlap` (any overlap counts) | `exact` |
| coord_flag | `0`/`1`, historical VEP option, generally left `0` | `0` |
| fields... | Which INFO fields to pull (VCF only) | `CLNSIG`, `CLNSIGCONF`, ... |

For `bigwig` custom tracks (used for the Conservation scores — GERP,
phyloP, phastCons), there are no `fields`, since bigwig carries a single
numeric value per position:

```
--custom "$GERP_BW",GERP_RS,bigwig,exact
```

### 7.2. File preparation requirements

Any VCF or BED used as a `--custom` source must be:

1. Sorted by chromosome/position.
2. Compressed with `bgzip` (not plain `gzip` — VEP needs the BGZF block
   structure to seek into it).
3. Indexed with `tabix -p vcf` (or `-p bed`).

`bigwig` files are self-indexed and need neither `bgzip` nor `tabix`, but
`vep` does need `Bio::DB::BigFile` installed to read them (see
[section 4.2](#42-what-install_vep_engineshsh-actually-does-step-by-step), step 4).

### 7.3. What this project actually uses as custom tracks

| Track | short_name | Source | Fields pulled |
|---|---|---|---|
| ClinVar | `ClinVar` | NCBI FTP, reprocessed (see 7.4) | `CLNSIG`, `CLNSIGCONF`, `CLNREVSTAT`, `CLNDN`, `ALLELEID`, `CLNSIGINCL` |
| gnomAD genomes v4.1 | `gnomADg` | Google Cloud Storage, public | `AF`, `AC`, `AN`, `nhomalt`, `grpmax`, `AF_grpmax`, `fafmax_faf95_max`, `AS_VQSLOD` |
| gnomAD exomes v4.1 | `gnomADe` | Google Cloud Storage, public | same as above |
| RegulomeDB ranking | `RegulomeDB_ranking` | ENCODE/Stanford | (BED, no fields — overlap only) |
| RegulomeDB score | `RegulomeDB_score` | ENCODE/Stanford | (BED, no fields — overlap only) |
| GERP conservation | `GERP_RS` | Ensembl compara | (bigwig, single value) |
| phyloP 100way | `PhyloP_100way` | UCSC | (bigwig, single value) |
| phastCons 100way | `PhastCons_100way` | UCSC | (bigwig, single value) |

> **Note on `data/custom/regulomedb/`:** the reference disk's folder
> actually has 4 files, not the 2 listed above —
> `regulomedb_ranking.bed.gz`/`regulomedb_score.bed.gz` (the two actually
> used by `--custom`, confirmed by grepping `phase4.sh`/`rute_1.sh`) plus
> `regulomedb.tsv.gz` (~215M) and `regulomedb_hg38_final.tsv.gz` (~116M),
> which appear to be raw/intermediate downloads from preparing the two BED
> tracks and aren't referenced anywhere in the pipeline. Only the two
> `.bed.gz` files (plus their `.tbi`) are actually required; the exact
> RegulomeDB source URL and the processing steps that turned the raw
> download into those two ranking/score BED tracks were not captured
> before losing access to the reference disk — flagged here rather than
> silently dropped, same as the gnomAD situation in
> [section 7.5](#75-gnomad-present-on-disk-but-the-download-itself-is-not-scripted).

### 7.4. ClinVar: why it needs reprocessing before use as a custom track

NCBI's official ClinVar VCF (`ftp.ncbi.nlm.nih.gov/pub/clinvar/vcf_GRCh38/clinvar.vcf.gz`)
can't be used as-is:

1. It names chromosomes `1`..`22`, `X`, `Y`, `MT` (no `chr` prefix), while
   this pipeline's reference and all its other tracks use UCSC-style
   naming (`chr1`, `chrX`, `chrM`).
2. It declares **no `##contig` header lines at all**, which makes
   `bcftools` reject it outright.
3. It includes variants on 8 alternate scaffolds (`NT_*`/`NW_*`, ~48 out
   of ~4.4M variants) that don't exist in this pipeline's reference FASTA.

`install_annotation_sources.sh` fixes all three in a 3-step `bcftools`
pipeline (inject `##contig` lines using the real lengths from the
reference `.fai` → filter down to the 25 canonical contigs → rename to
`chr*` naming, `MT`→`chrM`) before bgzipping and tabix-indexing the result
as `data/custom/clinvar/clinvar_chr.vcf.gz`. See the script itself for the
exact `awk`/`bcftools` commands.

**Note on ClinVar's update cadence:** ClinVar is updated **weekly** by
NCBI. The expected download size hardcoded in the script
(`CLINVAR_EXPECTED_BYTES`, checked as of 2026-07-21) will drift out of date
over time — if the size check fails on a re-run, confirm the new
`Content-Length` with `curl -sI` against the source URL and update the
constant.

### 7.5. gnomAD: present on disk, but the download itself is not scripted

**`install_annotation_sources.sh` explicitly does NOT download gnomAD** —
but the data **is** present and in active use on the reference disk (both
`--custom` tracks referenced by `phase4.sh`/`rute_1.sh` exist and are
correctly bgzipped + tabix-indexed). What's missing is a *script* that
reproduces this step from scratch; the manual steps and confirmed sizes
below are what's known so far, extracted directly from the reference disk
before it stops being accessible:

| File | Confirmed size on disk |
|---|---|
| `data/custom/gnomad/v4.1/genomes/gnomad.genomes.v4.1.sites.concat.vcf.gz` (+ `.tbi`) | **~525G** |
| `data/custom/gnomad/v4.1/exomes/gnomad.exomes.v4.1.sites.concat.vcf.gz` (+ `.tbi`) | **~185G** |

That's **~710G combined** — confirming the "several hundred GB" estimate
from the original audit, and explaining directly why this was never
scripted: it dwarfs every other dataset in this guide by an order of
magnitude (compare to CADD's 82G, the single next-largest item in
[section 6.3](#63-installing-plugin-data--whats-automated-vs-what-isnt)).

gnomAD v4.1 (genomes) is public on Google Cloud Storage, distributed as 24
per-chromosome sites VCFs that must be downloaded and concatenated into
the single file `phase4.sh`/`rute_1.sh` expect
(`gnomad.genomes.v4.1.sites.concat.vcf.gz`) — the exact per-chromosome
source URLs and the concatenation command used to produce the file
currently on the reference disk were **not** captured before access to it
was lost; reconstructing this file requires re-deriving that process from
gnomAD's public download documentation. Same situation for the exomes
file.

**Also present on the reference disk but not referenced by any current
script**, discovered during this same extraction pass and worth flagging
for whoever picks this up next: `data/custom/gnomad/v4.1/coverage/`
(`gnomad.exomes.v4.0.coverage.summary.tsv.bgz`) and
`data/custom/gnomad/v4.1/snv_cnv/` (`gnomad.v4.1.cnv.all.vcf.gz`,
`gnomad.v4.1.sv.sites.vcf.gz` + `.tbi`) — these look like they were
downloaded for a `--custom` track that was never wired into
`phase4.sh`/`rute_1.sh`, or leftovers from evaluating whether to add
structural-variant/CNV/coverage annotation. Not documented anywhere else;
flagged here rather than silently dropped.

---

## 8. Plugins vs. custom tracks: which to use for what

A recurring question when adding a new annotation source: should it be a
VEP **plugin** or a **custom track**? Both end up adding INFO fields to
the output VCF, but they work very differently under the hood and aren't
interchangeable for every source.

- **Plugins** are Perl code that runs *inside* VEP's annotation loop —
  they can implement arbitrary logic (e.g. combining multiple scores,
  looking up a value in a SQLite database like `mutfunc`, or applying a
  custom formula). Use a plugin when the annotation source **ships as a
  VEP plugin already** (which covers most well-known pathogenicity/impact
  predictors: CADD, REVEL, AlphaMissense, SpliceAI, dbNSFP, etc.) — there's
  rarely a reason to reimplement one of these as a raw custom track.
- **Custom tracks** are a generic mechanism for pulling values out of any
  properly-indexed VCF/BED/bigWig file by direct coordinate lookup, with no
  Perl logic involved. Use `--custom` when the source is **not**
  distributed as a plugin — which is exactly the case for ClinVar, gnomAD,
  and RegulomeDB in this project. There is no official "ClinVar plugin" or
  "gnomAD plugin"; they're both meant to be used via `--custom`.

### 8.1. When a custom track is preferable *even if* a plugin-like path exists

This is the part worth calling out explicitly, since it isn't just "use
whichever the source ships as" — for a few resources, going through
`--custom` against a properly maintained/updated source is a **better**
choice than relying on data bundled with an older plugin release or
snapshot:

- **ClinVar via `--custom`, not a static bundled snapshot.** ClinVar
  updates **weekly**. `install_annotation_sources.sh` re-downloads and
  reprocesses it fresh from NCBI every time it's run (see
  [section 7.4](#74-clinvar-why-it-needs-reprocessing-before-use-as-a-custom-track)),
  so the annotation always reflects the current classification consensus —
  a `source_ClinVar` version embedded inside a VEP cache release (like the
  `202502` snapshot baked into this project's `homo_sapiens_merged`
  cache, see [section 5.3](#53-verifying-its-the-right-one)) is a
  point-in-time snapshot that goes stale the moment a variant's
  classification changes.
- **gnomAD v4.1 via `--custom`, not gnomAD data bundled in older plugin
  releases.** gnomAD v4.1 (the version targeted here) has a substantially
  larger sample size and different QC than v2/v3 data that ships bundled
  with some older annotation resources — pulling it directly as its own
  `--custom` track guarantees the exact version being used, rather than
  whatever gnomAD snapshot happens to be embedded in another tool's
  release cycle.

*(This section is a placeholder for further build-out: as more sources get
added or audited, this is the place to document further "custom track over
plugin/bundled-snapshot" recommendations with the specific reasoning per
source — freshness, completeness of fields, sample size, licensing, etc.)*

---

## 9. Packaged runtime environments: how and why

`engine/phase4_env.sqfs`/`.tar.gz` and `engine/gatk_env.sqfs`/`.tar.gz` are
**not created by any script in this repository** — they were built once,
by hand, with `conda pack`, and are meant to be regenerated only when the
tool versions in [section 2](#2-versions-to-target) change. This section
documents how they were built and why, so a future rebuild can reproduce
the same result.

### 9.1. Why pre-packaged environments instead of `conda install` at runtime

Going back to the [portable-disk design principle](#1-why-this-exists-the-portable-disk-design):
a brand-new computer connecting the disk for the first time should be able
to run a re-annotation **without an internet connection**, and without
installing conda or resolving any dependency graph on the spot (which,
for an environment this size — VEP, GATK, BWA, htslib, and their full
dependency trees — can itself take many minutes even with a fast
connection, on top of needing one at all). Packaging the fully-resolved
environment once and shipping it *inside* the portable disk turns that
into a local file operation.

### 9.2. How each environment was built

Both environments are conda environments resolved from the `conda-forge`
and `bioconda` channels, then exported with:

```bash
conda pack --dest-prefix <the exact absolute path the disk uses at package time> -o phase4_env.tar.gz
```

`phase4_env.yml` (the source spec for `phase4_env`, kept under
`scripts/setup/` as the fallback path when no packaged environment is
available at all) lists its core packages:

```yaml
name: phase4_env
channels: [conda-forge, bioconda, defaults]
dependencies:
  - htslib
  - samtools
  - perl-io-compress
  - perl-bio-db-hts
  - perl-dbi
  - perl-dbd-mysql
  - whatshap
  - ensembl-vep=115
  - vcfanno
  - bcftools
```

`gatk_env.yml`, extracted the same way (`conda list --prefix` against the
real activated environment on the reference disk, confirming exact
top-level package versions — `tabix`/`bgzip` come from the `htslib`
package, not standalone ones):

```yaml
name: gatk_env
channels: [conda-forge, bioconda, defaults]
dependencies:
  - gatk4=4.6.2.0
  - bwa
  - samtools
  - htslib
  - picard
  - openjdk=17
```

Confirmed top-level versions at extraction time: `gatk4` 4.6.2.0, `bwa`
0.7.19, `samtools`/`htslib` 1.23, `picard` **3.4.0** (not previously
documented anywhere else in this project before this extraction), `openjdk`
17.0.17, `python` 3.10.19 (pulled in transitively by `gatk4`).

### 9.3. The `--dest-prefix` decision and its consequence

`conda pack --dest-prefix` bakes the environment's install prefix as a
**fixed absolute path** into every binary and shebang line, exactly as it
was on the machine that built the package (e.g.
`/mnt/f/ReAnote/engine/phase4_env`). This was a deliberate choice over the
alternative (`conda-unpack`, which relocates paths after extraction): it
lets `reanotar.sh` activate the environment with a plain `source
bin/activate` and start using it immediately, with **zero** post-extraction
processing step — critical for the SquashFS mount path (see 9.4), where
there's no extraction step to hook a relocation script into at all.

The cost of that choice is what the rest of this section is about: two
specific breakages that a fixed absolute path introduces, and how
`reanotar.sh` works around each one at activation time (see
`activate_packed_env()` and `fix_hardcoded_python_shebangs()` in
[`reanotar.sh`](reanotar.sh) for the exact implementation):

- **Symlinks don't survive NTFS/exFAT.** The portable disk typically lives
  on NTFS/exFAT (mounted via WSL2), which supports neither symlinks nor
  hard links. Binaries that relied on resolving their own location through
  a symlink (`vep`, `filter_vep`, `gatk`, `picard`, `java`, and the JVM
  tools) had those symlinks materialized as full file copies during
  packaging — but some of those tools still fail if their *shebang line*
  (baked in with the absolute `--dest-prefix` path) no longer matches
  where the disk actually mounts on a different computer.
- **A different mount letter/path breaks Python console-script shebangs.**
  `conda pack` writes an absolute interpreter path into the shebang of
  every Python script installed as a pip/setuptools console entry point
  (e.g. `whatshap`). If the disk mounts at `/mnt/d/ReAnote` on one computer
  and `/mnt/f/ReAnote` on another, that shebang points at an interpreter
  that doesn't exist on the second machine, and the script dies with `No
  such file or directory` when invoked directly.

`reanotar.sh`'s fix for the second problem: at every environment
activation, it generates a one-line wrapper script (in
`$HOME/.reanote_wrappers/`, on the *local* machine, never on the portable
disk) that invokes `python <real script path>` explicitly — since the
interpreter is named explicitly on the command line, bash never needs to
read (or care about) the script's own broken shebang. This wrapper
directory is prepended to `PATH` ahead of the environment's own `bin/` on
every activation (re-prepended every time, not just once — activating a
second environment in the same shell, e.g. `gatk_env` then `phase4_env`
for the `full` subcommand, re-prepends *that* environment's `bin/` and can
otherwise push the wrapper behind it).

### 9.4. Two redundant formats, and why both exist

Each environment ships as **both** `.sqfs` (SquashFS image) and `.tar.gz`
(the original `conda pack` output):

- **`.sqfs` is the preferred, fast path.** With `squashfuse` installed
  (`sudo apt install -y squashfuse`, no root needed to *use* it), the
  environment is **mounted**, not extracted — this only indexes the image,
  it never creates loose files on disk, so it takes milliseconds even the
  very first time on a new machine. This matters enormously specifically
  because the portable disk lives on NTFS/exFAT via WSL2 (9p): creating
  thousands of small files one at a time over that filesystem stack is
  what makes a `.tar.gz` extraction take 10-25 minutes, and mounting a
  single pre-built image sidesteps that entirely. The mount point itself
  (`~/.reanote_mounts/<name>/`) has to live on the local machine's *native*
  filesystem, not the portable disk — the kernel explicitly forbids
  mounting a FUSE filesystem on top of a 9p one.
- **`.tar.gz` is the universal fallback.** If `squashfuse` isn't installed,
  `reanotar.sh` falls back to extracting the tarball into
  `engine/<name>/`, directly on the portable disk (see the timing
  breakdown in the main [`README.md`](README.md#packaged-runtime-environments)).
  This is strictly slower but requires nothing beyond `tar`, present on
  any Linux/WSL2 system by default.

### 9.5. Regenerating a packaged environment (when versions change)

Not yet scripted end-to-end in this repository — currently a manual
process. At a minimum, regenerating `phase4_env.tar.gz` after any version
bump in `phase4_env.yml` looks like:

```bash
conda env create -n phase4_env -f scripts/setup/phase4_env.yml
conda pack -n phase4_env --dest-prefix /mnt/f/ReAnote/engine/phase4_env -o phase4_env.tar.gz
# then materialize any symlinks manually before/after packing (NTFS/exFAT can't hold them),
# generate the .sqfs with mksquashfs, and re-verify the wrapper logic in reanotar.sh still
# covers every tool with a broken shebang in the freshly-packed environment.
```

See [section 10](#10-open-items--not-yet-covered) — this whole workflow
deserves its own automated script rather than living as prose here.

---

## 10. Open items / not yet covered

This is a first template, built from what was already audited and
scripted in this project plus official Ensembl documentation. Known gaps,
to fill in as this document grows:

- **gnomAD v4.1 (genomes + exomes) download automation** — currently
  manual, no script. Needs the 24-per-chromosome-file concatenation
  strategy worked out and the total size confirmed before scripting it
  (see [section 7.5](#75-gnomad-not-yet-automated)).
- **An actual `conda pack` regeneration script**, replacing the manual
  prose in [section 9.5](#95-regenerating-a-packaged-environment-when-versions-change).
- **The manually-gated plugin data sources** (SpliceAI, dbNSFP, dbscSNV,
  REVEL, satMutMPRA, MaxEntScan, EVE) — each needs its own step-by-step
  "how to actually get this once you have an account" walkthrough, since
  [section 6.3](#63-installing-plugin-data--whats-automated-vs-what-isnt)
  currently only says *where* to start, not the full manual procedure.
- **More detail in [section 8](#8-plugins-vs-custom-tracks-which-to-use-for-what)**
  as more sources get evaluated — the user specifically wants concrete
  "prefer custom track X over plugin/bundled snapshot Y because Z"
  recommendations built out further here.
- **A from-scratch dry-run**: this whole guide has not yet been validated
  by actually tearing down and rebuilding `data/` on a truly clean
  machine end-to-end — worth doing once to catch anything the scripts'
  own comments assume but this document doesn't state explicitly.
