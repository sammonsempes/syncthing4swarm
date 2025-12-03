#!/bin/sh

set -eu

[ -n "${UMASK:-}" ] && umask "$UMASK"

(
    # Attendre que Syncthing soit prêt
    echo "Waiting for Syncthing to start for configuration..."
    until curl -s http://localhost:8384/rest/system/status > /dev/null 2>&1; do
        sleep 1
    done

    sleep 5

    echo "=== Begining of swarm discovery ==="

    # Configuration
    KEY="${STGUIAPIKEY:-}"
    PORT="${SYNCTHING_PORT:-8384}"
    SYNC_PORT="${SYNCTHING_SYNC_PORT:-22000}"
    DISABLE_GLOBAL="${SYNCTHING_DISABLE_GLOBAL:-true}"
    FOLDER_ID="${SYNCTHING_FOLDER_ID:-shared}"
    FOLDER_PATH="${SYNCTHING_FOLDER_PATH:-/var/syncthing/data}"
    FOLDER_LABEL="${SYNCTHING_FOLDER_LABEL:-Shared}"

    # Validate required configuration
    if [ -z "$KEY" ]; then
        echo "Error: STGUIAPIKEY environment variable must be set"
        exit 1
    fi

    # Extract JSON value using sed/grep
    json_extract() {
        field="$1"
        sed -n 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
    }

    # Extract array of values for a field
    json_extract_array() {
        field="$1"
        grep -o '"'"$field"'"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
    }

    # Make a request to Syncthing API
    syncthing_request() {
        method="$1"
        url="$2"
        data="${3:-}"

        if [ -n "$data" ]; then
            curl -s -f -X "$method" \
                -H "Content-Type: application/json" \
                -H "X-API-Key: ${KEY}" \
                --max-time 30 \
                -d "$data" \
                "$url"
        else
            curl -s -f -X "$method" \
                -H "Content-Type: application/json" \
                -H "X-API-Key: ${KEY}" \
                --max-time 30 \
                "$url"
        fi
    }

    # Disable global discovery and relays via API
    disable_global_features() {
        if [ "$DISABLE_GLOBAL" = "true" ]; then
            echo "Disabling global discovery and relays..."
            
            # Get current options
            options=$(syncthing_request "GET" "http://localhost:${PORT}/rest/config/options")
            
            # Check if already disabled
            if echo "$options" | grep -q '"relaysEnabled"[[:space:]]*:[[:space:]]*false' && \
               echo "$options" | grep -q '"globalAnnounceEnabled"[[:space:]]*:[[:space:]]*false'; then
                echo "Global features already disabled"
                return 0
            fi
            
            # Patch options to disable relays and global discovery but KEEP local discovery
            syncthing_request "PATCH" "http://localhost:${PORT}/rest/config/options" \
                '{"globalAnnounceEnabled": false, "relaysEnabled": false, "natEnabled": false, "localAnnounceEnabled": true}' > /dev/null
            
            echo "Global discovery, relays and NAT disabled (local discovery kept)"
        fi
    }

    # Create shared folder if it doesn't exist
    create_shared_folder() {
        echo "Checking if folder '${FOLDER_ID}' exists..."
        
        # Check if folder already exists
        if syncthing_request "GET" "http://localhost:${PORT}/rest/config/folders/${FOLDER_ID}" > /dev/null 2>&1; then
            echo "Folder '${FOLDER_ID}' already exists"
            return 0
        fi
        
        echo "Creating folder '${FOLDER_ID}' at '${FOLDER_PATH}'..."
        
        # Create the directory if it doesn't exist
        mkdir -p "${FOLDER_PATH}"
        
        # Get our own device ID
        my_id=$(syncthing_request "GET" "http://localhost:${PORT}/rest/system/status" | json_extract "myID")
        
        # Create the folder via API
        folder_config=$(cat <<EOF
{
    "id": "${FOLDER_ID}",
    "label": "${FOLDER_LABEL}",
    "path": "${FOLDER_PATH}",
    "type": "sendreceive",
    "devices": [{"deviceID": "${my_id}"}],
    "rescanIntervalS": 3600,
    "fsWatcherEnabled": true,
    "fsWatcherDelayS": 10,
    "ignorePerms": false,
    "autoNormalize": true
}
EOF
)
        
        syncthing_request "POST" "http://localhost:${PORT}/rest/config/folders" "$folder_config" > /dev/null
        
        echo "Folder '${FOLDER_ID}' created successfully"
    }

    # Get local IP and subnet
    get_local_network() {
        local_ip=$(hostname -i 2>/dev/null | awk '{print $1}')
        if [ -z "$local_ip" ]; then
            local_ip=$(ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
        fi
        echo "$local_ip"
    }

    # Get network prefix (first 3 octets)
    get_network_prefix() {
        ip="$1"
        echo "$ip" | cut -d'.' -f1-3
    }

    # Scan subnet for Syncthing instances
    scan_for_syncthing() {
        prefix="$1"
        
        echo "Scanning ${prefix}.0/24 for Syncthing instances..." >&2
        
        for i in $(seq 1 254); do
            ip="${prefix}.${i}"
            if curl -s -f --max-time 1 -o /dev/null \
                -H "X-API-Key: ${KEY}" \
                "http://${ip}:${PORT}/rest/system/status" 2>/dev/null; then
                echo "Found Syncthing at ${ip}" >&2
                echo "$ip"
            fi
        done
    }

    # Check if a string contains a substring
    contains() {
        string="$1"
        substring="$2"
        case "$string" in
            *"$substring"*) return 0 ;;
            *) return 1 ;;
        esac
    }

    # Add missing devices to a Syncthing instance with static IP address
    add_device_with_address() {
        target_ip="$1"
        device_id="$2"
        device_ip="$3"
        
        url="http://${target_ip}:${PORT}/rest/config/devices"
        existing=$(syncthing_request "GET" "$url" | json_extract_array "deviceID")
        
        if ! contains "$existing" "$device_id"; then
            echo "Adding device ${device_id} to Syncthing ${target_ip} with address tcp://${device_ip}:${SYNC_PORT}"
            payload=$(printf '{"deviceID": "%s", "addresses": ["tcp://%s:%s"], "autoAcceptFolders": true}' "$device_id" "$device_ip" "$SYNC_PORT")
            syncthing_request "POST" "$url" "$payload" > /dev/null
        else
            # Device exists, update address
            echo "Updating device ${device_id} address on Syncthing ${target_ip}"
            device_url="http://${target_ip}:${PORT}/rest/config/devices/${device_id}"
            payload=$(printf '{"addresses": ["tcp://%s:%s"]}' "$device_ip" "$SYNC_PORT")
            syncthing_request "PATCH" "$device_url" "$payload" > /dev/null 2>&1 || true
        fi
    }

    # Configure all devices with their static addresses
    configure_devices_with_addresses() {
        # $1 = space-separated "ip:deviceid" pairs
        pairs="$1"
        
        # For each Syncthing instance
        for pair in $pairs; do
            target_ip=$(echo "$pair" | cut -d: -f1)
            
            # Add all OTHER devices to this instance
            for other_pair in $pairs; do
                other_ip=$(echo "$other_pair" | cut -d: -f1)
                other_id=$(echo "$other_pair" | cut -d: -f2)
                
                # Don't add device to itself
                if [ "$target_ip" != "$other_ip" ]; then
                    add_device_with_address "$target_ip" "$other_id" "$other_ip"
                fi
            done
        done
    }

    # Build devices JSON array from space-separated IDs
    build_devices_json() {
        ids="$1"
        result='{"devices": ['
        first=1
        for id in $ids; do
            if [ "$first" = "1" ]; then
                first=0
            else
                result="$result,"
            fi
            result="$result{\"deviceID\": \"$id\"}"
        done
        result="$result]}"
        printf '%s' "$result"
    }

    # Sort and deduplicate space-separated values
    sort_unique() {
        echo "$1" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//'
    }

    # Ensure all devices are added to folder on every Syncthing instance
    sync_folder_devices() {
        folder_id="$1"
        ips_str="$2"
        ids_str="$3"

        for ip in $ips_str; do
            url="http://${ip}:${PORT}/rest/config/folders/${folder_id}"
            
            # Check if folder exists on this instance
            if ! folder=$(syncthing_request "GET" "$url" 2>/dev/null); then
                echo "Folder '${folder_id}' does not exist on ${ip}, skipping..."
                continue
            fi

            existing=$(echo "$folder" | json_extract_array "deviceID" | tr '\n' ' ' | sed 's/ $//')
            existing_sorted=$(sort_unique "$existing")
            expected_sorted=$(sort_unique "$ids_str")

            if [ "$existing_sorted" != "$expected_sorted" ]; then
                echo "patch folder devices at Syncthing ${ip} ${folder_id}"

                devices_payload=$(build_devices_json "$ids_str")
                syncthing_request "PATCH" "$url" "$devices_payload" > /dev/null
            fi
        done
    }

    # Main run function
    run() {
        # First, disable global features
        disable_global_features
        
        # Create shared folder
        create_shared_folder
        
        # Get local IP
        local_ip=$(get_local_network)
        echo "Local IP: $local_ip"
        
        if [ -z "$local_ip" ]; then
            echo "Error: Could not determine local IP"
            return 1
        fi
        
        # Get network prefix
        prefix=$(get_network_prefix "$local_ip")
        echo "Network prefix: $prefix"
        
        # Scan for Syncthing instances (output goes to stdout, logs to stderr)
        ips_str=$(scan_for_syncthing "$prefix" | tr '\n' ' ' | sed 's/ $//')
        
        echo "Got IPs from network scan: ${ips_str}"

        if [ -z "$ips_str" ]; then
            echo "No Syncthing instances found, skipping..."
            return 0
        fi

        # Get Syncthing IDs and build ip:id pairs
        ids_str=""
        pairs=""
        for ip in $ips_str; do
            response=$(syncthing_request "GET" "http://${ip}:${PORT}/rest/system/status") || continue
            id=$(echo "$response" | json_extract "myID")
            if [ -z "$id" ] || [ "$id" = "null" ]; then
                echo "Warning: Failed to get ID from ${ip}, skipping..."
                continue
            fi
            
            # Build pairs list (ip:deviceid)
            if [ -n "$pairs" ]; then
                pairs="$pairs ${ip}:${id}"
            else
                pairs="${ip}:${id}"
            fi
            
            # Build ids list
            if [ -n "$ids_str" ]; then
                ids_str="$ids_str $id"
            else
                ids_str="$id"
            fi
        done
        
        # Deduplicate IDs
        ids_str=$(sort_unique "$ids_str")

        echo "Got IDs from Syncthing: ${ids_str}"
        echo "IP:ID pairs: ${pairs}"

        if [ -z "$ids_str" ]; then
            echo "No valid Syncthing IDs found"
            return 1
        fi

        # Configure devices with static addresses
        echo "Configuring devices with static addresses..."
        configure_devices_with_addresses "$pairs"
        
        # Update folder to include all devices
        # Need to rebuild ips_str from pairs (deduplicated by IP this time)
        ips_for_folder=""
        for pair in $pairs; do
            ip=$(echo "$pair" | cut -d: -f1)
            if [ -n "$ips_for_folder" ]; then
                ips_for_folder="$ips_for_folder $ip"
            else
                ips_for_folder="$ip"
            fi
        done
        
        sync_folder_devices "$FOLDER_ID" "$ips_for_folder" "$ids_str"
        
        echo "Configuration complete!"
    }

    main() {
        run
    }

    main "$@"

    echo "=== End of swarm discovery ==="
) > /proc/1/fd/1 2> /proc/1/fd/2 &

if [ "$(id -u)" = '0' ]; then
    binary="$1"
    if [ -z "${PCAP:-}" ]; then
        setcap -r "$binary" 2>/dev/null || true
    else
        setcap "$PCAP" "$binary"
    fi

    chown "${PUID}:${PGID}" "${HOME}" || true
    exec su-exec "${PUID}:${PGID}" \
        env HOME="$HOME" "$@"
else
    exec "$@"
fi
