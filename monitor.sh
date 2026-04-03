#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================
# Constants
# ==============================
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="2.0.0"

# ==============================
# Default Configuration
# ==============================
TEXTFILE_PATH="/opt/node_exporter/textfile_collector/combined_monitor.prom"
TEMP_FILE="/tmp/combined_monitor_temp.prom"
CONFIG_FILE=""
MAX_PARALLEL_JOBS=5
CLI_MODE=false

# Default targets (fallback when no config file is provided)
DEFAULT_WEBSITES=(
    "https://www.corp-analytics-portal.com/"
    "https://beta.project-nebula.io/login"
    "http://192.168.50.11/metrics"
    "https://support.global-solutions.org/knowledgebase"
    "https://dev.api-gateway-v2.net/v1/status"
)

DEFAULT_VM_HOSTS=(
    "vm-prod-app03"
    "dev-db-master01"
    "edge-node-sfo1"
    "test-web-proxy-b"
    "lab-jumper-007"
)

# Active target lists (populated from config or defaults)
WEBSITES=()
VM_HOSTS=()

# ==============================
# Colors
# ==============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Temporary directory for parallel job output
JOB_TMP_DIR=""

# ==============================
# Error Handler
# ==============================
error_handler() {
    echo -e "${RED}[ERROR] Unexpected failure on line $1${NC}" >&2
    cleanup
    exit 1
}
trap 'error_handler $LINENO' ERR
trap 'echo -e "\n${RED}Aborted by user.${NC}"; cleanup; exit 130' SIGINT

# ==============================
# Cleanup
# ==============================
cleanup() {
    if [[ -n "${JOB_TMP_DIR:-}" && -d "${JOB_TMP_DIR:-}" ]]; then
        rm -rf "$JOB_TMP_DIR"
    fi
}
trap cleanup EXIT

# ==============================
# Usage
# ==============================
usage() {
cat << EOF
${BOLD}${SCRIPT_NAME}${NC} v${VERSION} - Prometheus website & VM host monitor

Usage:
  ${SCRIPT_NAME} [options]

Options:
  -c, --config <file>   Path to YAML config file
      --cli             CLI-only mode (skip Prometheus file output)
  -h, --help            Show this help

Examples:
  ./${SCRIPT_NAME}                          # Use hardcoded defaults
  ./${SCRIPT_NAME} --config config.yaml     # Load targets from config
  ./${SCRIPT_NAME} --cli                    # Quick CLI health check
  ./${SCRIPT_NAME} --config config.yaml --cli
EOF
}

# ==============================
# YAML Config Parser (built-in, no yq dependency)
# ==============================
parse_yaml_config() {
    local config_file="$1"

    [[ -f "$config_file" ]] || {
        echo -e "${RED}[ERROR] Config file not found: $config_file${NC}" >&2
        exit 1
    }

    # --- textfile_path ---
    local parsed_path
    parsed_path=$(grep -E "^textfile_path:" "$config_file" 2>/dev/null | head -1 \
        | sed 's/^textfile_path:[[:space:]]*//' \
        | sed "s/^[\"']//" | sed "s/[\"']$//" \
        | tr -d '\r') || true
    if [[ -n "$parsed_path" ]]; then
        TEXTFILE_PATH="$parsed_path"
    fi

    # --- websites ---
    local in_section=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^websites:[[:space:]]*$ ]]; then
            in_section=true
            continue
        fi
        if $in_section; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
                local value
                value=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed "s/^[\"']//" | sed "s/[\"']$//")
                [[ -n "$value" ]] && WEBSITES+=("$value")
            elif [[ "$line" =~ ^[a-zA-Z_] ]]; then
                break
            fi
        fi
    done < "$config_file"

    # --- vm_hosts ---
    in_section=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^vm_hosts:[[:space:]]*$ ]]; then
            in_section=true
            continue
        fi
        if $in_section; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
                local value
                value=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed "s/^[\"']//" | sed "s/[\"']$//")
                [[ -n "$value" ]] && VM_HOSTS+=("$value")
            elif [[ "$line" =~ ^[a-zA-Z_] ]]; then
                break
            fi
        fi
    done < "$config_file"

    # --- parallel.max_jobs ---
    local parsed_jobs
    parsed_jobs=$(sed -n '/^parallel:/,/^[a-zA-Z_]/p' "$config_file" \
        | grep -E "^[[:space:]]+max_jobs:" | head -1 \
        | sed 's/.*max_jobs:[[:space:]]*//' | tr -d '\r') || true
    if [[ -n "$parsed_jobs" && "$parsed_jobs" =~ ^[0-9]+$ ]]; then
        MAX_PARALLEL_JOBS="$parsed_jobs"
    fi
}

# ==============================
# Argument Parsing
# ==============================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                [[ -z "${2:-}" ]] && {
                    echo -e "${RED}[ERROR] --config requires a file path${NC}" >&2
                    exit 2
                }
                CONFIG_FILE="$2"
                shift 2
                ;;
            --cli)
                CLI_MODE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo -e "${RED}[ERROR] Unknown option: $1${NC}" >&2
                usage
                exit 2
                ;;
        esac
    done
}

# ==============================
# Target Loading
# ==============================
load_targets() {
    if [[ -n "$CONFIG_FILE" ]]; then
        echo -e "${BLUE}[INFO]${NC} Loading configuration from: ${BOLD}$CONFIG_FILE${NC}"
        parse_yaml_config "$CONFIG_FILE"

        if [[ ${#WEBSITES[@]} -eq 0 ]]; then
            echo -e "${YELLOW}[WARN]${NC} No websites found in config, using defaults"
            WEBSITES=("${DEFAULT_WEBSITES[@]}")
        fi
        if [[ ${#VM_HOSTS[@]} -eq 0 ]]; then
            echo -e "${YELLOW}[WARN]${NC} No VM hosts found in config, using defaults"
            VM_HOSTS=("${DEFAULT_VM_HOSTS[@]}")
        fi
    else
        WEBSITES=("${DEFAULT_WEBSITES[@]}")
        VM_HOSTS=("${DEFAULT_VM_HOSTS[@]}")
    fi
}

# ==============================
# Helper Functions
# ==============================
normalize_url_for_label() {
    local url="$1"
    echo "$url" | sed -e 's|^https\?://||' -e 's|[^a-zA-Z0-9]|_|g' -e 's|_*$||'
}

normalize_hostname_for_label() {
    local hostname="$1"
    echo "$hostname" | sed -e 's|[^a-zA-Z0-9]|_|g' -e 's|_*$||'
}

get_hostname() {
    local url="$1"
    echo "$url" | sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||'
}

# ==============================
# Parallel Job Control
# ==============================
limit_parallel_jobs() {
    local max_jobs=$1
    while [[ $(jobs -rp | wc -l) -ge $max_jobs ]]; do
        wait -n 2>/dev/null || true
    done
}

# ==============================
# Website Check (parallel-safe)
# ==============================
check_website_prometheus() {
    # Reset traps - subshells must not delete the shared temp directory
    trap - ERR EXIT

    local url="$1"
    local job_id="$2"
    local metrics_file="${JOB_TMP_DIR}/web_metrics_${job_id}.prom"
    local console_file="${JOB_TMP_DIR}/web_console_${job_id}.log"

    local hostname
    hostname=$(get_hostname "$url")
    local url_label
    url_label=$(normalize_url_for_label "$url")

    # Defaults
    local website_up=0
    local http_status_code=0
    local response_time=0
    local ssl_valid=0
    local ssl_cert_expiry_days=0
    local tls_version=""

    # HTTP check
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" \
                    --connect-timeout 15 --max-time 30 -L "$url" 2>/dev/null) || true

    if [[ -n "$response" ]]; then
        IFS='|' read -r http_status_code response_time <<< "$response"

        if [[ $http_status_code -ge 200 && $http_status_code -lt 400 ]]; then
            website_up=1
            echo -e "${GREEN}✓ UP${NC}: $url (${http_status_code})" > "$console_file"
        else
            echo -e "${RED}✗ DOWN${NC}: $url (${http_status_code})" > "$console_file"
        fi
    else
        echo -e "${RED}✗ DOWN${NC}: $url (No response)" > "$console_file"
    fi

    # SSL certificate check (HTTPS only)
    if [[ $url =~ ^https:// ]]; then
        local cert_info
        cert_info=$(echo '' | timeout 10 openssl s_client -connect "$hostname":443 \
                    -servername "$hostname" 2>/dev/null \
                    | openssl x509 -noout -dates 2>/dev/null) || true

        if [[ -n "$cert_info" ]]; then
            ssl_valid=1

            local not_after
            not_after=$(echo "$cert_info" | grep "notAfter=" | cut -d= -f2-)
            if [[ -n "$not_after" ]]; then
                local exp_date current_date
                exp_date=$(date -d "$not_after" +%s 2>/dev/null) || true
                current_date=$(date +%s)
                if [[ -n "${exp_date:-}" ]]; then
                    ssl_cert_expiry_days=$(( (exp_date - current_date) / 86400 ))
                    [[ $ssl_cert_expiry_days -lt 0 ]] && ssl_cert_expiry_days=0
                fi
            fi

            tls_version=$(echo '' | timeout 10 openssl s_client -connect "$hostname":443 \
                          -servername "$hostname" 2>/dev/null \
                          | grep "Protocol" | head -1 | awk '{print $2}' | tr -d '\r\n') || true
        fi
    else
        ssl_valid=-1
        ssl_cert_expiry_days=-1
    fi

    # Write metrics to per-target temp file
    {
        echo "website_up{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\"} $website_up"
        echo "website_http_status_code{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\"} $http_status_code"
        echo "website_response_time_seconds{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\"} $response_time"
        echo "website_ssl_valid{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\"} $ssl_valid"
        echo "website_ssl_cert_expiry_days{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\"} $ssl_cert_expiry_days"
        if [[ -n "$tls_version" ]]; then
            echo "website_tls_version_info{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\",tls_version=\"$tls_version\"} 1"
        fi
    } > "$metrics_file"
}

# ==============================
# VM Host Check (parallel-safe)
# ==============================
check_vm_host_prometheus() {
    # Reset traps - subshells must not delete the shared temp directory
    trap - ERR EXIT

    local host="$1"
    local job_id="$2"
    local metrics_file="${JOB_TMP_DIR}/vm_metrics_${job_id}.prom"
    local console_file="${JOB_TMP_DIR}/vm_console_${job_id}.log"

    local host_label
    host_label=$(normalize_hostname_for_label "$host")

    local vm_host_up=0
    local ping_response_time=0
    local packet_loss=100

    local ping_result ping_exit_code
    ping_result=$(ping -c 3 -W 3 "$host" 2>/dev/null) && ping_exit_code=0 || ping_exit_code=$?

    if [[ "$ping_exit_code" -eq 0 ]]; then
        vm_host_up=1
        echo -e "${GREEN}✓ UP${NC}: $host" > "$console_file"

        local avg_time
        avg_time=$(echo "$ping_result" | grep "rtt min/avg/max/mdev" | awk -F'/' '{print $5}') || true
        if [[ -n "${avg_time:-}" ]]; then
            ping_response_time=$(echo "scale=6; $avg_time / 1000" | bc -l 2>/dev/null) || ping_response_time="0"
        fi

        local loss_line
        loss_line=$(echo "$ping_result" | grep "packet loss") || true
        if [[ -n "${loss_line:-}" ]]; then
            packet_loss=$(echo "$loss_line" | grep -o '[0-9]\+%' | sed 's/%//') || packet_loss="0"
        fi
    else
        echo -e "${RED}✗ DOWN${NC}: $host" > "$console_file"
    fi

    {
        echo "vm_host_up{hostname=\"$host\",host_label=\"$host_label\"} $vm_host_up"
        echo "vm_host_ping_response_time_seconds{hostname=\"$host\",host_label=\"$host_label\"} $ping_response_time"
        echo "vm_host_packet_loss_percentage{hostname=\"$host\",host_label=\"$host_label\"} $packet_loss"
    } > "$metrics_file"
}

# ==============================
# Metrics Output (collects from per-target temp files)
# ==============================
output_metrics() {
    # --- Website metrics ---
    if compgen -G "${JOB_TMP_DIR}/web_metrics_*.prom" > /dev/null 2>&1; then
        echo "# HELP website_up Whether the website is accessible (1 = up, 0 = down)" >> "$TEMP_FILE"
        echo "# TYPE website_up gauge" >> "$TEMP_FILE"
        grep -h "^website_up{" "${JOB_TMP_DIR}"/web_metrics_*.prom >> "$TEMP_FILE" || true
        echo "" >> "$TEMP_FILE"

        echo "# HELP website_http_status_code HTTP status code returned by the website" >> "$TEMP_FILE"
        echo "# TYPE website_http_status_code gauge" >> "$TEMP_FILE"
        grep -h "^website_http_status_code{" "${JOB_TMP_DIR}"/web_metrics_*.prom >> "$TEMP_FILE" || true
        echo "" >> "$TEMP_FILE"

        echo "# HELP website_response_time_seconds Response time in seconds" >> "$TEMP_FILE"
        echo "# TYPE website_response_time_seconds gauge" >> "$TEMP_FILE"
        grep -h "^website_response_time_seconds{" "${JOB_TMP_DIR}"/web_metrics_*.prom >> "$TEMP_FILE" || true
        echo "" >> "$TEMP_FILE"

        echo "# HELP website_ssl_valid Whether SSL certificate is valid (1 = valid, 0 = invalid, -1 = not applicable)" >> "$TEMP_FILE"
        echo "# TYPE website_ssl_valid gauge" >> "$TEMP_FILE"
        grep -h "^website_ssl_valid{" "${JOB_TMP_DIR}"/web_metrics_*.prom >> "$TEMP_FILE" || true
        echo "" >> "$TEMP_FILE"

        echo "# HELP website_ssl_cert_expiry_days Days until SSL certificate expires" >> "$TEMP_FILE"
        echo "# TYPE website_ssl_cert_expiry_days gauge" >> "$TEMP_FILE"
        grep -h "^website_ssl_cert_expiry_days{" "${JOB_TMP_DIR}"/web_metrics_*.prom >> "$TEMP_FILE" || true
        echo "" >> "$TEMP_FILE"

        if grep -hq "^website_tls_version_info{" "${JOB_TMP_DIR}"/web_metrics_*.prom 2>/dev/null; then
            echo "# HELP website_tls_version_info TLS version information" >> "$TEMP_FILE"
            echo "# TYPE website_tls_version_info gauge" >> "$TEMP_FILE"
            grep -h "^website_tls_version_info{" "${JOB_TMP_DIR}"/web_metrics_*.prom >> "$TEMP_FILE" || true
            echo "" >> "$TEMP_FILE"
        fi
    fi

    # --- VM Host metrics ---
    if compgen -G "${JOB_TMP_DIR}/vm_metrics_*.prom" > /dev/null 2>&1; then
        echo "# HELP vm_host_up Whether the VM host is reachable via ping (1 = up, 0 = down)" >> "$TEMP_FILE"
        echo "# TYPE vm_host_up gauge" >> "$TEMP_FILE"
        grep -h "^vm_host_up{" "${JOB_TMP_DIR}"/vm_metrics_*.prom >> "$TEMP_FILE" || true
        echo "" >> "$TEMP_FILE"

        echo "# HELP vm_host_ping_response_time_seconds Average ping response time in seconds" >> "$TEMP_FILE"
        echo "# TYPE vm_host_ping_response_time_seconds gauge" >> "$TEMP_FILE"
        grep -h "^vm_host_ping_response_time_seconds{" "${JOB_TMP_DIR}"/vm_metrics_*.prom >> "$TEMP_FILE" || true
        echo "" >> "$TEMP_FILE"

        echo "# HELP vm_host_packet_loss_percentage Packet loss percentage during ping test" >> "$TEMP_FILE"
        echo "# TYPE vm_host_packet_loss_percentage gauge" >> "$TEMP_FILE"
        grep -h "^vm_host_packet_loss_percentage{" "${JOB_TMP_DIR}"/vm_metrics_*.prom >> "$TEMP_FILE" || true
        echo "" >> "$TEMP_FILE"
    fi
}

# ==============================
# Metadata Metrics
# ==============================
add_metadata_metrics() {
    cat << EOF >> "$TEMP_FILE"
# HELP website_monitor_last_run_timestamp Unix timestamp of the last monitoring run
# TYPE website_monitor_last_run_timestamp gauge
website_monitor_last_run_timestamp $(date +%s)

# HELP website_monitor_websites_total Total number of websites being monitored
# TYPE website_monitor_websites_total gauge
website_monitor_websites_total ${#WEBSITES[@]}

# HELP vm_host_monitor_last_run_timestamp Unix timestamp of the last VM host monitoring run
# TYPE vm_host_monitor_last_run_timestamp gauge
vm_host_monitor_last_run_timestamp $(date +%s)

# HELP vm_host_monitor_hosts_total Total number of VM hosts being monitored
# TYPE vm_host_monitor_hosts_total gauge
vm_host_monitor_hosts_total ${#VM_HOSTS[@]}

EOF
}

# ==============================
# Dependency Check
# ==============================
check_dependencies() {
    local missing_deps=()

    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v openssl >/dev/null 2>&1 || missing_deps+=("openssl")
    command -v ping >/dev/null 2>&1 || missing_deps+=("ping")
    command -v bc >/dev/null 2>&1 || missing_deps+=("bc")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}[ERROR] Missing required dependencies: ${missing_deps[*]}${NC}" >&2
        exit 3
    fi
}

# ==============================
# Main
# ==============================
main() {
    echo -e "${GREEN}Starting combined monitoring...${NC}"
    echo -e "Monitoring ${#WEBSITES[@]} websites and ${#VM_HOSTS[@]} VM hosts..."
    echo -e "Execution: ${BOLD}parallel${NC} (max ${MAX_PARALLEL_JOBS} concurrent jobs)"
    if $CLI_MODE; then
        echo -e "Mode: ${BOLD}CLI-only${NC} (no Prometheus output)"
    fi
    echo -e "-----------------------------------------"

    # Create isolated temp directory for this run
    JOB_TMP_DIR=$(mktemp -d /tmp/bbx_monitor_XXXXXX)

    # Write header to output file (skip in CLI mode)
    if ! $CLI_MODE; then
        cat << EOF > "$TEMP_FILE"
# Combined Website and VM Host Monitor Metrics for Prometheus
# Generated on $(date)
# Monitoring ${#WEBSITES[@]} websites and ${#VM_HOSTS[@]} VM hosts

EOF
    fi

    # --- Check websites (parallel) ---
    echo -e "${GREEN}Checking websites...${NC}" >&2
    local job_id=0
    for website in "${WEBSITES[@]}"; do
        check_website_prometheus "$website" "$job_id" &
        limit_parallel_jobs "$MAX_PARALLEL_JOBS"
        job_id=$((job_id + 1))
    done
    wait

    # Replay buffered console output in order
    for f in $(ls "${JOB_TMP_DIR}"/web_console_*.log 2>/dev/null | sort -t_ -k3 -n); do
        cat "$f" >&2
    done

    echo -e "-----------------------------------------" >&2

    # --- Check VM hosts (parallel) ---
    echo -e "${GREEN}Checking VM hosts...${NC}" >&2
    job_id=0
    for host in "${VM_HOSTS[@]}"; do
        check_vm_host_prometheus "$host" "$job_id" &
        limit_parallel_jobs "$MAX_PARALLEL_JOBS"
        job_id=$((job_id + 1))
    done
    wait

    # Replay buffered console output in order
    for f in $(ls "${JOB_TMP_DIR}"/vm_console_*.log 2>/dev/null | sort -t_ -k3 -n); do
        cat "$f" >&2
    done

    echo -e "-----------------------------------------" >&2

    # In CLI mode, skip Prometheus file output entirely
    if $CLI_MODE; then
        echo -e "${GREEN}CLI check complete.${NC}"
        return 0
    fi

    # Collect all metrics from per-target temp files
    output_metrics
    add_metadata_metrics

    # Atomically move temp file to final location
    if mv "$TEMP_FILE" "$TEXTFILE_PATH"; then
        echo -e "${GREEN}Metrics written to $TEXTFILE_PATH${NC}"
        echo "Total metrics generated: $(grep -c "^website_\|^vm_host_" "$TEXTFILE_PATH")"
    else
        echo -e "${RED}[ERROR] Could not write to $TEXTFILE_PATH${NC}" >&2
        exit 1
    fi
}

# ==============================
# Entry Point
# ==============================
parse_args "$@"
check_dependencies
load_targets

# Ensure textfile directory exists (skip in CLI mode)
if ! $CLI_MODE; then
    if [[ ! -d "$(dirname "$TEXTFILE_PATH")" ]]; then
        echo -e "${RED}[ERROR] Textfile collector directory does not exist: $(dirname "$TEXTFILE_PATH")${NC}" >&2
        echo "Please create it first or update textfile_path in your config" >&2
        exit 1
    fi
fi

main