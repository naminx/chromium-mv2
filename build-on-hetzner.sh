#!/usr/bin/env bash
set -e

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./build-on-hetzner.sh <HETZNER_IP> <CACHIX_TOKEN> [HETZNER_API_TOKEN]"
    echo "  (If API token is provided, server will SELF-DESTRUCT when finished!)"
    exit 1
fi

HETZNER_IP="$1"
CACHIX_TOKEN="$2"
HETZNER_API="$3"

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

    echo "🏗️ Preparing autonomous detached build script..."
    cat << 'INNERSCRIPT' > /root/autonomous_build.sh
#!/usr/bin/env bash
# Source Nix daemon
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

echo "======================================"
echo "Starting Chromium Build at \$(date)"
echo "======================================"

if nix build --refresh github:naminx/chromium-mv2#default -L --print-out-paths | cachix push namin; then
    echo "🎉 SUCCESS: The Chromium binary was seamlessly pushed to Cachix!"
    if [ -n "$HETZNER_API" ]; then
        echo "💥 Self-destructing server..."
        SERVER_ID=\$(curl -s http://169.254.169.254/hetzner/v1/metadata/instance-id)
        curl -X DELETE -H "Authorization: Bearer $HETZNER_API" "https://api.hetzner.cloud/v1/servers/\$SERVER_ID"
    fi
else
    echo "❌ BUILD FAILED!"
fi
INNERSCRIPT

    chmod +x /root/autonomous_build.sh

    echo "🚀 Launching autonomous build in the background (nohup)..."
    nohup /root/autonomous_build.sh > /var/log/build.log 2>&1 &

    echo "====================================================================="
    echo "✅ The compiler has been successfully detached and is running!"
    echo "You can now safely close your laptop or press Ctrl+C without killing the build."
    echo "To monitor the build progress at any time, run:"
    echo "👉 ./tail-hetzner.sh $HETZNER_IP"
    if [ -n "$HETZNER_API" ]; then
        echo "💥 API TOKEN DETECTED: The server will AUTOMATICALLY DELETE ITSELF when finished!"
    else
        echo "🛑 NO API TOKEN: You MUST delete the server manually from the Hetzner dashboard when done!"
    fi
    echo "====================================================================="
EOF
