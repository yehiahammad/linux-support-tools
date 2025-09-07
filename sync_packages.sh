#!/bin/bash

DESIRED_FILE="desired_packages.txt"
LOGFILE="sync_packages.log"
echo "Sync started at $(date)" > "$LOGFILE"

# Create associative arrays
declare -A desired
declare -A installed

# Read desired packages
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pkg=$(echo "$line" | sed -E 's/-[0-9]+.*//')
    desired["$pkg"]="$line"
done < "$DESIRED_FILE"

# Get installed packages
while IFS= read -r line; do
    pkg=$(echo "$line" | sed -E 's/-[0-9]+.*//')
    installed["$pkg"]="$line"
done < <(rpm -qa)

# Compare and act
for pkg in "${!desired[@]}"; do
    if [[ -z "${installed[$pkg]}" ]]; then
        echo "Installing ${desired[$pkg]}" | tee -a "$LOGFILE"
        dnf install -y "${desired[$pkg]}" >> "$LOGFILE" 2>&1
    elif [[ "${installed[$pkg]}" == "${desired[$pkg]}" ]]; then
        echo "$pkg is already at desired version." | tee -a "$LOGFILE"
    else
        echo "Downgrading $pkg from ${installed[$pkg]} to ${desired[$pkg]}" | tee -a "$LOGFILE"
        dnf downgrade -y "${desired[$pkg]}" >> "$LOGFILE" 2>&1
    fi
done

# Prompt to remove extra packages with dependency info
for pkg in "${!installed[@]}"; do
    if [[ -z "${desired[$pkg]}" ]]; then
        echo -e "\\n${pkg} (${installed[$pkg]}) is not in the desired list."

        echo "Simulating removal to show dependencies..."
        echo "Packages that would be removed:"
        dnf remove "$pkg" --assumeno | awk '/Removing:/,/Complete!/'

        read -p "Do you want to remove $pkg? [y/N]: " answer
        if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
            echo "Removing $pkg" | tee -a "$LOGFILE"
            dnf remove -y "$pkg" >> "$LOGFILE" 2>&1
        fi
    fi
done

echo "Sync completed at $(date)" >> "$LOGFILE"
