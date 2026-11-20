# Security Policy

## Supported versions

Only the latest release of Meboki gets security fixes. The app checks for updates daily (Sparkle) unless you turn that off, so please update before reporting.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Older releases | No |

## Reporting a vulnerability

Please don't open a public issue for a security problem.

Report it privately instead, either way works:

- GitHub: the **Report a vulnerability** button on the [Security tab](https://github.com/mebokihq/meboki/security) of this repository.
- Email: support@meboki.com, with "Security" in the subject.

Please include the Meboki version, your macOS version, the steps to reproduce, and what you think the impact is.

You'll get a reply within 7 days. Once a fix is ready, it ships in a new release and the report is credited in the release notes, unless you'd rather stay anonymous.

## Scope

Meboki reads text from other apps through the macOS Accessibility API, so these matter most:

- text leaving the Mac when only a local model is selected
- reading secure (password) fields or apps that Meboki should skip
- the local model server (bound to 127.0.0.1) being reachable from other machines
- tampering with model downloads (they are checked against pinned SHA-256 hashes)
- the update feed or licence check accepting unsigned data

Bugs in third-party projects Meboki bundles (llama.cpp, Sparkle) should also go to those projects.
