# Using Suspicious Package and AI to Build Better macOS Uninstaller

Mac admins are often asked to remove software that was originally deployed by a vendor `.pkg` or `.mpkg`, and the uncomfortable answer is usually: "It depends what the installer put on disk." Receipts help, but they are not always enough. Vendor uninstallers may be missing, outdated, interactive, or unsuitable for an MDM-driven deployment workflow. Hand-building an uninstaller from memory is even worse.

A better workflow is to extract the installer evidence first, then ask AI to help draft an uninstaller from that evidence. The key distinction is important: AI should not guess what to remove. It should work from package IDs, payload paths, installer scripts, and receipts.

This post walks through using `spkg_package_id_and_manifest.sh` to generate that evidence with the Suspicious Package command-line tool, then using the generated AI context file to draft a safer, MDM-friendly uninstall script.

## Why Suspicious Package belongs in this workflow

[Suspicious Package](https://www.mothersruin.com/software/SuspiciousPackage/) is built for inspecting macOS installer packages before you install them. It can show who signed a package, whether it was notarized, what files it installs, metadata such as versions and bundle identifiers, scripts the package will run, installer receipts, and potential issues.

For admins, that makes it useful beyond one-off inspection. The `spkg` command-line tool lets you automate parts of that inspection and produce repeatable artifacts that can be archived, compared, and fed into an AI prompt.

The Suspicious Package download page currently lists version 4.6.1 and provides a signed disk image. Installation is simple: download the disk image, open it, then drag Suspicious Package into `/Applications` or another admin tools folder. On my admin Mac, the command-line tool is located inside the app bundle at:

```bash
/Applications/Utilities/Admin/Suspicious Package.app/Contents/SharedSupport/spkg
```

and exposed in the shell with a symlink:

```bash
/usr/local/bin/spkg -> /Applications/Utilities/Admin/Suspicious Package.app/Contents/SharedSupport/spkg
```

If `spkg` is not in your `PATH`, you can create a symlink to the bundled tool:

```bash
sudo ln -s "/Applications/Suspicious Package.app/Contents/SharedSupport/spkg" /usr/local/bin/spkg
```

Adjust the source path if you keep admin apps somewhere else.

## Useful `spkg` features for Mac admins

Running `spkg` with no arguments prints the built-in help. The actions that matter most for uninstaller research are:

```bash
spkg --show-component-packages "/path/to/Installer.pkg"
```

Prints component package information. This is where you often get package identifiers that can later be checked with `pkgutil --pkg-info` or removed from the receipt database with `pkgutil --forget`.

```bash
spkg --manifest "/path/to/output.spkg-manifest.txt" "/path/to/Installer.pkg"
```

Creates a diffable manifest. Suspicious Package describes this as a folder-like manifest containing plain-text metadata for installed files, installer scripts, and package information. That is ideal for AI because it converts a package into readable context without requiring the model to inspect the binary installer directly.

```bash
spkg --show-signature "/path/to/Installer.pkg"
```

Prints signature information for the package.

```bash
spkg --reveal-scripts "/path/to/Installer.pkg"
```

Opens the package in Suspicious Package and jumps to the Scripts tab.

```bash
spkg --difftool "/path/to/Old.pkg" "/path/to/New.pkg"
```

Creates temporary manifests for two packages and sends them to the configured diff tool. This is useful when a vendor changes payload layout between versions.

For scripting, `--quiet` is especially helpful because it suppresses status output that would otherwise make parsing harder.

## What `spkg_package_id_and_manifest.sh` does

After downloading the script from the blog post or GitHub, place it somewhere convenient, for example:

```bash
/path/to/spkg_package_id_and_manifest.sh
```

It wraps this workflow into one repeatable command. It accepts a `.pkg` or `.mpkg`, extracts component package information with `spkg`, generates a Suspicious Package manifest, builds an AI-ready context file, and optionally copies that context to the clipboard.

Example:

```bash
/path/to/spkg_package_id_and_manifest.sh "/path/to/Vendor Installer.pkg"
```

By default, output is written under:

```bash
/path/to/output
```

You can provide a second argument to choose a different output root:

```bash
/path/to/spkg_package_id_and_manifest.sh \
  "/path/to/Vendor Installer.pkg" \
  "/path/to/package-research"
```

For each installer, the script creates an output folder named after the package and writes files like:

```bash
Vendor_Installer_20260612_143000.spkg-manifest.json
Vendor_Installer_20260612_143000.spkg-manifest.txt
Vendor_Installer_20260612_143000_ai_uninstall_context.txt
```

The script also does some admin-friendly cleanup on input paths. If you paste a path with quotes, a trailing colon from Finder, a leading `~`, or escaped spaces, it normalizes the path before testing whether the package exists.

## Suspicious Package 4.6.2 and JSON manifests

Suspicious Package 4.6.2 adds a new `spkg` option:

```bash
spkg --json-manifest "/path/to/output.json" "/path/to/Installer.pkg"
```

This creates a single JSON manifest file instead of the directory-style diffable manifest produced by `--manifest`. That JSON output is useful for automation and AI-assisted workflows because it can be archived, parsed, validated, and passed into an LLM without first walking and flattening the manifest directory.

`spkg_package_id_and_manifest.sh` automatically detects whether the installed `spkg` supports `--json-manifest`.

- If JSON manifest support is available, the script creates a `.spkg-manifest.json` file and embeds that JSON in the generated AI context.
- If JSON manifest support is not available, the script falls back to the older `--manifest` workflow and reconstructs the relevant payload and script context from the manifest directory.

You can also test a preview or alternate `spkg` binary without replacing your installed copy by setting `SPKG_BIN`:

```bash
SPKG_BIN="/Volumes/Suspicious Package 4.6.2/Suspicious Package.app/Contents/SharedSupport/spkg" \
  /path/to/spkg_package_id_and_manifest.sh \
  "/path/to/Installer.pkg" \
  "/path/to/output"
```

This keeps the helper script backward-compatible with Suspicious Package 4.6.1 and earlier while taking advantage of the cleaner JSON output in 4.6.2 and later.

## Example script run

Here is a simplified example of what a session might look like. The exact package IDs, component package names, payload paths, and scripts will vary by installer.

```bash
/path/to/spkg_package_id_and_manifest.sh \
  "/path/to/installers/ExampleApp.pkg" \
  "/path/to/package-research"
```

Example output:

```text
Package: /path/to/installers/ExampleApp.pkg
Output folder: /path/to/package-research/ExampleApp
Manifest output: /path/to/package-research/ExampleApp/ExampleApp_20260613_101530.spkg-manifest.txt

== Component Package Info ==
com.example.exampleapp.pkg | 4.2.1 | ExampleApp.pkg | 125 MB | /
com.example.exampleapp.helper.pkg | 4.2.1 | ExampleAppHelper.pkg | 3 MB | /

== Parsed Package IDs ==
com.example.exampleapp.helper.pkg
com.example.exampleapp.pkg

== Generating Manifest ==
Manifest created: /path/to/package-research/ExampleApp/ExampleApp_20260613_101530.spkg-manifest.txt

== Generating AI Context File ==
AI context file created: /path/to/package-research/ExampleApp/ExampleApp_20260613_101530_ai_uninstall_context.txt

Privacy note: the AI context file may include installer scripts, internal paths,
package identifiers, server URLs, license details, or other configuration data.
Review the context file before copying it into any hosted AI service.

Copy AI context to clipboard and open an AI tool? (Y/N) [Y]:
```

## Example output tree

The Suspicious Package manifest is created as a directory-style structure, even though the path ends with `.txt`. That is useful for diff tools, but the script also creates a flattened AI context file beside it.

Example output folder:

```text
/path/to/package-research/ExampleApp
|-- ExampleApp_20260613_101530.spkg-manifest.txt
|   |-- All Files
|   |   |-- Applications
|   |   |   `-- ExampleApp.app
|   |   |       `-- Contents
|   |   |           |-- Info.plist
|   |   |           |-- MacOS
|   |   |           `-- Resources
|   |   `-- Library
|   |       |-- LaunchDaemons
|   |       |   `-- com.example.exampleapp.helper.plist
|   |       `-- PrivilegedHelperTools
|   |           `-- com.example.exampleapp.helper
|   |-- All Scripts
|   |   |-- PackageInfo
|   |   |-- postinstall
|   |   `-- preinstall
|   `-- PackageInfo
`-- ExampleApp_20260613_101530_ai_uninstall_context.txt
```

Inside the AI context file, the script assembles the important parts into one prompt-friendly document:

```text
AI Prompt:
### ROLE ###
...

Payload - ExampleApp
Applications
`-- ExampleApp.app
Library
|-- LaunchDaemons
|   `-- com.example.exampleapp.helper.plist
`-- PrivilegedHelperTools
    `-- com.example.exampleapp.helper

########################################

postinstall - ExampleApp
#!/bin/sh
...

########################################

Package ID - ExampleApp
com.example.exampleapp.helper.pkg
com.example.exampleapp.pkg
```

## How the script gathers evidence

The first evidence source is component package information:

```bash
spkg --quiet --show-component-packages "$pkg_path"
```

The script parses package identifiers from common `spkg` output formats. If that parsing does not find package IDs, it falls back to expanding the package with:

```bash
pkgutil --expand-full "$pkg_path" "$temp_expand_dir"
```

and then reads `PackageInfo` files for identifiers. That fallback matters because installer packages are not always structured the way we wish they were.

The second evidence source is the Suspicious Package manifest:

```bash
spkg --quiet --manifest "$manifest_path" "$pkg_path"
```

The manifest gives you a readable view of the payload and scripts. The generated AI context file includes:

- The package payload tree from the manifest's `All Files` content.
- Any installer scripts found under `All Scripts`.
- Parsed package identifiers.
- A detailed prompt that tells the AI how to build an uninstall script safely.

This is the most useful part of the workflow. Instead of asking AI, "Write me an uninstaller for Vendor App," you are giving it structured evidence and boundaries.

## The safety model: payload evidence first

The generated prompt instructs AI to treat payload paths as the highest-confidence uninstall evidence, installer scripts as supporting evidence, and package IDs as receipt evidence. It also tells the AI to separate high-confidence removal candidates from uncertain items.

That framing prevents one of the most common AI mistakes in uninstallers: removing broad shared directories because they "look related." For example, `/Library/Application Support/Vendor` might be safe for one product and dangerously shared for another. The prompt explicitly discourages broad deletion, wildcards, and filesystem sweeps.

Package payload evidence is the starting point, not the complete story for every application. Some software creates additional files after installation during first launch, relaunch, licensing, update checks, helper startup, background service initialization, or normal user activity. Those items may not appear in the original installer package at all. Treat them as a separate discovery step: install the app on a test Mac, launch it, exercise the expected workflow, then compare filesystem changes or review known vendor locations before deciding whether any post-install artifacts belong in the uninstaller.

The requested uninstall script structure includes:

- `#!/bin/bash`
- `set -u`
- `set -o pipefail`
- A root check.
- Quoted variables.
- Arrays for paths and receipts.
- Timestamped logging.
- `DRY_RUN` support.
- Graceful process stopping.
- LaunchDaemon and LaunchAgent unload logic.
- `pkgutil --forget` for receipts.
- Verification of remaining known artifacts.
- A final summary.

For MDM deployment, those requirements are exactly the kind of operational polish you want before the script gets anywhere near production.

## Prompting tips that make this work

The prompting approach in this script lines up well with guidance from Fatih Kadir Akin's *The Prompting Book*, which emphasizes role, context, task, constraints, output format, examples, iteration, and verification. The online version is available at [prompts.chat/book](https://prompts.chat/book).

Here is how those ideas translate to Mac admin scripting.

### 1. Give the AI a real role

Do not ask for "a script." Ask for the perspective you need:

```text
You are a senior macOS endpoint engineer and security-minded shell script reviewer.
```

That role steers the model toward macOS deployment concerns: root context, launch services, receipts, payload paths, user data, and destructive command safety.

### 2. Provide context, not vibes

AI is much better when it has the actual package evidence. Include:

- Package IDs.
- Payload paths.
- Installer scripts.
- LaunchDaemon and LaunchAgent labels.
- App bundle identifiers.
- Known install locations.
- Any vendor uninstall commands.

The script does this by generating an AI context file instead of expecting you to paste random fragments from Suspicious Package.

### 3. Be explicit about the task

Good:

```text
Create one complete, safe, idempotent bash uninstall script suitable for deployment by an MDM.
```

Better:

```text
Create one complete, safe, idempotent bash uninstall script suitable for deployment by an MDM using only high-confidence payload paths, package identifiers, and installer script evidence.
```

That extra phrase matters. It tells the model what evidence it is allowed to trust.

### 4. Add constraints before the AI gets creative

For uninstallers, constraints are not bureaucracy. They are how you prevent accidental data loss.

Useful constraints include:

- Do not delete user data unless explicitly requested.
- Do not remove broad shared vendor folders unless every child is proven product-specific.
- Do not use wildcards for deletion.
- Do not use `find` sweeps across shared locations.
- Handle missing paths gracefully.
- Include `DRY_RUN=1`.
- Log every action.
- Verify remaining artifacts at the end.

This is the difference between a helpful draft and a dangerous one-liner with a smile.

### 5. Specify the exact output format

The script's prompt tells AI:

```text
Return only one complete bash script.
Do not wrap the script in Markdown fences.
Do not include explanatory prose outside the script.
```

That is useful when you want to save the output directly as a `.sh` file. For earlier review rounds, you may prefer asking for a table first:

```text
Before writing the script, return a table with:
- Path
- Evidence source
- Confidence
- Removal action
- Risk notes
```

Then run a second prompt to generate the script from the reviewed table. This is prompt chaining: extract, review, then generate.

### 6. Use an iterative workflow

For high-impact scripts, do not expect the first AI output to be final. A practical workflow is:

1. Generate the evidence file with `spkg_package_id_and_manifest.sh`.
2. Ask AI for an uninstall candidate table.
3. Review the table manually.
4. Ask AI to generate the script from approved high-confidence items.
5. Run `bash -n` or `zsh -n`, depending on the shell.
6. Test with `DRY_RUN=1`.
7. Test on a disposable VM or test Mac.
8. Launch or relaunch the app and exercise the expected workflow to identify post-install files created outside the original package payload.
9. Review logs and update the script.
10. Only then deploy through your MDM.
11. After real-world deployment, review issues and logs, then feed that information back into AI to refine the uninstaller, the evidence review process, or the prompt itself.

AI can accelerate the middle of the process. It does not replace the beginning or the end.

### 7. Ask the AI to verify itself

Add a review step:

```text
Review the uninstall script you generated for:
- Syntax errors
- Unsafe rm usage
- Unquoted variables
- Shared directory deletion risk
- Missing root check
- Missing dry-run handling
- Receipts forgotten before payload removal
- User data removal without explicit opt-in
```

Then review it yourself. AI-generated scripts can look confident and still be wrong.

## Prompting techniques used by the script

The generated AI context uses several common prompting techniques to make the output more useful and easier to review. The goal is not to have AI guess how an application should be removed. The goal is to provide installer evidence, define safety rules, and request a predictable result.

It starts with a role so the AI responds from the right perspective. For this workflow, that means a macOS-focused script reviewer who understands receipts, launchd, app bundles, root context, managed deployment, and least-destructive cleanup.

It then provides context. Package identifiers, payload paths, manifest content, and installer scripts are included as the source material. The prompt also makes clear that anything outside the provided context should not be assumed.

The task is direct and specific: create one complete, safe, idempotent uninstall script. The prompt defines the expected scope, including package-owned files, launch items, helper artifacts, and package receipts.

It includes guardrails for risky behavior. The AI is told not to remove broad shared directories, not to use wildcards or fuzzy matching, not to sweep the filesystem, and not to remove user data unless the evidence clearly supports it.

It also ranks the evidence. Payload paths are treated as the strongest source, installer scripts are supporting evidence, and uncertain targets should be logged instead of removed.

Finally, it controls the output format. The AI is asked for a complete bash script with configuration arrays, helper functions, dry-run support, receipt cleanup, verification, and a final summary. It is also asked to review its own output for common scripting risks before returning the result.

Together, these prompting techniques create a repeatable pattern: gather evidence, provide context, apply guardrails, control the output, and require verification.

### AI prompting notables

- Role: start with a specific role so the AI responds from the right operational perspective.
- Evidence: provide the evidence, not just the goal. Include package IDs, payload paths, scripts, receipts, and launch labels.
- Assumptions: tell the AI what it cannot assume. If it is not in the provided context, it should not be treated as fact.
- Guardrails: define safety rules clearly. For uninstallers, avoid broad deletes, wildcards, fuzzy matching, and user data removal without evidence.
- Confidence: rank the evidence. Payload paths are stronger than guesses from product names.
- Uncertainty: ask for uncertain items to be logged, not removed.
- Format: control the output format so the result is usable as a script, table, checklist, or review artifact.
- Verification: build in verification. Ask the AI to check for unsafe deletes, quoting issues, missing dry-run support, and risky assumptions.
- Iteration: iterate with real logs and test results. Better prompts come from seeing where the first draft struggled.
- Ownership: keep a human in the loop. AI can draft and review, but admins still own deployment decisions.

Short summary: good AI output depends on good context. The script uses installer evidence, explicit guardrails, and a structured prompt so AI can draft a better uninstaller with fewer assumptions. The safest workflow is still iterative: generate, review, test, deploy carefully, and feed real-world results back into the next revision.

## A sample workflow

Start with the installer:

```bash
pkg="/Users/Shared/Installers/VendorApp.pkg"
out="/Users/Shared/package-research"

/path/to/spkg_package_id_and_manifest.sh "$pkg" "$out"
```

Open the generated context file:

```bash
open "$out/VendorApp"
```

Paste the `_ai_uninstall_context.txt` file into your AI tool, or use the script's prompt to copy it to the clipboard and open Claude, Gemini, or ChatGPT.

After the AI generates the script, save it into your script repo and run a syntax check:

```bash
bash -n vendor_app_uninstaller.sh
```

Run a dry run:

```bash
sudo DRY_RUN=1 ./vendor_app_uninstaller.sh
```

Then run the script on a test Mac where the app is installed. Review the log output for removed paths, skipped paths, warnings, and remaining artifacts.

## MDM deployment considerations

For MDM deployment, I like uninstallers to support parameters or environment variables for the few things that might change. Jamf Pro, Kandji, Mosyle, Intune, Addigy, Workspace ONE, and other tools all have different ways to pass script input, so the script should not depend on one vendor-specific mechanism unless you intentionally build it that way.

- `DRY_RUN`
- `REMOVE_USER_DATA`
- Custom install path
- Verbose logging

The default behavior should be conservative. Remove the application and known system-level support files. Preserve per-user data unless the policy intentionally opts in to removing it.

In the MDM policy, script notes, or internal documentation, document:

- What the script removes.
- What it intentionally preserves.
- Which parameters are supported.
- Whether a restart may be required.
- How to run a dry run.

That documentation matters six months later when someone is staring at a policy wondering why it exists.

## Final thoughts

The best part of this workflow is that it gives AI the boring but essential context it needs. Suspicious Package and `spkg` answer the factual questions: what package IDs exist, what payload paths are present, what scripts run, and what receipts the installer creates. AI then helps turn that evidence into a readable, repeatable, MDM-ready uninstaller.

The rule is simple: evidence first, generation second, human review always.

## Developer summary and future options

This workflow currently exists because the Suspicious Package diffable manifest is optimized for human review and comparison tools such as Git, Kaleidoscope, BBEdit, and other diff utilities. That design is excellent for comparing package versions, but programmatic and AI-assisted workflows benefit from a single structured context file that can be passed directly into an LLM.

I contacted Randy Saldinger, the developer of Suspicious Package, to describe this use case and asked whether `spkg` might eventually support a single-file output mode, such as `--manifest-flat`, `--manifest-file`, `--context`, or `--summary`. Randy replied that he would see what he could do, and that the most tractable mapping of the current diffable manifest into a single-file format would probably be JSON.

That would be a great future direction. A native JSON output could make `spkg` even more useful for Mac admins by removing the need for wrapper scripts to traverse and flatten the manifest folder. A structured output could include payload metadata, installer scripts, package identifiers, signature details, and receipts in one predictable file. That would make automated review, uninstaller generation, CI checks, documentation, and MDM deployment workflows easier to build and easier to validate.

Until then, `spkg_package_id_and_manifest.sh` acts as a practical bridge. It takes the current `spkg --manifest` output, extracts the useful evidence, and assembles a single AI context file with safety-focused prompting already included.

## Sources

- Suspicious Package product page: https://www.mothersruin.com/software/SuspiciousPackage/
- Suspicious Package download and install page: https://www.mothersruin.com/software/SuspiciousPackage/get.html
- Suspicious Package user guide: https://www.mothersruin.com/software/SuspiciousPackage/use.html
- Suspicious Package scripting page: https://www.mothersruin.com/software/SuspiciousPackage/scripting.html
- The Prompting Book: https://prompts.chat/book
