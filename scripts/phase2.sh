#!/bin/bash

# ==============================================================================
# SCRIPT: Phase 2 Workflow - BAM to gVCF (HaplotypeCaller)
# Supports: WES / WGS (Single Sample -> GVCF)
# ==============================================================================

set -euo pipefail

# --- COLORS AND STYLING ---
R="\e[31m"  # Red (Error)
G="\e[32m"  # Green (Success)
Y="\e[33m"  # Yellow (Warning)
B="\e[34m"  # Blue (Info)
NC="\e[0m"  # No Color

log_info()  { echo -e "${B}[$(date '+%H:%M:%S')] [INFO]${NC} $1"; }
log_warn()  { echo -e "${Y}[$(date '+%H:%M:%S')] [WARN]${NC} $1"; }
log_error() { echo -e "${R}[$(date '+%H:%M:%S')] [ERROR]${NC} $1"; }
log_ok()    { echo -e "${G}[$(date '+%H:%M:%S')] [OK]${NC} $1"; }

banner() {
    echo -e "${B}==========================================================${NC}"
    echo -e "${B}   GATK BEST PRACTICES - PHASE 2: HAPLOTYPE CALLER        ${NC}"
    echo -e "${B}==========================================================${NC}"
}

usage() {
    echo -e "
${Y}Usage:${NC} $0 -i <bam> -o <dir> -r <dir> -s <name> -t <wes|wgs> [-b targets.bed] [-m memory]

${B}Arguments:${NC}
  -i  analysis_ready BAM file (requires .bai)
  -o  Output directory
  -r  Reference directory (must contain hg38 and dbsnp)
  -s  Sample name
  -t  Type: 'wes' (Exome) or 'wgs' (Genome)
  -b  BED file (Required for WES)
  -m  Java memory (Default: 16g)
"
    exit 1
}

# --- DEFAULT VALUES ---
JAVA_MEM="16g"
THREADS_HMM=4  # 4 is the sweet spot for PairHMM, 16 is usually overkill

# --- ARGUMENT PARSING ---
while getopts "i:o:r:s:t:b:m:" opt; do
    case $opt in
        i) INPUT_BAM="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        r) REF_DIR="$OPTARG" ;;
        s) SAMPLE_NAME="$OPTARG" ;;
        t) SEQ_TYPE="$OPTARG" ;;
        b) TARGET_BED="$OPTARG" ;;
        m) JAVA_MEM="$OPTARG" ;;
        *) usage ;;
    esac
done

banner

# --- 1. ARGUMENT VALIDATION ---
if [[ -z "${INPUT_BAM:-}" || -z "${OUTPUT_DIR:-}" || -z "${REF_DIR:-}" || -z "${SAMPLE_NAME:-}" || -z "${SEQ_TYPE:-}" ]]; then
    log_error "Missing required arguments."
    usage
fi

if [[ "$SEQ_TYPE" != "wes" && "$SEQ_TYPE" != "wgs" ]]; then
    log_error "Type (-t) must be 'wes' or 'wgs'."
    exit 1
fi

if [[ "$SEQ_TYPE" == "wes" && -z "${TARGET_BED:-}" ]]; then
    log_error "For WES (-t wes) the BED file (-b) is required."
    exit 1
fi

# --- 2. PATH SETUP AND FILE VALIDATION ---
# Adjust these names if your references are named differently
REF_FASTA="${REF_DIR}/Homo_sapiens_assembly38.fasta"
DBSNP="${REF_DIR}/Homo_sapiens_assembly38.dbsnp138.vcf"

# Array of required files to check for existence
REQUIRED_FILES=("$INPUT_BAM" "$REF_FASTA" "$DBSNP")
[[ "$SEQ_TYPE" == "wes" ]] && REQUIRED_FILES+=("$TARGET_BED")

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        exit 1
    fi
done

# Prepare directories
mkdir -p "$OUTPUT_DIR"
TMP_DIR="${OUTPUT_DIR}/tmp"
mkdir -p "$TMP_DIR"

OUTPUT_GVCF="${OUTPUT_DIR}/${SAMPLE_NAME}.g.vcf.gz"

# --- 3. BAM INDEX CHECK ---
if [[ ! -f "${INPUT_BAM}.bai" && ! -f "${INPUT_BAM%.bam}.bai" ]]; then
    log_warn "BAM index not found. Generating with Samtools..."
    if command -v samtools &> /dev/null; then
        samtools index -@ 8 "$INPUT_BAM"
        log_ok "Index generated."
    else
        log_error "Samtools is not installed/on PATH and the index is missing."
        exit 1
    fi
fi

# --- 4. BUILDING THE GATK COMMAND ---
log_info "Configuring HaplotypeCaller..."
log_info "  > Sample: $SAMPLE_NAME"
log_info "  > Type:   $SEQ_TYPE"
log_info "  > Memory: $JAVA_MEM"

HC_OPTS=(
    -R "$REF_FASTA"
    -I "$INPUT_BAM"
    -O "$OUTPUT_GVCF"
    -ERC GVCF                # CRITICAL: GVCF mode for cohorts
    --dbsnp "$DBSNP"
    --native-pair-hmm-threads "$THREADS_HMM"
    --tmp-dir "$TMP_DIR"     # CRITICAL: avoid filling up the system's /tmp
    --create-output-variant-index true
)

if [[ "$SEQ_TYPE" == "wes" ]]; then
    log_info "  > Intervals: $TARGET_BED"
    # Add optional 100bp padding to catch variants near exon boundaries
    HC_OPTS+=( -L "$TARGET_BED" --interval-padding 100 )
fi

# --- 5. EXECUTION ---
log_info "Starting analysis..."

gatk --java-options "-Xmx${JAVA_MEM}" HaplotypeCaller "${HC_OPTS[@]}"

# --- 6. WRAP-UP ---
if [[ -f "$OUTPUT_GVCF" ]]; then
    log_ok "Phase 2 completed successfully."
    log_ok "Generated: $OUTPUT_GVCF"

    # tmp cleanup (optional, uncomment if desired)
    # rm -rf "$TMP_DIR"
else
    log_error "GATK finished but the output file was not generated."
    exit 1
fi
