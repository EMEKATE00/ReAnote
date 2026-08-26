#!/usr/bin/env bash
# ==============================================================================
# ReAnote — Bootstrap the runtime environment on a new machine
#
# When connecting the ReAnote/ portable disk (F:\ on Windows/WSL) to a
# different computer, this script gets that machine ready to run
# phase4.sh/rute_1.sh, WITHOUT NEEDING INTERNET: the 'phase4_env' environment
# already comes fully resolved and packaged on the disk itself
# (engine/phase4_env.tar.gz, ~800M compressed / ~2.5G uncompressed, ~27000
# files — manually trimmed from what 'conda pack' generates by default: no
# docs, cross-compilation headers, man pages, gcc compiler, terminfo, X11,
# JVM, or the duplicated Python directory that 'conda pack --dereference'
# leaves when it materializes the python3.1->python3.12 symlink as a full
# copy. None of that is used by vep/filter_vep/bcftools/samtools/whatshap/
# vcfanno/tabix/bgzip at runtime — see the history of the session that
# generated this tarball for the exact details of what was removed and why).
# The absolute paths already come baked in at engine/phase4_env (generated
# with 'conda pack --dest-prefix'), so conda-unpack isn't needed on extraction.
#
#   1. If engine/phase4_env/ already exists (extracted in a previous run on
#      this same machine), it does nothing: already ready.
#   2. If it doesn't exist but engine/phase4_env.tar.gz does (the normal
#      case, it travels on the disk), it extracts it right there. This does
#      NOT require network access or conda installed on the new machine.
#      The number of files is what weighs the most on NTFS/exFAT disks via
#      WSL (9p): each file has its own creation latency on top of
#      throughput — hence the effort to trim the tarball to the strict
#      minimum instead of just compressing it better.
#   3. Only if the .tar.gz is also missing (incomplete/old disk) does it
#      fall back to the old method: install Miniconda if needed and resolve
#      'phase4_env' from phase4_env.yml against the conda-forge/bioconda
#      channels — this DOES require internet, it's the only emergency path.
#   4. Delegates to install_vep_engine.sh / verify_vep_engine.sh the part
#      that lives on the portable disk and travels with it: the VEP cache
#      (~26G), the hg38 reference FASTA, and the VEP_plugins .pm files.
#
# Important note on what uses what (to avoid repeating past confusion):
#   - "vep" is resolved by the conda environment (packaged or created), and
#     is invoked by name from the active PATH.
#   - "filter_vep" is invoked by phase4.sh/rute_1.sh via an ABSOLUTE PATH to
#     the tree cloned by hand at ReAnote/data/ensembl-vep/filter_vep, NOT
#     the one bundled with the conda ensembl-vep package. Both pieces are
#     needed and both live on the portable disk — install_vep_engine.sh
#     takes care of the second one.
#
# Idempotent: each step checks whether it's already done before acting.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE4_ENV_YML="$SCRIPT_DIR/phase4_env.yml"
PHASE4_ENV_NAME="phase4_env"
MINICONDA_INSTALL_DIR="$HOME/miniconda3"
MINICONDA_INSTALLER_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"

SCRIPT_START_TS=$(date +%s)
log()  { printf '[%s] [INFO]  %s\n'  "$(date '+%H:%M:%S')" "$1"; }
warn() { printf '[%s] [WARN]  %s\n'  "$(date '+%H:%M:%S')" "$1" >&2; }
err()  { printf '[%s] [ERROR] %s\n'  "$(date '+%H:%M:%S')" "$1" >&2; }
step() {
    local elapsed=$(( $(date +%s) - SCRIPT_START_TS ))
    printf '\n[%s] [+%ds] ==== %s ====\n' "$(date '+%H:%M:%S')" "$elapsed" "$1"
}

# --- AUTOMATIC BASE PATH DETECTION (portable disk) ---
detect_reanote_base() {
    local found
    found=$(find /mnt/*/ReAnote -maxdepth 0 2>/dev/null | head -n1)
    if [[ -z "$found" ]]; then
        found=$(find /media/*/ReAnote -maxdepth 0 2>/dev/null | head -n1)
    fi
    if [[ -z "$found" ]]; then
        err "Could not find the ReAnote folder under any mount point (/mnt/*, /media/*). Is the disk connected?"
        exit 1
    fi
    echo "$found"
}

REANOTE_BASE="$(detect_reanote_base)"
log "REANOTE_BASE detected: $REANOTE_BASE"

ENGINE_DIR="$REANOTE_BASE/engine"
PACKED_ENV_TARBALL="$ENGINE_DIR/phase4_env.tar.gz"
PACKED_ENV_DIR="$ENGINE_DIR/phase4_env"

# ==============================================================================
# STEP 1/2: 'phase4_env' environment — extract from disk (no internet)
# ==============================================================================
step "STEP 1/2: '$PHASE4_ENV_NAME' environment"

if [[ -x "$PACKED_ENV_DIR/bin/vep" ]]; then
    log "Packaged environment already extracted at $PACKED_ENV_DIR. Skipping."
    set +u
    # shellcheck disable=SC1091
    source "$PACKED_ENV_DIR/bin/activate"
    set -u

elif [[ -f "$PACKED_ENV_TARBALL" ]]; then
    log "Extracting packaged environment from $PACKED_ENV_TARBALL (no internet required)..."
    log "(the tarball already has symlinks materialized as file copies, so that"
    log " extraction also works on NTFS/exFAT disks without symlink support; and"
    log " absolute paths are already baked in as $PACKED_ENV_DIR, so"
    log " conda-unpack isn't needed)"
    mkdir -p "$PACKED_ENV_DIR"
    # -m / --no-same-permissions: NTFS/exFAT (typical portable disks) don't
    # support utime() or the exact Unix permission bits carried by the tar;
    # without these flags, tar aborts with "Cannot change mode"/"Cannot
    # utime". Even with both, some NTFS/9p variants still reject the final
    # chmod on the destination root directory ("tar: . : Cannot change
    # mode...") — this is cosmetic (the content was already extracted
    # correctly), so tar's exit code isn't treated as fatal here; instead,
    # the 'vep' binary is verified below to exist and work, which is the
    # real signal that extraction succeeded.
    tar -xzf "$PACKED_ENV_TARBALL" -m --no-same-permissions -C "$PACKED_ENV_DIR" || true

    set +u
    # shellcheck disable=SC1091
    source "$PACKED_ENV_DIR/bin/activate"
    set -u
    log "Environment ready at $PACKED_ENV_DIR (activated in this shell)."

else
    warn "$PACKED_ENV_TARBALL was not found on the portable disk (incomplete disk or old version?)."
    warn "Falling back to the emergency method: install Miniconda + resolve the environment over the internet."

    if [[ ! -f "$PHASE4_ENV_YML" ]]; then
        err "$PHASE4_ENV_YML was not found either. There is no way to prepare the environment. Aborting."
        exit 1
    fi

    if command -v conda >/dev/null 2>&1; then
        log "conda is already available: $(command -v conda)"
    else
        if [[ -x "$MINICONDA_INSTALL_DIR/bin/conda" ]]; then
            log "Miniconda is already installed at $MINICONDA_INSTALL_DIR but not on this shell's PATH. Using it directly."
        else
            warn "conda is not installed on this machine. Installing Miniconda at $MINICONDA_INSTALL_DIR (requires internet)..."
            installer_tmp="$(mktemp -d)/miniconda_installer.sh"
            curl -fL --retry 3 --retry-delay 10 -o "$installer_tmp" "$MINICONDA_INSTALLER_URL"
            bash "$installer_tmp" -b -p "$MINICONDA_INSTALL_DIR"
            rm -f "$installer_tmp"
            log "Miniconda installed at $MINICONDA_INSTALL_DIR."
        fi
        # shellcheck disable=SC1091
        source "$MINICONDA_INSTALL_DIR/etc/profile.d/conda.sh"
    fi

    CONDA_BASE="$(conda info --base 2>/dev/null || true)"
    if [[ -z "$CONDA_BASE" ]]; then
        err "conda was installed/detected but 'conda info --base' returned nothing. Check the Miniconda installation."
        exit 1
    fi
    set +u
    # shellcheck disable=SC1091
    source "$CONDA_BASE/etc/profile.d/conda.sh"
    set -u
    log "conda operational (base: $CONDA_BASE)."

    if conda env list 2>/dev/null | awk '{print $1}' | grep -qx "$PHASE4_ENV_NAME"; then
        log "Conda environment '$PHASE4_ENV_NAME' already exists. Skipping creation."
    else
        log "Creating '$PHASE4_ENV_NAME' from $PHASE4_ENV_YML over the internet (can take several minutes)..."
        conda env create -n "$PHASE4_ENV_NAME" -f "$PHASE4_ENV_YML"
        log "Environment '$PHASE4_ENV_NAME' created."
    fi

    set +u
    conda activate "$PHASE4_ENV_NAME"
    set -u
fi

log "Active environment (perl: $(command -v perl), $(perl -e 'print $^V'))"

for tool in vep filter_vep bcftools samtools whatshap vcfanno; do
    if command -v "$tool" >/dev/null 2>&1; then
        log "  $tool: OK ($(command -v "$tool"))"
    else
        err "  $tool: NOT found in the environment after preparing it. Check engine/phase4_env.tar.gz or phase4_env.yml."
        exit 1
    fi
done

vep_version_line="$(vep --help 2>&1 | grep -m1 'ensembl-vep' | xargs || true)"
log "vep --help reports: '${vep_version_line:-<empty>}'"

# ==============================================================================
# STEP 2/2: data on the portable disk (cache, FASTA, plugins) — delegated
# ==============================================================================
step "STEP 2/2: portable disk data (VEP cache, FASTA, plugins)"

log "Delegating to install_vep_engine.sh (idempotent: only downloads/clones what's missing)..."
bash "$SCRIPT_DIR/install_vep_engine.sh"

log "Running verify_vep_engine.sh to confirm the final state..."
bash "$SCRIPT_DIR/verify_vep_engine.sh"

step "BOOTSTRAP COMPLETE"
log "This machine can now run phase4.sh/rute_1.sh."
log "For everyday use, use the ReAnote/reanotar.sh launcher instead of"
log "invoking these scripts by hand: it activates the environment automatically."
