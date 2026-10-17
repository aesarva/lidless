# Security

Lidless installs a small privileged helper for closed-lid mode: a sudoers rule that allows only `/usr/bin/pmset -a disablesleep 0|1` for the installing user, and a root launchd watchdog that resets `disablesleep` to 0 when Lidless is not running. The full model, including its current limits before Developer ID signing, is described in the README under [Security model](README.md#security-model).

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private vulnerability reporting for this repository (**Security → Report a vulnerability**). Include the macOS version, the Lidless version, and steps to reproduce. You can expect an acknowledgement within a week.
