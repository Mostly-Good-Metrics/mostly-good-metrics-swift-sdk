#!/bin/bash
# Bootstrap script for swift-sdk (Swift Package Manager)
set -e

echo "Bootstrapping swift-sdk..."

# Copy .env.sample to .env if it exists and .env doesn't
if [ -f ".env.sample" ] && [ ! -f ".env" ]; then
  cp .env.sample .env
  echo "Created .env from .env.sample"
fi

# Resolve and fetch dependencies
swift package resolve

echo "Done! Swift SDK is ready."
