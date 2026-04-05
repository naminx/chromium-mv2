import sys
import subprocess
import os

mock_vs_path = r"/windrive/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools"
mock_sdk_path = r"/windrive/Program Files (x86)/Windows Kits/10"

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

# Load the file, replace \ with / dynamically
with open('/depot_tools/win_toolchain/package_from_installed.py', 'r') as f:
    code = f.read()

# Make paths compatible with Linux and Zip format
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
    r"[:-len(os.path.sep)]": r"",  # Remove trailing slash stripping safely
    r"os.path.sep": r"'/'",
    r"'%cd%\\' + os.path.join(*d)": r"'%cd%\\\\' + '\\\\'.join(d)",
    r"BatDirs(dirs), ';%PATH%'": r"BatDirs(dirs).replace('/', '\\\\'), ';%PATH%'",
    r"r'ucrt\dlls\x86'": r"'ucrt/dlls/x86'",
    r"r'redist\ucrt\dlls\x86'": r"'redist/ucrt/dlls/x86'",
    r"r'ucrt\dlls\x64'": r"'ucrt/dlls/x64'",
    r"r'redist\ucrt\dlls\x64'": r"'redist/ucrt/dlls/x64'",
    r"SUPPORTED_VS_FILESYSTEM_NAME = '18'": r"SUPPORTED_VS_FILESYSTEM_NAME = '17'",
    r"SUPPORTED_VS_VERSION = '2026'": r"SUPPORTED_VS_VERSION = '2022'"
}

for k, v in replacements.items():
    code = code.replace(k, v)

for d in ['References', 'Windows Performance Toolkit', 'Testing', 'App Certification Kit', 'Extension SDKs', 'Assessment and Deployment Kit']:
    code = code.replace(f"'{d}\\\\'", f"'{d}/'")

# Also fix the _vs_version override error if missing
code = code.replace("usage: %prog [options] 2026", "usage: %prog [options] 2022")

sys.path.append('/depot_tools/win_toolchain')
exec(code, globals())
