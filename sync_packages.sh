#!/usr/bin/env bash
# ==============================================================================
# Script Name: sync_rpm_packages.sh
# Description: Synchronizes local RHEL system packages to match a reference
#              RPM list file. Correctly handles RPM Epochs, multi-arch, and
#              produces an end-of-run discrepancy report.
# Execution Order: 1. Remove  ->  2. Downgrade  ->  3. Install & Upgrade
# Package Mgr: dnf / rpm
# ==============================================================================

set -uo pipefail

# --- Configuration & Defaults ---
LOG_FILE="${LOG_FILE:-/var/log/rpm_sync_$(date +'%Y%m%d_%H%M%S').log}"
DRY_RUN=false
ASSUME_YES=false
REFRESH_CACHE=true
INPUT_FILE=""

# --- Helper Functions ---
log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $*" | tee -a "$LOG_FILE"
}

log_info()    { log "INFO" "$@"; }
log_warn()    { log "WARN" "$@"; }
log_error()   { log "ERROR" "$@"; }
log_success() { log "SUCCESS" "$@"; }

show_progress() {
    local completed="$1"
    local total="$2"
    local stage_name="$3"
    local remaining=$((total - completed))
    local percent=0
    if [[ "$total" -gt 0 ]]; then
        percent=$((completed * 100 / total))
    fi

    local bar_len=20
    local filled_len=$((percent * bar_len / 100))
    local empty_len=$((bar_len - filled_len))
    local bar=""
    for ((i = 0; i < filled_len; i++)); do bar="${bar}="; done
    if [[ "$filled_len" -lt "$bar_len" ]]; then bar="${bar}>"; empty_len=$((empty_len - 1)); fi
    for ((i = 0; i < empty_len; i++)); do bar="${bar} "; done

    echo "" | tee -a "$LOG_FILE"
    log_info "----------------------------------------------------------------------"
    log_info " PROGRESS: [${bar}] ${percent}% | Completed: ${completed}/${total} | Remaining: ${remaining}"
    log_info " CURRENT PHASE: ${stage_name}"
    log_info "----------------------------------------------------------------------"
    echo "" | tee -a "$LOG_FILE"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <package_list_file>

Options:
  -d, --dry-run          Only calculate and display package differences; do not execute dnf.
  -y, --yes              Automatically answer yes for all dnf prompts.
  -l, --log-file         Custom log file path (default: /var/log/rpm_sync_<timestamp>.log).
  --no-cache-refresh     Skip dnf makecache --refresh.
  -h, --help             Show this help message and exit.
EOF
    exit 1
}

# --- Parse CLI Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        -l|--log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        --no-cache-refresh)
            REFRESH_CACHE=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            ;;
        *)
            if [[ -z "$INPUT_FILE" ]]; then
                INPUT_FILE="$1"
            else
                echo "Unexpected argument: $1" >&2
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "$INPUT_FILE" ]]; then
    echo "Error: Target package list file is required." >&2
    usage
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: File '$INPUT_FILE' not found." >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

if [[ $EUID -ne 0 && "$DRY_RUN" = false ]]; then
    log_error "This script must be run as root (or with sudo) to apply changes."
    exit 1
fi

log_info "=== Starting RPM Package Sync ==="
log_info "Target Package List : $INPUT_FILE"
log_info "Log File            : $LOG_FILE"
log_info "Dry Run Mode        : $DRY_RUN"

TMP_DIR=$(mktemp -d /tmp/rpm_sync.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

# --- Step 0: Refresh DNF Repositories Metadata ---
if [[ "$REFRESH_CACHE" = true ]]; then
    log_info "Refreshing DNF repository cache..."
    dnf makecache --refresh 2>&1 | tee -a "$LOG_FILE" || log_warn "Cache refresh partially failed. Continuing with existing metadata..."
fi

# --- Step 1: Export Installed Packages & Query Available Epochs ---
log_info "Querying currently installed RPM packages (including Epochs)..."
# Format: NAME|EPOCH|VERSION|RELEASE|ARCH
rpm -qa --qf "%{NAME}|%{EPOCHNUM}|%{VERSION}|%{RELEASE}|%{ARCH}\n" | sort > "$TMP_DIR/installed_raw.txt"

log_info "Querying repository package epochs..."
dnf repoquery --available --qf "%{NAME}|%{EPOCHNUM}|%{VERSION}|%{RELEASE}|%{ARCH}\n" > "$TMP_DIR/repo_evr.txt" 2>/dev/null || true

# --- Step 2: Parse Target Package List & Reconcile Epochs ---
log_info "Parsing target package list and resolving Epochs..."
python3 - << 'PY_PARSE' "$INPUT_FILE" "$TMP_DIR"
import sys, re, os

input_file = sys.argv[1]
tmp_dir = sys.argv[2]

# Load installed and repo epochs for lookup
known_epochs = {} # (name, arch) -> epoch or (name) -> epoch

def load_epochs(filepath):
    if not os.path.exists(filepath):
        return
    with open(filepath, 'r') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) == 5:
                name, epoch, ver, rel, arch = parts
                if epoch != "(none)" and epoch != "None":
                    known_epochs[(name, arch)] = epoch
                    known_epochs[name] = epoch

load_epochs(os.path.join(tmp_dir, "installed_raw.txt"))
load_epochs(os.path.join(tmp_dir, "repo_evr.txt"))

pattern = re.compile(r'^(?:(?P<epoch>\d+):)?(?P<name>.+)-(?P<version>[^-]+)-(?P<release>[^-]+)\.(?P<arch>[^.]+)$')

with open(input_file, "r") as f_in, open(os.path.join(tmp_dir, "target_parsed.txt"), "w") as f_out:
    for line_num, line in enumerate(f_in, 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.endswith('.rpm'):
            line = line[:-4]
        
        match = pattern.match(line)
        if match:
            d = match.groupdict()
            name = d['name']
            arch = d['arch']
            ver = d['version']
            rel = d['release']
            
            # Resolve Epoch: Explicit in file > Known from installed/repo > "0"
            if d['epoch'] is not None:
                epoch = d['epoch']
            elif (name, arch) in known_epochs:
                epoch = known_epochs[(name, arch)]
            elif name in known_epochs:
                epoch = known_epochs[name]
            else:
                epoch = "0"

            f_out.write(f"{name}|{epoch}|{ver}|{rel}|{arch}\n")
        else:
            sys.stderr.write(f"Warning: Line {line_num} ('{line}') does not match expected RPM naming convention. Skipping.\n")
PY_PARSE

# --- Step 3: Compare Versions & Categorize Planned Actions ---
log_info "Analyzing package differences with accurate Epochs..."

python3 - << 'PY_COMPARE' "$TMP_DIR"
import sys, os
import rpm

tmp_dir = sys.argv[1]

def read_packages(filepath):
    pkgs = {}
    if not os.path.exists(filepath):
        return pkgs
    with open(filepath, 'r') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) == 5:
                name, epoch, version, release, arch = parts
                pkgs[(name, arch)] = (epoch, version, release)
    return pkgs

installed = read_packages(os.path.join(tmp_dir, "installed_raw.txt"))
target = read_packages(os.path.join(tmp_dir, "target_parsed.txt"))

to_install = []
to_upgrade = []
to_downgrade = []
to_remove = []

for (name, arch), (t_epoch, t_ver, t_rel) in target.items():
    # Build complete DNF spec with epoch: name-epoch:ver-rel.arch
    t_evr_spec = f"{name}-{t_epoch}:{t_ver}-{t_rel}.{arch}" if t_epoch != "0" else f"{name}-{t_ver}-{t_rel}.{arch}"
    
    if (name, arch) not in installed:
        to_install.append(t_evr_spec)
    else:
        i_epoch, i_ver, i_rel = installed[(name, arch)]
        # Compare (epoch, version, release)
        cmp_result = rpm.labelCompare((str(t_epoch), str(t_ver), str(t_rel)), 
                                      (str(i_epoch), str(i_ver), str(i_rel)))
        if cmp_result > 0:
            to_upgrade.append(t_evr_spec)
        elif cmp_result < 0:
            to_downgrade.append(t_evr_spec)

# Protected list from removal
PROTECTED = {
    "systemd", "dnf", "rpm", "glibc", "kernel", "coreutils", 
    "bash", "shadow-utils", "falcon-sensor"
}

for (name, arch), (i_epoch, i_ver, i_rel) in installed.items():
    if (name, arch) not in target:
        if name not in PROTECTED and not name.startswith("kernel"):
            to_remove.append(f"{name}.{arch}")

def write_list(filename, items):
    with open(os.path.join(tmp_dir, filename), 'w') as f:
        for item in sorted(items):
            f.write(f"{item}\n")

write_list("remove_list.txt", to_remove)
write_list("downgrade_list.txt", to_downgrade)
write_list("upgrade_list.txt", to_upgrade)
write_list("install_list.txt", to_install)
PY_COMPARE

# --- Step 4: Display Initial Plan Summary ---
count_remove=$(wc -l < "$TMP_DIR/remove_list.txt")
count_downgrade=$(wc -l < "$TMP_DIR/downgrade_list.txt")
count_upgrade=$(wc -l < "$TMP_DIR/upgrade_list.txt")
count_install=$(wc -l < "$TMP_DIR/install_list.txt")
count_install_upgrade=$((count_upgrade + count_install))

total_changes=$((count_remove + count_downgrade + count_install_upgrade))
completed_changes=0

echo "" | tee -a "$LOG_FILE"
log_info "================ INITIAL SYNC PLAN ================"
log_info "1. Packages to REMOVE            : $count_remove"
log_info "2. Packages to DOWNGRADE         : $count_downgrade"
log_info "3. Packages to INSTALL & UPGRADE : $count_install_upgrade (Install: $count_install, Upgrade: $count_upgrade)"
log_info "---------------------------------------------------"
log_info "TOTAL PLANNED ACTIONS            : $total_changes"
log_info "==================================================="
echo "" | tee -a "$LOG_FILE"

log_section() {
    local title="$1"
    local file="$2"
    if [[ -s "$file" ]]; then
        log_info "--- $title ---"
        while IFS= read -r pkg; do
            log_info "  $pkg"
        done < "$file"
    fi
}

log_section "Packages to Remove (Phase 1)" "$TMP_DIR/remove_list.txt"
log_section "Packages to Downgrade (Phase 2)" "$TMP_DIR/downgrade_list.txt"
log_section "Packages to Upgrade (Phase 3)" "$TMP_DIR/upgrade_list.txt"
log_section "Packages to Install (Phase 3)" "$TMP_DIR/install_list.txt"

if [[ "$total_changes" -eq 0 ]]; then
    log_success "System is already fully in sync with target package list. No actions needed."
    exit 0
fi

if [[ "$DRY_RUN" = true ]]; then
    log_info "Dry-run mode enabled. No package modifications will be made."
    exit 0
fi

# --- Step 5: Execute Sync Process using DNF ---
# --setopt=strict=0 ensures missing packages don't abort the entire command
DNF_FLAGS=("--setopt=strict=0" "--allowerasing")
if [[ "$ASSUME_YES" = true ]]; then
    DNF_FLAGS+=("-y")
fi

log_info "Starting package synchronization via DNF..."

# ----------------- PHASE 1: REMOVALS -----------------
show_progress "$completed_changes" "$total_changes" "Phase 1/3: Removing Packages ($count_remove packages)"
if [[ "$count_remove" -gt 0 ]]; then
    mapfile -t pkgs_remove < "$TMP_DIR/remove_list.txt"
    dnf remove "${DNF_FLAGS[@]}" "${pkgs_remove[@]}" 2>&1 | tee -a "$LOG_FILE" || log_warn "Some removals could not be processed."
    completed_changes=$((completed_changes + count_remove))
else
    log_info "No packages to remove. Skipping Phase 1."
fi

# ----------------- PHASE 2: DOWNGRADES -----------------
show_progress "$completed_changes" "$total_changes" "Phase 2/3: Downgrading Packages ($count_downgrade packages)"
if [[ "$count_downgrade" -gt 0 ]]; then
    mapfile -t pkgs_downgrade < "$TMP_DIR/downgrade_list.txt"
    dnf downgrade "${DNF_FLAGS[@]}" "${pkgs_downgrade[@]}" 2>&1 | tee -a "$LOG_FILE" || log_warn "Some downgrades could not be matched or processed."
    completed_changes=$((completed_changes + count_downgrade))
else
    log_info "No packages to downgrade. Skipping Phase 2."
fi

# ----------------- PHASE 3: INSTALLS & UPGRADES -----------------
show_progress "$completed_changes" "$total_changes" "Phase 3/3: Installing and Upgrading Packages ($count_install_upgrade packages)"
if [[ "$count_install_upgrade" -gt 0 ]]; then
    pkgs_install_upgrade=()
    if [[ "$count_upgrade" -gt 0 ]]; then
        mapfile -t pkgs_up < "$TMP_DIR/upgrade_list.txt"
        pkgs_install_upgrade+=("${pkgs_up[@]}")
    fi
    if [[ "$count_install" -gt 0 ]]; then
        mapfile -t pkgs_in < "$TMP_DIR/install_list.txt"
        pkgs_install_upgrade+=("${pkgs_in[@]}")
    fi
    dnf install "${DNF_FLAGS[@]}" "${pkgs_install_upgrade[@]}" 2>&1 | tee -a "$LOG_FILE" || log_warn "Some installs/upgrades could not be matched or processed."
    completed_changes=$((completed_changes + count_install_upgrade))
else
    log_info "No packages to install or upgrade. Skipping Phase 3."
fi

show_progress "$completed_changes" "$total_changes" "DNF Operations Finished - Generating Final Discrepancy Report..."

# --- Step 6: Post-Sync Verification & Discrepancy Reporting ---
log_info "Re-querying system packages to verify final state..."
rpm -qa --qf "%{NAME}|%{EPOCHNUM}|%{VERSION}|%{RELEASE}|%{ARCH}\n" | sort > "$TMP_DIR/post_installed_raw.txt"

python3 - << 'PY_REPORT' "$TMP_DIR"
import sys, os
import rpm

tmp_dir = sys.argv[1]

def read_packages(filepath):
    pkgs = {}
    if not os.path.exists(filepath):
        return pkgs
    with open(filepath, 'r') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) == 5:
                name, epoch, version, release, arch = parts
                pkgs[(name, arch)] = (epoch, version, release)
    return pkgs

installed_post = read_packages(os.path.join(tmp_dir, "post_installed_raw.txt"))
target = read_packages(os.path.join(tmp_dir, "target_parsed.txt"))

missing_on_server = []
version_mismatches = []
extra_on_server = []

PROTECTED = {
    "systemd", "dnf", "rpm", "glibc", "kernel", "coreutils", 
    "bash", "shadow-utils", "falcon-sensor"
}

# 1. Check target list against what is installed
for (name, arch), (t_epoch, t_ver, t_rel) in target.items():
    t_evr = f"{name}-{t_ver}-{t_rel}.{arch}"
    if (name, arch) not in installed_post:
        missing_on_server.append(t_evr)
    else:
        i_epoch, i_ver, i_rel = installed_post[(name, arch)]
        cmp_result = rpm.labelCompare((str(t_epoch), str(t_ver), str(t_rel)), 
                                      (str(i_epoch), str(i_ver), str(i_rel)))
        if cmp_result != 0:
            i_evr = f"{name}-{i_ver}-{i_rel}.{arch}"
            version_mismatches.append((t_evr, i_evr))

# 2. Check installed packages not in target
for (name, arch), (i_epoch, i_ver, i_rel) in installed_post.items():
    if (name, arch) not in target:
        i_evr = f"{name}-{i_ver}-{i_rel}.{arch}"
        is_prot = " [PROTECTED]" if (name in PROTECTED or name.startswith("kernel")) else ""
        extra_on_server.append(f"{i_evr}{is_prot}")

with open(os.path.join(tmp_dir, "report_missing.txt"), "w") as f:
    for item in sorted(missing_on_server):
        f.write(f"{item}\n")

with open(os.path.join(tmp_dir, "report_mismatch.txt"), "w") as f:
    for t_evr, i_evr in sorted(version_mismatches):
        f.write(f"Target: {t_evr} <---> Installed: {i_evr}\n")

with open(os.path.join(tmp_dir, "report_extra.txt"), "w") as f:
    for item in sorted(extra_on_server):
        f.write(f"{item}\n")
PY_REPORT

cnt_miss=$(wc -l < "$TMP_DIR/report_missing.txt")
cnt_mismatch=$(wc -l < "$TMP_DIR/report_mismatch.txt")
cnt_extra=$(wc -l < "$TMP_DIR/report_extra.txt")

echo "" | tee -a "$LOG_FILE"
log_info "======================================================================"
log_info "                 POST-SYNC INCONSISTENCY REPORT                       "
log_info "======================================================================"
log_info "1. MISSING ON SERVER (In file, but not installed)      : $cnt_miss"
log_info "2. VERSION MISMATCHES (Installed != Target in file)    : $cnt_mismatch"
log_info "3. EXTRA ON SERVER (Installed on server, not in file)  : $cnt_extra"
log_info "======================================================================"

if [[ "$cnt_miss" -gt 0 ]]; then
    echo "" | tee -a "$LOG_FILE"
    log_warn "--- [1] Packages in file NOT installed (Missing third-party repo/RPM) ---"
    while IFS= read -r line; do
        log_warn "  [MISSING] $line"
    done < "$TMP_DIR/report_missing.txt"
fi

if [[ "$cnt_mismatch" -gt 0 ]]; then
    echo "" | tee -a "$LOG_FILE"
    log_warn "--- [2] Version Mismatches on Server ---"
    while IFS= read -r line; do
        log_warn "  [MISMATCH] $line"
    done < "$TMP_DIR/report_mismatch.txt"
fi

if [[ "$cnt_extra" -gt 0 ]]; then
    echo "" | tee -a "$LOG_FILE"
    log_info "--- [3] Extra Packages on Server (Retained dependencies / Protected) ---"
    while IFS= read -r line; do
        log_info "  [EXTRA] $line"
    done < "$TMP_DIR/report_extra.txt"
fi

echo "" | tee -a "$LOG_FILE"
if [[ "$cnt_miss" -eq 0 && "$cnt_mismatch" -eq 0 ]]; then
    log_success "Sync completed successfully! Server matches target list with 0 missing/mismatched packages."
else
    log_warn "Sync completed with inconsistencies (e.g. proprietary agents or unconfigured repos). Check report above."
fi
log_info "Full execution log written to: $LOG_FILE"
