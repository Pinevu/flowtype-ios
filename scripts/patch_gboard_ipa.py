#!/usr/bin/env python3
import os
import sys
import struct
import shutil
import zipfile
import plistlib
import subprocess
import pathlib

def inject_macho_load_dylib(binary_path, dylib_rpath):
    print(f"Injecting {dylib_rpath} into {binary_path}...")
    with open(binary_path, "rb") as f:
        data = bytearray(f.read())

    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IIIIIIII", data, 0)
    cmd_end = 32 + sizeofcmds

    # Check if already injected
    offset = 32
    for _ in range(ncmds):
        cmd, cmdsz = struct.unpack_from("<II", data, offset)
        if cmd == 0xc: # LC_LOAD_DYLIB
            str_off = struct.unpack_from("<I", data, offset + 8)[0]
            s = data[offset + str_off:offset + cmdsz].split(b"\x00")[0].decode("utf-8", "ignore")
            if s == dylib_rpath:
                print(f"  Already contains {dylib_rpath}, skipping.")
                return
        offset += cmdsz

    path_bytes = dylib_rpath.encode("utf-8") + b"\x00"
    cmdsize = 24 + len(path_bytes)
    if cmdsize % 8 != 0:
        cmdsize += (8 - (cmdsize % 8))
        path_bytes = path_bytes.ljust(cmdsize - 24, b"\x00")

    cmd_bytes = struct.pack("<IIIIII", 0xc, cmdsize, 24, 2, 0x10000, 0x10000) + path_bytes

    # Update header
    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    # Insert command at cmd_end
    data[cmd_end:cmd_end + cmdsize] = cmd_bytes

    with open(binary_path, "wb") as f:
        f.write(data)
    print(f"  Successfully injected {dylib_rpath} (new ncmds: {ncmds + 1})")

def patch_gboard(base_ipa, dylib_path, output_ipa):
    work_dir = pathlib.Path("/tmp/gboard_patch_work")
    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True)

    print(f"Unpacking {base_ipa}...")
    with zipfile.ZipFile(base_ipa, "r") as zf:
        zf.extractall(work_dir)

    payload_dir = work_dir / "Payload"
    app_dir = payload_dir / "Gboard.app"
    appex_dir = app_dir / "PlugIns" / "Gboard.appex"

    assert app_dir.exists(), "Gboard.app not found in IPA"
    assert appex_dir.exists(), "Gboard.appex not found in Gboard.app"

    # Copy dylib into Frameworks
    app_fw = app_dir / "Frameworks"
    app_fw.mkdir(parents=True, exist_ok=True)
    shutil.copy2(dylib_path, app_fw / "libLintypeGboard.dylib")

    appex_fw = appex_dir / "Frameworks"
    appex_fw.mkdir(parents=True, exist_ok=True)
    shutil.copy2(dylib_path, appex_fw / "libLintypeGboard.dylib")

    # Inject load command
    inject_macho_load_dylib(app_dir / "Gboard", "@rpath/libLintypeGboard.dylib")
    inject_macho_load_dylib(appex_dir / "Gboard", "@rpath/libLintypeGboard.dylib")

    # Update Info.plist with speech and mic permissions
    for plist_path in [app_dir / "Info.plist", appex_dir / "Info.plist"]:
        with open(plist_path, "rb") as f:
            pl = plistlib.load(f)
        pl["NSMicrophoneUsageDescription"] = "Lintype 语音输入需要访问您的麦克风以进行实时语音输入。"
        pl["NSSpeechRecognitionUsageDescription"] = "Lintype 语音输入需要使用系统的语音识别功能以将语音转换为文字。"
        with open(plist_path, "wb") as f:
            plistlib.dump(pl, f)
        print(f"Updated permissions in {plist_path}")

    # Remove existing code signature for clean resign / ESign / TrollStore
    for p in work_dir.rglob("_CodeSignature"):
        if p.is_dir():
            shutil.rmtree(p)

    # If codesign is available on system, ad-hoc sign
    if shutil.which("codesign"):
        print("Ad-hoc codesigning with codesign...")
        try:
            subprocess.run(["codesign", "--force", "--sign", "-", str(app_fw / "libLintypeGboard.dylib")], check=False)
            subprocess.run(["codesign", "--force", "--sign", "-", str(appex_dir)], check=False)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app_dir)], check=False)
        except Exception as e:
            print("Codesign note:", e)

    print(f"Packaging {output_ipa}...")
    output_path = pathlib.Path(output_ipa).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for file in work_dir.rglob("*"):
            if file.is_file():
                arcname = file.relative_to(work_dir)
                zf.write(file, arcname)

    size = os.path.getsize(output_path)
    print(f"Generated {output_path} successfully ({size} bytes, {size / 1024 / 1024:.2f} MB)")

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <base_ipa> <dylib_path> <output_ipa>")
        sys.exit(1)
    patch_gboard(sys.argv[1], sys.argv[2], sys.argv[3])
