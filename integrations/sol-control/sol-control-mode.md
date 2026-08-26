<!-- LUME-SOL-CONTROL-BEGIN -->
### Sol Control mode policy

When Lume integration is installed, resolve the worker mode immediately before
every new worker spawn by running:

```sh
rtk /usr/bin/python3 "${CODEX_HOME:-$HOME/.codex}/skills/sol-control/scripts/lume_policy.py" resolve
```

Use the returned `mode` for each new worker. Existing workers keep their model
and ownership. A directive explicitly limited to the current call takes
precedence for that call. Always announce the selected mode, source, worker, and
scope before spawning.

Persistent modes are `openai` and `quota-save`; `openai` is the default. A clear
affirmative natural-language routing directive persists unless the user limits
it with words such as "this call", "this turn", "this task", "temporary", "这次",
"本轮", "当前任务", or "临时". Discussion, quotations, examples, and ambiguous
mentions keep the current selection. To persist a mode after interpreting the
directive, run:

```sh
rtk /usr/bin/python3 "${CODEX_HOME:-$HOME/.codex}/skills/sol-control/scripts/lume_policy.py" set-mode MODE
```

An explicit current-call directive takes precedence without writing policy.
`mode=openai` and `mode=quota-save` are unambiguous persistent directives.
<!-- LUME-SOL-CONTROL-END -->
