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
echo "Before building, you can pull the absolute newest Chromium version"
echo "from NixOS stable. This will update your flake.lock file automatically."
read -p "Do you want to update the Flake before compiling on Hetzner? (y/N): " UPDATE_FLAKE

if [[ "$UPDATE_FLAKE" =~ ^[Yy]$ ]]; then
    echo "🔄 Updating Flake lockfile..."
    nix flake update
    
    if command git -C ~/sources/chromium-mv2 diff --quiet flake.lock; then
        echo "✅ Flake is already up to date!"
    else
        echo "📝 Committing and pushing the updated flake.lock to GitHub..."
        command git -C ~/sources/chromium-mv2 add flake.lock
        # Ensure the commit isn't blocked by generic GPG tty issues by letting the user type their PIN if needed
        command git -C ~/sources/chromium-mv2 commit -m "chore(flake): lock nixpkgs to latest nixos-stable version" || true
        command git -C ~/sources/chromium-mv2 push
        echo "✅ Successfully synced new Chromium version to GitHub."
    fi
else
    echo "⚠️  Skipping Flake update. Proceeding with currently locked version."
fi

echo ""
echo "Fetching version info from github:naminx/chromium-mv2 (bypassing local cache)..."
if VERSION=$(nix eval --raw --refresh github:naminx/chromium-mv2#default.version 2>/dev/null); then
    echo "📦 You are about to build Chromium Version: $VERSION"
else
    echo "⚠️  Could not fetch version natively. Ensure your flake is pushed cleanly."
fi
echo "If this version looks correct, press Enter to blast off!"
echo "Otherwise, press Ctrl+C to abort."
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
