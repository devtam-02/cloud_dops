#!/bin/bash

# Step 1: Create directory for certificates if it doesn't exist
mkdir -p ./certs

# Step 2: Generate self-signed certificates (if you don't have them already)
# Only run this if you need new certificates
if [ ! -f ./certs/cert.pem ] || [ ! -f ./certs/key.pem ]; then
  echo "Generating self-signed certificates..."
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout ./certs/key.pem \
    -out ./certs/cert.pem \
    -subj "/CN=keycloak.devtam.dev" \
    -addext "subjectAltName=DNS:keycloak.devtam.dev"
fi

# Step 3: Add the domain to /etc/hosts if needed (requires sudo)
if ! grep -q "keycloak.devtam.dev" /etc/hosts; then
  echo "Adding keycloak.devtam.dev to /etc/hosts (requires sudo)..."
  echo "127.0.0.1 keycloak.devtam.dev" | sudo tee -a /etc/hosts
fi

# Step 4: Deploy with Docker Compose
echo "Deploying Keycloak with Docker Compose..."
docker compose -f docker-compose.keycloak.yml up -d

# Step 5: Check if containers are running
echo "Checking container status..."
docker compose -f docker-compose.keycloak.yml ps

# Step 6: Display access information
echo ""
echo "==================================================================="
echo "Keycloak is being deployed!"
echo "==================================================================="
echo "Access Keycloak at: https://keycloak.devtam.dev:8443"
echo "Admin username: admin"
echo "Admin password: Dev22x22"
echo "==================================================================="
echo "Note: If using self-signed certificates, you may need to accept the"
echo "security warning in your browser."
echo "==================================================================="