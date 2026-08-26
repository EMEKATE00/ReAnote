#!/usr/bin/env bash
# ==============================================================================
# ReAnote — Post-installation verification of the VEP engine
# Compares ReAnote/data/ensembl-vep/ and ReAnote/data/.vep/ against the
# values audited in ReAnote/vep_install_manifest.md. Read-only, doesn't
# modify anything.
# ==============================================================================
set -uo pipefail  # no 'set -e': we want to go through every check even if one fails

# --- EXPECTED VALUES (identical to install_vep_engine.sh) ---
VEP_TAG="release/115.2"
VEP_VERSION_LINE="ensembl-vep          : 115.2"
CACHE_SPECIES="homo_sapiens"
CACHE_ASSEMBLY="GRCh38"
CACHE_VERSION="115"
CACHE_TYPE="merged"
FASTA_NAME="Homo_sapiens_assembly38.fasta"
FASTA_EXPECTED_BYTES=3249912778
FASTA_FAI_EXPECTED_BYTES=160928
FASTA_DICT_EXPECTED_BYTES=581712

# LoF.pm, TissueExpression.pm, ancestral.pm and context.pm do NOT belong to
# VEP_plugins — they come from konradjk/loftee.git (see the manifest,
# section "Plugins/loftee/") and are only installed if INSTALL_LOFTEE=true
# in install_vep_engine.sh (false by default: neither phase4.sh nor
# rute_1.sh invoke --plugin LoF today). If you enable INSTALL_LOFTEE,
# compare those 4 separately against $VEP_PLUGINS/loftee/, not here.
EXPECTED_PLUGINS=(
    AlphaMissense.pm BayesDel.pm CADD.pm Conservation.pm DosageSensitivity.pm
    EVE.pm GeneBe.pm LOEUF.pm LOVD.pm LoFtool.pm MaxEntScan.pm NMD.pm
    NearestGene.pm PhenotypeOrthologous.pm REVEL.pm SpliceAI.pm
    UTRAnnotator.pm dbNSFP.pm
    dbscSNV.pm mutfunc.pm pLI.pm satMutMPRA.pm SpliceRegion.pm
)

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
VEP_HOME="$DATA_DIR/ensembl-vep"
VEP_CACHE="$DATA_DIR/.vep"
VEP_PLUGINS="$VEP_CACHE/Plugins"
REF_DIR="$DATA_DIR/reanote/referencias/hg38"
CACHE_TARGET_DIR="$VEP_CACHE/${CACHE_SPECIES}_${CACHE_TYPE}/${CACHE_VERSION}_${CACHE_ASSEMBLY}"

# --- ACTIVATING phase4_env (same as install_vep_engine.sh) ---
# The CPAN/htslib modules were installed inside phase4_env (see
# install_vep_engine.sh). If this script is launched with a bare "bash
# verify_vep_engine.sh", without activating the environment first, "vep"
# runs against the system's Perl (or another environment) and "vep
# --version" silently fails even though the installation is perfectly
# fine — it's not a real failure, it's a matter of which Perl is being looked at.
#
# If 'vep' already resolves on PATH (packaged environment already activated
# by bootstrap_environment.sh/reanotar.sh), it's used as-is. Otherwise, the
# 'phase4_env' conda environment is attempted by name as a fallback. Only a
# warning is issued (the rest of the checks aren't aborted) if neither
# alternative is available, since this script is read-only and should go
# through every check regardless.
PHASE4_ENV_ACTIVE=false
if command -v vep >/dev/null 2>&1; then
    PHASE4_ENV_ACTIVE=true
else
    CONDA_BASE="$(conda info --base 2>/dev/null || true)"
    if [[ -n "$CONDA_BASE" ]]; then
        set +u
        # shellcheck disable=SC1091
        source "$CONDA_BASE/etc/profile.d/conda.sh" 2>/dev/null
        if conda activate phase4_env 2>/dev/null; then
            PHASE4_ENV_ACTIVE=true
        fi
        set -u
    fi
fi
if [[ "$PHASE4_ENV_ACTIVE" != "true" ]]; then
    echo "WARNING: No active environment has 'vep' available, and the 'phase4_env' conda environment could not be activated. The 'vep --version' check will likely fail against the wrong Perl." >&2
fi

# ensembl-vep/vep only adds its own modules/ to @INC, not the 4 core API
# repos (ensembl, ensembl-variation, ensembl-io, ensembl-funcgen — cloned
# separately by install_vep_engine.sh under $DATA_DIR) — without this,
# Bio::EnsEMBL::Registry and friends don't resolve and "vep --help" fails
# silently, even though everything else is installed correctly.
export PERL5LIB="$DATA_DIR/ensembl/modules:$DATA_DIR/ensembl-variation/modules:$DATA_DIR/ensembl-io/modules:$DATA_DIR/ensembl-funcgen/modules${PERL5LIB:+:$PERL5LIB}"

# Without this, vep dies with "Attempt to reload Bio/DB/HTS/Tabix.pm aborted":
# Bio::EnsEMBL::VEP::AnnotationSource::File does a nested require+use of
# that XS module inside its own BEGIN (see install_vep_engine.sh for the
# full detail), and preloading it beforehand avoids the recursion.
export PERL5OPT="-MBio::DB::HTS::Tabix${PERL5OPT:+ $PERL5OPT}"

log()  { printf '[%s] [INFO]  %s\n'  "$(date '+%H:%M:%S')" "$1"; }

declare -a RESULTS=()
record() {
    # record <label> <ok|fail> <detail>
    RESULTS+=("$1|$2|$3")
    if [[ "$2" == "ok" ]]; then
        printf '✅ %-45s %s\n' "$1" "$3"
    else
        printf '❌ %-45s %s\n' "$1" "$3"
    fi
}

echo "=========================================================="
echo "VEP ENGINE VERIFICATION — ReAnote"
echo "REANOTE_BASE: $REANOTE_BASE"
echo "=========================================================="
echo ""

# --- 1. vep --version ---
log "Checking VEP version..."
VEP_BIN=""
if command -v vep >/dev/null 2>&1; then
    VEP_BIN="vep"
elif [[ -x "$VEP_HOME/vep" ]]; then
    VEP_BIN="perl $VEP_HOME/vep"
fi

if [[ -z "$VEP_BIN" ]]; then
    record "vep --version" "fail" "The 'vep' executable was not found, nor was $VEP_HOME/vep on PATH"
else
    version_output="$($VEP_BIN --help 2>&1 || true)"
    installed_line="$(grep -m1 'ensembl-vep' <<<"$version_output" | xargs || true)"
    expected_line="$(xargs <<<"$VEP_VERSION_LINE")"
    if [[ "$installed_line" == "$expected_line" ]]; then
        record "vep --version" "ok" "$installed_line"
    else
        record "vep --version" "fail" "Got: '${installed_line:-<empty, check Perl dependencies>}' | Expected: '$expected_line'"
    fi
fi

# --- ensembl-vep release tag ---
# ReAnote/data/ensembl-vep NEVER contains its own .git: the portable disk is
# mounted via 9p/drvfs, which doesn't support chmod and therefore can't host
# an active git repo (see install_vep_engine.sh, install_release_via_native_tmp).
# The clone+checkout is verified in a native temp directory and only the
# working tree is copied; the installed tag is recorded in the plain-text
# marker .reanote_release_tag, which is what's checked here.
tag_marker="$VEP_HOME/.reanote_release_tag"
if [[ -f "$tag_marker" ]]; then
    recorded_tag="$(cat "$tag_marker" 2>/dev/null || echo "")"
    if [[ "$recorded_tag" == "$VEP_TAG" ]]; then
        record "ensembl-vep tag (marker)" "ok" "$recorded_tag"
    else
        record "ensembl-vep tag (marker)" "fail" "Got: '$recorded_tag' | Expected: '$VEP_TAG'"
    fi
else
    record "ensembl-vep tag (marker)" "fail" "$tag_marker does not exist"
fi

if [[ -d "$VEP_HOME/.git" ]]; then
    record "ensembl-vep has no .git on the portable disk" "fail" "$VEP_HOME/.git exists — it shouldn't (see the policy in install_vep_engine.sh); the 9p/drvfs mount doesn't support an active git repo"
else
    record "ensembl-vep has no .git on the portable disk" "ok" "correct: working copy only, no .git"
fi

# --- 2. Listing of .pm files in Plugins/ ---
log "Comparing the list of plugins (.pm)..."
if [[ -d "$VEP_PLUGINS" ]]; then
    mapfile -t actual_plugins < <(find "$VEP_PLUGINS" -maxdepth 1 -iname "*.pm" -printf '%f\n' 2>/dev/null | sort)
    mapfile -t expected_sorted < <(printf '%s\n' "${EXPECTED_PLUGINS[@]}" | sort)

    missing=()
    for p in "${expected_sorted[@]}"; do
        printf '%s\n' "${actual_plugins[@]}" | grep -qx "$p" || missing+=("$p")
    done
    extra=()
    for p in "${actual_plugins[@]}"; do
        printf '%s\n' "${expected_sorted[@]}" | grep -qx "$p" || extra+=("$p")
    done

    if [[ ${#missing[@]} -eq 0 && ${#extra[@]} -eq 0 ]]; then
        record "Plugin .pm files (exact listing)" "ok" "${#actual_plugins[@]} files, matches the manifest"
    elif [[ ${#missing[@]} -eq 0 ]]; then
        record "Plugin .pm files (exact listing)" "ok" "${#actual_plugins[@]} files, all expected ones present + extra: ${extra[*]}"
    else
        record "Plugin .pm files (exact listing)" "fail" "Missing: ${missing[*]:-none} | Extra: ${extra[*]:-none}"
    fi
else
    record "Plugin .pm files (exact listing)" "fail" "$VEP_PLUGINS does not exist"
fi

# --- 3. Cache ---
log "Checking VEP cache..."
if [[ -f "$CACHE_TARGET_DIR/info.txt" ]]; then
    cache_species=$(awk -F'\t' '$1=="species"{print $2}' "$CACHE_TARGET_DIR/info.txt")
    cache_assembly=$(awk -F'\t' '$1=="assembly"{print $2}' "$CACHE_TARGET_DIR/info.txt")
    if [[ "$cache_species" == "$CACHE_SPECIES" && "$cache_assembly" == "$CACHE_ASSEMBLY" ]]; then
        record "VEP cache ($CACHE_TYPE)" "ok" "$CACHE_TARGET_DIR (species=$cache_species, assembly=$cache_assembly)"
    else
        record "VEP cache ($CACHE_TYPE)" "fail" "info.txt has species='$cache_species' assembly='$cache_assembly', expected '$CACHE_SPECIES'/'$CACHE_ASSEMBLY'"
    fi
else
    record "VEP cache ($CACHE_TYPE)" "fail" "$CACHE_TARGET_DIR/info.txt does not exist"
fi

# --- 4. FASTA + indices ---
log "Checking reference FASTA and indices..."
FASTA_PATH="$REF_DIR/$FASTA_NAME"
FAI_PATH="${FASTA_PATH}.fai"
DICT_PATH="${FASTA_PATH%.fasta}.dict"

check_file_size() {
    local label="$1" path="$2" expected="$3"
    if [[ ! -f "$path" ]]; then
        record "$label" "fail" "Does not exist: $path"
        return
    fi
    local actual
    actual=$(stat -c%s "$path" 2>/dev/null || echo 0)
    if [[ "$actual" == "$expected" ]]; then
        record "$label" "ok" "$path ($actual bytes, exact match)"
    else
        # May come from a different public source: reported without a hard
        # failure if the file exists and has a reasonable size (>0).
        if [[ "$actual" -gt 0 ]]; then
            record "$label" "fail" "$path: $actual bytes, expected $expected bytes (check whether it's a different source or an incomplete download)"
        else
            record "$label" "fail" "$path exists but is empty"
        fi
    fi
}

check_file_size "FASTA ($FASTA_NAME)" "$FASTA_PATH" "$FASTA_EXPECTED_BYTES"
check_file_size "FASTA .fai" "$FAI_PATH" "$FASTA_FAI_EXPECTED_BYTES"
check_file_size "FASTA .dict" "$DICT_PATH" "$FASTA_DICT_EXPECTED_BYTES"

# --- SUMMARY ---
echo ""
echo "=========================================================="
echo "SUMMARY"
echo "=========================================================="
total=0
ok_count=0
for r in "${RESULTS[@]}"; do
    IFS='|' read -r label status detail <<<"$r"
    total=$((total+1))
    if [[ "$status" == "ok" ]]; then
        ok_count=$((ok_count+1))
        printf '✅ %s\n' "$label"
    else
        printf '❌ %s — %s\n' "$label" "$detail"
    fi
done
echo "--------------------------------------------------------"
echo "$ok_count / $total checks OK"
echo "=========================================================="

if [[ "$ok_count" -ne "$total" ]]; then
    exit 1
fi
