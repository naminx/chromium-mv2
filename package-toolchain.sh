#!/usr/bin/env bash
# package-toolchain2.sh — Direct 7z Toolchain Packager (VM Adapted)
#
# WHY: Improved version that skips the ZIP-unzip-repack cycle entirely.
# The file list is collected normally, then files are packed straight into
# a 7z archive named after the user-supplied hash — no zip, no hash
# computation, one compression pass.
set -e

usage() {
    echo "Usage: $0 --version <SDK_VER> --hash <TOOLCHAIN_HASH>"
    echo "Example: $0 --version 10.0.26100.0 --hash e66617bc68"
    exit 1
}

SDK_VER=""
HASH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) SDK_VER="$2"; shift 2 ;;
        --hash) HASH="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$SDK_VER" ] || [ -z "$HASH" ]; then usage; fi
if [ -z "$GITHUB_TOKEN" ]; then echo "❌ ERROR: GITHUB_TOKEN not set."; exit 1; fi

export VM_IMAGE="/home/namin/.local/chiba/chiba.qcow2"
export MOUNT_POINT="/mnt/win_vm"
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SDK_VER HASH

# ── 1. Cleanup & Preparation ─────────────────────────────────────────────────
echo "🧹 Cleaning previous state..."
sudo umount -l "$MOUNT_POINT" 2>/dev/null || true
sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
rm -f "${HASH}.7z"

# ── 2. Mount VM Disk ─────────────────────────────────────────────────────────
echo "💾 Mounting Windows VM image..."
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 "$VM_IMAGE"
sleep 2
sudo mkdir -p "$MOUNT_POINT"
# WHY: Read-only mount prevents accidental corruption of your VM disk.
sudo mount -o ro /dev/nbd0p3 "$MOUNT_POINT"

# ── 3. Path Discovery ────────────────────────────────────────────────────────
VS_PATH=""
for p in "$MOUNT_POINT/Program Files/Microsoft Visual Studio/2022/Community" \
         "$MOUNT_POINT/Program Files (x86)/Microsoft Visual Studio/2022/Community"; do
    if [ -d "$p" ]; then VS_PATH="$p"; break; fi
done

SDK_PATH="$MOUNT_POINT/Program Files (x86)/Windows Kits/10"

if [ ! -d "$VS_PATH" ] || [ ! -d "$SDK_PATH" ]; then
    echo "❌ ERROR: Could not find VS 2022 or SDK in the VM mount."
    sudo umount "$MOUNT_POINT"
    sudo qemu-nbd --disconnect /dev/nbd0
    exit 1
fi
export VS_PATH SDK_PATH

# ── 4. Collect File List & Pack Directly to 7z ───────────────────────────────
echo "📦 Capturing toolchain from VM (direct 7z output)..."

sudo mkdir -p /tmp/depot_tools
if [ ! -d "/tmp/depot_tools/win_toolchain" ]; then
    sudo git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git /tmp/depot_tools
fi

cat > /tmp/vm_packager2.py << 'PYTHON'
import sys
import subprocess
import os
import glob
import re
import shutil
import warnings

mock_vs_path = os.environ['VS_PATH']
mock_sdk_path = os.environ['SDK_PATH']
sdk_version = os.environ['SDK_VER']

original_check_output = subprocess.check_output
def mock_check_output(command, **kwargs):
    cmd_str = " ".join(command) if not isinstance(command, str) else command
    if "vswhere.exe" in cmd_str:
        return f"resolvedInstallationPath: {mock_vs_path}\ncatalog_productLineVersion: 17\n"
    if "reg query" in cmd_str:
        return f"    KitsRoot10    REG_SZ    {mock_sdk_path}\n"
    return original_check_output(command, **kwargs)
subprocess.check_output = mock_check_output

def generate_case_insensitive_pattern(pattern):
    return ''.join([f'[{c.lower()}{c.upper()}]' if c.isalpha() else c for c in pattern])

def custom_ExpandWildcards(root, sub_dir):
    path = os.path.normpath(os.path.join(root, sub_dir))
    matches = glob.glob(generate_case_insensitive_pattern(path))
    return matches[0] if matches else path

with open('/tmp/depot_tools/win_toolchain/package_from_installed.py', 'r') as f:
    code = f.read()

code = re.sub(r'def ExpandWildcards.*?return matches\[0\]', '', code, flags=re.DOTALL)
code = "ExpandWildcards = custom_ExpandWildcards\n" + code

replacements = {
    r"'Include\\'": r"'Include/'",
    r"'Lib\\'": r"'Lib/'",
    r"'Source\\'": r"'Source/'",
    r"'bin\\'": r"'bin/'",
    r"'arm\\'": r"'arm/'",
    r"'arm64\\'": r"'arm64/'",
    r"'samples\\'": r"'samples/'",
    r"'Windows Kits', '10', 'Debuggers'": r"'Windows Kits', '10', 'Debuggers'",
    r"'Windows Kits\\10\\bin\\SetEnv.cmd'": r"'Windows Kits/10/bin/SetEnv.cmd'",
    r"'Windows Kits\\10\\bin\\SetEnv.x86.json'": r"'Windows Kits/10/bin/SetEnv.x86.json'",
    r"'Windows Kits\\10\\bin\\SetEnv.x64.json'": r"'Windows Kits/10/bin/SetEnv.x64.json'",
    r"'Windows Kits\\10\\bin\\SetEnv.arm64.json'": r"'Windows Kits/10/bin/SetEnv.arm64.json'",
    r"r'Windows Kits\10\bin\SetEnv'": r"'Windows Kits/10/bin/SetEnv'",
    r"r'Windows Kits\10\bin\x64'": r"'Windows Kits/10/bin/x64'",
    r"r'Windows Kits\10\bin\x86'": r"'Windows Kits/10/bin/x86'",
    r"r'VC\bin\amd64'": r"'VC/bin/amd64'",
    r"r'VC\bin\amd64_x86'": r"'VC/bin/amd64_x86'",
    r"[:-len(os.path.sep)]": r"",
    r"os.path.sep": r"'/'",
    r"'%cd%\\' + os.path.join(*d)": r"'%cd%\\\\' + '\\\\'.join(d)",
    r"BatDirs(dirs), ';%PATH%'": r"BatDirs(dirs).replace('/', '\\\\'), ';%PATH%'",
    r"glob.glob(ucrt_dir + r'\*')": r"glob.glob(generate_case_insensitive_pattern(ucrt_dir) + '/*')",
    r"os.path.exists(ucrt_dir)": r"len(glob.glob(generate_case_insensitive_pattern(ucrt_dir))) > 0",
    r"ucrt_dir = os.path.join(sdk_path, 'redist', _win_version, r'ucrt\dlls\x86')": r"ucrt_dir = os.path.join(sdk_path, 'Redist', _win_version, 'ucrt/dlls/x86')",
    r"ucrt_dir = os.path.join(sdk_path, r'redist\ucrt\dlls\x86')": r"ucrt_dir = os.path.join(sdk_path, 'Redist/ucrt/dlls/x86')",
    r"ucrt_dir = os.path.join(sdk_path, 'redist', _win_version, r'ucrt\dlls\x64')": r"ucrt_dir = os.path.join(sdk_path, 'Redist', _win_version, 'ucrt/dlls/x64')",
    r"ucrt_dir = os.path.join(sdk_path, r'redist\ucrt\dlls\x64')": r"ucrt_dir = os.path.join(sdk_path, 'Redist/ucrt/dlls/x64')",
    r"SUPPORTED_VS_FILESYSTEM_NAME = '18'": r"SUPPORTED_VS_FILESYSTEM_NAME = '17'",
    r"SUPPORTED_VS_VERSION = '2026'": r"SUPPORTED_VS_VERSION = '2022'",
    r"tail.count(_win_version) == 0": r"tail.lower().count(_win_version.lower()) == 0",
}

for k, v in replacements.items(): code = code.replace(k, v)
for d in ['References', 'Windows Performance Toolkit', 'Testing', 'App Certification Kit', 'Extension SDKs', 'Assessment and Deployment Kit']:
    code = code.replace(f"'{d}\\\\'", f"'{d}/'")
code = code.replace("VC/redist", "VC/Redist")

# Replace the entire zip-write block + RenameToSha1 call at the end of main()
# with a direct 7z invocation. The archive is named after the user-supplied
# HASH — no hash computation needed.
old_tail = """    output = 'out.zip'
    if os.path.exists(output):
        os.unlink(output)
    count = 0
    version_match_count = 0
    total_size = 0
    missing_files = False
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, True) as zf:
        for disk_name, archive_name in files:
            sys.stdout.write('\\r%d/%d ...%s' %
                             (count, len(files), disk_name[-40:]))
            sys.stdout.flush()
            count += 1
            if not options.repackage_dir and disk_name.count(_win_version) > 0:
                version_match_count += 1
            if os.path.exists(disk_name):
                total_size += os.path.getsize(disk_name)
                if not options.dryrun:
                    zf.write(disk_name, archive_name)
            else:
                missing_files = True
                sys.stdout.write('\\r%s does not exist.\\n\\n' % disk_name)
                sys.stdout.flush()
    sys.stdout.write(
        '\\r%1.3f GB of data in %d files, %d files for %s.%s\\n' %
        (total_size / 1e9, count, version_match_count, _win_version, ' ' * 50))
    if options.dryrun:
        return 0
    if missing_files:
        raise Exception('One or more files were missing - aborting')
    if not options.repackage_dir and version_match_count == 0:
        raise Exception('No files found that match the specified winversion')
    sys.stdout.write('\\rWrote to %s.%s\\n' % (output, ' ' * 50))
    sys.stdout.flush()

    RenameToSha1(output)

    return 0"""

new_tail = """    if options.dryrun:
        total_size = sum(os.path.getsize(d) for d, _ in files if os.path.exists(d))
        missing = [d for d, _ in files if not os.path.exists(d)]
        version_match_count = sum(
            1 for d, _ in files if not options.repackage_dir and d.count(_win_version) > 0)
        sys.stdout.write('%1.3f GB of data in %d files, %d files for %s.\\n' %
                         (total_size / 1e9, len(files), version_match_count, _win_version))
        if missing:
            for m in missing: print(f'  MISSING: {m}')
        return 0

    missing_files = [d for d, _ in files if not os.path.exists(d)]
    if missing_files:
        raise Exception('One or more files were missing - aborting: ' + missing_files[0])
    if not options.repackage_dir and not any(d.count(_win_version) > 0 for d, _ in files):
        raise Exception('No files found that match the specified winversion')

    # Stage files as symlinks into a temp tree mirroring the archive layout,
    # then invoke 7z with each symlink named explicitly.
    # WHY explicit names: `7z a out.7z mylink` dereferences the symlink and
    # stores the real file content; `7z a out.7z` (dot/glob) stores the symlink
    # itself. Naming each entry forces dereferencing.
    # WHY symlinks and not copies: zero-copy, instant, no extra disk space needed.
    import tempfile

    archive_name = os.environ['HASH'] + '.7z'
    archive_root = tempfile.mkdtemp(prefix='toolchain_7z_')
    try:
        total = len(files)
        for i, (disk_name, dest_name) in enumerate(files, 1):
            dest = os.path.join(archive_root, dest_name.replace('\\\\', os.sep))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if os.path.exists(disk_name):
                os.symlink(disk_name, dest)
            sys.stdout.write(f'\\r  Staging {i}/{total}...')
            sys.stdout.flush()
        sys.stdout.write('\\n')

        print(f'🔒 Compressing to {archive_name} ...')
        subprocess.run(
            ['7z', 'a',
             f'-p{os.environ["GITHUB_TOKEN"]}',
             '-m0=lzma2', '-mx=9', '-md=64m', '-mmt=2',
             '-mhe=on',
             '-l',      # dereference symlinks
             os.path.join(os.environ.get('OLDPWD', os.getcwd()), archive_name),
             '.'],
            cwd=archive_root,
            check=True,
        )
    finally:
        shutil.rmtree(archive_root, ignore_errors=True)

    print(f'✅ Archive ready: {archive_name}')
    return 0"""

code = code.replace(old_tail, new_tail)

sys.path.append('/tmp/depot_tools/win_toolchain')
sys.argv = ['package_from_installed.py', '2022', '-w', sdk_version, '--noarm']
warnings.filterwarnings("ignore", category=SyntaxWarning)
exec(code, globals())
PYTHON

python3 /tmp/vm_packager2.py

# ── 5. Release to GitHub ──────────────────────────────────────────────────────
echo "🚀 Releasing ${HASH}.7z to GitHub..."
gh release create "$SDK_VER" "${HASH}.7z" --repo naminx/chromium-mv2 \
    --title "Windows SDK $SDK_VER" \
    --notes "Automated toolchain release for Chromium $HASH" || \
gh release upload "$SDK_VER" "${HASH}.7z" --repo naminx/chromium-mv2 --clobber

# ── 6. Cleanup ───────────────────────────────────────────────────────────────
echo "🧹 Final Cleanup..."
sudo umount "$MOUNT_POINT"
sudo qemu-nbd --disconnect /dev/nbd0
rm -f /tmp/vm_packager2.py
echo "✅ Done! Toolchain $HASH is live."
