#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# GATK BEST PRACTICES – PHASE 1 (UNIFIED & STABLE)
# FASTQ → uBAM → Aligned BAM → Merge → MarkDuplicates → BQSR
# Environment: WSL2 / Linux Compatible
# Strategy: Robust Alignment (Named Pipes) + Stable Processing (Picard/No-Spark)
# ==============================================================================

# --- 0. PRE-FLIGHT CHECKS ---

JAVA_VER=$(java -version 2>&1 | head -n1 | cut -d'"' -f2 | cut -d'.' -f1)
if [[ "$JAVA_VER" -gt 21 ]]; then
    echo "WARNING: You are using Java $JAVA_VER. For stable production use, Java 17 LTS is recommended."
fi

usage() {
    echo "Usage: $0 -i <input_dir_fastq> -o <base_data_dir> -r <ref_dir> -s <sample_name> [-t threads]"
    echo "Description: Full GATK Best Practices Pipeline (Phase 1)."
    exit 1
}

THREADS=16 # Safe default value to avoid saturation in final steps

while getopts "i:o:r:s:t:" opt; do
    case "$opt" in
        i) DATA_DIR="$OPTARG" ;;
        o) BASE_DATA_DIR="$OPTARG" ;;
        r) REF_DIR="$OPTARG" ;;
        s) SAMPLE="$OPTARG" ;;
        t) THREADS="$OPTARG" ;;
        *) usage ;;
    esac
done

if [[ -z "${DATA_DIR:-}" || -z "${BASE_DATA_DIR:-}" || -z "${REF_DIR:-}" || -z "${SAMPLE:-}" ]]; then
    echo "ERROR: Missing required arguments."
    usage
fi

# ==============================
# DIRECTORY SETUP
# ==============================

OUT_DIR="${BASE_DATA_DIR}/phase1/${SAMPLE}"
TMP_DIR="${OUT_DIR}/tmp"
mkdir -p "${OUT_DIR}"/{ubam,aligned,logs} "$TMP_DIR"


JAVA_OPT_PER_LANE="-Xmx8g -Djava.io.tmpdir=${TMP_DIR}"
JAVA_OPT_HEAVY="-Xmx12g -Djava.io.tmpdir=${TMP_DIR}"

REF_FASTA="${REF_DIR}/Homo_sapiens_assembly38.fasta"
DBSNP="${REF_DIR}/Homo_sapiens_assembly38.dbsnp138.vcf"
MILLS="${REF_DIR}/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz"

# Reference validation
for file in "$REF_FASTA" "$DBSNP" "$MILLS" "${REF_FASTA}.bwt"; do
    if [[ ! -f "$file" ]]; then
        echo "CRITICAL ERROR: Missing reference file or index: $file"
        exit 1
    fi
done

echo "=== STARTING PIPELINE: $SAMPLE ==="
echo "Output Directory: $OUT_DIR"

# ==============================================================================
# STEP 1: PER-LANE ALIGNMENT (PER-LANE PROCESSING)
# ==============================================================================

BAM_LIST_FILE="${OUT_DIR}/bam_list.txt"
FASTQ_LIST="${OUT_DIR}/fastq_inputs.txt"

# Generate list of inputs
find "$DATA_DIR" -name "*_1.fastq.gz" > "$FASTQ_LIST"

if [ ! -s "$FASTQ_LIST" ]; then
    echo "ERROR: No *_1.fastq.gz files found in $DATA_DIR"
    exit 1
fi

> "$BAM_LIST_FILE"

# --- FIX FOR WSL2: CREATE PIPE DIRECTORY ON LOCAL LINUX DISK ---
LOCAL_PIPE_DIR=$(mktemp -d)
trap "rm -rf '$LOCAL_PIPE_DIR'" EXIT

echo ">>> STARTING ALIGNMENT..."

while read -r R1; do
    R2="${R1/_1.fastq.gz/_2.fastq.gz}"
    if [[ ! -f "$R2" ]]; then echo "ERROR: Missing R2 for: $R1"; exit 1; fi

    BASE=$(basename "$R1" _1.fastq.gz)

    FLOWCELL=$(echo "$BASE" | cut -d_ -f1)
    LANE=$(echo "$BASE" | cut -d_ -f2)
    LIBRARY_NAME=$(echo "$BASE" | cut -d_ -f3-)
    RGID="${FLOWCELL}.${LANE}"
    PL_UNIT="${FLOWCELL}.${LANE}"

    UBAM="${OUT_DIR}/ubam/${BASE}.ubam"
    ALIGNED_LANE="${OUT_DIR}/aligned/${BASE}.aligned.bam"

    # Named pipe on local disk
    BWA_PIPE="${LOCAL_PIPE_DIR}/${BASE}.bwa_output.pipe"
    rm -f "$BWA_PIPE" 2>/dev/null
    mkfifo "$BWA_PIPE"

    echo ">>> [LANE] Processing $RGID (Lib: $LIBRARY_NAME)"

    # A. FASTQ -> uBAM
    gatk --java-options "$JAVA_OPT_PER_LANE" FastqToSam \
        --FASTQ "$R1" --FASTQ2 "$R2" \
        --OUTPUT "$UBAM" \
        --SAMPLE_NAME "$SAMPLE" \
        --READ_GROUP_NAME "$RGID" \
        --LIBRARY_NAME "$LIBRARY_NAME" \
        --PLATFORM "ILLUMINA" \
        --PLATFORM_UNIT "$PL_UNIT" \
        --COMPRESSION_LEVEL 5

    # B. Streaming Alignment
    echo "   [ALIGN] Streaming uBAM -> BWA -> Pipe -> MergeBamAlignment"

    (
        set -o pipefail
        gatk --java-options "-Xmx4g" SamToFastq \
            --INPUT "$UBAM" \
            --FASTQ /dev/stdout \
            --CLIPPING_ATTRIBUTE XT --CLIPPING_ACTION 2 \
            --INTERLEAVE true --INCLUDE_NON_PF_READS true \
        | \
        bwa mem -p -v 3 -t "$THREADS" -Y -K 100000000 "$REF_FASTA" /dev/stdin \
        > "$BWA_PIPE"
    ) &
    PID_PRODUCER=$!

    gatk --java-options "$JAVA_OPT_PER_LANE" MergeBamAlignment \
        --VALIDATION_STRINGENCY SILENT \
        --EXPECTED_ORIENTATIONS FR \
        --ATTRIBUTES_TO_RETAIN X0 \
        --ALIGNED_BAM "$BWA_PIPE" \
        --UNMAPPED_BAM "$UBAM" \
        --OUTPUT "$ALIGNED_LANE" \
        --REFERENCE_SEQUENCE "$REF_FASTA" \
        --PAIRED_RUN true \
        --SORT_ORDER "unsorted" \
        --IS_BISULFITE_SEQUENCE false \
        --ALIGNED_READS_ONLY false \
        --CLIP_ADAPTERS false \
        --MAX_RECORDS_IN_RAM 2000000 \
        --ADD_MATE_CIGAR true \
        --MAX_INSERTIONS_OR_DELETIONS -1 \
        --PRIMARY_ALIGNMENT_STRATEGY MostDistant \
        --UNMAPPED_READ_STRATEGY COPY_TO_TAG \
        --ALIGNER_PROPER_PAIR_FLAGS true \
        --UNMAP_CONTAMINANT_READS true

    wait $PID_PRODUCER
    if [ $? -ne 0 ]; then echo "ERROR: Alignment failed"; exit 1; fi

    rm -f "$BWA_PIPE"
    echo "$ALIGNED_LANE" >> "$BAM_LIST_FILE"

done < "$FASTQ_LIST"

# ==============================================================================
# STEP 2: MERGE & SORT (Picard MergeSamFiles)
# ==============================================================================
# Replaces Spark/SortSam. Merges N files and sorts by coordinate.

mapfile -t ALIGNED_BAMS_ARRAY < "$BAM_LIST_FILE"
if [ ${#ALIGNED_BAMS_ARRAY[@]} -eq 0 ]; then echo "ERROR: No BAMs were generated."; exit 1; fi

INPUT_ARGS=()
for b in "${ALIGNED_BAMS_ARRAY[@]}"; do
    INPUT_ARGS+=("--INPUT" "$b")
done

SORTED_BAM="${OUT_DIR}/${SAMPLE}.sorted.bam"

echo ">>> [MERGE] Merging and sorting ${#ALIGNED_BAMS_ARRAY[@]} files..."

gatk --java-options "$JAVA_OPT_HEAVY" MergeSamFiles \
    "${INPUT_ARGS[@]}" \
    --OUTPUT "$SORTED_BAM" \
    --SORT_ORDER coordinate \
    --CREATE_INDEX true \
    --MAX_RECORDS_IN_RAM 2000000 \
    --VALIDATION_STRINGENCY SILENT \
    --USE_THREADING true

# ==============================================================================
# STEP 3: MARK DUPLICATES (Picard Standard)
# ==============================================================================

DEDUP_BAM="${OUT_DIR}/${SAMPLE}.dedup.bam"
METRICS_FILE="${OUT_DIR}/${SAMPLE}.duplicate_metrics.txt"

echo ">>> [MARKDUPS] Marking duplicates (Standard)..."

gatk --java-options "$JAVA_OPT_HEAVY" MarkDuplicates \
    --INPUT "$SORTED_BAM" \
    --OUTPUT "$DEDUP_BAM" \
    --METRICS_FILE "$METRICS_FILE" \
    --CREATE_INDEX true \
    --VALIDATION_STRINGENCY SILENT \
    --ASSUME_SORT_ORDER coordinate

# Clean up the sorted intermediate (saves space)
rm -f "$SORTED_BAM" "${SORTED_BAM%.bam}.bai"

# ==============================================================================
# STEP 4: BQSR (GATK Engine - Short Arguments)
# ==============================================================================

RECAL_TABLE="${OUT_DIR}/${SAMPLE}.recal.table"
FINAL_BAM="${OUT_DIR}/${SAMPLE}.analysis_ready.bam"

echo ">>> [BQSR] Generating recalibration table..."

# Note: BaseRecalibrator uses -I, -R, -O arguments (does not accept --INPUT)
gatk --java-options "$JAVA_OPT_HEAVY" BaseRecalibrator \
    -I "$DEDUP_BAM" \
    -R "$REF_FASTA" \
    --known-sites "$DBSNP" \
    --known-sites "$MILLS" \
    -O "$RECAL_TABLE"

echo ">>> [BQSR] Applying recalibration..."

# Note: ApplyBQSR uses -I, -R, -O arguments (does not accept --INPUT)
gatk --java-options "$JAVA_OPT_HEAVY" ApplyBQSR \
    -I "$DEDUP_BAM" \
    -R "$REF_FASTA" \
    --bqsr-recal-file "$RECAL_TABLE" \
    -O "$FINAL_BAM" \
    --create-output-bam-index true

echo "============================================================"
echo "PHASE 1 PIPELINE COMPLETED SUCCESSFULLY"
echo "Sample:    $SAMPLE"
echo "Final BAM: $FINAL_BAM"
echo "============================================================"
