#!/usr/bin/env bash
# ==============================================================================
# ReAnote — Installing directly-downloadable annotation sources (no login)
#
# Downloads the sources rute_1.sh/phase4.sh need that do NOT require
# registration/account/license with authentication friction: ClinVar,
# mutfunc, UTRAnnotator, AlphaMissense, Conservation (GERP/phyloP/phastCons)
# and CADD. Every URL was manually verified with curl -I before writing this
# script (see the 2026-07-21 conversation) — no size/URL from third-party
# audits was assumed without confirming it.
#
# NOT covered (require manual intervention — see the separate report):
#   - SpliceAI:   requires an Illumina BaseSpace account + an authenticated
#                 'bs' CLI.
#   - dbNSFP:     requires registration with an institutional email (Google
#                 Form) and reconstructing the file from per-chromosome tables.
#   - dbscSNV:    same ecosystem/academic license as dbNSFP.
#   - REVEL:      no account needed, but restricted to non-commercial use
#                 (manual download from Google Sites, no stable verified
#                 direct download URL).
#   - satMutMPRA: the verified endpoint returns 401 Unauthorized — it's an
#                 interactive Shiny app (kircherlab.bihealth.org), not an FTP.
#   - MaxEntScan: origin server (hollywood.mit.edu) unreachable at the time
#                 this script was written (ERR_CONNECT_FAIL) — retry later
#                 or look for a mirror.
#   - EVE:        the login-free endpoint only exposes alignments (MSAs),
#                 not the variant-scores VCF the plugin needs — requires
#                 non-trivial reconstruction from evemodel.org.
#   - gnomAD genomes v4.1: public on GCS but split into 24 per-chromosome
#                 files to concatenate; total size not confirmed, left out
#                 of this script due to its volume (possibly several hundred
#                 GB) — see the separate report before downloading it.
#
# Idempotent: each download checks the expected size before repeating it.
# ==============================================================================
set -euo pipefail

# --- AUTOMATIC BASE PATH DETECTION (portable disk) ---
detect_reanote_base() {
    local found
    found=$(find /mnt/*/ReAnote -maxdepth 0 2>/dev/null | head -n1)
    if [[ -z "$found" ]]; then
        found=$(find /media/*/ReAnote -maxdepth 0 2>/dev/null | head -n1)
    fi
    if [[ -z "$found" ]]; then
        echo "ERROR: Could not find the ReAnote folder under any mount point (/mnt/*, /media/*). Is the disk connected?" >&2
        exit 1
    fi
    echo "$found"
}

REANOTE_BASE="$(detect_reanote_base)"
DATA_DIR="$REANOTE_BASE/data"
VEP_CACHE="$DATA_DIR/.vep"
VEP_PLUGINS="$VEP_CACHE/Plugins"
VEP_DATA="$VEP_PLUGINS/Data"
CUSTOM_DIR="$DATA_DIR/custom"
REF_DIR="$DATA_DIR/reanote/referencias/hg38"
REF_FASTA="$REF_DIR/Homo_sapiens_assembly38.fasta"

SCRIPT_START_TS=$(date +%s)
log()  { printf '[%s] [INFO]  %s\n'  "$(date '+%H:%M:%S')" "$1"; }
warn() { printf '[%s] [WARN]  %s\n'  "$(date '+%H:%M:%S')" "$1" >&2; }
err()  { printf '[%s] [ERROR] %s\n'  "$(date '+%H:%M:%S')" "$1" >&2; }
step() {
    local elapsed=$(( $(date +%s) - SCRIPT_START_TS ))
    printf '\n[%s] [+%ds] ==== %s ====\n' "$(date '+%H:%M:%S')" "$elapsed" "$1"
}
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

# --- ACTIVATING phase4_env (for bcftools/tabix/bgzip in the ClinVar step) ---
CONDA_BASE="$(conda info --base 2>/dev/null || true)"
if [[ -n "$CONDA_BASE" ]]; then
    set +u
    # shellcheck disable=SC1091
    source "$CONDA_BASE/etc/profile.d/conda.sh"
    conda activate phase4_env 2>/dev/null || warn "Could not activate 'phase4_env'. bcftools/tabix must still be on PATH for the ClinVar step."
    set -u
else
    warn "conda is not on PATH. bcftools/tabix must still be available for the ClinVar step."
fi

for c in curl bcftools tabix bgzip; do require_cmd "$c"; done

mkdir -p "$VEP_PLUGINS/Conservation" "$VEP_DATA" "$CUSTOM_DIR/clinvar"

# resumable_download <url> <dest_final> [expected_bytes] [min_sane_bytes]
# (identical to the one in install_vep_engine.sh — see there for the full reasoning)
resumable_download() {
    local url="$1" dest="$2" expected_bytes="${3:-}" min_sane_bytes="${4:-1048576}"
    local part="${dest}.part"

    if [[ -f "$dest" ]]; then
        if [[ -n "$expected_bytes" ]]; then
            local existing_bytes
            existing_bytes=$(stat -c%s "$dest" 2>/dev/null || echo 0)
            if [[ "$existing_bytes" == "$expected_bytes" ]]; then
                log "$(basename "$dest") already exists with the expected size ($expected_bytes bytes). Skipping download."
                return 0
            fi
            warn "$(basename "$dest") exists but with a size different from expected ($existing_bytes vs $expected_bytes). It will be re-verified/resumed via .part."
            mv -f "$dest" "$part"
        else
            log "$(basename "$dest") already exists. Skipping download."
            return 0
        fi
    fi

    if [[ -f "$part" ]]; then
        local part_bytes
        part_bytes=$(stat -c%s "$part" 2>/dev/null || echo 0)
        if [[ "$part_bytes" -gt 0 && "$part_bytes" -lt "$min_sane_bytes" ]]; then
            warn "Existing partial for $(basename "$dest") is suspiciously small ($part_bytes bytes, reasonable minimum $min_sane_bytes). Discarding and starting over instead of resuming."
            rm -f "$part"
        fi
    fi

    local part_size_before=0
    [[ -f "$part" ]] && part_size_before=$(stat -c%s "$part" 2>/dev/null || echo 0)
    if [[ "$part_size_before" -gt 0 ]]; then
        log "Resuming download of $(basename "$dest") from $part_size_before bytes already downloaded..."
    else
        log "Downloading $(basename "$dest") from $url ..."
    fi

    if ! curl -fL --retry 3 --retry-delay 10 -C - -o "$part" "$url"; then
        if [[ -f "$part" ]]; then
            warn "curl -C - failed (possibly the server doesn't support partial ranges, or a network drop). Discarding partial and retrying from scratch."
            rm -f "$part"
        fi
        curl -fL --retry 3 --retry-delay 10 -C - -o "$part" "$url"
    fi

    mv -f "$part" "$dest"

    if [[ -n "$expected_bytes" ]]; then
        local final_bytes
        final_bytes=$(stat -c%s "$dest")
        if [[ "$final_bytes" != "$expected_bytes" ]]; then
            err "$(basename "$dest") downloaded but with a size different from expected ($final_bytes vs $expected_bytes bytes). It may be corrupted or the source changed — check manually."
            exit 1
        fi
    fi
    log "$(basename "$dest") downloaded and verified ($(stat -c%s "$dest") bytes)."
}

# ==============================================================================
# STEP 1: ClinVar (NCBI FTP) + chromosome naming reprocessing
# ==============================================================================
step "STEP 1/6: ClinVar (NCBI) + 'chr' prefix"

CLINVAR_RAW="$CUSTOM_DIR/clinvar/clinvar_raw.vcf.gz"
CLINVAR_FINAL="$CUSTOM_DIR/clinvar/clinvar_chr.vcf.gz"
# Size verified with curl -I on 2026-07-21; ClinVar is updated weekly, so
# this value may become outdated — if the size check fails on a future run,
# confirm the new Content-Length with:
#   curl -sI https://ftp.ncbi.nlm.nih.gov/pub/clinvar/vcf_GRCh38/clinvar.vcf.gz
CLINVAR_EXPECTED_BYTES=192302201

if [[ -f "$CLINVAR_FINAL" ]]; then
    log "$CLINVAR_FINAL already exists. Skipping ClinVar entirely."
else
    if [[ ! -f "$REF_FASTA.fai" ]]; then
        err "$REF_FASTA.fai does not exist — needed to get the real contig lengths. Run install_vep_engine.sh first (STEP 6)."
        exit 1
    fi

    resumable_download "https://ftp.ncbi.nlm.nih.gov/pub/clinvar/vcf_GRCh38/clinvar.vcf.gz" "$CLINVAR_RAW" "$CLINVAR_EXPECTED_BYTES" 1024

    # NCBI's official VCF names chromosomes "1".."22","X","Y","MT" (no
    # prefix) and also does NOT declare ##contig header lines — bcftools
    # rejects this outright ("Contig '1' is not defined in the header").
    # The VCF also includes variants on 8 alternate scaffolds (NT_*/NW_*,
    # confirmed: 48 out of ~4.4M variants) that don't exist in this
    # pipeline's reference FASTA (which only has the 25 main contigs) —
    # they're dropped, not remapped.
    #
    # 3-step strategy:
    #   A. Inject ##contig for EVERY CHROM value present in the VCF
    #      (including the NT_/NW_ scaffolds) so bcftools can parse it
    #      without error. The 25 main ones use the real length from the
    #      .fai; the scaffolds get a placeholder (dropped in the next step,
    #      their declared length is irrelevant).
    #   B. Filter down to just the 25 main contigs (bcftools view -t),
    #      dropping the NT_/NW_ scaffolds.
    #   C. Rename 1->chr1 ... MT->chrM (bcftools annotate --rename-chrs).
    log "Detecting every CHROM value present in the source VCF..."
    all_chroms="$(mktemp)"
    zcat "$CLINVAR_RAW" | grep -v "^#" | awk '{print $1}' | sort -u > "$all_chroms"

    log "Generating ##contig lines (real length for 1-22/X/Y/MT from the .fai; placeholder for the NT_/NW_ scaffolds, which are dropped afterward)..."
    contig_lines="$(mktemp)"
    fai_lengths="$(mktemp)"
    awk 'BEGIN{OFS="\t"} {name=$1; sub(/^chr/,"",name); if (name=="M") name="MT"; print name, $2}' "$REF_FASTA.fai" > "$fai_lengths"
    while read -r c; do
        real_len="$(awk -v c="$c" '$1==c{print $2; exit}' "$fai_lengths")"
        echo "##contig=<ID=$c,length=${real_len:-999999999}>" >> "$contig_lines"
    done < "$all_chroms"
    rm -f "$fai_lengths" "$all_chroms"

    log "Step A: injecting contig headers..."
    step_a="$(mktemp --suffix=.vcf.gz)"
    bcftools annotate --header-lines "$contig_lines" -Oz -o "$step_a" "$CLINVAR_RAW"
    rm -f "$contig_lines"

    log "Step B: filtering down to the 25 main contigs (dropping alternate NT_/NW_ scaffolds)..."
    step_b="$(mktemp --suffix=.vcf.gz)"
    bcftools view -t "$(seq -s, 1 22),X,Y,MT" "$step_a" -Oz -o "$step_b"
    rm -f "$step_a"

    log "Step C: renaming chromosomes to 'chr*' naming (MT -> chrM)..."
    chr_map="$(mktemp)"
    {
        for i in $(seq 1 22); do echo "$i chr$i"; done
        echo "X chrX"
        echo "Y chrY"
        echo "MT chrM"
    } > "$chr_map"
    bcftools annotate --rename-chrs "$chr_map" -Oz -o "$CLINVAR_FINAL" "$step_b"
    rm -f "$chr_map" "$step_b"

    log "Indexing $CLINVAR_FINAL with tabix..."
    tabix -f -p vcf "$CLINVAR_FINAL"

    rm -f "$CLINVAR_RAW"
    log "ClinVar OK: $CLINVAR_FINAL"
fi

# ==============================================================================
# STEP 2: mutfunc (Ensembl FTP)
# ==============================================================================
step "STEP 2/6: mutfunc (Ensembl FTP)"

mkdir -p "$VEP_PLUGINS/mutfunc"
resumable_download \
    "https://ftp.ensembl.org/pub/current_variation/mutfunc/mutfunc_data.db" \
    "$VEP_PLUGINS/mutfunc/mutfunc_data.db" \
    2098589696

# ==============================================================================
# STEP 3: UTRAnnotator (GitHub, MIT license)
# ==============================================================================
step "STEP 3/6: UTRAnnotator"

mkdir -p "$VEP_DATA/UTRannotator"
resumable_download \
    "https://raw.githubusercontent.com/ImperialCardioGenetics/UTRannotator/master/uORF_5UTR_GRCh38_PUBLIC.txt" \
    "$VEP_DATA/UTRannotator/uORF_5UTR_GRCh38_PUBLIC.txt" \
    2376724 \
    1024

# ==============================================================================
# STEP 4: AlphaMissense (Zenodo, CC BY 4.0)
# ==============================================================================
step "STEP 4/6: AlphaMissense"

mkdir -p "$VEP_PLUGINS/Alphamissense"
resumable_download \
    "https://zenodo.org/records/10813168/files/AlphaMissense_hg38.tsv.gz" \
    "$VEP_PLUGINS/Alphamissense/AlphaMissense_hg38.tsv.gz" \
    642961469

# ==============================================================================
# STEP 5: Conservation — GERP (Ensembl) + phyloP/phastCons (UCSC)
# ==============================================================================
step "STEP 5/6: Conservation (GERP, phyloP100way, phastCons100way)"

# GERP: the folder is "92_mammals.gerp_conservation_score" in release-115
# (not "91_mammals" — verified by listing the real directory, not assumed).
resumable_download \
    "https://ftp.ensembl.org/pub/release-115/compara/conservation_scores/92_mammals.gerp_conservation_score/gerp_conservation_scores.homo_sapiens.GRCh38.bw" \
    "$VEP_PLUGINS/Conservation/gerp_conservation_scores.homo_sapiens.GRCh38.bw" \
    9600895779

resumable_download \
    "https://hgdownload.soe.ucsc.edu/goldenPath/hg38/phyloP100way/hg38.phyloP100way.bw" \
    "$VEP_PLUGINS/Conservation/hg38.phyloP100way.bw" \
    9870053206

resumable_download \
    "https://hgdownload.soe.ucsc.edu/goldenPath/hg38/phastCons100way/hg38.phastCons100way.bw" \
    "$VEP_PLUGINS/Conservation/hg38.phastCons100way.bw" \
    5886377734

# ==============================================================================
# STEP 6: CADD v1.6 (SNVs + indels GRCh38) — free for NON-commercial use only
# ==============================================================================
step "STEP 6/6: CADD v1.6 (SNVs + indels)"
warn "CADD is free to use for NON-commercial purposes only (see the COPYRIGHT at the source URL). Commercial use requires a license — https://cadd.gs.washington.edu/"

mkdir -p "$VEP_PLUGINS/CADD"

# NOTE: the pipeline specifically asks for 'gnomad.genomes.r3.0.indel.tsv.gz',
# which corresponds to CADD v1.6 (the current v1.7 already uses gnomAD r4.0
# with a different file name) — v1.6 is pinned on purpose, it's not an old
# version left by oversight.
resumable_download \
    "https://krishna.gs.washington.edu/download/CADD/v1.6/GRCh38/whole_genome_SNVs.tsv.gz" \
    "$VEP_PLUGINS/CADD/whole_genome_SNVs.tsv.gz" \
    86592987071 \
    $((100 * 1024 * 1024))

resumable_download \
    "https://krishna.gs.washington.edu/download/CADD/v1.6/GRCh38/whole_genome_SNVs.tsv.gz.tbi" \
    "$VEP_PLUGINS/CADD/whole_genome_SNVs.tsv.gz.tbi"

resumable_download \
    "https://krishna.gs.washington.edu/download/CADD/v1.6/GRCh38/gnomad.genomes.r3.0.indel.tsv.gz" \
    "$VEP_PLUGINS/CADD/gnomad.genomes.r3.0.indel.tsv.gz" \
    1165363333

resumable_download \
    "https://krishna.gs.washington.edu/download/CADD/v1.6/GRCh38/gnomad.genomes.r3.0.indel.tsv.gz.tbi" \
    "$VEP_PLUGINS/CADD/gnomad.genomes.r3.0.indel.tsv.gz.tbi"

# ==============================================================================
# SUMMARY
# ==============================================================================
step "SUMMARY"
elapsed_total=$(( $(date +%s) - SCRIPT_START_TS ))
log "Completed in ${elapsed_total}s: ClinVar, mutfunc, UTRAnnotator, AlphaMissense, Conservation, CADD."
log ""
log "PENDING MANUAL ACTION (cannot be automated without your intervention):"
log "  - SpliceAI:   requires an Illumina BaseSpace account (basespace.illumina.com) + the 'bs' CLI."
log "  - dbNSFP:     academic registration at dbnsfp.org/download (non-commercial license)."
log "  - dbscSNV:    distributed together with dbNSFP, same registration."
log "  - REVEL:      sites.google.com/site/revelgenomics/downloads (non-commercial use)."
log "  - satMutMPRA: interactive portal kircherlab.bihealth.org (401 on direct download)."
log "  - MaxEntScan: server hollywood.mit.edu was unreachable at the time this was written."
log "  - EVE:        evemodel.org only exposes MSAs without login; the final VCF requires reconstruction."
log "  - gnomAD genomes v4.1: public on GCS but split into 24 per-chromosome files to concatenate,"
log "    total size not confirmed (possibly hundreds of GB) — not included here due to its volume."
