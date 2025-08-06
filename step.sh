#!/usr/bin/env bash

# Fail if any command fails
set -e

# Debug logging
if [ "${show_debug_logs}" == "true" ]; then
  set -x
    echo "Debug mode enabled"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    if [ "${show_debug_logs}" == "true" ]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install Tartufo
install_tartufo() {
    print_info "Installing Tartufo..."
    
    # Check if Python 3 is available
    if ! command_exists python3; then
        print_error "Python 3 is required but not installed"
        exit 1
    fi
    
    # Check if pip is available
    if ! command_exists pip; then
        print_error "pip is required but not installed"
            exit 1
    fi
    
    # Install tartufo
    if [ "${show_debug_logs}" == "true" ]; then
        pip install tartufo
    else
        pip install tartufo >/dev/null 2>&1
    fi
    
    if command_exists tartufo; then
        print_success "Tartufo installed successfully"
        if [ "${show_debug_logs}" == "true" ]; then
            tartufo --version
        fi
    else
        print_error "Failed to install Tartufo"
        exit 1
    fi 
}

# Function to build tartufo command
build_tartufo_command() {
    local cmd="tartufo"
    
    # Add entropy sensitivity
    if [ -n "${entropy_sensitivity}" ]; then
        cmd="${cmd} --entropy-sensitivity ${entropy_sensitivity}"
    fi
    
    # Add regex checks
    if [ "${regex_checks}" == "false" ]; then
        cmd="${cmd} --no-regex"
    fi
    
    # Add entropy checks
    if [ "${entropy_checks}" == "false" ]; then
        cmd="${cmd} --no-entropy"
    fi
    
    # Add config file if provided
    if [ -n "${config_file_path}" ] && [ -f "${config_file_path}" ]; then
        cmd="${cmd} --config ${config_file_path}"
        print_info "Using config file: ${config_file_path}"
    fi
    
    # Add baseline file if provided
    if [ -n "${baseline_file_path}" ] && [ -f "${baseline_file_path}" ]; then
        cmd="${cmd} --baseline ${baseline_file_path}"
        print_info "Using baseline file: ${baseline_file_path}"
    fi
    
    # Add output format
    if [ -n "${output_format}" ]; then
        cmd="${cmd} --output-format ${output_format}"
    fi
    
    # Add include paths
    if [ -n "${include_paths}" ]; then
        IFS=',' read -ra INCLUDE_ARRAY <<< "${include_paths}"
        for path in "${INCLUDE_ARRAY[@]}"; do
            path=$(echo "$path" | xargs) # trim whitespace
            cmd="${cmd} --include-path '${path}'"
        done
    fi
    
    # Add exclude paths
    if [ -n "${exclude_paths}" ]; then
        IFS=',' read -ra EXCLUDE_ARRAY <<< "${exclude_paths}"
        for path in "${EXCLUDE_ARRAY[@]}"; do
            path=$(echo "$path" | xargs) # trim whitespace
            cmd="${cmd} --exclude-path '${path}'"
        done
    fi
    
    # Add scan mode specific options
    if [ "${scan_mode}" == "history" ]; then
        cmd="${cmd} scan-local-repo"
        
        # Add branch name if specified
        if [ -n "${branch_name}" ]; then
            cmd="${cmd} --branch ${branch_name}"
        fi
        
        # Add since commit if specified
        if [ -n "${since_commit}" ]; then
            cmd="${cmd} --since-commit ${since_commit}"
        fi
        
        # Add max depth if specified
        if [ -n "${max_depth}" ]; then
            cmd="${cmd} --max-depth ${max_depth}"
        fi
        
    elif [ "${scan_mode}" == "path" ]; then
        cmd="${cmd} scan-folder"
    else
        print_error "Invalid scan mode: ${scan_mode}"
        exit 1
    fi
    
    # Add extra arguments if provided
    if [ -n "${extra_args}" ]; then
        cmd="${cmd} ${extra_args}"
    fi
    
    # Add target path
    cmd="${cmd} ${target_path}"
    
    echo "${cmd}"
}

# Function to run tartufo and handle results
run_tartufo_scan() {
    local cmd="$1"
    # Determine output directory (use parent directory if target is a file)
    local output_dir="${BITRISE_SOURCE_DIR:-}"
    if [ -z "${output_dir}" ]; then
        if [ -f "${target_path}" ]; then
            output_dir=$(dirname "${target_path}")
        else
            output_dir="${target_path}"
        fi
    fi
    local output_file="${output_dir}/tartufo-results.txt"
    local json_output_file="${output_dir}/tartufo-results.json"
    
    print_info "Running Tartufo scan..."
    print_info "Command: ${cmd}"
    print_info "Target path: ${target_path}"
    print_info "Scan mode: ${scan_mode}"
    
    # Ensure target path exists
    if [ ! -e "${target_path}" ]; then
        print_error "Target path does not exist: ${target_path}"
        exit 1
    fi
    
    # Run the command and capture output
    local exit_code=0
    
    # Save original output format for later use
    local original_output_format="${output_format}"
    
    # File size limits (in bytes)
    local max_file_size=$((30 * 1024 * 1024))  # 30MB
    local warning_file_size=$((20 * 1024 * 1024))  # 20MB
    local emergency_file_size=$((100 * 1024 * 1024))  # 100MB - kill scan if exceeded
    
    # Scan timeout (default to 300 seconds if not set)
    local timeout_seconds="${scan_timeout:-300}"
    
    # Warn about potentially problematic entropy settings
    local entropy_val="${entropy_sensitivity:-90}"
    if [ "${entropy_val}" -lt 85 ]; then
        print_warning "Entropy sensitivity is set to ${entropy_val}. Values below 85 may generate very large output files."
        print_warning "Consider using path exclusions or increasing entropy sensitivity if scan generates large files."
    fi
    
    # Function to monitor file size during scan
    monitor_file_size() {
        local file_to_monitor="$1"
        local max_size="$2"
        local scan_pid="$3"
        
        while kill -0 "$scan_pid" 2>/dev/null; do
            if [ -f "$file_to_monitor" ]; then
                local current_size=$(stat -f%z "$file_to_monitor" 2>/dev/null || wc -c < "$file_to_monitor" 2>/dev/null || echo "0")
                if [ "$current_size" -gt "$max_size" ]; then
                    print_error "Output file exceeded ${max_size} bytes (currently ${current_size}). Terminating scan to prevent system overload."
                    kill -TERM "$scan_pid" 2>/dev/null
                    sleep 2
                    kill -KILL "$scan_pid" 2>/dev/null
                    return 1
                fi
            fi
            sleep 2
        done
        return 0
    }
    
    # Always capture text output for logging with size monitoring
    if [ "${scan_mode}" == "path" ]; then
        # scan-folder might prompt for confirmation if it's a git repo
        echo "y" | timeout "${timeout_seconds}" bash -c "${cmd}" > "${output_file}" 2>&1 &
        local scan_pid=$!
        monitor_file_size "${output_file}" "${emergency_file_size}" "${scan_pid}" &
        local monitor_pid=$!
        wait "${scan_pid}" || exit_code=$?
        kill "${monitor_pid}" 2>/dev/null || true
    else
        timeout "${timeout_seconds}" bash -c "${cmd}" > "${output_file}" 2>&1 &
        local scan_pid=$!
        monitor_file_size "${output_file}" "${emergency_file_size}" "${scan_pid}" &
        local monitor_pid=$!
        wait "${scan_pid}" || exit_code=$?
        kill "${monitor_pid}" 2>/dev/null || true
    fi
    
    # Check file size and truncate if necessary
    if [ -f "${output_file}" ]; then
        local file_size=$(stat -f%z "${output_file}" 2>/dev/null || wc -c < "${output_file}")
        if [ "${file_size}" -gt "${max_file_size}" ]; then
            print_warning "Output file is too large (${file_size} bytes). Truncating to ${max_file_size} bytes."
            print_warning "RECOMMENDATIONS to reduce file size:"
            print_warning "  1. Increase entropy_sensitivity to 95 or higher"
            print_warning "  2. Add exclude_paths for large directories (node_modules/, .git/, build/)"
            print_warning "  3. Use scan-local-repo instead of scan-folder for git repositories"
            print_warning "  4. Set max_depth to limit commit history scanning"
            # Keep the first part of the file and add truncation notice
            head -c $((max_file_size - 1000)) "${output_file}" > "${output_file}.tmp"
            echo -e "\n\n[TRUNCATED] Output was too large and has been truncated. Original size: ${file_size} bytes" >> "${output_file}.tmp"
            echo -e "RECOMMENDATIONS: Increase entropy_sensitivity to 95+, add exclude_paths, or use scan-local-repo mode" >> "${output_file}.tmp"
            mv "${output_file}.tmp" "${output_file}"
        elif [ "${file_size}" -gt "${warning_file_size}" ]; then
            print_warning "Output file is large (${file_size} bytes). Consider increasing entropy_sensitivity to 90+ or using path exclusions."
        fi
    fi
    
    # Also capture JSON output for programmatic processing (with size limits)
    if [ "${output_format}" != "json" ]; then
        local json_cmd=$(echo "${cmd}" | sed 's/--output-format [^ ]*/--output-format json/')
        if [ "${scan_mode}" == "path" ]; then
            echo "y" | timeout "${timeout_seconds}" bash -c "${json_cmd}" > "${json_output_file}" 2>/dev/null || true
        else
            timeout "${timeout_seconds}" bash -c "${json_cmd}" > "${json_output_file}" 2>/dev/null || true
        fi
        
        # Check JSON file size
        if [ -f "${json_output_file}" ]; then
            local json_file_size=$(stat -f%z "${json_output_file}" 2>/dev/null || wc -c < "${json_output_file}")
            if [ "${json_file_size}" -gt "${max_file_size}" ]; then
                print_warning "JSON output file is too large (${json_file_size} bytes). Truncating."
                echo '{"error": "Output truncated due to size limit", "original_size": '${json_file_size}', "max_size": '${max_file_size}'}' > "${json_output_file}"
            fi
        fi
    else
        cp "${output_file}" "${json_output_file}"
    fi
    
    # Handle timeout and termination exit codes
    if [ "${exit_code}" -eq 124 ]; then
        print_error "Tartufo scan timed out after ${timeout_seconds} seconds. Consider using path exclusions, reducing entropy sensitivity, or increasing scan_timeout."
        exit_code=1
    elif [ "${exit_code}" -eq 143 ] || [ "${exit_code}" -eq 137 ]; then
        print_error "Tartufo scan was terminated (likely due to large output file). Consider increasing entropy sensitivity or using path exclusions."
        exit_code=1
    fi
    
    # Display results
    print_info "Scan completed with exit code: ${exit_code}"
    
    if [ -f "${output_file}" ]; then
        local file_size=$(wc -c < "${output_file}")
        if [ ${file_size} -gt 0 ]; then
            if [ "${show_debug_logs}" == "true" ]; then
                print_info "Tartufo output:"
                echo "===================="
                # Only show first 10000 characters to avoid overwhelming the logs
                if [ ${file_size} -gt 10000 ]; then
                    head -c 10000 "${output_file}"
                    echo -e "\n[OUTPUT TRUNCATED FOR DISPLAY - Full output saved to ${output_file}]"
                else
                    cat "${output_file}"
                fi
                echo "===================="
            fi
        fi
    fi
    
    # Analyze results
    local findings_count=0
    
    if [ -f "${json_output_file}" ] && [ -s "${json_output_file}" ]; then
        # Try to count findings from JSON output
        if command_exists jq; then
            findings_count=$(jq '.found_issues | length' "${json_output_file}" 2>/dev/null || echo "0")
        else
            # Fallback: count lines that look like findings
            findings_count=$(grep -c "signature\|entropy\|reason" "${json_output_file}" 2>/dev/null || echo "0")
        fi
    elif [ -f "${output_file}" ] && [ -s "${output_file}" ]; then
        # For text output, count lines that indicate findings
        findings_count=$(grep -c "Reason:\|entropy\|signature" "${output_file}" 2>/dev/null || echo "0")
    fi
    
    # Ensure findings_count is numeric
    if ! [[ "${findings_count}" =~ ^[0-9]+$ ]]; then
        findings_count=0
    fi
    
    # Note: findings_count will be displayed in the summary
    
    # Handle results based on configuration
    if [ "${exit_code}" -eq 0 ]; then
        if [ "${findings_count}" -eq 0 ]; then
            print_success "✅ No secrets found! Repository is clean."
        else
            print_warning "⚠️  Scan completed but ${findings_count} potential secrets were found."
        fi
    else
        if [ "${findings_count}" -gt 0 ]; then
            print_error "❌ ${findings_count} potential secrets detected!"
        else
            print_error "❌ Scan failed with exit code ${exit_code}"
        fi
    fi
    
    # Export results for other steps (only if envman is available)
    if command_exists envman; then
        envman add --key TARTUFO_FINDINGS_COUNT --value "${findings_count}"
        envman add --key TARTUFO_RESULTS_FILE --value "${output_file}"
        if [ -f "${json_output_file}" ]; then
            envman add --key TARTUFO_JSON_RESULTS_FILE --value "${json_output_file}"
        fi
    fi
    
    # Show summary (always displayed)
    echo "========================================="
    echo "Tartufo Scan Summary:"
    echo "Target: ${target_path}"
    echo "Mode: ${scan_mode}"
    echo "Findings: ${findings_count}"
    echo "========================================="
    
    # Fail build if configured to do so and findings were detected
    if [ "${fail_on_findings}" == "true" ] && [ "${findings_count}" -gt 0 ]; then
        print_error "Build failed due to detected secrets (fail_on_findings=true)"
        exit 1
    elif [ "${fail_on_findings}" == "true" ] && [ "${exit_code}" -ne 0 ]; then
        print_error "Build failed due to scan error (fail_on_findings=true)"
        exit 1
    fi
    
    print_success "Tartufo scan completed successfully"
}

# Main execution
main() {
    print_info "Starting Tartufo security scan..."
    
    # Validate required inputs
    if [ -z "${scan_mode}" ]; then
        print_error "scan_mode is required"
        exit 1
    fi
    
    if [ -z "${target_path}" ]; then
        print_error "target_path is required"
        exit 1
    fi
    
    # Install Tartufo if not already installed
    if ! command_exists tartufo; then
        install_tartufo
    else
        print_info "Tartufo is already installed"
        if [ "${show_debug_logs}" == "true" ]; then
            tartufo --version
        fi
    fi
    
    # Build the command
    local tartufo_cmd=$(build_tartufo_command)
    
    # Run the scan
    run_tartufo_scan "${tartufo_cmd}"
}

# Execute main function
main "$@"


