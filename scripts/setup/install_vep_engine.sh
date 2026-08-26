#!/usr/bin/env bash
# ==============================================================================
# ReAnote — Reproducible installation of the VEP engine (ensembl-vep + .vep)
# Reproduces, based on the manifest audited in ReAnote/vep_install_manifest.md,
# an identical installation at:
#   ReAnote/data/ensembl-vep/
#   ReAnote/data/.vep/
#   ReAnote/data/reanote/referencias/hg38/  (only the FASTA + indices VEP uses)
#
# Does NOT touch ReAnote/data/custom/ or the heavy plugin data (CADD, dbNSFP,
# REVEL, AlphaMissense, SpliceAI, EVE, mutfunc, satMutMPRA, dbscSNV,
# MaxEntScan, UTRAnnotator, Conservation) — that's a later phase.
#
# Idempotent: each step checks whether the expected result already exists
# and, if it matches, skips it. Can be relaunched after a failure without
# duplicating work.
# ==============================================================================
set -euo pipefail

# --- VALUES FIXED IN THE AUDIT (ReAnote/vep_install_manifest.md) ---
VEP_TAG="release/115.2"
VEP_PLUGINS_TAG_HINT="115"          # resolved to the real available tag in VEP_plugins, see resolve_plugins_tag()
LOFTEE_REPO="https://github.com/konradjk/loftee.git"
LOFTEE_TAG="v1.0.4_GRCh38"
CACHE_SPECIES="homo_sapiens"
CACHE_ASSEMBLY="GRCh38"
CACHE_VERSION="115"
CACHE_TYPE="merged"                  # confirmed: the scripts use --merged
CACHE_TARBALL_NAME="homo_sapiens_merged_vep_115_GRCh38.tar.gz"
CACHE_TARBALL_URL="https://ftp.ensembl.org/pub/release-${CACHE_VERSION}/variation/indexed_vep_cache/${CACHE_TARBALL_NAME}"
CACHE_TARBALL_EXPECTED_BYTES=27845183833   # confirmed with curl -I (Content-Length), ~25.9G/26G
FASTA_NAME="Homo_sapiens_assembly38.fasta"
FASTA_EXPECTED_BYTES=3249912778
FASTA_FAI_EXPECTED_BYTES=160928
FASTA_DICT_EXPECTED_BYTES=581712
GATK_FASTA_BASE_URL="https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0"  # genomics-public-data stopped being anonymously accessible (403); same file (identical bytes/md5), Broad mirror
INSTALL_LOFTEE=false                 # present upstream but not invoked by any current script; optional

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

# --- LOGGING ---
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

# --- ACTIVATING phase4_env (required) ---
# The manifest (ReAnote/vep_install_manifest.md) audits exact Perl/CPAN/htslib
# versions inside "phase4_env" — the same environment rute_1.sh and
# phase4.sh use before invoking vep/filter_vep in production. If this script
# is launched with the wrong Perl active, cpanm/INSTALL.pl compile and
# install modules against that Perl instead of the one the pipeline actually
# uses — the module ends up "installed" but invisible to rute_1.sh/phase4.sh.
#
# Two valid ways to have "phase4_env" active:
#   (a) A packaged environment (engine/phase4_env.tar.gz) already extracted
#       and activated in this shell by bootstrap_environment.sh/reanotar.sh —
#       this is the normal flow on a portable disk without conda installed.
#       Detected because 'vep' already resolves on PATH with no further action.
#   (b) A conda environment registered under the name 'phase4_env' (emergency/
#       development flow, a machine with its own conda) — activated by name
#       if (a) doesn't apply.
if command -v vep >/dev/null 2>&1; then
    log "Environment already active in this shell (perl: $(command -v perl)) — using it as-is, not touching conda."
else
    CONDA_BASE="$(conda info --base 2>/dev/null || true)"
    if [[ -z "$CONDA_BASE" ]]; then
        echo "ERROR: No environment is active ('vep' is not on PATH) and 'conda' was not found either. Run bootstrap_environment.sh first (see ReAnote/vep_install_manifest.md)." >&2
        exit 1
    fi
    # conda's activation scripts (and some hooks from the environment's own
    # packages, e.g. activate-gcc_linux-64.sh) reference their own
    # environment variables without checking they exist (e.g. $HOST), which
    # aborts with "unbound variable" under "set -u". Temporarily disabled
    # only around activation, not for the rest of the script.
    set +u
    # shellcheck disable=SC1091
    source "$CONDA_BASE/etc/profile.d/conda.sh"
    if ! conda activate phase4_env; then
        set -u
        echo "ERROR: No environment is active and the conda environment 'phase4_env' doesn't exist either. Run bootstrap_environment.sh first, or create the conda environment manually (see the manifest)." >&2
        exit 1
    fi
    set -u
fi

for c in git curl du find rsync perl cpanm; do require_cmd "$c"; done

log "Active environment: perl $(perl -e 'print $^V') ($(command -v perl))"

# --- INSTALLING GIT RELEASES ON A 9p/drvfs PORTABLE DISK ---
# Confirmed diagnosis (not a core.fileMode issue or badly compared
# permissions): ReAnote/data/ lives on an external disk mounted in WSL2 via
# 9p (mount shows "type 9p ... aname=drvfs", i.e. a Windows drive). That
# mount point does NOT support the chmod syscall AT ALL — not even on files
# it just created itself, and not even "git config" can run there because it
# fails to create its own lockfile ("chmod on .git/config.lock failed:
# Operation not permitted"). Git simply cannot function as an ACTIVE
# repository on this filesystem: neither clone, nor checkout, nor even "git
# status" are reliable operations once .git lives on the portable disk (a
# full clone of .git there leaves the working tree in a state git perceives
# as "dirty" even with no real changes, because it can't set mode/time bits
# correctly — hence errors like "local changes would be overwritten by
# checkout" showing up on files nobody touched).
#
# The fix is NOT more resilience around git-on-the-portable-disk (that was
# already tried with safe.directory/fsck/reset+clean and still fails at the
# root cause) but to not run git there at all:
#   1. Clone and check out the exact tag ONLY in a temp directory on the
#      native Linux filesystem (ext4 via WSL2), where chmod works normally.
#   2. Verify there, with "git status --porcelain", that the checkout came
#      out clean (no diffs) before considering it valid.
#   3. Copy to the portable disk ONLY the working tree, EXCLUDING the .git/
#      folder, via rsync -a --exclude='.git'. The destination on the
#      portable disk never becomes a git repo again: it's a read-only copy
#      of that release's content, as documented in the manifest
#      (ReAnote/vep_install_manifest.md), which already records the exact
#      tag/commit — no traceability is lost by not carrying .git.
#   4. Record the installed tag in a plain-text marker (.reanote_release_tag)
#      at the destination, so future runs of the script know what's
#      installed without needing git there.

# install_release_via_native_tmp <url> <tag> <dest>
#
# Clones <url> and checks out <tag> in a native temp directory, verifies the
# working tree came out clean, and syncs the result (without .git) to <dest>
# on the portable disk with rsync. If <dest> already has the same tag
# recorded in .reanote_release_tag, it does nothing (idempotent).
install_release_via_native_tmp() {
    local url="$1" tag="$2" dest="$3"
    local marker="$dest/.reanote_release_tag"

    if [[ -f "$marker" && "$(cat "$marker" 2>/dev/null)" == "$tag" ]]; then
        log "$dest already has tag '$tag' installed (per $marker). Skipping clone."
        return 0
    fi

    local tmp_clone
    tmp_clone="$(mktemp -d)"
    trap 'rm -rf "$tmp_clone"' RETURN

    log "Cloning $url into a native temp directory ($tmp_clone)..."
    git clone --quiet "$url" "$tmp_clone"

    log "Checking out '$tag' in $tmp_clone..."
    git -C "$tmp_clone" checkout --quiet "$tag"

    local dirty
    dirty="$(git -C "$tmp_clone" status --porcelain)"
    if [[ -n "$dirty" ]]; then
        err "The checkout of '$tag' in $tmp_clone did not come out clean (git status --porcelain reported diffs). This shouldn't happen on a freshly-made native clone — aborting instead of propagating a suspicious state to the portable disk."
        err "$dirty"
        exit 1
    fi
    log "Checkout of '$tag' verified clean on the native filesystem."

    mkdir -p "$dest"
    log "Syncing working tree (without .git/) to $dest via rsync..."
    # $dest lives on the portable disk mounted as 9p/drvfs (WSL): it always
    # reports root:root 777 and doesn't support chgrp, the mkstemp+rename
    # rsync uses by default, OR preserving mtimes (utime fails with
    # "Operation not permitted"). That's why -rl (without -o/-g/-p/-t from
    # -a) and --inplace are used instead of plain -a, even though the rsync
    # command itself runs on the native filesystem.
    rsync -rl --inplace --delete --exclude='.git' "$tmp_clone/" "$dest/"

    echo "$tag" > "$marker"
    log "$dest updated and marked with tag '$tag' in $marker."
}

# resumable_download <url> <dest_final> [expected_bytes] [min_sane_bytes]
# Downloads with curl -C - (resumable): if <dest_final>.part already exists
# from a previous interruption, continues from where it left off instead of
# restarting. Before deciding to resume, checks that the partial file isn't
# suspiciously small (< min_sane_bytes, default 1 MiB) — a tiny partial
# usually indicates a truncated error response, not real progress, and is
# discarded to start fresh instead of risking "resuming" over garbage.
# Verifies the final size against expected_bytes if provided.
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

    # -C -: resumes automatically if $part already exists (curl detects the
    # partial size and requests that range with Range:). If the server
    # doesn't support partial ranges, curl with -C - fails explicitly
    # instead of silently restarting over the same corrupted file — that
    # case is detected and retried once, discarding the partial.
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
            err "Download of $(basename "$dest") completed but the size ($final_bytes bytes) doesn't match the expected one ($expected_bytes bytes). Possibly a truncated download."
            err "The file is NOT considered valid. Delete it or relaunch (the .part will resume if it fails again mid-way)."
            exit 1
        fi
        log "$(basename "$dest") downloaded and verified: $final_bytes bytes."
    else
        log "$(basename "$dest") downloaded (no expected size to verify)."
    fi
}

log "REANOTE_BASE detected: $REANOTE_BASE"
log "ensembl-vep destination: $VEP_HOME"
log ".vep destination (cache+plugins): $VEP_CACHE"
log "hg38 references destination: $REF_DIR"

mkdir -p "$DATA_DIR" "$VEP_CACHE" "$VEP_PLUGINS" "$REF_DIR"

# ==============================================================================
# STEP 1: CLONE ensembl-vep AT THE EXACT TAG
# ==============================================================================
step "STEP 1/7: ensembl-vep @ $VEP_TAG"

# $VEP_HOME must never contain its own .git (see install_release_via_native_tmp
# above) — if one is left over from a previous attempt with the old approach
# (direct clone onto the portable disk), it's removed entirely to start from
# a clean state instead of trying to repair it in place.
if [[ -d "$VEP_HOME/.git" ]]; then
    warn "$VEP_HOME contains a leftover .git from a previous approach (direct clone onto the portable disk, already discarded). Removing it to reinstall cleanly."
    rm -rf "$VEP_HOME"
fi

install_release_via_native_tmp "https://github.com/Ensembl/ensembl-vep.git" "$VEP_TAG" "$VEP_HOME"
log "ensembl-vep OK at tag: $VEP_TAG ($VEP_HOME, no .git — read-only copy of the release)"

# --- Ensembl Core API (4 repos besides ensembl-vep): provides
# Bio::EnsEMBL::Registry (ensembl), Bio::EnsEMBL::Variation::* (ensembl-variation),
# Bio::EnsEMBL::IO::* (ensembl-io) and Bio::EnsEMBL::Funcgen::* (ensembl-funcgen).
# ensembl-vep does NOT include any of these in its own tree (it only ships
# modules/Bio/EnsEMBL/VEP/), so without these 4 clones "vep --help" fails in
# cascade: first with "Can't locate Bio/EnsEMBL/Registry.pm", and after
# resolving that, with "Can't locate Bio/EnsEMBL/Variation/DBSQL/...Adaptor.pm"
# (confirmed by testing one at a time). Just like VEP_plugins, these 4 repos
# version by branch (release/115, no patch suffix), not by tag — resolved
# to VEP_TAG's major branch, not the exact ensembl-vep tag.
ENSEMBL_API_TAG="release/$(cut -d. -f1 <<<"${VEP_TAG#release/}")"
ENSEMBL_CORE_HOME="$DATA_DIR/ensembl"
ENSEMBL_VARIATION_HOME="$DATA_DIR/ensembl-variation"
ENSEMBL_IO_HOME="$DATA_DIR/ensembl-io"
ENSEMBL_FUNCGEN_HOME="$DATA_DIR/ensembl-funcgen"
for d in "$ENSEMBL_CORE_HOME" "$ENSEMBL_VARIATION_HOME" "$ENSEMBL_IO_HOME" "$ENSEMBL_FUNCGEN_HOME"; do
    if [[ -d "$d/.git" ]]; then
        warn "$d contains a leftover .git from a previous approach. Removing it to reinstall cleanly."
        rm -rf "$d"
    fi
done
install_release_via_native_tmp "https://github.com/Ensembl/ensembl.git" "$ENSEMBL_API_TAG" "$ENSEMBL_CORE_HOME"
install_release_via_native_tmp "https://github.com/Ensembl/ensembl-variation.git" "$ENSEMBL_API_TAG" "$ENSEMBL_VARIATION_HOME"
install_release_via_native_tmp "https://github.com/Ensembl/ensembl-io.git" "$ENSEMBL_API_TAG" "$ENSEMBL_IO_HOME"
install_release_via_native_tmp "https://github.com/Ensembl/ensembl-funcgen.git" "$ENSEMBL_API_TAG" "$ENSEMBL_FUNCGEN_HOME"
log "Ensembl Core API (ensembl, ensembl-variation, ensembl-io, ensembl-funcgen) OK at branch: $ENSEMBL_API_TAG"

# vep (ensembl-vep/vep) only adds its own modules/ to @INC (use lib
# $RealBin.'/modules'), not the 4 core API repos — an explicit PERL5LIB is
# needed for them to resolve, both for this script's own checks and for
# phase4.sh/rute_1.sh (which export this same variable before invoking "vep").
export PERL5LIB="$ENSEMBL_CORE_HOME/modules:$ENSEMBL_VARIATION_HOME/modules:$ENSEMBL_IO_HOME/modules:$ENSEMBL_FUNCGEN_HOME/modules${PERL5LIB:+:$PERL5LIB}"

# Load-order bug between independent Ensembl repos when combined without
# going through INSTALL.pl: Bio::EnsEMBL::VEP::AnnotationSource::File does
# "eval { require Bio::DB::HTS::Tabix }" inside its own BEGIN and, if
# successful, in that SAME BEGIN loads File::VCF -> ensembl-io's
# VCF4Tabix.pm -> TabixParser.pm, which does "use Bio::DB::HTS::Tabix" again
# while the first require hasn't finished registering in %INC yet. Result:
# "Attempt to reload Bio/DB/HTS/Tabix.pm aborted" and vep dies outright.
# Preloading the whole module BEFORE vep starts (via PERL5OPT, which perl
# applies to any later invocation even by name on PATH) avoids the recursion
# — confirmed end-to-end with vep --help.
export PERL5OPT="-MBio::DB::HTS::Tabix${PERL5OPT:+ $PERL5OPT}"

# ==============================================================================
# STEP 2: PERL / CPAN MODULES
# ==============================================================================
step "STEP 2/7: Perl dependencies (CPAN)"

# Versions detected during the audit (functional phase4_env environment, Perl 5.32.1):
#   DBI 1.643 | DBD::mysql 4.050 | Set::IntervalTree 0.12 | JSON 4.10
#   Text::CSV 2.01 | PerlIO::gzip 0.20 | IO::Uncompress::Gunzip 2.214
#   Bio::DB::BigFile 1.07 | Sereal 5.004 | Capture::Tiny 0.48
#   Bio::DB::HTS(::Faidx) 3.01 (installed via INSTALL.pl, not cpanm)
# HTML::Lint and Archive::Zip were NOT installed upstream and the pipeline
# works fine without them (recommends, not requires) — they're attempted
# anyway for completeness but a failure on them doesn't abort the script.

require_cmd cpanm

REQUIRED_MODULES=(
    "DBI"
    "Set::IntervalTree"
    "JSON"
    "Text::CSV"
)
RECOMMENDED_MODULES=(
    "DBD::mysql@4.050"
    "PerlIO::gzip"
    "IO::Uncompress::Gunzip"
    "Bio::DB::BigFile"
    "Sereal"
    "HTML::Lint"
    "Capture::Tiny"
)

module_installed() {
    perl -M"$1" -e1 >/dev/null 2>&1
}

for mod in "${REQUIRED_MODULES[@]}"; do
    if module_installed "$mod"; then
        log "Required module already installed: $mod"
    else
        log "Installing required module: $mod"
        cpanm --notest "$mod"
    fi
done

for entry in "${RECOMMENDED_MODULES[@]}"; do
    mod="${entry%%@*}"
    if module_installed "$mod"; then
        log "Recommended module already installed: $mod"
    else
        log "Installing recommended module: $entry"
        cpanm --notest "$entry" || warn "Could not install '$entry' (recommends, non-blocking). Continuing."
    fi
done

CACHE_TARGET_DIR="$VEP_CACHE/${CACHE_SPECIES}_${CACHE_TYPE}/${CACHE_VERSION}_${CACHE_ASSEMBLY}"

# ==============================================================================
# STEP 3: INSTALL.pl — Faidx/htslib (Bio::DB::HTS)
# ==============================================================================
# Diagnosis (verified on this network): INSTALL.pl uses Net::FTP (port 21)
# to list and download the cache unless --USE_HTTPS_PROTO is passed (which in
# turn requires HTML::TableExtract, not guaranteed to be installed). FTP is
# blocked on this network ("Connection timed out"), but HTTPS does work
# (confirmed with curl -I on the cache URL: 200 OK). install_biodbhts()
# instead uses https://github.com/Ensembl/Bio-DB-HTS directly — it doesn't
# touch FTP and needs no bypass.
#
# Also, INSTALL.pl ALWAYS calls (unless --NO_UPDATE) update() on startup,
# which queries https://api.github.com/repos/Ensembl/ensembl-vep to check the
# default branch. Unauthenticated, the GitHub API limits to 60 req/hour per
# IP; if that's already exhausted, that call returns 403 and aborts the
# entire script (see github.com/Ensembl/ensembl-vep/issues/1687). Since
# step 1 already fixes the exact tag (release/115.2) by hand, that version
# check isn't needed: --NO_UPDATE is passed to skip it entirely.
#
# If GITHUB_TOKEN is also present in the environment, INSTALL.pl picks it up
# natively (see its read_config_from_environment() function, which looks for
# the GITHUB_TOKEN variable without needing a VEP_ prefix) and adds it as an
# "Authorization: Bearer" header in its own curl calls to the GitHub API
# (download_to_file()) — no need to patch INSTALL.pl for this. The token is
# never written to disk: it's only inherited as an environment variable by
# the process launching this script and by the child `perl INSTALL.pl`.
step "STEP 3/7: INSTALL.pl (Faidx/htslib for Bio::DB::HTS)"

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    log "GITHUB_TOKEN detected in the environment: it will be used to authenticate calls to api.github.com (avoids the 60 req/hour unauthenticated rate limit)."
else
    warn "GITHUB_TOKEN is not set. INSTALL.pl's calls to api.github.com may fail with 403 due to rate-limiting (60 req/hour unauthenticated)."
    warn "If this fails, export a token before relaunching: export GITHUB_TOKEN=ghp_xxx  (only needs public read access)."
fi

if module_installed "Bio::DB::HTS::Faidx"; then
    log "Bio::DB::HTS is already installed. Skipping htslib installation."
else
    log "Installing Faidx/htslib (Bio::DB::HTS)..."
    # --AUTO l: Faidx/htslib only. Doesn't include 'c' (cache) — the cache is
    # downloaded separately in step 4 to avoid cache()'s FTP mechanism.
    # Doesn't include 'a' (API, already present from the git checkout) or 'f'/'p'.
    # --NO_UPDATE: avoids the call to api.github.com on startup (see above).
    # GITHUB_TOKEN (if set) is inherited from the environment as-is;
    # INSTALL.pl picks it up by its exact name without this script needing
    # to pass it via a flag.
    cd "$VEP_HOME"
    perl INSTALL.pl --AUTO l --NO_UPDATE
    cd - >/dev/null
fi

if module_installed "Bio::DB::HTS::Faidx"; then
    log "Bio::DB::HTS OK."
else
    err "Bio::DB::HTS was not installed after INSTALL.pl --AUTO l. Check the log above."
    exit 1
fi

# ==============================================================================
# STEP 4: homo_sapiens_merged / 115 / GRCh38 CACHE — direct HTTPS download
# ==============================================================================
step "STEP 4/7: VEP cache ($CACHE_TYPE, $CACHE_SPECIES, v$CACHE_VERSION, $CACHE_ASSEMBLY) via HTTPS"

CACHE_TMP_DIR="$VEP_CACHE/tmp"
CACHE_TARBALL_PATH="$CACHE_TMP_DIR/$CACHE_TARBALL_NAME"
mkdir -p "$CACHE_TMP_DIR"

if [[ -f "$CACHE_TARGET_DIR/info.txt" ]]; then
    log "Cache already present at $CACHE_TARGET_DIR (info.txt found). Skipping download and extraction."
else
    # Check the server's partial-range support: if it doesn't advertise
    # Accept-Ranges: bytes, "curl -C -" may fail or (worse) the server could
    # ignore the Range and return the whole file from byte 0, overwriting the
    # partial inconsistently. An explicit warning is shown if support isn't
    # detected, though it's attempted anyway (resumable_download already
    # retries from scratch if -C - fails).
    accept_ranges="$(curl -sI --max-time 15 "$CACHE_TARBALL_URL" 2>/dev/null | grep -i '^accept-ranges:' | tr -d '\r')"
    if [[ -z "$accept_ranges" ]]; then
        warn "The server didn't advertise 'Accept-Ranges' for $CACHE_TARBALL_NAME. Resuming (-C -) may not work; if it fails, it will be retried from scratch automatically."
    else
        log "The server supports partial ranges ($accept_ranges) — the download is resumable after an interruption."
    fi

    # Generous min_sane_bytes (100 MiB) for a ~26G tarball: a partial below
    # that is almost certainly a very early cutoff or an error response, not
    # real progress worth keeping.
    resumable_download "$CACHE_TARBALL_URL" "$CACHE_TARBALL_PATH" "$CACHE_TARBALL_EXPECTED_BYTES" $((100 * 1024 * 1024))

    log "Extracting the cache into $VEP_CACHE (this can take several minutes)..."
    tar -xzf "$CACHE_TARBALL_PATH" -C "$VEP_CACHE"

    rm -f "$CACHE_TARBALL_PATH"
fi

if [[ -f "$CACHE_TARGET_DIR/info.txt" ]]; then
    log "Cache OK: $CACHE_TARGET_DIR"
else
    err "$CACHE_TARGET_DIR/info.txt was not found after extracting the tarball. Check the contents of $CACHE_TARBALL_NAME."
    exit 1
fi

# ==============================================================================
# STEP 5: VEP_plugins (+ optional loftee)
# ==============================================================================
step "STEP 5/7: Ensembl/VEP_plugins @ release $VEP_PLUGINS_TAG_HINT"

resolve_plugins_tag() {
    # Unlike ensembl-vep, Ensembl/VEP_plugins does NOT publish git tags: it
    # versions each release as a branch (refs/heads/release/115, release/116...).
    # That's why it has to be resolved against --heads (branches), not just --tags.
    local candidates=("release/${VEP_PLUGINS_TAG_HINT}" "${VEP_PLUGINS_TAG_HINT}.0" "${VEP_PLUGINS_TAG_HINT}")
    local remote_refs
    remote_refs="$(git ls-remote --heads --tags https://github.com/Ensembl/VEP_plugins.git 2>/dev/null | awk -F'refs/(heads|tags)/' '{print $2}' | sed 's/\^{}$//')"
    for c in "${candidates[@]}"; do
        if grep -qx "$c" <<<"$remote_refs"; then
            echo "$c"
            return 0
        fi
    done
    # Fallback: the most recent branch/tag starting with the detected major version
    local best
    best="$(grep -E "^(release/)?${VEP_PLUGINS_TAG_HINT}(\.|$)" <<<"$remote_refs" | sort -V | tail -n1)"
    if [[ -n "$best" ]]; then
        echo "$best"
        return 0
    fi
    return 1
}

PLUGINS_TAG="$(resolve_plugins_tag || true)"
if [[ -z "${PLUGINS_TAG:-}" ]]; then
    err "Could not resolve a branch/tag of Ensembl/VEP_plugins matching version $VEP_PLUGINS_TAG_HINT."
    err "Check the available branches/tags manually: git ls-remote --heads --tags https://github.com/Ensembl/VEP_plugins.git"
    exit 1
fi
log "Resolved tag for VEP_plugins: $PLUGINS_TAG"

# $VEP_PLUGINS_SRC_CLONE is an auxiliary directory inside the portable disk
# that holds VEP_plugins' working tree (no .git — see
# install_release_via_native_tmp) only to copy the .pm files from there.
VEP_PLUGINS_SRC_CLONE="$VEP_PLUGINS/.vep_plugins_src"

if [[ -d "$VEP_PLUGINS_SRC_CLONE/.git" ]]; then
    warn "$VEP_PLUGINS_SRC_CLONE contains a leftover .git from a previous approach. Removing it to reinstall cleanly."
    rm -rf "$VEP_PLUGINS_SRC_CLONE"
fi

install_release_via_native_tmp "https://github.com/Ensembl/VEP_plugins.git" "$PLUGINS_TAG" "$VEP_PLUGINS_SRC_CLONE"

log "Copying VEP_plugins' .pm files into $VEP_PLUGINS (without overwriting Data/ or its own data subfolders)..."
find "$VEP_PLUGINS_SRC_CLONE" -maxdepth 1 -iname "*.pm" -exec cp -f {} "$VEP_PLUGINS/" \;

# --- Comparison against the audited manifest (section 3.1) ---
# LoF.pm, TissueExpression.pm, ancestral.pm and context.pm do NOT belong to
# VEP_plugins — they come from konradjk/loftee.git (see manifest, section
# "Plugins/loftee/") and are only installed if INSTALL_LOFTEE=true above
# (false by default). They aren't compared here so they don't get reported
# as "missing" when loftee is deliberately disabled.
EXPECTED_PLUGINS=(
    AlphaMissense.pm BayesDel.pm CADD.pm Conservation.pm DosageSensitivity.pm
    EVE.pm GeneBe.pm LOEUF.pm LOVD.pm LoFtool.pm MaxEntScan.pm NMD.pm
    NearestGene.pm PhenotypeOrthologous.pm REVEL.pm SpliceAI.pm
    UTRAnnotator.pm dbNSFP.pm
    dbscSNV.pm mutfunc.pm pLI.pm satMutMPRA.pm SpliceRegion.pm
)
log "Comparing installed .pm files against the audited manifest (22 from VEP_plugins + SpliceRegion.pm added on purpose; loftee is compared separately if INSTALL_LOFTEE=true)..."
missing=()
for p in "${EXPECTED_PLUGINS[@]}"; do
    [[ -f "$VEP_PLUGINS/$p" ]] || missing+=("$p")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Plugins expected per the manifest that did NOT appear after cloning: ${missing[*]}"
    warn "Check whether VEP_plugins tag '$PLUGINS_TAG' really includes them."
else
    log "All .pm files from the manifest are present, including SpliceRegion.pm (upstream discrepancy fixed)."
fi

extra=()
while IFS= read -r -d '' f; do
    bn="$(basename "$f")"
    found=false
    for p in "${EXPECTED_PLUGINS[@]}"; do [[ "$bn" == "$p" ]] && found=true && break; done
    $found || extra+=("$bn")
done < <(find "$VEP_PLUGINS" -maxdepth 1 -iname "*.pm" -print0)
if [[ ${#extra[@]} -gt 0 ]]; then
    log "Additional plugins present (not in the audited manifest, informational): ${extra[*]}"
fi

# --- loftee (optional, present upstream but not used by the current scripts) ---
if [[ "$INSTALL_LOFTEE" == "true" ]]; then
    LOFTEE_DIR="$VEP_PLUGINS/loftee"
    if [[ -d "$LOFTEE_DIR/.git" ]]; then
        warn "$LOFTEE_DIR contains a leftover .git from a previous approach. Removing it to reinstall cleanly."
        rm -rf "$LOFTEE_DIR"
    fi
    install_release_via_native_tmp "$LOFTEE_REPO" "$LOFTEE_TAG" "$LOFTEE_DIR"
    log "loftee installed at $LOFTEE_DIR."
else
    log "INSTALL_LOFTEE=false — skipping loftee (not invoked by phase4.sh/rute_1.sh). Change the variable if you need it."
fi

# ==============================================================================
# STEP 6: reference FASTA + indices
# ==============================================================================
step "STEP 6/7: reference FASTA ($FASTA_NAME) + indices"

FASTA_PATH="$REF_DIR/$FASTA_NAME"
FAI_PATH="${FASTA_PATH}.fai"
DICT_PATH="${FASTA_PATH%.fasta}.dict"

# Resumable downloads (resumable_download, defined at the top of the script)
# — the FASTA (~3.1G) is large enough to suffer the same kind of
# interruption as the cache; the .fai/.dict are small but handled the same
# way for consistency and to avoid duplicating logic.
resumable_download "$GATK_FASTA_BASE_URL/$FASTA_NAME" "$FASTA_PATH" "$FASTA_EXPECTED_BYTES"
resumable_download "$GATK_FASTA_BASE_URL/${FASTA_NAME}.fai" "$FAI_PATH" "$FASTA_FAI_EXPECTED_BYTES" 1024
resumable_download "$GATK_FASTA_BASE_URL/$(basename "$DICT_PATH")" "$DICT_PATH" "$FASTA_DICT_EXPECTED_BYTES" 1024

# Generate indices locally if the direct download from the bucket isn't available
if [[ ! -f "$FAI_PATH" ]]; then
    require_cmd samtools
    log "Generating .fai with samtools faidx (couldn't download it)..."
    samtools faidx "$FASTA_PATH"
fi
if [[ ! -f "$DICT_PATH" ]]; then
    log "Generating .dict (couldn't download it)..."
    if command -v gatk >/dev/null 2>&1; then
        gatk CreateSequenceDictionary -R "$FASTA_PATH" -O "$DICT_PATH"
    elif command -v picard >/dev/null 2>&1; then
        picard CreateSequenceDictionary R="$FASTA_PATH" O="$DICT_PATH"
    else
        err "Neither gatk nor picard is available to generate $DICT_PATH."
        exit 1
    fi
fi

log "FASTA OK: $FASTA_PATH"
log ".fai OK:  $FAI_PATH"
log ".dict OK: $DICT_PATH"

# ==============================================================================
# STEP 7: SUMMARY
# ==============================================================================
step "STEP 7/7: Summary"

elapsed_total=$(( $(date +%s) - SCRIPT_START_TS ))
log "Installation completed in ${elapsed_total}s."
log "ensembl-vep: $VEP_HOME (tag $VEP_TAG)"
log "Core API:    ensembl, ensembl-variation, ensembl-io, ensembl-funcgen (branch $ENSEMBL_API_TAG, at $DATA_DIR)"
log "Cache:       $CACHE_TARGET_DIR"
log "Plugins:     $VEP_PLUGINS ($(find "$VEP_PLUGINS" -maxdepth 1 -iname '*.pm' | wc -l) .pm files)"
log "FASTA:       $FASTA_PATH"
log ""
log "IMPORTANT: 'vep' needs in the environment:"
log "  PERL5LIB=\"$PERL5LIB\""
log "  PERL5OPT=\"$PERL5OPT\"  (avoids 'Attempt to reload Bio/DB/HTS/Tabix.pm aborted')"
log "They're already exported in this script's session; phase4.sh and rute_1.sh"
log "also export them before invoking vep."
log ""
log "Remember: the heavy plugin data (CADD, dbNSFP, REVEL, AlphaMissense,"
log "SpliceAI, EVE, mutfunc, satMutMPRA, dbscSNV, MaxEntScan, UTRAnnotator,"
log "Conservation) and ReAnote/data/custom/ (ClinVar, gnomAD, RegulomeDB) were NOT"
log "touched — they are a separate, later phase."
log ""
log "Now run: ReAnote/scripts/setup/verify_vep_engine.sh"
