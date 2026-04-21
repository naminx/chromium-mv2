import sys
with open('/tmp/depot_tools/win_toolchain/package_from_installed.py', 'r') as f:
    code = f.read()

split_result = code.split("output = 'out.zip'")
print(f"Split length: {len(split_result)}")

code = split_result[0]
code += """\
    count = 0
    version_match_count = 0
    total_size = 0
    missing_files = False

    out_dir = 'win_toolchain'
    if os.path.exists(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)

    for disk_name, archive_name in files:
        sys.stdout.write('\\r%d/%d ...%s' % (count, len(files), disk_name[-40:]))
        sys.stdout.flush()
        count += 1
        if not options.repackage_dir and disk_name.count(_win_version) > 0:
            version_match_count += 1
        if os.path.exists(disk_name):
            total_size += os.path.getsize(disk_name)
            if not options.dryrun:
                target = os.path.join(out_dir, archive_name)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copy2(disk_name, target)
        else:
            missing_files = True
            sys.stdout.write('\\r%s does not exist.\\n\\n' % disk_name)
            sys.stdout.flush()

    sys.stdout.write('\\r%1.3f GB of data in %d files, %d files for %s.%s\\n' %
                     (total_size / 1e9, count, version_match_count, _win_version, ' ' * 50))
    if missing_files:
        raise Exception('One or more files were missing - aborting')
    sys.stdout.write('\\nFinished copying files.\\n')
    return 0

if __name__ == '__main__':
    sys.exit(main())
"""

with open('patched.py', 'w') as f:
    f.write(code)
