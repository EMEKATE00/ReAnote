# ReAnote

Bioinformatics pipeline for variant re-annotation/analysis (VEP + GATK +
WhatsHap), packaged to live on a portable external hard drive shared
between different computers.

**Single entry point: `./reanotar.sh`.** Doesn't require conda installed or
an internet connection (except the first time each environment is used on
a new machine, and only as a last resort if something is missing from the
disk): the runtime environments (`phase4_env`, `gatk_env`) travel already
resolved and packaged under `engine/`, and activate automatically — via a
SquashFS mount (instant) if the machine has `squashfuse`, or by extracting
the `.tar.gz` as a fallback.

There's also a simple **graphical panel** (`Open_ReAnote.bat`) for anyone
not comfortable with a terminal — see [`USER_MANUAL.Rmd`](USER_MANUAL.Rmd)
for the full, non-technical, step-by-step guide (both the panel and the
command-line flow).

> **Looking to rebuild the reference data (`data/`, `engine/`) from
> scratch on a brand-new machine, with no portable disk to copy from?**
> That's a much longer, separate guide — see
> [**`INSTALLING_DATA.md`**](INSTALLING_DATA.md): VEP installation, the
> cache, every plugin and custom annotation track, and the reasoning
> behind the packaged runtime environments.

## First time on a new computer (with only WSL2 installed)

1. Connect the disk and open a terminal in your WSL2 distro.
2. Install `squashfuse` — optional but highly recommended, it's what makes
   the first load of each environment take milliseconds instead of minutes:
   ```bash
   sudo apt update && sudo apt install -y squashfuse
   ```
3. Launch the re-annotation directly, without installing anything else (no
   conda, no Perl, no VEP, no GATK — everything travels already resolved
   on the disk):
   ```bash
   cd /mnt/f/ReAnote   # or whatever letter/path Windows assigns on that machine
   ./reanotar.sh annotate -i input/X.vcf.gz -o outputs/X_annotated -s SampleName
   ```

If you skip step 2, everything still works the same, only the first time
each environment (`phase4_env`, and `gatk_env` if you use `liftover` or
`full`) is used on that machine it will take several minutes to extract
instead of being instant (see the *Packaged runtime environments* section).

## Quick usage

```bash
cd /mnt/f/ReAnote   # or wherever the system mounts the disk

./reanotar.sh --help                # see all subcommands
./reanotar.sh annotate --help       # help for a specific subcommand
./reanotar.sh annotate -i input/150.vep.annotated.vcf.gz -o outputs/150_annotated -s AY0167
```

### Subcommands

| Subcommand | Input | What it does |
|---|---|---|
| `annotate` | VCF already in hg38 | Cleans up previous annotations + VEP re-annotation (plugins + custom tracks). |
| `liftover` | VCF in hg19/hg37 | Liftover (GATK) hg19→hg38, then the same as `annotate`. |
| `full` | FASTQ folder | Full pipeline: alignment (BWA-MEM), variant calling (GATK HaplotypeCaller), filtering, VEP re-annotation. |

Each subcommand automatically activates the environment it needs
(`phase4_env` for VEP/WhatsHap, `gatk_env` for GATK/BWA) without the user
having to do anything by hand. With `squashfuse` installed, the first time
an environment is used on a machine it mounts in ~10ms — without
`squashfuse`, it extracts, which takes between ~1-2 min (internal/native
disks) and ~10-25 min (external NTFS/exFAT disks over USB, due to the
latency of creating thousands of small files). Later uses on the same
machine are practically instant either way.

## Folder structure

```
ReAnote/
├── reanotar.sh                      # Single entry point (subcommands annotate/liftover/full)
├── engine/
│   ├── phase4_env.sqfs              # SquashFS image of the environment (fast path: mounted, not extracted)
│   ├── phase4_env.tar.gz            # Same environment as a tar.gz (fallback if no squashfuse)
│   ├── gatk_env.sqfs                # SquashFS image: gatk, bwa, samtools, tabix, bgzip, picard, java
│   └── gatk_env.tar.gz              # Same environment as a tar.gz (fallback)
├── data/
│   ├── ensembl-vep/                 # ensembl-vep install (VEP + filter_vep, invoked by absolute path)
│   ├── ensembl*/                    # Ensembl Core API (ensembl, ensembl-variation, ensembl-io, ensembl-funcgen)
│   ├── .vep/                        # VEP cache (--dir_cache)
│   │   └── Plugins/                 # VEP plugins (--dir_plugins) and their own binaries/data
│   │       └── Data/                # Data files used directly by some plugins (SpliceAI, MaxEntScan, dbNSFP, dbscSNV...)
│   ├── reanote/
│   │   └── referencias/
│   │       └── hg38/                # Reference FASTA, dbSNP, Mills, liftover chain (hg19ToHg38.over.chain), etc.
│   └── custom/                      # VEP --custom annotation sources
│       ├── clinvar/                 # clinvar_chr.vcf.gz
│       ├── gnomad/
│       │   └── v4.1/
│       │       ├── genomes/         # gnomad.genomes.v4.1.sites.concat.vcf.gz
│       │       └── exomes/          # gnomad.exomes.v4.1.sites.concat.vcf.gz
│       └── regulomedb/              # regulomedb_ranking.bed.gz, regulomedb_score.bed.gz
├── scripts/                         # Internal scripts reanotar.sh invokes (rute_1.sh, phase1-4.sh, setup/)
├── input/                           # User input VCFs
└── outputs/                         # Outputs generated by pipeline runs
```

## Automatic base path detection

Since the external disk can be mounted with a different drive letter /
mount point depending on the computer (`/mnt/d`, `/mnt/e`, `/mnt/f`,
`/media/user/...`), `reanotar.sh` and the internal scripts it invokes
(`rute_1.sh`, `phase1-4.sh`) locate the disk at runtime:

1. It looks for a `ReAnote` folder directly under any `/mnt/*` mount point
   (typical on WSL2, where Windows mounts its drives).
2. If not found, it also tries under `/media/*` (typical mount on native
   Linux).
3. If neither search succeeds, the script aborts with an explicit error
   asking to check that the disk is connected.

## Platform support

- **The pipeline itself (`reanotar.sh` and everything under `scripts/`) is
  plain bash and was designed with native Linux in mind from the start**,
  not just WSL2 — the automatic base-path detection above already falls
  back to `/media/*/ReAnote` for that case, and none of the shell code is
  Windows-specific. On native Linux it should work at least as well as on
  WSL2, arguably better: a native filesystem (ext4, etc.) supports real
  symlinks/hard links, so several WSL2/NTFS-specific workarounds simply
  don't apply — no materialized-symlink packaging quirks, no broken
  Python shebangs to patch around (see
  [`INSTALLING_DATA.md`](INSTALLING_DATA.md#9-packaged-runtime-environments-how-and-why)
  for why those exist at all). This has not yet been tested end-to-end on
  a native Linux machine, only reasoned through from the code — treat it
  as "should work, not yet verified" rather than "confirmed."
- **The graphical panel (`ReAnote_GUI.ps1` / `Open_ReAnote.bat`) is Windows-only.**
  It's written in PowerShell against Windows Forms and has no Linux
  equivalent. On native Linux (or WSL2 without wanting to touch Windows at
  all), the pipeline is used entirely from the command line — see the
  *Quick usage* section above and [`USER_MANUAL.Rmd`](USER_MANUAL.Rmd) for
  the same commands explained step by step for non-technical users.
- **`squashfuse`** is a Linux userspace tool either way (not WSL-specific),
  so the fast `.sqfs` mount path works identically on native Linux.

## Packaged runtime environments

`phase4_env` and `gatk_env` are fully-resolved conda environments packaged
with `conda pack`, with one important quirk: since the disk usually lives
on NTFS/exFAT (via WSL2), which doesn't support symlinks or hard links,
all its links are materialized as real file copies, and the binaries that
relied on resolving their own location through a symlink (`vep`,
`filter_vep`, `gatk`, `picard`, `java`, and the JVM tools) carry a small
wrapper that invokes them at their real location. Each environment travels
in two redundant formats:

- **`engine/<name>.sqfs`** (SquashFS image) — preferred path. With
  `squashfuse` installed, `reanotar.sh` **mounts** it (doesn't extract it)
  at `~/.reanote_mounts/<name>/`, inside that machine's local filesystem —
  it can't be mounted directly on top of the portable disk, because the
  kernel forbids mounting FUSE on top of a 9p filesystem (which is how
  WSL2 exposes external disks). Mounting only indexes the image, it
  doesn't create loose files: it takes milliseconds even the first time.
- **`engine/<name>.tar.gz`** — the same environment as a tarball. If
  `squashfuse` isn't available, `reanotar.sh` automatically falls back to
  extracting it into `engine/<name>/`, on the portable disk itself (see
  timings in the previous section).

### What happens when I switch computers?

Nothing needs to be touched or deleted when moving the disk to another
computer — the behavior is automatic, but it's worth knowing what to
expect:

- If the `.tar.gz` path was ever used on some computer (for not having
  `squashfuse`), the already-extracted `engine/<name>/` folder stays
  **saved on the portable disk itself** and travels with it. On the next
  computer, `reanotar.sh` finds it already ready and uses it directly,
  without extracting or mounting anything again — extraction happens "once
  per disk", not "once per computer", if it's already been triggered once.
- The SquashFS path is different: the mount point (`~/.reanote_mounts/`)
  lives on each computer's **local** filesystem (not on the portable
  disk), so it doesn't travel with the disk. On every new computer where
  `engine/<name>/` isn't extracted yet, `reanotar.sh` mounts the image
  there again — but this is automatic and takes milliseconds, nothing
  needs to be done manually.
- In short: **nothing needs to be modified or deleted when switching
  computers**. At most, the first re-annotation on each new computer may
  take a bit longer while the environment mounts/prepares that first time;
  later ones are instant.

If you ever suspect a `.tar.gz` extraction was left half-done (due to a
disk/power interruption mid-process), force a clean extraction by deleting
the corresponding folder — `reanotar.sh` will regenerate it on its own on
the next run:

```bash
rm -rf engine/phase4_env engine/gatk_env
```

The `.sqfs`/`.tar.gz` files are never touched or lost by this — they're
the real portable artifacts; what gets deleted is only the already-extracted
working copy.

## Requirements and versions

- **WSL2** (Windows Subsystem for Linux 2) or native Linux, with `bash` and
  standard utilities (`tar`, `awk`, `grep`, `find`) — these come standard
  with any distro.
- **`squashfuse`** (optional but recommended): `sudo apt install -y
  squashfuse`. Enables the fast environment-loading path (milliseconds
  instead of minutes). Without it, everything still works the same, just
  slower the first time each environment is used on a machine.
- **conda is not required.** It's only used as a last resort if both the
  `.sqfs` and the `.tar.gz` of some environment are missing from `engine/`
  (an incomplete/old disk).

### Exact versions used in the reference installation

These are the real versions the pipeline was built and tested with
(confirmed by command, not from memory) — they serve as an exact reference
when rebuilding the `data/` environment from scratch on a new computer
(see [`INSTALLING_DATA.md`](INSTALLING_DATA.md)) or when repackaging
`engine/` with `conda pack`.

**Base system (Windows/WSL):**

| Component | Confirmed version |
|---|---|
| WSL | 2.7.12.0 (kernel 6.18.33.2) |
| WSL distro | Ubuntu 24.04.4 LTS (Noble Numbat) |
| bash | 5.2.21 |
| PowerShell (`powershell.exe`, classic Windows PowerShell) | 5.1.22621.7376 — **not** PowerShell 7/Core |
| squashfuse | 0.5.0 |
| RStudio Desktop (for `USER_MANUAL.Rmd`) | 2025.05.1+513 "Mariposa Orchid" (bundled Quarto 1.6.42) |

**`gatk_env` environment** (alignment + variant calling — `phase1.sh`/`phase2.sh`/`phase3.sh`):

| Tool | Confirmed version |
|---|---|
| GATK | 4.6.2.0 (HTSJDK 4.2.0) |
| BWA | 0.7.19-r1273 |
| samtools | 1.23 |
| Python (from the conda environment itself) | 3.10.19 |
| Java (OpenJDK) | 17.0.17 |

**`phase4_env` environment** (VEP re-annotation + phasing — `phase4.sh`/`rute_1.sh`):

| Tool | Confirmed version |
|---|---|
| ensembl-vep | 115.2 (tag `release/115.2`) |
| VEP cache | `homo_sapiens_merged`, version 115, GRCh38.p14 — GENCODE 49, dbSNP 156, ClinVar 202502, gnomAD v4.1 |
| WhatsHap | 2.8 |
| Perl | 5.32.1 |
| bcftools | 1.21 |
| samtools | 1.21 (note: different from `gatk_env`'s 1.23 — each environment was packaged separately) |
| vcfanno | 0.3.7 |

The full detail of the `ensembl-vep`/cache/plugins installation (exact git
tags, Perl dependencies, discrepancies found and fixed) is documented in
[`vep_install_manifest.md`](vep_install_manifest.md).
