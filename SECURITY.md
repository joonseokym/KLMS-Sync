# Security Policy

## Sensitive Local Files

Never commit files that contain local account state, KLMS content, downloads, cookies, MFA registration data, or course-specific private information.

The repository intentionally ignores:

- `config.env`
- `manual_assignment_overrides.json`
- `kaikey_state.json`
- `runtime/`
- `course_files/`
- `course_transcripts/`
- `course_videos/`
- `launchd/*.plist`
- QR screenshots, cookies, logs, and local caches

`examples/config.env.example` and `examples/manual_assignment_overrides.example.json` are safe templates. Real local values should stay outside git.

## Kaikey/MFA Automation

Kaikey auto-login uses a locally registered device key. Treat `kaikey_state.json` like an MFA device credential.

- Do not upload it to GitHub, paste it into an issue, or include it in logs.
- If it may have leaked, remove/re-register the KAIST MFA device and delete the old state file.
- Do not expose approval through a public HTTP endpoint.
- For iPhone Shortcuts, prefer `Run Script over SSH` to the Mac or another access-controlled path.
- Approval helpers must only approve when the displayed 2-digit challenge matches the server-derived challenge.

KAIST MFA may allow only one registered device. In that case choose either Mac auto-login or phone PASSNI as the single registered authenticator.

## Reporting

This is an unofficial personal automation project. Do not include secrets, cookies, QR codes, state files, screenshots with account data, or course materials in public issues. For a suspected leak, rotate the affected credentials or MFA registration before sharing a minimal reproduction.
