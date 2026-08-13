<!-- LUME-SOL-CONTROL-BEGIN -->
### Lume routing policy

When Lume integration is installed, resolve the worker mode immediately before
every new worker spawn by running:

```sh
rtk /usr/bin/python3 "${CODEX_HOME:-$HOME/.codex}/skills/sol-control/scripts/lume_policy.py" resolve
```

Use the returned `mode` for that new worker only. Existing workers keep their
model and ownership. Resolution order is: a directive explicitly limited to the
current call, persistent `openai` or `quota-save`, Lume automatic state, then the
safe `openai` fallback. Always announce the resolved mode, source, worker, and
scope before spawning.

Persistent modes are `auto`, `openai`, and `quota-save`. A clear affirmative
natural-language routing directive persists unless the user limits it with words
such as "this call", "this turn", "this task", "temporary", "这次", "本轮",
"当前任务", or "临时". Discussion, quotations, examples, and ambiguous mentions
must not update policy. To persist a mode after interpreting the directive, run:

```sh
rtk /usr/bin/python3 "${CODEX_HOME:-$HOME/.codex}/skills/sol-control/scripts/lume_policy.py" set-mode MODE
```

An explicit current-call directive takes precedence without writing policy.
`mode=auto`, `mode=openai`, and `mode=quota-save` are unambiguous persistent
directives. In automatic mode, Lume selects `quota-save` below 20% unrounded 7D
remaining allowance and returns to `openai` at 25% or above. Missing, invalid,
unsafe, or expired automatic state fails open to `openai`.
<!-- LUME-SOL-CONTROL-END -->
