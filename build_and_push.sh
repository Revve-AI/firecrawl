#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# Configuration
REGISTRY="asia-southeast1-docker.pkg.dev/revve-infra-dev/revve-dev"
SHORT_SHA=$(git rev-parse --short HEAD)
TIMESTAMP=$(date +%s)
TAG="${SHORT_SHA}"

echo "🚀 Starting build process..."
echo "📍 Registry: $REGISTRY"
echo "O  Tag: $TAG"

# Ensure we have authentication (assumes running on GCP VM with service account or gcloud auth login already done)
# echo "Configuring Docker authentication..."
# gcloud auth configure-docker asia-southeast1-docker.pkg.dev --quiet

# --- Build Firecrawl API ---
echo "--------------------------------------------------"
echo "📦 Building Firecrawl API..."
echo "--------------------------------------------------"

# Navigate to context to ensure relative paths work if needed, or just use -f and context
# Using context apps/api as per docker-compose
docker build \
  --platform linux/amd64 \
  -f apps/api/Dockerfile \
  -t "$REGISTRY/firecrawl-api:$TAG" \
  apps/api

# --- Build Playwright Service ---
echo "--------------------------------------------------"
echo "📦 Building Playwright Service..."
echo "--------------------------------------------------"

docker build \
  --platform linux/amd64 \
  -f apps/playwright-service-ts/Dockerfile \
  -t "$REGISTRY/firecrawl-playwright:$TAG" \
  apps/playwright-service-ts

# --- Push Images ---
echo "--------------------------------------------------"
echo "Pk Pushing images to Google Artifact Registry..."
echo "--------------------------------------------------"

docker push "$REGISTRY/firecrawl-api:$TAG"
docker push "$REGISTRY/firecrawl-playwright:$TAG"

echo "--------------------------------------------------"
echo "✅ Build and Push Complete!"
echo "--------------------------------------------------"
echo "API Image:        $REGISTRY/firecrawl-api:$TAG"
echo "Playwright Image: $REGISTRY/firecrawl-playwright:$TAG"
