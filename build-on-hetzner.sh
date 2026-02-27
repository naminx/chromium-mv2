#!/usr/bin/env bash
set -e

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./build-on-hetzner.sh <HETZNER_IP> <CACHIX_TOKEN>"
    exit 1
fi

HETZNER_IP="$1"
CACHIX_TOKEN="$2"

echo "====================================================================="
echo "🚨 CRITICAL REMINDER BEFORE PROCEEDING 🚨"
echo "Because you are building 'github:naminx/chromium-mv2' remotely, the"
echo "Hetzner server can ONLY see code that has been COMPLETED, COMMITTED,"
echo "and PUSHED to GitHub! If you have local unsaved patch changes on your"
echo "laptop, the Hetzner server will build the OLD broken version!"
echo "====================================================================="
echo "If your code is pushed, press Enter to begin the automated setup & build."
echo "Otherwise, press Ctrl+C to abort and run 'git push' first."
read -p "..."

echo "🚀 Connecting to Hetzner Cloud server ($HETZNER_IP)..."

# SSH into the server and pipe the entire installation and build process
# directly into the remote shell! No rsync required.
ssh -o StrictHostKeyChecking=accept-new root@$HETZNER_IP << EOF
    set -e

    echo "⚙️ Setting up 16GB Swap Space..."
    if [ ! -f /swapfile ]; then
        fallocate -l 16G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo "✅ Swap space created and enabled."
    else
        echo "✅ Swap file already exists."
    fi

    echo "📦 Checking for Nix installation..."
    if ! command -v nix &> /dev/null; then
        echo "Nix not found. Installing now..."
        curl --proto "=https" --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm
    fi
    
    # Load Nix natively into this SSH session
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

    echo "🔑 Configuring Cachix..."
    nix profile install nixpkgs#cachix || true
    cachix authtoken "$CACHIX_TOKEN"

    echo "🏗️ Fetching your GitHub Flake and Building Chromium! (1.5 - 2 hours)..."
    nix build github:naminx/chromium-mv2#default \
        -L --print-out-paths \
    | cachix push namin

    echo "🎉 SUCCESS: The Chromium binary was seamlessly pushed to Cachix!"
    echo "🛑 STOP RECORDING BILLING: Go to console.hetzner.cloud and DELETE this server immediately!"
EOF
