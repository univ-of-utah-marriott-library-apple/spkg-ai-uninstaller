#!/bin/zsh
#
# Suspicious Package CLI - Package ID and Manifest Extraction Script
#
# This script extracts component package information from a .pkg or .mpkg installer using the Suspicious Package CLI.
# It parses the output to list package identifiers and generates a manifest file with detailed information.
#
# Revised Date: 2026.06.18
# Version: 1.3.0
#
# Public example script. Review and adapt for your environment before use.
# This software is supplied as is without expressed or implied warranties of any kind.

set -euo pipefail

if [[ -n "${SPKG_BIN:-}" ]]; then
  if [[ ! -x "${SPKG_BIN}" ]]; then
    echo "Error: SPKG_BIN is set but is not executable: ${SPKG_BIN}" >&2
    exit 1
  fi
else
  if ! command -v spkg >/dev/null 2>&1; then
    echo "Error: 'spkg' command not found. Install Suspicious Package CLI first." >&2
    exit 1
  fi
  SPKG_BIN="$(command -v spkg)"
fi

spkg_usage="$("${SPKG_BIN}" 2>&1 || true)"
supports_json_manifest=0
if printf "%s\n" "${spkg_usage}" | grep -q -- "--json-manifest"; then
  supports_json_manifest=1
fi

prompt_copy_ai_context() {
  local choice
  local ai_choice
  local ai_url

  echo
  echo "Privacy note: the AI context file may include installer scripts, internal paths,"
  echo "package identifiers, server URLs, license details, or other configuration data."
  echo "Review the context file before copying it into any hosted AI service."
  echo
  printf "Copy AI context to clipboard and open an AI tool? (Y/N) [Y]: "
  IFS= read -r choice
  choice="$(printf "%s" "${choice}" | tr '[:upper:]' '[:lower:]')"

  case "${choice}" in
    ""|y|yes|c|copy)
      if command -v pbcopy >/dev/null 2>&1; then
        if pbcopy < "${ai_context_path}" 2>/dev/null; then
          echo "Copied AI context to clipboard."
        else
          echo "Error: pbcopy failed. AI context file remains at: ${ai_context_path}" >&2
          return 1
        fi
      else
        echo "pbcopy not available. AI context file remains at: ${ai_context_path}"
        return 0
      fi

      echo
      echo "Open which AI?"
      echo "1) Claude"
      echo "2) Gemini"
      echo "3) OpenAI"
      echo "4) Exit"
      printf "Choice [3]: "
      IFS= read -r ai_choice
      ai_choice="$(printf "%s" "${ai_choice}" | tr '[:upper:]' '[:lower:]')"

      case "${ai_choice}" in
        1|claude)
          ai_url="https://claude.ai/new"
          ;;
        2|gemini)
          ai_url="https://gemini.google.com/app"
          ;;
        4|q|quit|exit)
          echo "Exiting AI open step."
          return 0
          ;;
        3|""|openai|chatgpt)
          ai_url="https://chatgpt.com/"
          ;;
        *)
          echo "Unknown selection. Defaulting to OpenAI."
          ai_url="https://chatgpt.com/"
          ;;
      esac

      if command -v open >/dev/null 2>&1; then
        echo "Opening ${ai_url} ..."
        open "${ai_url}" 2>/dev/null || true
      else
        echo "Open this URL manually: ${ai_url}"
      fi
      ;;
    *)
      echo "Skipped clipboard copy and AI open step."
      ;;
  esac
}

pkg_path="${1:-}"
output_root="${2:-${HOME}/Desktop/spkg-output}"

if [[ -z "${pkg_path}" ]]; then
  printf "Enter installer package path (.pkg/.mpkg): "
  IFS= read -r pkg_path
fi

# Clean common paste artifacts from interactive input.
pkg_path="$(printf "%s" "${pkg_path}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
pkg_path="${pkg_path%:}"
pkg_path="${pkg_path#\"}"
pkg_path="${pkg_path%\"}"
pkg_path="${pkg_path#\'}"
pkg_path="${pkg_path%\'}"
pkg_path="${pkg_path/#\~/$HOME}"

# If the literal path does not exist, try unescaping shell-style pasted input
# (for example "\ " for spaces) without using eval.
if [[ ! -e "${pkg_path}" && "${pkg_path}" == *\\* ]]; then
  pkg_path_unescaped="${(Q)pkg_path}"
  pkg_path_unescaped="${pkg_path_unescaped/#\~/$HOME}"
  if [[ -e "${pkg_path_unescaped}" ]]; then
    pkg_path="${pkg_path_unescaped}"
  fi
fi

if [[ ! -e "${pkg_path}" ]]; then
  echo "Error: Package not found: ${pkg_path}" >&2
  exit 1
fi

if [[ ! "${pkg_path}" =~ \.(pkg|mpkg)$ ]]; then
  echo "Warning: Input does not end with .pkg or .mpkg: ${pkg_path}" >&2
fi

pkg_name="$(basename "${pkg_path}")"
pkg_stem="${pkg_name%.*}"
timestamp="$(date +%Y%m%d_%H%M%S)"
output_dir="${output_root}/${pkg_stem}"
manifest_path="${output_dir}/${pkg_stem}_${timestamp}.spkg-manifest.txt"
json_manifest_path="${output_dir}/${pkg_stem}_${timestamp}.spkg-manifest.json"
ai_context_path="${output_dir}/${pkg_stem}_${timestamp}_ai_uninstall_context.txt"

mkdir -p "${output_dir}"

echo
echo "Package: ${pkg_path}"
echo "spkg: ${SPKG_BIN}"
echo "Output folder: ${output_dir}"
if [[ "${supports_json_manifest}" -eq 1 ]]; then
  echo "JSON manifest output: ${json_manifest_path}"
else
  echo "Manifest output: ${manifest_path}"
fi
echo
echo "== Component Package Info =="

component_output="$("${SPKG_BIN}" --quiet --show-component-packages "${pkg_path}" 2>&1 || true)"
printf "%s\n" "${component_output}"

echo
echo "== Parsed Package IDs =="
parsed_ids="$(printf "%s\n" "${component_output}" | awk '
  BEGIN { IGNORECASE=1 }
  {
    # Format like: com.vendor.pkg.id | version | name.pkg | size | /path
    if (index($0, "|") > 0) {
      split($0, parts, "|")
      candidate=parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", candidate)
      if (candidate ~ /^[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+/) print candidate
    }
  }
' | cat - <(printf "%s\n" "${component_output}" | awk -F': *' '
  BEGIN { IGNORECASE=1 }
  /(Package Identifier|Package ID|Identifier):/ && NF >= 2 { print $2 }
') | sed 's/[[:space:]]*$//' | sed '/^$/d' | sort -u)"

if [[ -z "${parsed_ids}" ]]; then
  temp_expand_dir="$(mktemp -d "/tmp/${pkg_stem}_expand_XXXXXX")"
  if pkgutil --expand-full "${pkg_path}" "${temp_expand_dir}" >/dev/null 2>&1; then
    parsed_ids="$(
      while IFS= read -r package_info_file; do
        awk '
          match($0, /identifier="[^"]+"/) {
            id=substr($0, RSTART+12, RLENGTH-13)
            if (id != "") print id
          }
        ' "${package_info_file}" || true
      done < <(find "${temp_expand_dir}" -type f -name "PackageInfo" 2>/dev/null)
    )"
    parsed_ids="$(printf "%s\n" "${parsed_ids}" | sed '/^$/d' | sort -u)"
  fi
  rm -rf "${temp_expand_dir}" >/dev/null 2>&1 || true
fi

if [[ -n "${parsed_ids}" ]]; then
  printf "%s\n" "${parsed_ids}"
else
  echo "No package IDs parsed from spkg output (see raw component info above)."
fi

echo
if [[ "${supports_json_manifest}" -eq 1 ]]; then
  echo "== Generating JSON Manifest =="
  "${SPKG_BIN}" --quiet --json-manifest "${json_manifest_path}" "${pkg_path}"
  echo "JSON manifest created: ${json_manifest_path}"
else
  echo "== Generating Manifest =="
  "${SPKG_BIN}" --quiet --manifest "${manifest_path}" "${pkg_path}"
  echo "Manifest created: ${manifest_path}"

  all_files_path="${manifest_path}/All Files"
  all_scripts_dir="${manifest_path}/All Scripts"
fi

echo
echo "== Generating AI Context File =="
{
  cat <<'PROMPT'
AI Prompt:
### ROLE ###
You are a senior macOS endpoint engineer and security-minded shell script reviewer. You specialize in safe software removal, Apple installer receipts, launchd, application bundles, and least-destructive cleanup.

### CONTEXT ###
The evidence below was extracted from a macOS `.pkg` or `.mpkg` installer by Suspicious Package CLI. It may include:
- Payload paths from the package manifest.
- Installer scripts such as preinstall, postinstall, uninstall, or helper scripts.
- Package identifiers parsed from component package metadata.

Assume no access to the original package, local machine, internet, vendor documentation, or any files not shown below.

### UNINSTALL MODEL ###
Use a label-style uninstall model inspired by community macOS uninstallers:
- `APP_TITLE`: human-readable software name.
- `PACKAGE_IDS`: installer receipts to forget.
- `PROCESSES`: exact process names or proven executable paths to stop.
- `LAUNCH_AGENTS`: exact LaunchAgent plist paths or labels found in evidence.
- `LAUNCH_DAEMONS`: exact LaunchDaemon plist paths or labels found in evidence.
- `FILES`: exact installed files, app bundles, helpers, plugins, tools, and symlinks.
- `DIRECTORIES`: exact package-owned directories safe to remove recursively.
- `EMPTY_DIRECTORIES`: parent directories to remove only if empty after cleanup.
- `UNCERTAIN_ITEMS`: related-looking artifacts that should be reported but not deleted.

If the package evidence includes a primary app bundle, read its `CFBundleIdentifier`
when present and consider it as an additional receipt candidate only if `pkgutil`
shows an exact installed receipt match.

### TASK ###
Create one complete SAFE, IDEMPOTENT bash uninstall script for this package.

The script should remove this software's installed files, launch items, helper artifacts, and package receipts without damaging unrelated software, shared system locations, or user data.

### REASONING PROCESS ###
Before writing the script, privately work through these steps:
1. Identify the most likely software-owned namespace from package IDs, payload paths, launch labels, bundle IDs, process names, helper names, and installer scripts.
2. Treat payload paths as the highest-confidence removal source.
3. Treat installer scripts as supporting evidence for related processes, services, generated files, helpers, extensions, and receipts.
4. Separate high-confidence removal targets from uncertain targets.
5. Identify normal preference plists and their matching ByHost variants, but remove
   ByHost files only when the base preference plist is high-confidence package-owned.
6. For uncertain targets, do not remove them; log a warning or include them in verification output.
7. Check the final script for syntax issues, unsafe deletes, missing quoting, missing dry-run handling, and risky assumptions.

### CONSTRAINTS ###
- Start with `#!/bin/bash`.
- Use safe defaults such as `set -u` and `set -o pipefail`; avoid letting expected missing paths abort the whole script.
- Require root when needed and exit with a clear message if not run with sufficient privileges.
- Quote every variable and path.
- Put removable files, directories, launch items, processes, and receipts in readable arrays.
- Add timestamped logging, action logging, warning logging, and a final summary.
- Support `DRY_RUN=1` so the script can preview actions without changing the system.
- Stop matching processes gracefully first, then force-stop only if they are still running.
- Unload or boot out matching LaunchAgents and LaunchDaemons before removing their plist files. Use modern `launchctl bootout` where possible and tolerate already-unloaded services.
- Run `pkgutil --forget` for each listed package ID, with logging.
- If Jamf App Installers receipts are clearly associated with the app title, forget exact matches such as `com.jamf.appinstallers.<title>` only after checking they exist.
- Run `killall -q cfprefsd` near the end only if preference files were removed.
- Handle missing files, unloaded services, absent processes, and forgotten receipts gracefully.

### DELETION SAFETY RULES ###
- Remove only exact payload paths or clearly package-owned generated paths shown by installer context.
- Remove directories only when they are package-owned and empty after file removal, or when the entire directory path is explicitly package-owned in the payload.
- Never recursively delete broad shared locations such as `/Applications`, `/Library`, `/Library/Application Support`, `/Library/Preferences`, `/Library/PrivilegedHelperTools`, `/Users`, `/Users/Shared`, or user home directories.
- Default to preserving user-home data. Remove user LaunchAgents if they are package-owned because they can keep services alive; remove user preferences, caches, Application Support, containers, group containers, logs, or saved state only when the evidence clearly identifies them as package-owned and the script has an explicit `REMOVE_USER_DATA=1` or equivalent opt-in.
- If expanding paths for all users, enumerate real home directories safely and skip system/shared accounts.
- Do not use broad wildcards, fuzzy matching, `find` sweeps, or namespace guesses outside clear package-owned paths.
- Do not remove files merely because names look similar. Require evidence from the payload, scripts, package IDs, launch labels, or bundle identifiers.
- Do not delete user-created documents, project folders, downloads, caches, or preferences unless the installer evidence clearly shows they are package-owned and safe to remove.
- Do not execute vendor preinstall, postinstall, or uninstall script contents blindly. Translate only clearly relevant and safe cleanup actions into reviewed helper functions or log them as uncertain items.

### REQUIRED SCRIPT STRUCTURE ###
1. Header comment with purpose, safety notes, and dry-run usage.
2. Configuration arrays for package IDs, processes, launch services, files, directories, and uncertain items.
3. Helper functions for logging, dry-run execution, process stopping, launchd unloading, file removal, directory removal, receipt forgetting, and verification.
4. Main execution flow:
   - Check privileges.
   - Stop related processes.
   - Unload related launch services.
   - Remove high-confidence files.
   - Remove high-confidence directories according to the deletion safety rules.
   - Forget package receipts.
   - Verify remaining artifacts.
   - Print final summary.

### OUTPUT REQUIREMENTS ###
- Return only one complete bash script.
- Do not wrap the script in Markdown fences.
- Do not include explanatory prose outside the script.
- Include brief comments only for non-obvious safety decisions.
PROMPT
  echo
  echo "########################################"
  echo
  if [[ "${supports_json_manifest}" -eq 1 ]]; then
    echo "JSON Manifest - ${pkg_stem}"
    echo
    if [[ -f "${json_manifest_path}" ]]; then
      cat "${json_manifest_path}"
    else
      echo "JSON manifest not found: ${json_manifest_path}"
    fi
  else
    echo "Payload - ${pkg_stem}"
    echo
    if command -v tree >/dev/null 2>&1; then
      if [[ -e "${all_files_path}" ]]; then
        tree -a "${all_files_path}"
      else
        echo "All Files path not found: ${all_files_path}"
      fi
    else
      echo "tree command not found on this system."
    fi
    echo
    echo "########################################"
    echo

    script_files=()
    if [[ -d "${all_scripts_dir}" ]]; then
      while IFS= read -r script_file; do
        script_files+=("${script_file}")
      done < <(find "${all_scripts_dir}" -type f ! -name "PackageInfo" | sort)
    fi

    if [[ ${#script_files[@]} -eq 0 ]]; then
      echo "Scripts - ${pkg_stem}"
      echo "None found in manifest output"
      echo
    else
      for script_file in "${script_files[@]}"; do
        script_name="$(basename "${script_file}")"
        echo "${script_name} - ${pkg_stem}"
        echo
        cat "${script_file}"
        echo
        echo "########################################"
        echo
      done
    fi
  fi

  echo
  echo "########################################"
  echo
  echo "Package ID - ${pkg_stem}"
  echo
  if [[ -n "${parsed_ids}" ]]; then
    printf "%s\n" "${parsed_ids}"
  else
    echo "No package IDs found from spkg or expanded package metadata."
  fi
} > "${ai_context_path}"

echo "AI context file created: ${ai_context_path}"
prompt_copy_ai_context
