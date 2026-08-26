#!/usr/bin/env bash
# ==============================================================================
# ReAnote — Single entry point of the pipeline
#
# Replaces scripts/orchestrator.sh as the user-facing interface: same three
# paths, but with readable subcommands instead of -r rute_1/rute_2/rute_3,
# and automatically activating the environments (phase4_env, gatk_env) from
# the tarballs packaged under engine/ — no conda or internet needed on a new
# machine.
#
# Subcommands:
#   annotate   VCF already in hg38 -> cleanup + VEP re-annotation.
#   liftover   VCF in hg19/hg37 -> liftover to hg38 -> cleanup + VEP re-annotation.
#   full       FASTQ -> full pipeline (alignment, variant calling,
#              filtering, VEP re-annotation).
#
# Single-step subcommands (to resume/chain manually without repeating
# steps already done, e.g. if you only have a BAM and want to call variants):
#   align      FASTQ -> aligned BAM ready for analysis (step 1).
#   call       BAM -> gVCF (variant calling, step 2).
#   filter     gVCF -> filtered VCF (hard-filtering, step 3).
#   vep        Filtered VCF + BAM -> VCF re-annotated with VEP (phasing + step 4).
#
# Run "./reanotar.sh --help" or "./reanotar.sh <subcommand> --help" to see
# the arguments for each one.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
ENGINE_DIR="$SCRIPT_DIR/engine"
REF_DIR="$SCRIPT_DIR/data/reanote/referencias"
HG38_FASTA="$REF_DIR/hg38/Homo_sapiens_assembly38.fasta"
CHAIN_FILE="$REF_DIR/hg38/hg19ToHg38.over.chain"

log()  { printf '[%s] [reanotar]  %s\n'  "$(date '+%H:%M:%S')" "$1" >&2; }
warn() { printf '[%s] [reanotar] WARNING: %s\n'  "$(date '+%H:%M:%S')" "$1" >&2; }
err()  { printf '[%s] [reanotar] ERROR: %s\n'  "$(date '+%H:%M:%S')" "$1" >&2; }

# ------------------------------------------------------------------------------
# ACTIVATING PACKAGED ENVIRONMENTS (without relying on conda by name)
# ------------------------------------------------------------------------------
# phase4_env (vep/filter_vep/bcftools/samtools/whatshap/vcfanno) and gatk_env
# (gatk/bwa/samtools/tabix/bgzip/picard/java) travel packaged in two formats
# under engine/:
#   - engine/<name>.sqfs   : SquashFS image (same structure as the tarball,
#     generated with mksquashfs from the already-materialized tree).
#     Preferred path: with squashfuse (user-space mount, no sudo needed) the
#     environment is ready in milliseconds, because mounting only indexes
#     the image — it doesn't create loose files on disk. This completely
#     avoids the file-by-file creation latency that makes extracting the
#     .tar.gz slow on NTFS/exFAT disks via WSL2 (9p).
#   - engine/<name>.tar.gz : the original format (conda pack --dest-prefix,
#     symlinks materialized by hand). Still the fallback if squashfuse isn't
#     available on the machine — same behavior as before SquashFS was added,
#     unchanged.
# If the .tar.gz is missing too, it falls back to "conda activate <name>" as
# a last resort (a dev machine with a traditional conda install).
activate_packed_env() {
    local env_name="$1"
    local packed_dir="$ENGINE_DIR/$env_name"
    local packed_sqfs="$ENGINE_DIR/${env_name}.sqfs"
    local packed_tarball="$ENGINE_DIR/${env_name}.tar.gz"
    # The squashfuse mount point CANNOT live inside the portable disk itself:
    # WSL2 mounts external disks via 9p, and the kernel explicitly forbids
    # mounting a FUSE filesystem on top of a 9p one ("mounting over
    # filesystem type 0x01021997 is forbidden"). The .sqfs image itself is
    # READ fine from F: — only the mount point must be on a local filesystem
    # (here, under $HOME, which persists across reboots unlike /tmp). This
    # doesn't reintroduce slowness: mounting stays ~10ms regardless of where
    # the mount point lives.
    local mount_dir="$HOME/.reanote_mounts/${env_name}"

    # Already mounted (SquashFS) or already extracted (tar.gz) in this
    # shell/machine.
    if [[ -f "$mount_dir/bin/activate" ]] && mountpoint -q "$mount_dir" 2>/dev/null; then
        set +u
        # shellcheck disable=SC1091
        source "$mount_dir/bin/activate"
        set -u
        fix_hardcoded_python_shebangs "$mount_dir/bin"
        return 0
    fi
    if [[ -f "$packed_dir/bin/activate" ]]; then
        set +u
        # shellcheck disable=SC1091
        source "$packed_dir/bin/activate"
        set -u
        fix_hardcoded_python_shebangs "$packed_dir/bin"
        return 0
    fi

    # Preferred path: mount the SquashFS image with squashfuse (no sudo).
    if [[ -f "$packed_sqfs" ]] && command -v squashfuse >/dev/null 2>&1; then
        mkdir -p "$mount_dir"
        if squashfuse "$packed_sqfs" "$mount_dir" 2>/dev/null; then
            log "Environment '$env_name' mounted (SquashFS, nothing extracted) at $mount_dir."
            set +u
            # shellcheck disable=SC1091
            source "$mount_dir/bin/activate"
            set -u
            fix_hardcoded_python_shebangs "$mount_dir/bin"
            return 0
        fi
        warn "squashfuse could not mount $packed_sqfs (a stale previous mount? try 'fusermount -u $mount_dir'). Falling back to .tar.gz."
    elif [[ -f "$packed_sqfs" ]]; then
        warn "A SquashFS image exists ($packed_sqfs) but 'squashfuse' is not installed (sudo apt install squashfuse speeds this up a lot). Falling back to .tar.gz."
    fi

    if [[ -f "$packed_tarball" ]]; then
        log "First time using '$env_name' on this machine: extracting from $packed_tarball"
        log "(no internet required; can take 10-25 min on external NTFS/exFAT disks over USB,"
        log " much less on internal/native disks — only the first time)"
        mkdir -p "$packed_dir"
        # -m/--no-same-permissions: NTFS/exFAT don't support exact Unix
        # utime()/permissions; without these flags tar aborts with "Cannot
        # change mode"/"Cannot utime". Even with both, the final cosmetic
        # chmod on the root directory can still fail on some disks — not
        # fatal (the content was already extracted fine), hence the ||
        # true. The real success signal is checked afterward, by activating
        # and testing the binaries.
        tar -xzf "$packed_tarball" -m --no-same-permissions -C "$packed_dir" || true
        set +u
        # shellcheck disable=SC1091
        source "$packed_dir/bin/activate"
        set -u
        fix_hardcoded_python_shebangs "$packed_dir/bin"
        log "Environment '$env_name' ready at $packed_dir."
        return 0
    fi

    warn "Neither $packed_sqfs nor $packed_tarball nor an already-prepared environment was found. Trying 'conda activate $env_name' as a last resort..."
    if command -v conda >/dev/null 2>&1; then
        set +u
        # shellcheck disable=SC1091
        source "$(conda info --base)/etc/profile.d/conda.sh"
        conda activate "$env_name"
        set -u
    else
        err "No packaged environment and no conda available for '$env_name'. Aborting."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# WRAPPERS FOR SCRIPTS WITH A HARDCODED INTERPRETER PATH
# ------------------------------------------------------------------------------
# conda pack --dest-prefix bakes a FIXED absolute path (the one the disk had
# when the environment was generated, e.g. /mnt/f/ReAnote/...) into the
# shebang of Python scripts installed as "console" entry points
# (pip/setuptools). If the disk gets mounted at a different letter/path on
# another computer (e.g. /mnt/d/ReAnote), that shebang ends up pointing at
# an interpreter that doesn't exist there, and the script dies with "No such
# file or directory" when run directly.
#
# This can't be fixed by rewriting the environment's own file: it works if
# it came from an extracted .tar.gz (would need to be redone every time, on
# every new computer), but it's IMPOSSIBLE if it came from a mounted .sqfs —
# SquashFS is read-only by design.
#
# Robust solution for both cases: generate, in a dedicated directory
# prepended to PATH, a one-line wrapper that explicitly invokes "python
# <real script>". By specifying the interpreter on the command line, bash
# never needs to read (or care about) the original script's broken shebang.
#
# whatshap is the only one of these scripts the pipeline invokes today
# (phase4.sh/rute_1.sh); it's added here rather than in each phase script so
# the fix lives in one place and automatically covers any future use.
fix_hardcoded_python_shebangs() {
    local env_bin="$1"
    local wrapper_dir="$HOME/.reanote_wrappers"
    mkdir -p "$wrapper_dir"

    local tool
    for tool in whatshap; do
        # -f (not -x): on NTFS/exFAT disks via WSL2, different computers can
        # report the executable bit inconsistently for the same physical
        # file (seen in production: the wrapper wasn't generated on a
        # machine where "-x" evaluated to false, leaving the wrapper out of
        # PATH and silently falling back to the broken binary). We only
        # need the file to exist to be able to invoke it via
        # "python <script>" — the +x bit isn't required.
        if [[ ! -f "$env_bin/$tool" ]]; then
            warn "fix_hardcoded_python_shebangs: $env_bin/$tool not found, skipping wrapper for '$tool'."
            continue
        fi
        cat > "$wrapper_dir/$tool" <<WRAP
#!/usr/bin/env bash
exec "$env_bin/python" "$env_bin/$tool" "\$@"
WRAP
        chmod +x "$wrapper_dir/$tool"
        log "Wrapper generated for '$tool' -> $env_bin/python $env_bin/$tool"
    done

    # ALWAYS prepend to PATH, in first position, so these wrappers win over
    # the environment's real binary (which may have the broken shebang). It
    # is not enough to check "if it's already in PATH, do nothing": when two
    # environments are activated in the same session (e.g. cmd_full
    # activates gatk_env first, then phase4_env), the second environment's
    # "source .../bin/activate" prepends ITS OWN bin/ to PATH again, pushing
    # wrapper_dir (already set from the previous activation) further back —
    # the second environment's broken binary ends up winning even though
    # wrapper_dir is "still in PATH". That's why any previous occurrence
    # must be removed and re-prepended every time, not just the first.
    PATH="$(echo ":$PATH:" | sed "s|:$wrapper_dir:|:|g")"
    export PATH="$wrapper_dir:${PATH#:}"
    PATH="${PATH%:}"

    # bash caches the resolved path of each command already looked up in
    # this shell (the "hash" table). If "whatshap" was already resolved
    # earlier in this same session (e.g. a previous activation without the
    # wrapper, or a shell reused across runs), bash will keep using that
    # cached path even after PATH changes — "which"/"command -v" DO see the
    # change, but invoking the command itself doesn't, until the table is
    # refreshed.
    hash -r 2>/dev/null || true

    # Explicit check: confirm each generated wrapper is really the one that
    # wins in PATH, not the environment's broken binary. If "which" resolves
    # somewhere else (e.g. because something else in the user's PATH defines
    # its own whatshap, or wrapper_dir didn't end up in front due to some
    # PATH already modified earlier), warn here instead of letting the
    # pipeline fail later with a cryptic "exec ... No such file or
    # directory" error.
    for tool in whatshap; do
        [[ -f "$wrapper_dir/$tool" ]] || continue
        local resolved
        resolved="$(command -v "$tool" 2>/dev/null || true)"
        if [[ "$resolved" != "$wrapper_dir/$tool" ]]; then
            warn "'$tool' resolves to '$resolved' instead of the wrapper ($wrapper_dir/$tool)."
            warn "There may be another '$tool' earlier in PATH. Run 'hash -r' or open a new shell if the pipeline fails at this step."
        fi
    done
}

# ------------------------------------------------------------------------------
# INTEGRITY CHECKS FOR RESUMING
# ------------------------------------------------------------------------------
# A file from a previous step is only considered valid to skip that step if
# it passes a real integrity check, not just "exists and has some size".
# This covers the case of a disk/network cut mid-write (the file remains
# present on the filesystem but truncated).
bam_is_valid() {
    local bam="$1"
    [[ -s "$bam" ]] || return 1
    samtools quickcheck -v "$bam" >/dev/null 2>&1
}

vcf_is_valid() {
    local vcf="$1"
    [[ -s "$vcf" ]] || return 1
    # bgzip -t validates the full BGZF integrity (block by block) — a file
    # cut mid-write fails here. bgzip is used instead of bcftools/tabix
    # because bgzip is present in both gatk_env and phase4_env; bcftools
    # only lives in phase4_env, and these checks run during steps (1-3)
    # that activate gatk_env.
    bgzip -t "$vcf" >/dev/null 2>&1 || return 1
    # bgzip -t alone doesn't guarantee the file ends with the fixed 28-byte
    # EOF block that marks a proper close (a .gz truncated right after a
    # complete block can pass the test above). That marker is checked
    # explicitly as a second signal.
    local eof_hex
    eof_hex="$(tail -c 28 "$vcf" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [[ "$eof_hex" == "1f8b08040000000000ff0600424302001b0003000000000000000000" ]] || return 1
    # bgzip -t + the EOF marker certify that the COMPRESSION is intact, but
    # not that the CONTENT is: a VEP process that dies/writes concurrently
    # can leave stray line breaks inside a field (e.g. CSQ), splitting a
    # variant row into several shorter physical lines without breaking the
    # gzip itself. This is detected by checking that every data line has the
    # same number of columns as the #CHROM header.
    zcat -f "$vcf" 2>/dev/null | awk -F'\t' '
        /^#CHROM/ { ncols=NF; next }
        /^#/ { next }
        { if (ncols && NF != ncols) { bad=1; exit } }
        END { exit (bad ? 1 : 0) }
    '
}

# ------------------------------------------------------------------------------
# CHROMOSOME NAMING NORMALIZATION (1 -> chr1, MT -> chrM)
# ------------------------------------------------------------------------------
normalize_chromosomes() {
    local in_vcf="$1"
    local out_dir="$2"
    local sample="$3"
    local out_vcf="$out_dir/${sample}_chr_normalized.vcf.gz"

    local first_chrom
    first_chrom=$(zcat -f "$in_vcf" | grep -v "^#" | head -n 1 | awk '{print $1}')

    if [[ "$first_chrom" != chr* ]]; then
        log "Detected naming without 'chr' (e.g. $first_chrom). Normalizing VCF..."
        zcat -f "$in_vcf" | awk '
        BEGIN { FS="\t"; OFS="\t" }
        /^##contig/ {
            sub(/ID=/, "ID=chr", $0);
            sub(/ID=chrMT/, "ID=chrM", $0);
            print; next;
        }
        /^#/ { print; next; }
        {
            $1 = "chr" $1;
            if ($1 == "chrMT") $1 = "chrM";
            print;
        }' | bgzip -c > "$out_vcf"
        tabix -p vcf "$out_vcf" 2>/dev/null || true
        echo "$out_vcf"
    else
        log "Correct chromosome naming (UCSC/chr). Skipping normalization."
        echo "$in_vcf"
    fi
}

# ------------------------------------------------------------------------------
# HELP
# ------------------------------------------------------------------------------
usage_global() {
    cat <<EOF
ReAnote — variant re-annotation/analysis pipeline (VEP + GATK + WhatsHap)

Usage:
  ./reanotar.sh <subcommand> [options]

Subcommands:
  annotate    VCF already in hg38  -> cleanup of previous annotations + VEP re-annotation.
  liftover    VCF in hg19/37       -> liftover (GATK) to hg38 -> cleanup + VEP re-annotation.
  full        FASTQ                -> full pipeline: alignment (BWA), variant
                                       calling (GATK), filtering, and VEP re-annotation.

Single-step subcommands (to relaunch/chain manually without repeating steps
already done, e.g. if you only have a BAM and want to call variants):
  align       FASTQ -> aligned BAM (step 1).
  call        BAM   -> gVCF (variant calling, step 2).
  filter      gVCF  -> filtered VCF (step 3).
  vep         Filtered VCF + BAM -> VCF re-annotated with VEP (phasing + step 4).

Help for each subcommand:
  ./reanotar.sh annotate --help
  ./reanotar.sh liftover --help
  ./reanotar.sh full --help
  ./reanotar.sh align --help
  ./reanotar.sh call --help
  ./reanotar.sh filter --help
  ./reanotar.sh vep --help

Quick example:
  ./reanotar.sh annotate -i input/150.vep.annotated.vcf.gz -o outputs/150_reannotated -s AY0167

All subcommands automatically activate the environment they need
(phase4_env and/or gatk_env) from the tarballs packaged under engine/ — no
need to have conda installed or an internet connection except the first run
of each environment on a new machine.
EOF
}

usage_annotate() {
    cat <<EOF
Usage: ./reanotar.sh annotate -i <input_vcf> -o <output_dir> -s <sample_name> [-b <input_bam>] [-m <tags_info>]

  -i   VCF/VCF.gz file to re-annotate (already in hg38).
  -o   Output folder (created if it doesn't exist).
  -s   Sample name (used to name the output files).
  -b   (Optional) Associated BAM, to apply phasing with WhatsHap before annotating.
  -m   (Optional) Extra INFO fields to keep from the original VCF, comma-separated.

Example:
  ./reanotar.sh annotate -i input/150.vep.annotated.vcf.gz -o outputs/150_reannotated -s AY0167
EOF
}

usage_liftover() {
    cat <<EOF
Usage: ./reanotar.sh liftover -i <input_vcf_hg19> -o <output_dir> -s <sample_name> [-b <input_bam>] [-m <tags_info>]

  -i   VCF/VCF.gz file in hg19/hg37 to convert and re-annotate.
  -o   Output folder (created if it doesn't exist).
  -s   Sample name.
  -b   (Optional) Associated BAM, to apply phasing with WhatsHap before annotating.
  -m   (Optional) Extra INFO fields to keep from the original VCF, comma-separated.

Runs, in this order: normalize chromosome naming -> GATK LiftoverVcf
(hg19 -> hg38, using data/reanote/referencias/hg38/hg19ToHg38.over.chain) ->
cleanup + VEP re-annotation (same as 'annotate', on the VCF already in hg38).

Example:
  ./reanotar.sh liftover -i input/sample_hg19.vcf.gz -o outputs/sample_liftover -s Sample01
EOF
}

usage_full() {
    cat <<EOF
Usage: ./reanotar.sh full -i <input_fastq_dir> -o <output_dir> -s <sample_name> -t <wes|wgs> [-e <bed>]

  -i   Folder with the input FASTQ files.
  -o   Output folder (subfolders phase1/, phase2/, phase3/, phase4/ are created).
  -s   Sample name.
  -t   Sequencing type: 'wes' (exome) or 'wgs' (whole genome).
  -e   BED file with the target regions (required if -t wes).

Runs the 4 steps in order: alignment (BWA-MEM), variant calling
(GATK HaplotypeCaller), filtering, and VEP re-annotation.

Example:
  ./reanotar.sh full -i input/fastq_sample01 -o outputs/sample01_full -s Sample01 -t wes -e regions.bed
EOF
}

usage_align() {
    cat <<EOF
Usage: ./reanotar.sh align -i <input_fastq_dir> -o <output_dir> -s <sample_name>

  -i   Folder with the input FASTQ files (named \${sample}_1.fastq.gz / _2.fastq.gz).
  -o   Output folder (creates \$o/phase1/\$s/ with the final BAM inside).
  -s   Sample name.

Only step 1 (BWA-MEM alignment + duplicate marking + BQSR). Useful if you
only want the BAM, without continuing to variant calling.

Example:
  ./reanotar.sh align -i input/fastq_sample01 -o outputs/sample01 -s Sample01
EOF
}

usage_call() {
    cat <<EOF
Usage: ./reanotar.sh call -i <input_bam> -o <output_dir> -s <sample_name> -t <wes|wgs> [-e <bed>]

  -i   Input BAM (already aligned, e.g. the one generated by 'align').
  -o   Output folder (creates the gVCF \$o/\${s}.g.vcf.gz inside).
  -s   Sample name.
  -t   Sequencing type: 'wes' (exome) or 'wgs' (whole genome).
  -e   BED file with the target regions (required if -t wes).

Only step 2 (GATK HaplotypeCaller). Useful if you already have a BAM (your
own or from another source) and only want variant calling, without redoing
the alignment.

Example:
  ./reanotar.sh call -i outputs/sample01/phase1/Sample01/Sample01.analysis_ready.bam -o outputs/sample01/phase2 -s Sample01 -t wgs
EOF
}

usage_filter() {
    cat <<EOF
Usage: ./reanotar.sh filter -i <input_gvcf> -o <output_dir> -s <sample_name>

  -i   Input gVCF (e.g. the one generated by 'call').
  -o   Output folder (creates the VCF \$o/\${s}.hard_filtered.vcf.gz inside).
  -s   Sample name.

Only step 3 (hard-filtering of SNPs/indels). Useful to relaunch only the
filtering step, without redoing variant calling.

Example:
  ./reanotar.sh filter -i outputs/sample01/phase2/Sample01.g.vcf.gz -o outputs/sample01/phase3 -s Sample01
EOF
}

usage_vep() {
    cat <<EOF
Usage: ./reanotar.sh vep -i <input_vcf> -b <input_bam> -o <output_dir> -s <sample_name>

  -i   Input filtered VCF (e.g. the one generated by 'filter').
  -b   Associated BAM (required: used for phasing with WhatsHap before annotating).
  -o   Output folder (creates the VCF \$o/\${s}.vep.annotated.vcf.gz inside).
  -s   Sample name.

Only step 4 (phasing with WhatsHap + VEP re-annotation). Useful to relaunch
only the annotation step, without redoing alignment/calling/filtering. If
instead of a VCF already filtered by this pipeline you have a VCF already
in hg38 from any other source, it's usually better to use
'./reanotar.sh annotate'.

Example:
  ./reanotar.sh vep -i outputs/sample01/phase3/Sample01.hard_filtered.vcf.gz -b outputs/sample01/phase1/Sample01/Sample01.analysis_ready.bam -o outputs/sample01/phase4 -s Sample01
EOF
}

# ------------------------------------------------------------------------------
# SUBCOMMANDS
# ------------------------------------------------------------------------------
cmd_annotate() {
    local INPUT="" OUTPUT="" SAMPLE="" BAM_ARG="" TAGS_ARG=""
    for arg in "$@"; do [[ "$arg" == "--help" ]] && { usage_annotate; exit 0; }; done
    while getopts "i:o:s:b:m:h" opt; do
        case $opt in
            i) INPUT="$(realpath "$OPTARG")" ;;
            o) OUTPUT="$(realpath -m "$OPTARG")" ;;
            s) SAMPLE="$OPTARG" ;;
            b) BAM_ARG="-b $(realpath "$OPTARG")" ;;
            m) TAGS_ARG="-m $OPTARG" ;;
            h) usage_annotate; exit 0 ;;
            *) usage_annotate; exit 1 ;;
        esac
    done

    if [[ -z "$INPUT" || -z "$OUTPUT" || -z "$SAMPLE" ]]; then
        err "Missing required arguments (-i, -o, -s)."
        usage_annotate
        exit 1
    fi

    mkdir -p "$OUTPUT"
    activate_packed_env phase4_env

    local normalized
    normalized="$(normalize_chromosomes "$INPUT" "$OUTPUT" "$SAMPLE")"

    log "Launching re-annotation..."
    exec bash "$SCRIPTS_DIR/rute_1.sh" -i "$normalized" -o "$OUTPUT" -s "$SAMPLE" $BAM_ARG $TAGS_ARG
}

cmd_liftover() {
    local INPUT="" OUTPUT="" SAMPLE="" BAM_ARG="" TAGS_ARG=""
    for arg in "$@"; do [[ "$arg" == "--help" ]] && { usage_liftover; exit 0; }; done
    while getopts "i:o:s:b:m:h" opt; do
        case $opt in
            i) INPUT="$(realpath "$OPTARG")" ;;
            o) OUTPUT="$(realpath -m "$OPTARG")" ;;
            s) SAMPLE="$OPTARG" ;;
            b) BAM_ARG="-b $(realpath "$OPTARG")" ;;
            m) TAGS_ARG="-m $OPTARG" ;;
            h) usage_liftover; exit 0 ;;
            *) usage_liftover; exit 1 ;;
        esac
    done

    if [[ -z "$INPUT" || -z "$OUTPUT" || -z "$SAMPLE" ]]; then
        err "Missing required arguments (-i, -o, -s)."
        usage_liftover
        exit 1
    fi

    if [[ ! -f "$CHAIN_FILE" ]]; then
        err "Liftover chain file not found: $CHAIN_FILE"
        exit 1
    fi

    mkdir -p "$OUTPUT"
    activate_packed_env gatk_env

    local normalized
    normalized="$(normalize_chromosomes "$INPUT" "$OUTPUT" "$SAMPLE")"

    local lifted_vcf="$OUTPUT/${SAMPLE}_hg38.vcf.gz"
    log "Step 1/2: LiftoverVcf (GATK) hg19 -> hg38..."
    gatk --java-options "-Xmx16g" LiftoverVcf \
        -I "$normalized" \
        -O "$lifted_vcf" \
        -CHAIN "$CHAIN_FILE" \
        -R "$HG38_FASTA" \
        -REJECT "$OUTPUT/rejected.vcf" \
        --RECOVER_SWAPPED_REF_ALT true

    activate_packed_env phase4_env
    log "Step 2/2: VEP re-annotation (hg38)..."
    exec bash "$SCRIPTS_DIR/rute_1.sh" -i "$lifted_vcf" -o "$OUTPUT" -s "$SAMPLE" $BAM_ARG $TAGS_ARG
}

cmd_full() {
    local INPUT="" OUTPUT="" SAMPLE="" SEQ_TYPE="wgs" BED_ARG=""
    for arg in "$@"; do [[ "$arg" == "--help" ]] && { usage_full; exit 0; }; done
    while getopts "i:o:s:t:e:h" opt; do
        case $opt in
            i) INPUT="$(realpath "$OPTARG")" ;;
            o) OUTPUT="$(realpath -m "$OPTARG")" ;;
            s) SAMPLE="$OPTARG" ;;
            t) SEQ_TYPE="$OPTARG" ;;
            e) BED_ARG="-b $(realpath "$OPTARG")" ;;
            h) usage_full; exit 0 ;;
            *) usage_full; exit 1 ;;
        esac
    done

    if [[ -z "$INPUT" || -z "$OUTPUT" || -z "$SAMPLE" ]]; then
        err "Missing required arguments (-i, -o, -s)."
        usage_full
        exit 1
    fi
    if [[ "$SEQ_TYPE" == "wes" && -z "$BED_ARG" ]]; then
        err "-e <bed> is required when -t wes."
        usage_full
        exit 1
    fi

    mkdir -p "$OUTPUT"
    activate_packed_env gatk_env

    local bam_final="$OUTPUT/phase1/$SAMPLE/${SAMPLE}.analysis_ready.bam"
    local gvcf="$OUTPUT/phase2/${SAMPLE}.g.vcf.gz"
    local hard_filtered="$OUTPUT/phase3/${SAMPLE}.hard_filtered.vcf.gz"

    if bam_is_valid "$bam_final"; then
        log "Step 1/4: Alignment -- SKIPPED (already exists and is valid: $bam_final)"
    else
        if [[ -e "$OUTPUT/phase1" ]]; then
            warn "Step 1/4: incomplete/truncated previous output detected at $OUTPUT/phase1 -- deleting before relaunching."
            rm -rf "$OUTPUT/phase1"
        fi
        log "Step 1/4: Alignment (BWA-MEM)..."
        bash "$SCRIPTS_DIR/phase1.sh" -i "$INPUT" -o "$OUTPUT" -r "$REF_DIR/hg38" -s "$SAMPLE"
        bam_is_valid "$bam_final" || { err "Step 1 finished but $bam_final is not valid. Aborting."; exit 1; }
    fi

    if vcf_is_valid "$gvcf"; then
        log "Step 2/4: HaplotypeCaller -- SKIPPED (already exists and is valid: $gvcf)"
    else
        if [[ -e "$OUTPUT/phase2" ]]; then
            warn "Step 2/4: incomplete/truncated previous output detected at $OUTPUT/phase2 -- deleting before relaunching."
            rm -rf "$OUTPUT/phase2"
        fi
        log "Step 2/4: HaplotypeCaller ($SEQ_TYPE)..."
        bash "$SCRIPTS_DIR/phase2.sh" -i "$bam_final" -o "$OUTPUT/phase2" -r "$REF_DIR/hg38" -s "$SAMPLE" -t "$SEQ_TYPE" $BED_ARG
        vcf_is_valid "$gvcf" || { err "Step 2 finished but $gvcf is not valid. Aborting."; exit 1; }
    fi

    if vcf_is_valid "$hard_filtered"; then
        log "Step 3/4: Filtering -- SKIPPED (already exists and is valid: $hard_filtered)"
    else
        if [[ -e "$OUTPUT/phase3" ]]; then
            warn "Step 3/4: incomplete/truncated previous output detected at $OUTPUT/phase3 -- deleting before relaunching."
            rm -rf "$OUTPUT/phase3"
        fi
        log "Step 3/4: Filtering..."
        bash "$SCRIPTS_DIR/phase3.sh" -i "$gvcf" -o "$OUTPUT/phase3" -r "$REF_DIR/hg38" -s "$SAMPLE"
        vcf_is_valid "$hard_filtered" || { err "Step 3 finished but $hard_filtered is not valid. Aborting."; exit 1; }
    fi

    local vep_annotated="$OUTPUT/phase4/${SAMPLE}.vep.annotated.vcf.gz"
    if vcf_is_valid "$vep_annotated"; then
        log "Step 4/4: VEP re-annotation -- SKIPPED (already exists and is valid: $vep_annotated)"
        exit 0
    fi
    if [[ -e "$OUTPUT/phase4" ]]; then
        warn "Step 4/4: incomplete/truncated previous output detected at $OUTPUT/phase4 -- deleting before relaunching."
        rm -rf "$OUTPUT/phase4"
    fi

    activate_packed_env phase4_env
    log "Step 4/4: VEP re-annotation..."
    exec bash "$SCRIPTS_DIR/phase4.sh" -i "$hard_filtered" -b "$bam_final" -o "$OUTPUT/phase4" -s "$SAMPLE"
}

# ------------------------------------------------------------------------------
# SINGLE-STEP SUBCOMMANDS (individual steps, for manual use/resuming)
# ------------------------------------------------------------------------------
cmd_align() {
    local INPUT="" OUTPUT="" SAMPLE=""
    for arg in "$@"; do [[ "$arg" == "--help" ]] && { usage_align; exit 0; }; done
    while getopts "i:o:s:h" opt; do
        case $opt in
            i) INPUT="$(realpath "$OPTARG")" ;;
            o) OUTPUT="$(realpath -m "$OPTARG")" ;;
            s) SAMPLE="$OPTARG" ;;
            h) usage_align; exit 0 ;;
            *) usage_align; exit 1 ;;
        esac
    done

    if [[ -z "$INPUT" || -z "$OUTPUT" || -z "$SAMPLE" ]]; then
        err "Missing required arguments (-i, -o, -s)."
        usage_align
        exit 1
    fi

    mkdir -p "$OUTPUT"
    activate_packed_env gatk_env

    log "Alignment (BWA-MEM)..."
    bash "$SCRIPTS_DIR/phase1.sh" -i "$INPUT" -o "$OUTPUT" -r "$REF_DIR/hg38" -s "$SAMPLE"

    local bam_final="$OUTPUT/phase1/$SAMPLE/${SAMPLE}.analysis_ready.bam"
    bam_is_valid "$bam_final" || { err "Alignment finished but $bam_final is not valid."; exit 1; }
    log "Alignment completed: $bam_final"
}

cmd_call() {
    local INPUT="" OUTPUT="" SAMPLE="" SEQ_TYPE="wgs" BED_ARG=""
    for arg in "$@"; do [[ "$arg" == "--help" ]] && { usage_call; exit 0; }; done
    while getopts "i:o:s:t:e:h" opt; do
        case $opt in
            i) INPUT="$(realpath "$OPTARG")" ;;
            o) OUTPUT="$(realpath -m "$OPTARG")" ;;
            s) SAMPLE="$OPTARG" ;;
            t) SEQ_TYPE="$OPTARG" ;;
            e) BED_ARG="-b $(realpath "$OPTARG")" ;;
            h) usage_call; exit 0 ;;
            *) usage_call; exit 1 ;;
        esac
    done

    if [[ -z "$INPUT" || -z "$OUTPUT" || -z "$SAMPLE" ]]; then
        err "Missing required arguments (-i, -o, -s)."
        usage_call
        exit 1
    fi
    if [[ "$SEQ_TYPE" == "wes" && -z "$BED_ARG" ]]; then
        err "-e <bed> is required when -t wes."
        usage_call
        exit 1
    fi

    mkdir -p "$OUTPUT"
    activate_packed_env gatk_env

    log "Variant calling (HaplotypeCaller, $SEQ_TYPE)..."
    bash "$SCRIPTS_DIR/phase2.sh" -i "$INPUT" -o "$OUTPUT" -r "$REF_DIR/hg38" -s "$SAMPLE" -t "$SEQ_TYPE" $BED_ARG

    local gvcf="$OUTPUT/${SAMPLE}.g.vcf.gz"
    vcf_is_valid "$gvcf" || { err "Variant calling finished but $gvcf is not valid."; exit 1; }
    log "Variant calling completed: $gvcf"
}

cmd_filter() {
    local INPUT="" OUTPUT="" SAMPLE=""
    for arg in "$@"; do [[ "$arg" == "--help" ]] && { usage_filter; exit 0; }; done
    while getopts "i:o:s:h" opt; do
        case $opt in
            i) INPUT="$(realpath "$OPTARG")" ;;
            o) OUTPUT="$(realpath -m "$OPTARG")" ;;
            s) SAMPLE="$OPTARG" ;;
            h) usage_filter; exit 0 ;;
            *) usage_filter; exit 1 ;;
        esac
    done

    if [[ -z "$INPUT" || -z "$OUTPUT" || -z "$SAMPLE" ]]; then
        err "Missing required arguments (-i, -o, -s)."
        usage_filter
        exit 1
    fi

    mkdir -p "$OUTPUT"
    activate_packed_env gatk_env

    log "Filtering (hard-filtering SNPs/indels)..."
    bash "$SCRIPTS_DIR/phase3.sh" -i "$INPUT" -o "$OUTPUT" -r "$REF_DIR/hg38" -s "$SAMPLE"

    local hard_filtered="$OUTPUT/${SAMPLE}.hard_filtered.vcf.gz"
    vcf_is_valid "$hard_filtered" || { err "Filtering finished but $hard_filtered is not valid."; exit 1; }
    log "Filtering completed: $hard_filtered"
}

cmd_vep() {
    local INPUT="" BAM="" OUTPUT="" SAMPLE=""
    for arg in "$@"; do [[ "$arg" == "--help" ]] && { usage_vep; exit 0; }; done
    while getopts "i:b:o:s:h" opt; do
        case $opt in
            i) INPUT="$(realpath "$OPTARG")" ;;
            b) BAM="$(realpath "$OPTARG")" ;;
            o) OUTPUT="$(realpath -m "$OPTARG")" ;;
            s) SAMPLE="$OPTARG" ;;
            h) usage_vep; exit 0 ;;
            *) usage_vep; exit 1 ;;
        esac
    done

    if [[ -z "$INPUT" || -z "$BAM" || -z "$OUTPUT" || -z "$SAMPLE" ]]; then
        err "Missing required arguments (-i, -b, -o, -s)."
        usage_vep
        exit 1
    fi

    mkdir -p "$OUTPUT"
    activate_packed_env phase4_env

    log "Phasing (WhatsHap) + VEP re-annotation..."
    exec bash "$SCRIPTS_DIR/phase4.sh" -i "$INPUT" -b "$BAM" -o "$OUTPUT" -s "$SAMPLE"
}

# ------------------------------------------------------------------------------
# DISPATCH
# ------------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    usage_global
    exit 1
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
    annotate)   cmd_annotate "$@" ;;
    liftover)   cmd_liftover "$@" ;;
    full)       cmd_full "$@" ;;
    align)      cmd_align "$@" ;;
    call)       cmd_call "$@" ;;
    filter)     cmd_filter "$@" ;;
    vep)        cmd_vep "$@" ;;
    -h|--help|help) usage_global ;;
    *)
        err "Unknown subcommand: '$SUBCOMMAND'"
        usage_global
        exit 1
        ;;
esac
