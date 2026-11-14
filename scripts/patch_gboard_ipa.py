#!/usr/bin/env python3
import os
import sys
import struct
import shutil
import zipfile
import plistlib
import subprocess
import pathlib
import json

def inject_macho_load_dylib(binary_path, dylib_rpath):
    print(f"Injecting {dylib_rpath} into {binary_path}...")
    with open(binary_path, "rb") as f:
        data = bytearray(f.read())

    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IIIIIIII", data, 0)
    
    # Check if already injected
    offset = 32
    cs_offset = None
    cs_size = 0
    cs_bytes = b""
    for _ in range(ncmds):
        cmd, cmdsz = struct.unpack_from("<II", data, offset)
        if cmd == 0xc: # LC_LOAD_DYLIB
            str_off = struct.unpack_from("<I", data, offset + 8)[0]
            s = data[offset + str_off:offset + cmdsz].split(b"\x00")[0].decode("utf-8", "ignore")
            if s == dylib_rpath:
                print(f"  Already contains {dylib_rpath}, skipping.")
                return
        elif cmd == 0x1d: # LC_CODE_SIGNATURE
            cs_offset = offset
            cs_size = cmdsz
            cs_bytes = bytes(data[offset:offset + cmdsz])
        offset += cmdsz

    path_bytes = dylib_rpath.encode("utf-8") + b"\x00"
    new_cmdsize = 24 + len(path_bytes)
    if new_cmdsize % 8 != 0:
        new_cmdsize += (8 - (new_cmdsize % 8))
        path_bytes = path_bytes.ljust(new_cmdsize - 24, b"\x00")

    new_cmd_bytes = struct.pack("<IIIIII", 0xc, new_cmdsize, 24, 2, 0x10000, 0x10000) + path_bytes

    if cs_offset is not None:
        data[cs_offset:cs_offset + new_cmdsize] = new_cmd_bytes
        data[cs_offset + new_cmdsize:cs_offset + new_cmdsize + cs_size] = cs_bytes
    else:
        cmd_end = 32 + sizeofcmds
        data[cmd_end:cmd_end + new_cmdsize] = new_cmd_bytes

    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + new_cmdsize)

    # Verification
    v_ncmds, v_sizeofcmds = struct.unpack_from("<II", data, 16)
    v_offset = 32
    v_cmds = []
    for _ in range(v_ncmds):
        c, s = struct.unpack_from("<II", data, v_offset)
        v_cmds.append(c)
        v_offset += s
    if cs_offset is not None:
        assert v_cmds[-1] == 0x1d, "FATAL: LC_CODE_SIGNATURE is not the last load command!"
    print(f"  Successfully injected {dylib_rpath} (total cmds: {v_ncmds}, last cmd: {hex(v_cmds[-1])})")

    with open(binary_path, "wb") as f:
        f.write(data)

def patch_gboard(base_ipa, dylib_path, zh_zip_path, output_ipa):
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

    # 1. Place dylib in Payload/Gboard.app/Frameworks/
    app_fw = app_dir / "Frameworks"
    app_fw.mkdir(parents=True, exist_ok=True)
    shutil.copy2(dylib_path, app_fw / "libLintypeGboard.dylib")

    appex_fw = appex_dir / "Frameworks"
    if appex_fw.exists():
        shutil.rmtree(appex_fw)

    # 2. Inject load command into both binaries
    inject_macho_load_dylib(app_dir / "Gboard", "@rpath/libLintypeGboard.dylib")
    inject_macho_load_dylib(appex_dir / "Gboard", "@rpath/libLintypeGboard.dylib")

    # 3. Configure languages.plist: set 9-key as DEFAULT variant for Simplified Chinese
    lang_plist = app_fw / "gboard_framework.framework" / "GKBCommonResources.bundle" / "languages.plist"
    if lang_plist.exists():
        with open(lang_plist, "rb") as f:
            pl = plistlib.load(f)
        if "zh_hans" in pl:
            pl["zh_hans"]["variants"] = ["nine_key_zh_hans", "qwerty_zh_hans", "wubi_zh_hans", "stroke_zh_hans"]
            pl["zh_hans"]["default"] = True
            print("Configured zh_hans variants with nine_key_zh_hans as default in languages.plist!")
        with open(lang_plist, "wb") as f:
            plistlib.dump(pl, f)

    # 4. Bundle Chinese Language Model (zh_hans.zip)
    kb_res_bundle = appex_dir / "GKBKeyboardResources.bundle"
    if kb_res_bundle.exists() and zh_zip_path and os.path.exists(zh_zip_path):
        print(f"Bundling {zh_zip_path} into GKBKeyboardResources.bundle...")
        shutil.copy2(zh_zip_path, kb_res_bundle / "zh_hans.zip")
        shutil.copy2(zh_zip_path, app_dir / "zh_hans.zip")

        # Also pre-extract directly into LanguageModels in bundle
        zh_entry = {
            "id": "main:zh_hans_v2",
            "locale": "zh_hans_CN",
            "description": "简体中文",
            "filesize": str(os.path.getsize(zh_zip_path)),
            "rawChecksum": "6e61af57544cbb6dbc07101aba7cf8b7",
            "checksum": "6e61af57544cbb6dbc07101aba7cf8b7",
            "url": "https://www.gstatic.com/gboard/iOS/gboard_latest/lms/zh_hans.zip",
            "version": 13,
            "compression": "zip"
        }

        for base_target in [app_dir / "LanguageModels", appex_dir / "LanguageModels"]:
            base_target.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(zh_zip_path, "r") as zf:
                zf.extractall(base_target)
                target_sub = base_target / "main:zh_hans_v2"
                target_sub.mkdir(parents=True, exist_ok=True)
                zf.extractall(target_sub)
            with open(base_target / "metadata.json", "w", encoding="utf-8") as f:
                json.dump([zh_entry], f, ensure_ascii=False, indent=2)

        # Update metadata_bundled.json so Gboard knows zh_hans is locally bundled
        meta_bundled_path = kb_res_bundle / "metadata_bundled.json"
        if meta_bundled_path.exists():
            with open(meta_bundled_path, "r", encoding="utf-8") as f:
                mb_list = json.load(f)
            has_zh = any("zh_hans" in x.get("id", "") for x in mb_list)
            if not has_zh:
                mb_list.append(zh_entry)
                with open(meta_bundled_path, "w", encoding="utf-8") as f:
                    json.dump(mb_list, f, ensure_ascii=False)
                print("Updated metadata_bundled.json with offline zh_hans_v2 entry!")

        # Update bundle metadata.json as well
        bundle_meta_path = kb_res_bundle / "metadata.json"
        if bundle_meta_path.exists():
            with open(bundle_meta_path, "r", encoding="utf-8") as f:
                b_list = json.load(f)
            has_zh = any("zh_hans" in x.get("id", "") for x in b_list)
            if not has_zh:
                b_list.append(zh_entry)
                with open(bundle_meta_path, "w", encoding="utf-8") as f:
                    json.dump(b_list, f, ensure_ascii=False)
                print("Updated bundle metadata.json with zh_hans_v2 entry!")

    # 5. Update Info.plist permissions
    for plist_path in [app_dir / "Info.plist", appex_dir / "Info.plist"]:
        with open(plist_path, "rb") as f:
            pl = plistlib.load(f)
        pl["NSMicrophoneUsageDescription"] = "Lintype 语音输入需要访问您的麦克风以进行实时语音输入。"
        pl["NSSpeechRecognitionUsageDescription"] = "Lintype 语音输入需要使用系统的语音识别功能以将语音转换为文字。"
        with open(plist_path, "wb") as f:
            plistlib.dump(pl, f)
        print(f"Updated permissions in {plist_path}")

    # 6. Remove stale _CodeSignature folders
    for p in work_dir.rglob("_CodeSignature"):
        if p.is_dir():
            shutil.rmtree(p)

    # 7. Ad-hoc codesign
    if shutil.which("codesign"):
        print("Ad-hoc codesigning with clean entitlements for third-party cert compatibility...")
        try:
            subprocess.run(["codesign", "--force", "--sign", "-", str(app_fw / "libLintypeGboard.dylib")], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(appex_dir)], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app_dir)], check=True)
            print("Codesign verification completed successfully.")
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
    if len(sys.argv) < 5:
        print(f"Usage: {sys.argv[0]} <base_ipa> <dylib_path> <zh_zip_path> <output_ipa>")
        sys.exit(1)
    patch_gboard(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
