#!/bin/bash

# exit when any command fails
set -e

if [ ! -f .env ]; then
  echo "Exiting: Could not find .env file!"
  exit 1
fi

set -a
source .env
set +a

echo "Adding deploy user to server if necessary…"
# Add deploy user if it doesn’t already exist
id -u deploy >/dev/null 2>&1 || sudo useradd -m deploy

# set up ssh key from root to deploy
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

echo "Updating and installing required packages…"
apt update
apt install -y curl docker-compose jq

echo "Setting up Letsencrypt…"
mkdir -p ./data/etc/letsencrypt
mkdir -p ./data/var/lib/letsencrypt
mkdir -p ./data/couchdb

sudo docker run -it --rm \
 -p 80:80 -p 443:443 \
 --name certbot \
 -v "$PWD/data/etc/letsencrypt:/etc/letsencrypt" \
 -v "$PWD/data/var/lib/letsencrypt:/var/lib/letsencrypt" \
 certbot/certbot certonly \
 --standalone -d "$DOMAIN" --email "$CERTBOT_EMAIL" \
 --agree-tos --keep --non-interactive

# Concatenate the resulting certificate chain and the private key and write it to HAProxy's certificate file.
cd data/etc/letsencrypt/live/${DOMAIN}/
  cat fullchain.pem privkey.pem > ../../../haproxy/haproxychain.pem
cd -

mv renew_certificate_job /etc/cron.d/renew_certificate_job
chmod +x renew-certificate.sh

echo "Starting Docker Containers…"

docker-compose up -d

until curl -s -X GET http://localhost:5984 | jq -e '.couchdb == "Welcome"' >/dev/null; do
  echo "Waiting for CouchDB to start..."
  sleep 2
done

echo "CouchDB is ready!"
echo "Setting up CouchDB…"

# Make sure docker hasn't stolen deploy’s directory
chown deploy /home/deploy/web


# Configure cluster as single node
curl -X POST "${BASE_URL}/_cluster_setup" \
  -H "Content-Type: application/json" \
  -d "{\"action\":\"enable_single_node\",\"username\":\"${COUCHDB_USER}\",\"password\":\"${COUCHDB_PASS}\",\"bind_address\":\"0.0.0.0\",\"port\":5984,\"singlenode\":true}"  \
  --user "${COUCHDB_USER}:${COUCHDB_PASS}"

# Configure other parameters
curl -X PUT "${CONFIG_URL}/chttpd/require_valid_user" -H "Content-Type: application/json" -d '"true"' --user "${COUCHDB_USER}:${COUCHDB_PASS}"
curl -X PUT "${CONFIG_URL}/chttpd/max_http_request_size" -H "Content-Type: application/json" -d '"4294967296"' --user "${COUCHDB_USER}:${COUCHDB_PASS}"
curl -X PUT "${CONFIG_URL}/couchdb/max_document_size" -H "Content-Type: application/json" -d '"50000000"' --user "${COUCHDB_USER}:${COUCHDB_PASS}"

# Create system databases
curl -X PUT "${BASE_URL}/_users"
curl -X PUT "${BASE_URL}/_replicator"
curl -X PUT "${BASE_URL}/_global_changes"


# Create other user
curl -X PUT "${BASE_URL}/_users/org.couchdb.user:${COUCHDB_OTHER_USER}" \
  -H 'Content-Type: application/json' \
  -d "{\"_id\": \"org.couchdb.user:${COUCHDB_OTHER_USER}\", \"name\": \"${COUCHDB_OTHER_USER}\", \"type\": \"user\", \"roles\": [], \"password\": \"${COUCHDB_OTHER_PASS}\"}"

# Create db
curl -X PUT "${BASE_URL}/${COUCHDB_OTHER_DB}"

# Set security for new db
curl -X PUT "${BASE_URL}/${COUCHDB_OTHER_DB}/_security" \
  -H 'Content-type: application/json' \
  -H 'Accept: application/json' \
  -d "{\"admins\":{\"roles\":[\"_admin\"]},\"members\":{\"names\": [\"${COUCHDB_OTHER_USER}\"]}}"


if [ "$ENABLE_CORS" = "true" ]; then
  curl -X PUT ${CONFIG_URL}/chttpd/enable_cors -d '"true"'
  curl -X PUT ${CONFIG_URL}/cors/origins -d "\"$ALLOWED_ORIGINS\""
fi

if [ "$COUCHDB_PATH" = "/" ]; then
  COUCHDB_PATH=""
fi
echo "Running Fauxton at https://$DOMAIN${COUCHDB_PATH}/_utils/"

echo "All Done!"
