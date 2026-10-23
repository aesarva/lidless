# Security

Closed-lid mode uses a small privileged helper: a launchd daemon inside the app bundle, registered through `SMAppService` and approved by the user in System Settings → Login Items. It accepts XPC connections only from Lidless signed with the same Developer ID team, can only turn `pmset disablesleep` on and off, and restores normal sleep when Lidless quits, crashes or removes it. On its first start it also removes the sudoers rule and watchdog installed by Lidless 0.2.0. The full model is described in the README under [Security model](README.md#security-model).

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private vulnerability reporting for this repository (**Security → Report a vulnerability**). Include the macOS version, the Lidless version, and steps to reproduce. You can expect an acknowledgement within a week.
