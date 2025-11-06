#!/bin/bash

# Combined Prometheus Monitor Script for Websites and VM Hosts
# Outputs metrics in Prometheus format for textfile_collector

# Configuration
TEXTFILE_PATH="/opt/node_exporter/textfile_collector/combined_monitor.prom"
TEMP_FILE="/tmp/combined_monitor_temp.prom"

# Websites to monitor
WEBSITES=(
    "https://www.corp-analytics-portal.com/"
    "https://beta.project-nebula.io/login"
    "http://192.168.50.11/metrics"
    "https://support.global-solutions.org/knowledgebase"
    "https://dev.api-gateway-v2.net/v1/status"
)

# VM Hosts to monitor (hostnames or IP addresses)
VM_HOSTS=(
        "vm-prod-app03"
        "dev-db-master01"
        "edge-node-sfo1"
        "test-web-proxy-b"
        "lab-jumper-007"
)

# Color codes for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Trap for graceful exit
trap "echo -e '\n${RED}Aborted by user.${NC}'; exit 130" SIGINT

# Function to normalize URL for metric labels
normalize_url_for_label() {
    local url=$1
    echo $url | sed -e 's|^https\?://||' -e 's|[^a-zA-Z0-9]|_|g' -e 's|_*$||'
}

# Function to normalize hostname for metric labels
normalize_hostname_for_label() {
    local hostname=$1
    echo $hostname | sed -e 's|[^a-zA-Z0-9]|_|g' -e 's|_*$||'
}

# Function to get hostname from URL
get_hostname() {
    local url=$1
    echo $url | sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||'
}

# Function to check single website and collect metrics data
check_website_prometheus() {
    local url=$1
    local hostname=$(get_hostname "$url")
    local url_label=$(normalize_url_for_label "$url")

#    echo -e "${YELLOW}Checking website: $url${NC}" >&2

    # Initialize metrics with default values
    local website_up=0
    local http_status_code=0
    local response_time=0
    local ssl_valid=0
    local ssl_cert_expiry_days=0
    local tls_version=""

    # Check website availability and get metrics
    local response=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" \
                    --connect-timeout 15 --max-time 30 -L "$url" 2>/dev/null)

    if [[ -n "$response" ]]; then
        IFS='|' read -r http_status_code response_time <<< "$response"

        # Website is considered UP if status code is 2xx or 3xx
        if [[ $http_status_code -ge 200 && $http_status_code -lt 400 ]]; then
            website_up=1
            echo -e "${GREEN}✓ UP${NC}: $url (${http_status_code})" >&2
        else
            echo -e "${RED}✗ DOWN${NC}: $url (${http_status_code})" >&2
        fi
    else
        echo -e "${RED}✗ DOWN${NC}: $url (No response)" >&2
    fi

    # Check SSL certificate if HTTPS
    if [[ $url =~ ^https:// ]]; then
        local cert_info=$(echo '' | timeout 10 openssl s_client -connect $hostname:443 -servername $hostname 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)

        if [[ -n "$cert_info" ]]; then
            ssl_valid=1

            # Get certificate expiry date
            local not_after=$(echo "$cert_info" | grep "notAfter=" | cut -d= -f2-)
            if [[ -n "$not_after" ]]; then
                local exp_date=$(date -d "$not_after" +%s 2>/dev/null)
                local current_date=$(date +%s)
                ssl_cert_expiry_days=$(( (exp_date - current_date) / 86400 ))

                if [[ $ssl_cert_expiry_days -lt 0 ]]; then
                    ssl_cert_expiry_days=0
                fi
            fi

            # Get TLS version
            tls_version=$(echo '' | timeout 10 openssl s_client -connect $hostname:443 -servername $hostname 2>/dev/null | grep "Protocol" | head -1 | awk '{print $2}' | tr -d '\r\n')
        fi
    else
        ssl_valid=-1
        ssl_cert_expiry_days=-1
    fi

    # Store metrics data in arrays
    WEBSITE_UP_DATA+=("website_up{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\"} $website_up")
    HTTP_STATUS_DATA+=("website_http_status_code{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\"} $http_status_code")
    RESPONSE_TIME_DATA+=("website_response_time_seconds{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\"} $response_time")
    SSL_VALID_DATA+=("website_ssl_valid{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\"} $ssl_valid")
    SSL_EXPIRY_DATA+=("website_ssl_cert_expiry_days{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\"} $ssl_cert_expiry_days")

    if [[ -n "$tls_version" && "$tls_version" != "" ]]; then
        TLS_VERSION_DATA+=("website_tls_version_info{url=\"$url\",hostname=\"$hostname\",url_label=\"$url_label\",tls_version=\"$tls_version\"} 1")
    fi
}

# Function to check single VM host and collect metrics data
check_vm_host_prometheus() {
    local host=$1
    local host_label=$(normalize_hostname_for_label "$host")

#    echo -e "${YELLOW}Checking VM host: $host${NC}" >&2

    # Initialize metrics with default values
    local vm_host_up=0
    local ping_response_time=0
    local packet_loss=0

    # Ping the host (3 packets, 3 second timeout)
    ping_result=$(ping -c 3 -W 3 "$host" 2>/dev/null)
    ping_exit_code=$?
#    $ping_result
    if [[ "$ping_exit_code" -eq 0 ]]; then
        vm_host_up=1
        echo -e "${GREEN}✓ UP${NC}: $host" >&2

        # Extract average response time (in milliseconds, convert to seconds)
        local avg_time=$(echo "$ping_result" | grep "rtt min/avg/max/mdev" | awk -F'/' '{print $5}')
        if [[ -n "$avg_time" ]]; then
            ping_response_time=$(echo "scale=6; $avg_time / 1000" | bc -l 2>/dev/null || echo "0")
        fi

        # Extract packet loss percentage
        local loss_line=$(echo "$ping_result" | grep "packet loss")
        if [[ -n "$loss_line" ]]; then
            packet_loss=$(echo "$loss_line" | grep -o '[0-9]\+%' | sed 's/%//')
        fi
    else
        echo -e "${RED}✗ DOWN${NC}: $host" >&2
        packet_loss=100
    fi

    # Store metrics data in arrays
    VM_HOST_UP_DATA+=("vm_host_up{hostname=\"$host\",host_label=\"$host_label\"} $vm_host_up")
    VM_HOST_PING_TIME_DATA+=("vm_host_ping_response_time_seconds{hostname=\"$host\",host_label=\"$host_label\"} $ping_response_time")
    VM_HOST_PACKET_LOSS_DATA+=("vm_host_packet_loss_percentage{hostname=\"$host\",host_label=\"$host_label\"} $packet_loss")
}

# Function to add metadata metrics
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

# Function to output all metrics with proper HELP and TYPE comments
output_metrics() {
    # Website metrics
    if [[ ${#WEBSITE_UP_DATA[@]} -gt 0 ]]; then
        cat << EOF >> "$TEMP_FILE"
# HELP website_up Whether the website is accessible (1 = up, 0 = down)
# TYPE website_up gauge
EOF
        for metric in "${WEBSITE_UP_DATA[@]}"; do
            echo "$metric" >> "$TEMP_FILE"
        done
        echo "" >> "$TEMP_FILE"
    fi

    if [[ ${#HTTP_STATUS_DATA[@]} -gt 0 ]]; then
        cat << EOF >> "$TEMP_FILE"
# HELP website_http_status_code HTTP status code returned by the website
# TYPE website_http_status_code gauge
EOF
        for metric in "${HTTP_STATUS_DATA[@]}"; do
            echo "$metric" >> "$TEMP_FILE"
        done
        echo "" >> "$TEMP_FILE"
    fi

    if [[ ${#RESPONSE_TIME_DATA[@]} -gt 0 ]]; then
        cat << EOF >> "$TEMP_FILE"
# HELP website_response_time_seconds Response time in seconds
# TYPE website_response_time_seconds gauge
EOF
        for metric in "${RESPONSE_TIME_DATA[@]}"; do
            echo "$metric" >> "$TEMP_FILE"
        done
        echo "" >> "$TEMP_FILE"
    fi

    if [[ ${#SSL_VALID_DATA[@]} -gt 0 ]]; then
        cat << EOF >> "$TEMP_FILE"
# HELP website_ssl_valid Whether SSL certificate is valid (1 = valid, 0 = invalid, -1 = not applicable)
# TYPE website_ssl_valid gauge
EOF
        for metric in "${SSL_VALID_DATA[@]}"; do
            echo "$metric" >> "$TEMP_FILE"
        done
        echo "" >> "$TEMP_FILE"
    fi

    if [[ ${#SSL_EXPIRY_DATA[@]} -gt 0 ]]; then
        cat << EOF >> "$TEMP_FILE"
# HELP website_ssl_cert_expiry_days Days until SSL certificate expires
# TYPE website_ssl_cert_expiry_days gauge
EOF
        for metric in "${SSL_EXPIRY_DATA[@]}"; do
            echo "$metric" >> "$TEMP_FILE"
        done
        echo "" >> "$TEMP_FILE"
    fi

    if [[ ${#TLS_VERSION_DATA[@]} -gt 0 ]]; then
        cat << EOF >> "$TEMP_FILE"
# HELP website_tls_version_info TLS version information
# TYPE website_tls_version_info gauge
EOF
        for metric in "${TLS_VERSION_DATA[@]}"; do
            echo "$metric" >> "$TEMP_FILE"
        done
        echo "" >> "$TEMP_FILE"
    fi

    # VM Host metrics
    if [[ ${#VM_HOST_UP_DATA[@]} -gt 0 ]]; then
        cat << EOF >> "$TEMP_FILE"
# HELP vm_host_up Whether the VM host is reachable via ping (1 = up, 0 = down)
# TYPE vm_host_up gauge
EOF
        for metric in "${VM_HOST_UP_DATA[@]}"; do
            echo "$metric" >> "$TEMP_FILE"
        done
        echo "" >> "$TEMP_FILE"
    fi

    if [[ ${#VM_HOST_PING_TIME_DATA[@]} -gt 0 ]]; then
        cat << EOF >> "$TEMP_FILE"
# HELP vm_host_ping_response_time_seconds Average ping response time in seconds
# TYPE vm_host_ping_response_time_seconds gauge
EOF
        for metric in "${VM_HOST_PING_TIME_DATA[@]}"; do
            echo "$metric" >> "$TEMP_FILE"
        done
        echo "" >> "$TEMP_FILE"
    fi

    if [[ ${#VM_HOST_PACKET_LOSS_DATA[@]} -gt 0 ]]; then
        cat << EOF >> "$TEMP_FILE"
# HELP vm_host_packet_loss_percentage Packet loss percentage during ping test
# TYPE vm_host_packet_loss_percentage gauge
EOF
        for metric in "${VM_HOST_PACKET_LOSS_DATA[@]}"; do
            echo "$metric" >> "$TEMP_FILE"
        done
        echo "" >> "$TEMP_FILE"
    fi
}

# Main execution
main() {
    echo -e "${GREEN}Starting combined monitoring for Prometheus...${NC}"
    echo -e "Monitoring ${#WEBSITES[@]} websites and ${#VM_HOSTS[@]} VM hosts..."
    echo -e "-----------------------------------------"

    # Initialize arrays for storing metrics data
    WEBSITE_UP_DATA=()
    HTTP_STATUS_DATA=()
    RESPONSE_TIME_DATA=()
    SSL_VALID_DATA=()
    SSL_EXPIRY_DATA=()
    TLS_VERSION_DATA=()
    VM_HOST_UP_DATA=()
    VM_HOST_PING_TIME_DATA=()
    VM_HOST_PACKET_LOSS_DATA=()

    # Clear temp file
    > "$TEMP_FILE"

    # Add file header
    cat << EOF > "$TEMP_FILE"
# Combined Website and VM Host Monitor Metrics for Prometheus
# Generated on $(date)
# Monitoring ${#WEBSITES[@]} websites and ${#VM_HOSTS[@]} VM hosts

EOF

    # Check websites
    echo -e "${GREEN}Checking websites...${NC}" >&2
    for website in "${WEBSITES[@]}"; do
        check_website_prometheus "$website"
    done

    echo -e "-----------------------------------------" >&2

    # Check VM hosts
    echo -e "${GREEN}Checking VM hosts...${NC}" >&2
    for host in "${VM_HOSTS[@]}"; do
        check_vm_host_prometheus "$host"
    done

    echo -e "-----------------------------------------" >&2

    # Output all metrics with proper HELP/TYPE comments
    output_metrics

    # Add metadata metrics
    add_metadata_metrics

    # Atomically move temp file to final location
    if mv "$TEMP_FILE" "$TEXTFILE_PATH"; then
        echo -e "${GREEN}Metrics written to $TEXTFILE_PATH${NC}"
        echo "Total metrics generated: $(grep -c "^website_\|^vm_host_" "$TEXTFILE_PATH")"
    else
        echo -e "${RED}Error: Could not write to $TEXTFILE_PATH${NC}" >&2
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    local missing_deps=()

    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v openssl >/dev/null 2>&1 || missing_deps+=("openssl")
    command -v ping >/dev/null 2>&1 || missing_deps+=("ping")
    command -v bc >/dev/null 2>&1 || missing_deps+=("bc")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required dependencies: ${missing_deps[*]}${NC}" >&2
        exit 1
    fi
}

# Ensure textfile directory exists
if [[ ! -d "$(dirname "$TEXTFILE_PATH")" ]]; then
    echo -e "${RED}Error: Textfile collector directory does not exist: $(dirname "$TEXTFILE_PATH")${NC}" >&2
    echo "Please create it first or update TEXTFILE_PATH variable" >&2
    exit 1
fi

# Run the monitoring
check_dependencies
main