
#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONFIG="/etc/nginx/sites-available/blue-green-demo"
NGINX_PORT=8080
IMAGE="${1:-blue-green-demo:v2}"
BACKUP_CONFIG="/tmp/blue-green-nginx-backup-$$"

cd "$APP_DIR"

echo "Starting deployment of $IMAGE"

# Find the active Nginx target, ignoring commented lines.
ACTIVE_PORT=$( awk '
    /^[[:space:]]*#/ { next }
    /proxy_pass http:\/\/127\.0\.0\.1:[0-9]+;/ {
        line = $0
        sub(/^.*proxy_pass http:\/\/127\.0\.0\.1:/, "", line)
        sub(/;.*/, "", line)
        print line
        exit
    }
' "$NGINX_CONFIG")

if [[ -z "$ACTIVE_PORT" ]]; then
    echo "ERROR: Cannot find the active Nginx port."
    exit 1
fi

echo "Current active port: $ACTIVE_PORT"

# Select an unused port between 2000 and 2100.
NEW_PORT=""

for PORT in $(shuf -i 2000-2100 -n 101); do
    if !  ss -H -ltn "( sport = :$PORT )" | grep -q . &&
       ! docker ps --format '{{.Ports}}' |
           grep -qE "(^|[:, ])${PORT}->"; then
        NEW_PORT="$PORT"
        break
    fi
done

if [[ -z "$NEW_PORT" ]]; then
    echo "ERROR: No available port found."
    exit 1
fi

NEW_CONTAINER="blue-candidate-$(date +%s)"

echo "Selected port: $NEW_PORT"
echo "Starting candidate container: $NEW_CONTAINER"

# Start the new version without changing current traffic.
docker run -d \
    --name "$NEW_CONTAINER" \
    --restart unless-stopped \
    -p "$NEW_PORT:80" \
    "$IMAGE"

# Check the new application before switching traffic.
HEALTHY=false

for ATTEMPT in $(seq 1 10); do
    if curl -fsS --max-time 3 \
        "http://127.0.0.1:$NEW_PORT/" >/dev/null; then
        HEALTHY=true
        break
    fi

    echo "Health check $ATTEMPT failed; retrying..."
    sleep 2
done

if [[ "$HEALTHY" != true ]]; then
    echo "ERROR: Candidate failed health checks."
    docker rm -f "$NEW_CONTAINER" || true
    echo "Existing traffic remains unchanged."
    exit 1
fi

echo "Candidate health check passed."

# Save the original Nginx configuration for rollback.
sudo -n /usr/local/sbin/blue-green-nginx backup

# Switch Nginx to the candidate port.
if ! sudo -n /usr/local/sbin/blue-green-nginx switch "$NEW_PORT"; then
    echo "ERROR: Could not update Nginx configuration. Rolling back."
    sudo -n /usr/local/sbin/blue-green-nginx restore
    docker rm -f "$NEW_CONTAINER" || true
    exit 1
fi

# Validate the Nginx configuration.
if ! sudo -n /usr/local/sbin/blue-green-nginx test; then
    echo "ERROR: Nginx configuration test failed. Rolling back."
    sudo -n /usr/local/sbin/blue-green-nginx restore
    docker rm -f "$NEW_CONTAINER" || true
    exit 1
fi

# Reload Nginx.
if ! sudo -n /usr/local/sbin/blue-green-nginx reload; then
    echo "ERROR: Nginx reload failed. Rolling back."
    sudo -n /usr/local/sbin/blue-green-nginx restore
    docker rm -f "$NEW_CONTAINER" || true
    exit 1
fi

# Verify the application through Nginx.


# Determine the expected version from the image tag.
case "$IMAGE" in
    *:v1) EXPECTED_VERSION="Green v1" ;;
    *:v2) EXPECTED_VERSION="Blue v2" ;;
    *)
        echo "ERROR: Unknown image version: $IMAGE"
    sudo -n /usr/local/sbin/blue-green-nginx restore
        docker rm -f "$NEW_CONTAINER" || true
        exit 1
        ;;
esac

# Verify the expected version through Nginx.
if ! curl -fsS --max-time 5 \
    "http://127.0.0.1:$NGINX_PORT/" |
    grep -Fq "$EXPECTED_VERSION"; then
    echo "ERROR: Version verification failed. Rolling back."
    sudo -n /usr/local/sbin/blue-green-nginx restore
    docker rm -f "$NEW_CONTAINER" || true
    exit 1
fi

echo "Verified expected version: $EXPECTED_VERSION"
echo "Deployment successful!"
echo "Active port: $NEW_PORT"
echo "Active container: $NEW_CONTAINER"


# Remove old Blue-Green containers after successful verification.
for NAME in $(docker ps -a --format '{{.Names}}' |
    grep -E '^(blue-candidate-|blue-container$|green-container$)' || true); do

    if [[ "$NAME" != "$NEW_CONTAINER" ]]; then
        echo "Removing previous container: $NAME"
        docker rm -f "$NAME" || \
            echo "WARNING: Could not remove $NAME."
    fi
done

sudo -n /usr/local/sbin/blue-green-nginx cleanup

echo "Blue-Green deployment completed."

