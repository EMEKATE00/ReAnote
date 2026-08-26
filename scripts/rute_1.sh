#!/bin/bash

# ==============================================================================
# SCRIPT: Alternative Phase 4 Workflow - Re-Annotation of External VCFs
# DESCRIPTION:
# 0. Strips all previous INFO annotations (except those listed in -m).
# 1. Physical phasing with WhatsHap (using the BAM, if provided).
# 2. Deep functional annotation with VEP + the same Plugins as the original Phase 4.
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

# --- 1. PATH SETUP (identical to phase4.sh, based on REANOTE_BASE) ---
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

CUSTOM_DIR="$BASE_DIR/custom"
CLINVAR_FILE="$CUSTOM_DIR/clinvar/clinvar_chr.vcf.gz"
GNOMAD_GENOMES="$CUSTOM_DIR/gnomad/v4.1/genomes/gnomad.genomes.v4.1.sites.concat.vcf.gz"
GNOMAD_EXOMES="$CUSTOM_DIR/gnomad/v4.1/exomes/gnomad.exomes.v4.1.sites.concat.vcf.gz"

# --- 2. INPUT ARGUMENTS ---
usage() {
    echo "Usage: $0 -i <external_input_vcf> -o <output_dir> -s <sample_name> [-b <input_bam>] [-m <tags_to_keep>]"
    echo "  -i: external VCF/GVCF file to process."
    echo "  -o: output directory."
    echo "  -s: sample name (ID)."
    echo "  -b: (Optional) BAM file to apply phasing."
    echo "  -m: (Optional) comma-separated list of INFO fields to keep."
    echo "      Default: AC,AF,AN,BaseQRankSum,DB,DP,ExcessHet,FS,MLEAC,MLEAF,MQ,MQRankSum,QD,ReadPosRankSum,SOR"
    exit 1
}

INPUT_BAM=""
# DEFAULT: if the user doesn't pass -m, use GATK's standard set
KEEP_TAGS_ARG="AC,AF,AN,BaseQRankSum,DB,DP,ExcessHet,FS,MLEAC,MLEAF,MQ,MQRankSum,QD,ReadPosRankSum,SOR"

while getopts "i:b:o:s:m:" opt; do
    case $opt in
        i) INPUT_VCF="$OPTARG" ;;
        b) INPUT_BAM="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        s) SAMPLE_NAME="$OPTARG" ;;
        m) KEEP_TAGS_ARG="${KEEP_TAGS_ARG},${OPTARG}" ;;
        *) usage ;;
    esac
done

if [[ -z "${INPUT_VCF:-}" ]] || [[ -z "${OUTPUT_DIR:-}" ]] || [[ -z "${SAMPLE_NAME:-}" ]]; then
    echo "ERROR: Missing required arguments (-i, -o, -s)."
    usage
fi

mkdir -p "$OUTPUT_DIR"

echo "=========================================================="
echo "ALTERNATIVE 4: CLEANUP AND RE-ANNOTATION OF EXTERNAL VCF"
echo "Sample: $SAMPLE_NAME"
echo "Tags kept in INFO: $KEEP_TAGS_ARG"
echo "=========================================================="

# ------------------------------------------------------------------------------
# STEP 0: STRIP PREVIOUS ANNOTATIONS (Python)
# ------------------------------------------------------------------------------
echo "[0/2] Stripping external annotations from the VCF (keeping the specified metrics)..."

CLEANED_VCF_TXT="${OUTPUT_DIR}/${SAMPLE_NAME}.cleaned.vcf"
CLEANED_VCF_GZ="${OUTPUT_DIR}/${SAMPLE_NAME}.cleaned.vcf.gz"

cat <<'EOF' > "${OUTPUT_DIR}/clean_external_vcf.py"
import sys
import gzip

input_vcf = sys.argv[1]
output_vcf = sys.argv[2]
tags_arg = sys.argv[3]

# Turn the comma-separated string into a Python set for fast lookups
KEEP_TAGS = set(tag.strip() for tag in tags_arg.split(',') if tag.strip())
# CHROMOSOME ALLOW-LIST (strips the _random, _alt, Un... contigs)
VALID_CHROMS = {f"chr{i}" for i in range(1, 23)} | {"chrX", "chrY", "chrM"}

def get_open_func(f):
    return gzip.open(f, 'rt') if f.endswith('.gz') else open(f, 'r')

with get_open_func(input_vcf) as f_in, open(output_vcf, 'w') as f_out:
    for line in f_in:
        # 1. Header cleanup
        if line.startswith('##INFO='):
            try:
                tag_id = line.split('ID=')[1].split(',')[0]
                if tag_id not in KEEP_TAGS:
                    continue # Drop the header definition if it's not in our list
            except:
                pass

        if line.startswith('#'):
            f_out.write(line)
            continue

        # 2. Cleanup of variant rows
        cols = line.strip().split('\t')
        if len(cols) >= 8:
            # If it's not 1-22, X, Y or M, drop it
            if cols[0] not in VALID_CHROMS:
                continue

            info_raw = cols[7]
            if info_raw != '.':
                clean_info = []
                for chunk in info_raw.split(';'):
                    key = chunk.split('=')[0]
                    if key in KEEP_TAGS:
                        clean_info.append(chunk)

                # If nothing is left, use a dot
                cols[7] = ';'.join(clean_info) if clean_info else '.'

        f_out.write('\t'.join(cols) + '\n')
EOF

# Pass KEEP_TAGS_ARG to Python as the third argument
python3 "${OUTPUT_DIR}/clean_external_vcf.py" "$INPUT_VCF" "$CLEANED_VCF_TXT" "$KEEP_TAGS_ARG"

echo "      -> Compressing and indexing cleaned VCF..."
bgzip -c "$CLEANED_VCF_TXT" > "$CLEANED_VCF_GZ"
tabix -f -p vcf "$CLEANED_VCF_GZ"
rm -f "$CLEANED_VCF_TXT" "${OUTPUT_DIR}/clean_external_vcf.py"

INPUT_FOR_VEP="$CLEANED_VCF_GZ"


# ------------------------------------------------------------------------------
# STEP 1: PHASING WITH WHATSHAP (if a BAM is provided)
# ------------------------------------------------------------------------------
PHASED_VCF="${OUTPUT_DIR}/${SAMPLE_NAME}.phased.vcf.gz"

if [[ -n "$INPUT_BAM" && -f "$INPUT_BAM" ]]; then
    echo "[1/2] Running WhatsHap (Phasing)..."
    whatshap phase \
        --output "$PHASED_VCF" \
        --reference "$REF_HG38" \
        --ignore-read-groups \
        "$INPUT_FOR_VEP" \
        "$INPUT_BAM"

    tabix -f -p vcf "$PHASED_VCF"
    INPUT_FOR_VEP="$PHASED_VCF"
    echo "      -> Phasing completed."
else
    echo "[1/2] No BAM provided. Skipping phasing."
fi


# ------------------------------------------------------------------------------
# STEP 2: ANNOTATION WITH VEP (identical to Phase 4)
# ------------------------------------------------------------------------------
echo "[2/2] Running VEP (Transcript level + Plugins)..."

OUTPUT_VEP="${OUTPUT_DIR}/${SAMPLE_NAME}.vep.annotated.vcf.gz"

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

echo "      -> Indexing final VEP result..."
tabix -f -p vcf "$OUTPUT_VEP"

# Clean up the intermediate VCF if phasing was run, to save space
if [[ "$INPUT_FOR_VEP" == "$PHASED_VCF" ]]; then
    rm -f "$CLEANED_VCF_GZ" "${CLEANED_VCF_GZ}.tbi"
fi

echo "=========================================================="
echo "ALTERNATIVE PHASE 4 COMPLETED SUCCESSFULLY."
echo "Final file: $OUTPUT_VEP"
echo "=========================================================="
