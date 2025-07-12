#!/bin/bash

# Navigate to frontend directory
cd frontend || exit 1

# Install dependencies
echo "Installing npm packages..."
npm install

# Run the dev server
echo "Starting Vite dev server..."
npm run dev