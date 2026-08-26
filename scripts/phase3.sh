#!/bin/bash

# ==============================================================================
# SCRIPT: Phase 3 Workflow - Genotyping & Hard Filtering (GATK Best Practices)
# Reference: https://gatk.broadinstitute.org/hc/en-us/articles/360035890471
# Context: Small Cohort / Single Sample (VQSR not possible)
# ==============================================================================

set -euo pipefail

# --- COLORS AND LOGS ---
R="\e[31m"
G="\e[32m"
B="\e[34m"
NC="\e[0m"

log_info()  { echo -e "${B}[INFO]${NC} $1"; }
log_ok()    { echo -e "${G}[OK]${NC} $1"; }
log_error() { echo -e "${R}[ERROR]${NC} $1"; }

usage() {
    echo "Usage: $0 -i <input_gvcf> -o <output_dir> -r <ref_dir> -s <sample_name>"
    echo "Example: ./phase3.sh -i data/sample.g.vcf.gz -o data/phase3 -r refs/ -s Sample01"
    exit 1
}

# --- ARGUMENTS ---
while getopts "i:o:r:s:" opt; do
    case $opt in
        i) INPUT_GVCF="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        r) REF_DIR="$OPTARG" ;;
        s) SAMPLE_NAME="$OPTARG" ;;
        *) usage ;;
    esac
done

if [[ -z "${INPUT_GVCF:-}" || -z "${OUTPUT_DIR:-}" || -z "${REF_DIR:-}" || -z "${SAMPLE_NAME:-}" ]]; then
    log_error "Missing required arguments."
    usage
fi

# --- CONFIGURATION ---
REF_FASTA="${REF_DIR}/Homo_sapiens_assembly38.fasta"
DBSNP="${REF_DIR}/Homo_sapiens_assembly38.dbsnp138.vcf" # Adjust name if needed

# Check references
if [[ ! -f "$REF_FASTA" ]]; then log_error "FASTA not found: $REF_FASTA"; exit 1; fi
if [[ ! -f "$DBSNP" ]]; then log_error "dbSNP not found: $DBSNP"; exit 1; fi

mkdir -p "$OUTPUT_DIR"

# Intermediate and final files
RAW_VCF="${OUTPUT_DIR}/${SAMPLE_NAME}.raw.vcf.gz"
SNPS_VCF="${OUTPUT_DIR}/${SAMPLE_NAME}.snps.vcf.gz"
INDELS_VCF="${OUTPUT_DIR}/${SAMPLE_NAME}.indels.vcf.gz"
FILTERED_SNPS="${OUTPUT_DIR}/${SAMPLE_NAME}.filtered.snps.vcf.gz"
FILTERED_INDELS="${OUTPUT_DIR}/${SAMPLE_NAME}.filtered.indels.vcf.gz"
FINAL_VCF="${OUTPUT_DIR}/${SAMPLE_NAME}.hard_filtered.vcf.gz"

# --- EXECUTION ---

echo "=========================================================="
echo "PHASE 3: GENOTYPING AND FILTERING (HARD-FILTERING)"
echo "Sample: $SAMPLE_NAME"
echo "=========================================================="

# 1. GenotypeGVCFs
# --------------------------------------------------------
log_info "[1/4] Genotyping (GVCF -> VCF)..."

# Note: including -D (dbSNP) here is Best Practice so rsIDs get carried into
# the final VCF. GATK recommends --only-output-calls-starting-in-intervals
# if you're using intervals, but if it's WGS or you don't have a BED handy,
# it's omitted to analyze everything.

gatk --java-options "-Xmx16g" GenotypeGVCFs \
    -R "$REF_FASTA" \
    -V "$INPUT_GVCF" \
    -D "$DBSNP" \
    -O "$RAW_VCF"

# 2. Separate SNPs and INDELs
# --------------------------------------------------------
log_info "[2/4] Separating SNPs and Indels..."

gatk SelectVariants \
    -R "$REF_FASTA" \
    -V "$RAW_VCF" \
    -select-type SNP \
    -O "$SNPS_VCF"

gatk SelectVariants \
    -R "$REF_FASTA" \
    -V "$RAW_VCF" \
    -select-type INDEL \
    -O "$INDELS_VCF"

# 3. Hard Filtering (Per GATK Docs)
# --------------------------------------------------------
log_info "[3/4] Applying filters (tagging)..."

# SNP FILTERS: https://gatk.broadinstitute.org/hc/en-us/articles/360035890471
# QD < 2.0: Quality by Depth. High-quality but low-depth variant (false positive).
# MQ < 40.0: Mapping Quality. Poorly aligned reads.
# FS > 60.0: FisherStrand. Strand bias.
# SOR > 3.0: StrandOddsRatio. Another, more robust strand bias test.
# MQRankSum < -12.5: Compares mapping quality of reads with REF vs ALT.
# ReadPosRankSum < -8.0: Position of the variant within the read (edges are usually error-prone).

gatk VariantFiltration \
    -R "$REF_FASTA" \
    -V "$SNPS_VCF" \
    -O "$FILTERED_SNPS" \
    --filter-name "QD_filter"             -filter "QD < 2.0" \
    --filter-name "MQ_filter"             -filter "MQ < 40.0" \
    --filter-name "FS_filter"             -filter "FS > 60.0" \
    --filter-name "SOR_filter"            -filter "SOR > 3.0" \
    --filter-name "MQRankSum_filter"      -filter "MQRankSum < -12.5" \
    --filter-name "ReadPosRankSum_filter" -filter "ReadPosRankSum < -8.0"

# INDEL FILTERS:
# Note: MQRankSum is not used for Indels in recent standard recommendations,
# but FS is more permissive (200.0) than for SNPs.

gatk VariantFiltration \
    -R "$REF_FASTA" \
    -V "$INDELS_VCF" \
    -O "$FILTERED_INDELS" \
    --filter-name "QD_filter"             -filter "QD < 2.0" \
    --filter-name "FS_filter"             -filter "FS > 200.0" \
    --filter-name "ReadPosRankSum_filter" -filter "ReadPosRankSum < -20.0"

# 4. Final Merge
# --------------------------------------------------------
log_info "[4/4] Merging final VCF..."

# Merge the two filtered files
gatk MergeVcfs \
    -I "$FILTERED_SNPS" \
    -I "$FILTERED_INDELS" \
    -O "${OUTPUT_DIR}/temp_merged.vcf.gz"

# Final cleanup:
# - Exclude Non-Variants: removes 0/0 or ./. blocks that take up useless space.
# - We do NOT use --exclude-filtered: we want the "bad" variants to still
#   pass through to the database with their tag.

gatk SelectVariants \
    -R "$REF_FASTA" \
    -V "${OUTPUT_DIR}/temp_merged.vcf.gz" \
    -O "$FINAL_VCF" \
    --exclude-non-variants \
    --remove-unused-alternates

# Clean up intermediate files
rm -f "$SNPS_VCF" "$INDELS_VCF" "$FILTERED_SNPS" "$FILTERED_INDELS" "${OUTPUT_DIR}/temp_merged.vcf.gz"
rm -f "${OUTPUT_DIR}"/*.tbi

log_ok "Phase 3 completed."
log_ok "File ready for database: $FINAL_VCF"
