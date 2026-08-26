# Use user-selected Sol Control modes

Status: Accepted.

## Decision

Sol Control has two persistent modes: `openai` and `quota-save`. The default is `openai`. Lume and explicit Sol Control instructions write the selected mode to `~/.codex/sol-control-policy.json`; Sol Control resolves that file immediately before creating each new worker.

An instruction scoped with wording such as “这次” or “本轮” applies to the current call without changing the persistent selection. Existing workers retain their assigned model and ownership.

## Consequences

- Quota presentation and worker routing remain independent product responsibilities.
- The menu communicates one current mode and two direct choices.
- The policy file is the only shared runtime state required by Lume and Sol Control.
- Mode changes are deterministic, inspectable, and initiated by the user.
