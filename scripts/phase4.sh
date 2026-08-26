#!/bin/bash

# ==============================================================================
# SCRIPT: Phase 4 Workflow - Phasing & Functional Annotation (VEP)
# DESCRIPTION:
# 1. Physical phasing with WhatsHap (using the BAM).
# 2. Deep functional annotation with VEP + Plugins.
# 3. Filtering of priority transcripts (MANE, Canonical, etc.).
# ==============================================================================

set -e
set -u
set -o pipefail

# --- AUTOMATIC BASE PATH DETECTION (portable disk) ---
detect_reanote_base() {
    local found
    found=$(find /mnt/*/ReAnote -maxdepth 0 2>/dev/null | head -n1)
    if [[ -z "$found" ]]; then
        # Fallback: also look under /media/*/ReAnote-style mounts (native Linux)
        found=$(find /media/*/ReAnote -maxdepth 0 2>/dev/null | head -n1)
    fi
    if [[ -z "$found" ]]; then
        echo "ERROR: Could not find the ReAnote folder under any mount point (/mnt/*, /media/*). Is the disk connected?" >&2
        exit 1
    fi
    echo "$found"
}

REANOTE_BASE="$(detect_reanote_base)"

# --- 1. PATH SETUP (based on REANOTE_BASE, the portable disk) ---
BASE_DIR="$REANOTE_BASE/data"
VEP_HOME="$BASE_DIR/ensembl-vep"
VEP_CACHE="$BASE_DIR/.vep"
VEP_PLUGINS="$BASE_DIR/.vep/Plugins"
VEP_DATA="$VEP_PLUGINS/Data"
REF_HG38="$BASE_DIR/reanote/referencias/hg38/Homo_sapiens_assembly38.fasta"

# ensembl-vep/vep only adds its own modules/ to @INC, not the 4 core API
# repos (ensembl, ensembl-variation, ensembl-io, ensembl-funcgen — cloned by
# install_vep_engine.sh under $BASE_DIR) — without this, Bio::EnsEMBL::Registry
# and friends don't resolve and "vep" fails.
export PERL5LIB="$BASE_DIR/ensembl/modules:$BASE_DIR/ensembl-variation/modules:$BASE_DIR/ensembl-io/modules:$BASE_DIR/ensembl-funcgen/modules${PERL5LIB:+:$PERL5LIB}"

# Without this, vep dies with "Attempt to reload Bio/DB/HTS/Tabix.pm aborted"
# (a load-order bug between core API repos — see install_vep_engine.sh).
export PERL5OPT="-MBio::DB::HTS::Tabix${PERL5OPT:+ $PERL5OPT}"

# Plugin-specific paths
UTR_FILE="$VEP_DATA/UTRannotator/uORF_5UTR_GRCh38_PUBLIC.txt"

# --- CUSTOM TRACK PATHS ---
CUSTOM_DIR="$BASE_DIR/custom"
CLINVAR_FILE="$CUSTOM_DIR/clinvar/clinvar_chr.vcf.gz"

GNOMAD_GENOMES="$CUSTOM_DIR/gnomad/v4.1/genomes/gnomad.genomes.v4.1.sites.concat.vcf.gz"
GNOMAD_EXOMES="$CUSTOM_DIR/gnomad/v4.1/exomes/gnomad.exomes.v4.1.sites.concat.vcf.gz"

# --- 2. INPUT ARGUMENTS ---
usage() {
    echo "Usage: $0 -i <input_vcf> -b <input_bam> -o <output_dir> -s <sample_name>"
    echo "  -i: filtered VCF from Phase 3 (hard_filtered.pass.vcf.gz)."
    echo "  -b: final BAM from Phase 1 (analysis_ready.bam)."
    echo "  -o: output directory."
    echo "  -s: sample name (ID)."
    exit 1
}

while getopts "i:b:o:s:" opt; do
    case $opt in
        i) INPUT_VCF="$OPTARG" ;;
        b) INPUT_BAM="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        s) SAMPLE_NAME="$OPTARG" ;;
        *) usage ;;
    esac
done

if [[ -z "${INPUT_VCF:-}" ]] || [[ -z "${INPUT_BAM:-}" ]] || [[ -z "${OUTPUT_DIR:-}" ]] || [[ -z "${SAMPLE_NAME:-}" ]]; then
    echo "ERROR: Missing required arguments."
    usage
fi

# Create directory
mkdir -p "$OUTPUT_DIR"

echo "=========================================================="
echo "PHASE 4: PHASING AND ADVANCED ANNOTATION"
echo "Sample: $SAMPLE_NAME"
echo "=========================================================="

# ------------------------------------------------------------------------------
# STEP 0: PURGE NON-CANONICAL CHROMOSOMES (ultra-fast AWK filter)
# ------------------------------------------------------------------------------
echo "[0/3] Purging non-canonical contigs (random, Un, alt)..."

CANONICAL_VCF="${OUTPUT_DIR}/${SAMPLE_NAME}.canonical.vcf.gz"

# Only lets headers and chromosomes chr1-22, X, Y, M through
zcat -f "$INPUT_VCF" | awk '
    BEGIN {FS="\t"; OFS="\t"}
    /^#/ {print; next}
    $1 ~ /^chr([1-9]|1[0-9]|2[0-2]|X|Y|M)$/ {print}
' | bgzip -c > "$CANONICAL_VCF"

tabix -f -p vcf "$CANONICAL_VCF"
INPUT_FOR_PHASING="$CANONICAL_VCF"

# ------------------------------------------------------------------------------
# STEP 1: PHASING WITH WHATSHAP (Cis/Trans)
# ------------------------------------------------------------------------------
# WhatsHap uses the BAM's reads to connect nearby variants and determine
# whether they are on the same chromosome (phase).

PHASED_VCF="${OUTPUT_DIR}/${SAMPLE_NAME}.phased.vcf.gz"

if [ -f "$INPUT_BAM" ]; then
    echo "[1/2] Running WhatsHap (Phasing)..."

    # --ignore-read-groups: needed if the BAM has multiple RGs for the same sample
    # --reference: improves local realignment

    whatshap phase \
        --output "$PHASED_VCF" \
        --reference "$REF_HG38" \
        --ignore-read-groups \
        "$INPUT_FOR_PHASING" \
        "$INPUT_BAM"

    tabix -f -p vcf "$PHASED_VCF"
    INPUT_FOR_VEP="$PHASED_VCF"
    echo "      -> Phasing completed."
else
    echo "WARNING: BAM not found ($INPUT_BAM). Skipping phasing."
    INPUT_FOR_VEP="$INPUT_FOR_PHASING"
fi

# ------------------------------------------------------------------------------
# STEP 2: ANNOTATION WITH VEP (Strict Configuration)
# ------------------------------------------------------------------------------
echo "[2/2] Running VEP (Transcript level + Plugins)..."

# Check for critical resources
if [ ! -r "$UTR_FILE" ]; then
    echo "CRITICAL ERROR: Could not find UTRAnnotator at $UTR_FILE"
    exit 1
fi

OUTPUT_VEP="${OUTPUT_DIR}/${SAMPLE_NAME}.vep.annotated.vcf.gz"

# Filtering logic (custom)
# Prioritizes: MANE/Canonical/Coding transcripts OR high-impact/pathogenic variants
FILTER_LOGIC="(MANE_SELECT match \S or MANE_PLUS_CLINICAL match \S or CANONICAL is YES or APPRIS match \S or TSL match \S or CCDS match \S or BIOTYPE is protein_coding) or (IMPACT is HIGH or IMPACT is MODERATE) or (CLIN_SIG match pathogenic|likely_pathogenic) or (SpliceAI_pred_DS_max > 0.5) or (AlphaMissense_pred is pathogenic)"

# dbNSFP fields (protein scores only, no redundant gnomAD)
DBNSFP_FIELDS="BayesDel_noAF_score,BayesDel_addAF_score,BayesDel_noAF_pred,BayesDel_addAF_pred,ClinPred_score,ClinPred_pred,fathmm-XF_coding_score,fathmm-XF_coding_pred,MutScore_score,Interpro_domain,SIFT_score,SIFT_pred,Polyphen2_HVAR_score,Polyphen2_HVAR_pred,MutationTaster_pred,VEST4_score,MutationAssessor_pred,MetaRNN_score,MetaRNN_pred,PROVEAN_pred,M-CAP_score,MPC_score,MVP_score,PrimateAI_score,PrimateAI_pred,GERP++_RS,phyloP17way_primate,phastCons17way_primate,MisFit_D_score,MisFit_D_pred_stringent,VARITY_R_score,VARITY_ER_score"

vep \
    --format vcf --input_file "$INPUT_FOR_VEP" \
    --vcf --output_file STDOUT \
    --species homo_sapiens --assembly GRCh38 \
    --force_overwrite \
    --fork 6 \
    --offline --cache --dir_cache "$VEP_CACHE" \
    --fasta "$REF_HG38" \
    --merged \
    --buffer_size 5000 \
    --dont_skip \
    --exclude_null_alleles \
    --variant_class \
    --total_length \
    --numbers \
    --shift_3prime 1 \
    --allele_number \
    --symbol --hgvs --hgvsg --hgvsg_use_accession \
    --transcript_version --gene_version \
    --protein --ccds --uniprot --tsl \
    --canonical --mane \
    --biotype --appris --domains \
    --xref_refseq \
    --gene_phenotype \
    --nearest symbol \
    --overlaps \
    --pubmed \
    --dir_plugins "$VEP_PLUGINS" \
    \
    --plugin AlphaMissense,file="$VEP_CACHE/Plugins/Alphamissense/AlphaMissense_hg38.tsv.gz" \
    --plugin CADD,snvs="$VEP_CACHE/Plugins/CADD/whole_genome_SNVs.tsv.gz",indels="$VEP_CACHE/Plugins/CADD/gnomad.genomes.r3.0.indel.tsv.gz" \
    --plugin REVEL,file="$VEP_PLUGINS/REVEL/REVEL_with_chr.tsv.gz" \
    --plugin SpliceAI,snv="$VEP_DATA/spliceai_scores.raw.snv.hg38.vcf.gz",indel="$VEP_DATA/spliceai_scores.raw.indel.hg38.vcf.gz" \
    --plugin SpliceRegion \
    --plugin NMD \
    --plugin MaxEntScan,"$VEP_DATA/MaxEntScan" \
    --plugin UTRAnnotator,file="$UTR_FILE" \
    --plugin dbNSFP,"$VEP_DATA/dbNSFP5.3a_grch38.gz",$DBNSFP_FIELDS \
    --plugin dbscSNV,"$VEP_DATA/dbscSNV1.1_GRCh38.txt.gz" \
    --plugin mutfunc,db="$VEP_PLUGINS/mutfunc/mutfunc_data.db" \
    --plugin satMutMPRA,file="$VEP_PLUGINS/satMutMPRA/satMutMPRA_GRCh38_ALL.gz" \
    --plugin EVE,file="$VEP_PLUGINS/EVE/eve_final_sorted.vcf.gz" \
    \
    --custom "$CLINVAR_FILE",ClinVar,vcf,exact,0,CLNSIG,CLNSIGCONF,CLNREVSTAT,CLNDN,ALLELEID,CLNSIGINCL \
    --custom $VEP_PLUGINS/Conservation/gerp_conservation_scores.homo_sapiens.GRCh38.bw,GERP_RS,bigwig,exact \
    --custom $VEP_PLUGINS/Conservation/hg38.phyloP100way.bw,PhyloP_100way,bigwig,exact \
    --custom $VEP_PLUGINS/Conservation/hg38.phastCons100way.bw,PhastCons_100way,bigwig,exact \
    --custom "$CUSTOM_DIR/regulomedb/regulomedb_ranking.bed.gz",RegulomeDB_ranking,bed,overlap,0 \
    --custom "$CUSTOM_DIR/regulomedb/regulomedb_score.bed.gz",RegulomeDB_score,bed,overlap,0 \
    --custom "$GNOMAD_GENOMES",gnomADg,vcf,exact,0,AF,AC,AN,nhomalt,grpmax,AF_grpmax,fafmax_faf95_max,AS_VQSLOD \
    --custom "$GNOMAD_EXOMES",gnomADe,vcf,exact,0,AF,AC,AN,nhomalt,grpmax,AF_grpmax,fafmax_faf95_max,AS_VQSLOD \
    | \
    "$VEP_HOME/filter_vep" \
        --format vcf \
        --output_file STDOUT \
        --filter "$FILTER_LOGIC" \
        --only_matched \
    | bgzip -c > "$OUTPUT_VEP"

echo "      -> Indexing VEP result..."
tabix -f -p vcf "$OUTPUT_VEP"

echo "=========================================================="
echo "PHASE 4 COMPLETED SUCCESSFULLY."
echo "Final file: $OUTPUT_VEP"
echo "=========================================================="
