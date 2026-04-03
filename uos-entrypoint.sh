#!/bin/bash

# Persist UOS_UUID env var
if [ ! -f /data/uos_uuid ]; then
    if [ -n "${UOS_UUID+1}" ]; then
        echo "Setting UOS_UUID to $UOS_UUID"
        echo "$UOS_UUID" > /data/uos_uuid
    else
        echo "No UOS_UUID present, generating..."
        UUID=$(cat /proc/sys/kernel/random/uuid)

        # Spoof a v5 UUID
        UOS_UUID=$(echo $UUID | sed s/./5/15)
        echo "Setting UOS_UUID to $UOS_UUID"
        echo "$UOS_UUID" > /data/uos_uuid
    fi
fi

# Read version from package.json and write version string
echo "Setting UOS_SERVER_VERSION to $UOS_SERVER_VERSION"
echo "UOSSERVER.0000000.$UOS_SERVER_VERSION.0000000.000000.0000" > /usr/lib/version

ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" == "amd64" ]; then
    FIRMWARE_PLATFORM=linux-x64
elif [ "$ARCH" == "arm64" ]; then
    FIRMWARE_PLATFORM=arm64
else
    echo "FIRMWARE_PLATFORM not found for $ARCH"
    exit 1
fi

echo "Setting FIRMWARE_PLATFORM to $FIRMWARE_PLATFORM"
echo "$FIRMWARE_PLATFORM" > /usr/lib/platform

# Create eth0 alias to tap0 (requires NET_ADMIN cap & macvlan kernel module loaded on host) 
if [ ! -d "/sys/devices/virtual/net/eth0" ] && [ -d "/sys/devices/virtual/net/tap0" ]; then
    ip link add name eth0 link tap0 type macvlan
    ip link set eth0 up
fi 

# Initialize nginx log dirs
NXINX_LOG_DIR="/var/log/nginx"
if [ ! -d "$NXINX_LOG_DIR" ]; then
    mkdir -p "$NXINX_LOG_DIR"
    chown nginx:nginx "$NXINX_LOG_DIR"
    chmod 755 "$NXINX_LOG_DIR"
fi

# Initialize mongodb log dirs
MONGODB_LOG_DIR="/var/log/mongodb"
if [ ! -d "$MONGODB_LOG_DIR" ]; then
    mkdir -p "$MONGODB_LOG_DIR"
    chown mongodb:mongodb "$MONGODB_LOG_DIR"
    chmod 755 "$MONGODB_LOG_DIR"
fi

# Initialize mongodb lib dirs
MONGODB_LIB_DIR="/var/lib/mongodb"
if [ -z "${MONGO_HOST+1}" ]; then
    chown -R mongodb:mongodb "$MONGODB_LIB_DIR"
fi

# External MongoDB support
# Set MONGO_HOST to redirect localhost:27017 to an external MongoDB container.
# When unset, internal MongoDB runs normally via systemd (default behavior).
if [ -n "${MONGO_HOST+1}" ]; then
    echo "MONGO_HOST is set to '$MONGO_HOST'. Configuring external MongoDB..."

    # 1. Mask the internal MongoDB systemd service so it never starts.
    #    Replicates what 'systemctl mask' does: symlink service file to /dev/null.
    mkdir -p /etc/systemd/system
    ln -sf /dev/null /etc/systemd/system/mongodb.service
    echo "Masked mongodb.service (symlinked to /dev/null)"

    # 2. Wait for external MongoDB to be reachable before starting systemd.
    MONGO_WAIT_TIMEOUT=${MONGO_WAIT_TIMEOUT:-120}
    MONGO_WAIT_INTERVAL=2
    elapsed=0
    echo "Waiting for MongoDB at ${MONGO_HOST}:27017 (timeout: ${MONGO_WAIT_TIMEOUT}s)..."
    until bash -c ">/dev/tcp/${MONGO_HOST}/27017" 2>/dev/null; do
        if [ "$elapsed" -ge "$MONGO_WAIT_TIMEOUT" ]; then
            echo "ERROR: Timed out waiting for MongoDB at ${MONGO_HOST}:27017 after ${MONGO_WAIT_TIMEOUT}s. Aborting."
            exit 1
        fi
        sleep "$MONGO_WAIT_INTERVAL"
        elapsed=$((elapsed + MONGO_WAIT_INTERVAL))
    done
    echo "MongoDB is reachable at ${MONGO_HOST}:27017"

    # 3. Redirect localhost:27017 to the external MongoDB host using iptables NAT.
    #    OUTPUT chain covers connections initiated within this container.
    #    POSTROUTING MASQUERADE ensures the source IP is valid for return traffic.
    #    Both rules must run before systemd starts UniFi services.
    iptables -t nat -A OUTPUT \
        -d 127.0.0.1 -p tcp --dport 27017 \
        -j DNAT --to-destination "${MONGO_HOST}:27017"
    iptables -t nat -A POSTROUTING \
        -d "${MONGO_HOST}" -p tcp --dport 27017 \
        -j MASQUERADE
    echo "iptables NAT rule installed: localhost:27017 -> ${MONGO_HOST}:27017"

    echo "External MongoDB configuration complete."
fi

# Initialize rabbitmq log dirs
RABBITMQ_LOG_DIR="/var/log/rabbitmq"
if [ ! -d "$RABBITMQ_LOG_DIR" ]; then
    mkdir -p "$RABBITMQ_LOG_DIR"
    chown rabbitmq:rabbitmq "$RABBITMQ_LOG_DIR"
    chmod 755 "$RABBITMQ_LOG_DIR"
fi

# Apply Synology patches
SYS_VENDOR="/sys/class/dmi/id/sys_vendor"
if { [ -f "$SYS_VENDOR" ] && grep -q "Synology" "$SYS_VENDOR"; } \
    || [ "${HARDWARE_PLATFORM:-}" = "synology" ]; then

    if [ -n "${HARDWARE_PLATFORM+1}" ]; then
        echo "Setting HARDWARE_PLATFORM to $HARDWARE_PLATFORM"
    else
        echo "Synology hardware found, applying patches..."
    fi

    # Set postgresql overrides
    mkdir -p /etc/systemd/system/postgresql@14-main.service.d
    {
        echo "[Service]"
        echo "PIDFile="
    } > /etc/systemd/system/postgresql@14-main.service.d/override.conf

    # Set rabbitmq overrides
    mkdir -p /etc/systemd/system/rabbitmq-server.service.d
    {
        echo "[Service]"
        echo "Type=simple"
    } > /etc/systemd/system/rabbitmq-server.service.d/override.conf

    # Set ulp-go overrides
    mkdir -p /etc/systemd/system/ulp-go.service.d
    {
        echo "[Service]"
        echo "Type=simple"
    } > /etc/systemd/system/ulp-go.service.d/override.conf

    echo "Synology patches applied!"
fi

# Set UOS_SYSTEM_IP
UNIFI_SYSTEM_PROPERTIES="/var/lib/unifi/system.properties"
if [ -n "${UOS_SYSTEM_IP+1}" ]; then
    echo "Setting UOS_SYSTEM_IP to $UOS_SYSTEM_IP"
    if [ ! -f "$UNIFI_SYSTEM_PROPERTIES" ]; then
        echo "system_ip=$UOS_SYSTEM_IP" >> "$UNIFI_SYSTEM_PROPERTIES"
    else
        if grep -q "^system_ip=.*" "$UNIFI_SYSTEM_PROPERTIES"; then
            sed -i 's/^system_ip=.*/system_ip='"$UOS_SYSTEM_IP"'/' "$UNIFI_SYSTEM_PROPERTIES"
        else
            echo "system_ip=$UOS_SYSTEM_IP" >> "$UNIFI_SYSTEM_PROPERTIES"
        fi
    fi
fi

# Start systemd
exec /sbin/init