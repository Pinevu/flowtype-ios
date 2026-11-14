#!/usr/bin/env python3
"""
Configures project.yml (for both unsigned custom IDs and signed manual provisioning)
and generates ExportOptions.plist for GitHub Actions iOS CI builds.
"""

import argparse
import plistlib
import re
from pathlib import Path


def strip_team_prefix(app_id: str, team_id: str) -> str:
    prefix = f"{team_id}."
    if app_id.startswith(prefix):
        return app_id[len(prefix):]
    if "." in app_id:
        return app_id.split(".", 1)[1]
    return app_id


def parse_profile(plist_path: Path) -> dict:
    with plist_path.open("rb") as f:
        data = plistlib.load(f)
    entitlements = data.get("Entitlements", {})
    team_ids = data.get("TeamIdentifier", [])
    team_id = team_ids[0] if team_ids else ""
    raw_app_id = entitlements.get("application-identifier", "")
    bundle_id = strip_team_prefix(raw_app_id, team_id)
    app_groups = entitlements.get("com.apple.security.application-groups", [])
    return {
        "uuid": data["UUID"],
        "name": data.get("Name", data["UUID"]),
        "team_id": team_id,
        "bundle_id": bundle_id,
        "app_groups": app_groups,
    }


def resolve_bundle_id(profile_bundle_id: str, fallback: str) -> str:
    if "*" in profile_bundle_id:
        base = profile_bundle_id.replace(".*", "").replace("*", "")
        if base:
            suffix = fallback.split(".")[-1]
            return f"{base}.{suffix}"
        return fallback
    return profile_bundle_id


def update_project_yml_unsigned(project_yml_path: Path, bundle_id_prefix: str, app_group_id: str):
    text = project_yml_path.read_text(encoding="utf-8")
    prefix = bundle_id_prefix.strip()
    group = app_group_id.strip()
    if prefix:
        text = re.sub(
            r"^(\s*PRODUCT_BUNDLE_IDENTIFIER:\s*)com\.flowtype\.voice\.app\.keyboard\s*$",
            rf"\g<1>{prefix}.app.keyboard",
            text,
            flags=re.MULTILINE,
        )
        text = re.sub(
            r"^(\s*PRODUCT_BUNDLE_IDENTIFIER:\s*)com\.flowtype\.voice\.app\s*$",
            rf"\g<1>{prefix}.app",
            text,
            flags=re.MULTILINE,
        )
    if group:
        text = re.sub(
            r"^(\s*FLOWTYPE_APP_GROUP_ID:\s*).*$",
            rf"\g<1>{group}",
            text,
            flags=re.MULTILINE,
        )
    project_yml_path.write_text(text, encoding="utf-8")


def update_project_yml_signed(
    project_yml_path: Path,
    team_id: str,
    app_bundle_id: str,
    ext_bundle_id: str,
    app_group_id: str,
    app_profile_uuid: str,
    ext_profile_uuid: str,
    code_sign_identity: str,
):
    text = project_yml_path.read_text(encoding="utf-8")

    text = re.sub(r'^(\s*DEVELOPMENT_TEAM:\s*).*$', rf'\g<1>"{team_id}"', text, flags=re.MULTILINE)
    text = re.sub(r'^(\s*FLOWTYPE_APP_GROUP_ID:\s*).*$', rf'\g<1>{app_group_id}', text, flags=re.MULTILINE)

    app_signing_block = (
        f"        PRODUCT_BUNDLE_IDENTIFIER: {app_bundle_id}\n"
        f'        CODE_SIGN_STYLE: "Manual"\n'
        f'        CODE_SIGN_IDENTITY: "{code_sign_identity}"\n'
        f'        PROVISIONING_PROFILE_SPECIFIER: "{app_profile_uuid}"'
    )
    ext_signing_block = (
        f"        PRODUCT_BUNDLE_IDENTIFIER: {ext_bundle_id}\n"
        f'        CODE_SIGN_STYLE: "Manual"\n'
        f'        CODE_SIGN_IDENTITY: "{code_sign_identity}"\n'
        f'        PROVISIONING_PROFILE_SPECIFIER: "{ext_profile_uuid}"'
    )

    text, app_count = re.subn(
        r"^\s*PRODUCT_BUNDLE_IDENTIFIER:\s*com\.flowtype\.voice\.app\s*$",
        app_signing_block,
        text,
        count=1,
        flags=re.MULTILINE,
    )
    text, ext_count = re.subn(
        r"^\s*PRODUCT_BUNDLE_IDENTIFIER:\s*com\.flowtype\.voice\.app\.keyboard\s*$",
        ext_signing_block,
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if app_count != 1 or ext_count != 1:
        raise SystemExit(f"Failed to patch bundle IDs in project.yml (app={app_count}, ext={ext_count})")

    project_yml_path.write_text(text, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--unsigned", action="store_true")
    parser.add_argument("--app-plist", default="")
    parser.add_argument("--ext-plist", default="")
    parser.add_argument("--project-yml", required=True)
    parser.add_argument("--export-options", default="")
    parser.add_argument("--export-method", default="ad-hoc")
    parser.add_argument("--bundle-id-prefix", default="")
    parser.add_argument("--app-group-id", default="")
    parser.add_argument("--team-id", default="")
    parser.add_argument("--sign-identity", default="")
    parser.add_argument("--github-env", default="")
    args = parser.parse_args()

    if args.unsigned:
        update_project_yml_unsigned(
            Path(args.project_yml),
            bundle_id_prefix=args.bundle_id_prefix,
            app_group_id=args.app_group_id,
        )
        print("Configured unsigned project.yml")
        return

    app_prof = parse_profile(Path(args.app_plist))
    ext_prof = parse_profile(Path(args.ext_plist))

    team_id = args.team_id.strip() or app_prof["team_id"] or ext_prof["team_id"]
    if not team_id:
        raise SystemExit("Unable to determine Apple Team ID from provisioning profile or input")

    prefix = args.bundle_id_prefix.strip()
    default_app_id = f"{prefix}.app" if prefix else "com.flowtype.voice.app"
    default_ext_id = f"{prefix}.app.keyboard" if prefix else "com.flowtype.voice.app.keyboard"

    app_bundle_id = resolve_bundle_id(app_prof["bundle_id"], default_app_id)
    ext_bundle_id = resolve_bundle_id(ext_prof["bundle_id"], default_ext_id)

    app_group_id = args.app_group_id.strip()
    if not app_group_id:
        if app_prof["app_groups"]:
            app_group_id = app_prof["app_groups"][0]
        elif ext_prof["app_groups"]:
            app_group_id = ext_prof["app_groups"][0]
        else:
            app_group_id = f"group.{app_bundle_id}"

    sign_identity = args.sign_identity.strip() or (
        "Apple Development" if args.export_method == "development" else "Apple Distribution"
    )

    update_project_yml_signed(
        project_yml_path=Path(args.project_yml),
        team_id=team_id,
        app_bundle_id=app_bundle_id,
        ext_bundle_id=ext_bundle_id,
        app_group_id=app_group_id,
        app_profile_uuid=app_prof["uuid"],
        ext_profile_uuid=ext_prof["uuid"],
        code_sign_identity=sign_identity,
    )

    export_plist = {
        "method": args.export_method,
        "teamID": team_id,
        "signingStyle": "manual",
        "stripSwiftSymbols": True,
        "compileBitcode": False,
        "provisioningProfiles": {
            app_bundle_id: app_prof["uuid"],
            ext_bundle_id: ext_prof["uuid"],
        },
    }
    with Path(args.export_options).open("wb") as f:
        plistlib.dump(export_plist, f)

    print(f"Configured signing: team={team_id}, app={app_bundle_id}, ext={ext_bundle_id}, group={app_group_id}")
    if args.github_env:
        with open(args.github_env, "a", encoding="utf-8") as envf:
            envf.write(f"RESOLVED_APP_PROFILE_UUID={app_prof['uuid']}\n")
            envf.write(f"RESOLVED_EXT_PROFILE_UUID={ext_prof['uuid']}\n")
            envf.write(f"RESOLVED_TEAM_ID={team_id}\n")
            envf.write(f"RESOLVED_APP_BUNDLE_ID={app_bundle_id}\n")
            envf.write(f"RESOLVED_EXT_BUNDLE_ID={ext_bundle_id}\n")


if __name__ == "__main__":
    main()
