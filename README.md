

# Blackbox Lite


A comprehensive Bash script that monitors websites and VM hosts, collecting metrics in Prometheus format for integration with Node Exporter's textfile collector. This tool provides real-time monitoring of website availability, SSL certificate health, response times, and VM host connectivity.

## Features

### Website Monitoring

- **Availability Check**: Monitors website uptime with HTTP status code validation
- **Response Time**: Measures website response time in seconds
- **SSL Certificate Monitoring**:
	- Validates SSL certificate validity
	- Tracks days until certificate expiration
	- Detects TLS version in use
- **HTTP Status Codes**: Captures and reports HTTP response codes
- **Follow Redirects**: Automatically follows HTTP redirects (3xx)

### VM Host Monitoring

- **Ping Connectivity**: Tests host reachability using ICMP ping
- **Response Time**: Measures average ping response time

### Additional Features
- **Prometheus-Compatible**: Outputs metrics in standard Prometheus textfile format
- **Atomic Writes**: Uses temporary files for safe metric updates
- **Error Handling**: Graceful error handling and dependency checking
- **Metadata Metrics**: Includes monitoring run timestamps and target counts

### Required Dependencies

The script automatically checks for and requires the following tools:

- **curl**: For HTTP/HTTPS website checks
- **openssl**: For SSL certificate validation and TLS version detection
- **ping**: For VM host connectivity testing
- **bc**: For mathematical calculations (response time conversions)


## Configuration

### Customizing Websites to Monitor
Edit the `WEBSITES` array in the script
```bash
WEBSITES=(
    "https://example.com"
    "https://api.example.com"
    "http://internal.example.com"
    "https://example.com/specific/endpoint"
)
```

### Customizing VM Hosts to Monitor
Edit the `VM_HOSTS` array in the script (lines 21-39):
```bash
VM_HOSTS=(
    "server1.example.com"
    "192.168.1.100"
    "api-server.internal"
)
```

### Changing Output Path
Modify the `TEXTFILE_PATH` variable (line 7) to match your Node Exporter configuration:
```bash
TEXTFILE_PATH="/opt/node_exporter/textfile_collector/combined_monitor.prom"
```

## Usage
### Manual Execution
Run the script manually:
```bash
./monitor.sh
```
### Scheduled Execution with Cron
Add to crontab for automated monitoring (runs every 5 minutes):
```bash
crontab -e
```

Add the following line:
```bash
*/5 * * * * /path/to/monitor.sh >/dev/null 2>&1
```

Or for more frequent monitoring (every minute):
```bash
* * * * * /path/to/monitor.sh >/dev/null 2>&1
```

## Integration with Prometheus

### Node Exporter Configuration

1. **Install Node Exporter** (if not already installed)
2. **Configure Node Exporter** to use the textfile collector:
   Edit `/etc/systemd/system/node_exporter.service` or your Node Exporter configuration:

```ini
   [Service]
   ExecStart=/usr/local/bin/node_exporter \
       --collector.textfile.directory=/opt/node_exporter/textfile_collector \
       --collector.textfile
```

3. **Verify metrics are being collected**:

```bash
   curl http://localhost:9100/metrics | grep website_
   curl http://localhost:9100/metrics | grep vm_host_
```
  
## Examples

### Example Output
  ![[carbon.png]]

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.


