#!/bin/bash

# Base directory for processing
output_base=$1
if [[ -z $output_base ]]; then
    echo "Usage: $0 <output_base>"
    exit 1
fi

suse_commands_dir="$output_base/suse-commands"

# Ensure the base output directories exist
mkdir -p "$output_base"
mkdir -p "$suse_commands_dir"

# Process each .txt file in the current directory
for txt_file in *.txt; do
    echo "Processing $txt_file..."

    # Create a directory for this file inside suse-commands (if needed)
    file_base_name="${txt_file%.txt}"
    file_commands_dir="$suse_commands_dir/$file_base_name"
    mkdir -p "$file_commands_dir"

    # State variables
    state=""
    command_output_file=""
    config_file=""
    verification_file_initialized=false

    # Read the file line by line
    while IFS= read -r line || [[ -n $line ]]; do
        case "$line" in
            "#==[ Command ]"*)
                state="command"
                command_output_file=""
                continue
                ;;
            "#==[ Configuration File ]"*)
                state="config"
                config_file=""
                continue
                ;;
            "#==[ Log File ]"*)
                state="log"
                config_file=""
                continue
                ;;
            "#==[ Verification ]"*)
                state="verification"
                verification_file=""
                continue
                ;;
            "#==["*)
                # Unknown header or delimiter, reset state
                state=""
                echo "File $txt_file:" >> unprocessed-lines.log
                echo "$line" >> unprocessed-lines.log
                continue
                ;;
        esac

        # Process content based on the current state
        case "$state" in
            "command")
                if [[ -z "$command_output_file" ]]; then
                    # First line of command section
                    command_line=${line//# /}  # Remove leading "# "

                    # Read the next line to check for "Command not found"
                    read -r next_line
                    if [[ "$next_line" == *"Command not found"* ]]; then
                        echo "Skipping command due to 'Command not found': $command_line"
                        state=""
                        continue
                    fi

                    # Extract the command name
                    command_name=$(echo "$command_line" | awk '{print $1}' | awk -F"/" '{print $NF}')

                    # Check for arguments
                    command_arguments=$(echo "$command_line" | awk '{$1=""; sub(/^ /, ""); gsub(/[ |>|<|\\|\/]/, "_"); print}')

                    if [[ -z "$command_arguments" ]]; then
                        command_output_file="$file_commands_dir/$command_name"
                    else
                        command_output_file="$file_commands_dir/${command_name}_${command_arguments}"
                    fi

                    echo "Processing command: $command_line -> $command_output_file"
                    > "$command_output_file"
                else
                    # Subsequent lines are command output
                    echo "$line" >> "$command_output_file"
                fi
                ;;
            "config"|"log")
                if [[ -z "$config_file" ]]; then
                    # First line of config/log section
                    file_path_clean=${line//# /}  # Remove leading "# "

                    # Check for "File not found"
                    if [[ "$file_path_clean" == *"File not found"* ]]; then
                        echo "Skipping $state file: $file_path_clean (File not found)"
                        state=""
                        continue
                    fi

                    # Check for "grep" in log files
                    if [[ "$state" == "log" && "$file_path_clean" == *"grep"* ]]; then
                        echo "Skipping log file containing 'grep': $file_path_clean"
                        state=""
                        continue
                    fi

                    # Remove " - Last X Lines" if present
                    file_path_clean=$(echo "$file_path_clean" | sed -E 's/ - Last [0-9]+ Lines//g')

                    file_dir=$(dirname "$file_path_clean")
                    file_name=$(basename "$file_path_clean")

                    mkdir -p "$output_base/$file_dir"
                    config_file="$output_base/$file_dir/$file_name"
                    echo "Processing $state file: $file_path_clean -> $config_file"
                    > "$config_file"
                else
                    # Subsequent lines are file content
                    echo "$line" >> "$config_file"
                fi
                ;;
            "verification")
                if [[ -z "$verification_file" ]]; then
                    # Check for "RPM Not Installed" in the first line after the delimiter
                    if [[ "$line" == *"RPM Not Installed"* ]]; then
                        echo "Skipping verification section due to 'RPM Not Installed'"
                        state=""
                        break
                    fi

                    # Remove "# rpm -V " and extract the package name
                    package_name=${line//# rpm -V /}

                    # Flag to indicate when to process lines
                    process_lines=false

                    # Read the file line by line
                    while IFS= read -r line || [[ -n $line ]]; do
                        if [[ "$line" == *"# Verification Status: "* ]]; then
                            verification_status=${line//# Verification Status: /}
                            process_lines=true
                            # Optionally, handle the line here and exit the loop if needed
                            break
                        fi

                        # Skip lines until the target string is found
                        if ! $process_lines; then
                            continue
                        fi
                    done < "$txt_file"

                    verification_file="$output_base/rpm_-V"
                    sed -i '/^$/d' $verification_file

                    # Concatenate package_name and verification_status with a tab space
                    echo -e "$package_name\t$verification_status" >> "$verification_file"
                fi
                ;;
            "")
                echo "$line" >> unprocessed-lines.log
                ;;
        esac
    done < "$txt_file"
done

echo "Processing complete. Outputs saved to $output_base."
