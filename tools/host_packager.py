import sys
import subprocess
import os
import glob

# The exact paths as seen on the NixOS host mount
mock_vs_path = r"/home/namin/sources/chromium-mv2/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools"
mock_sdk_path = r"/home/namin/sources/chromium-mv2/c/Program Files (x86)/Windows Kits/10"

original_check_output = subprocess.check_output

def mock_check_output(command, **kwargs):
    if isinstance(command, str):
        cmd_str = command
    else:
        cmd_str = " ".join(command)
        
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
    
    # Special case, the glob might be looking for something with actual * in it,
    # generate_case_insensitive_pattern safely escapes character classes.
    matches = glob.glob(generate_case_insensitive_pattern(path))
    if len(matches) == 0:
        return path # let the caller fail with 'path missing' rather than '0 matches'
    return matches[0]

with open('/tmp/depot_tools/win_toolchain/package_from_installed.py', 'r') as f:
    code = f.read()

# Replace the original ExpandWildcards with our custom case-insensitive one
import re
code = re.sub(r'def ExpandWildcards.*?return matches\[0\]', '', code, flags=re.DOTALL)
code = "ExpandWildcards = custom_ExpandWildcards\n" + code

replacements = {
    # Replace \ with / for path separators
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
    
    # Fix the .count check which uses lower case in the source
    r"tail.count(_win_version) == 0": r"tail.lower().count(_win_version.lower()) == 0",
}

for k, v in replacements.items():
    code = code.replace(k, v)

for d in ['References', 'Windows Performance Toolkit', 'Testing', 'App Certification Kit', 'Extension SDKs', 'Assessment and Deployment Kit']:
    code = code.replace(f"'{d}\\\\'", f"'{d}/'")

# Fix capital Redist
code = code.replace("VC/redist", "VC/Redist")

# Also fix the _vs_version override error if missing
code = code.replace("usage: %prog [options] 2026", "usage: %prog [options] 2022")

sys.path.append('/tmp/depot_tools/win_toolchain')

# We inject sys.argv so it runs the command automatically
sys.argv = ['package_from_installed.py', '2022', '-w', '10.0.26100.0', '--noarm']

exec(code, globals())
