# A trustworthy quota companion

Status: Accepted.

Lume presents Codex allowance and brings its window forward. Its runtime and package focus on those responsibilities.

## Data

Select the named Codex bucket before interpreting its windows. A nonempty multi-bucket response is authoritative; unknown buckets are not combined with the legacy view. Legacy single-bucket responses remain supported. Cache provenance changes clear earlier snapshots.

Each window retains its own successful observation and reset time. Failed or throttled reads never advance successful timestamps. Data older than two minutes is labelled cached; data older than fifteen minutes or past its reset becomes unavailable. Reset times in details include date and timezone.

## Refresh

Use one-shot timers with tolerance: sixty seconds during Codex foreground use and a five-minute grace period, five minutes in the background, fifteen minutes when stopped. This foreground signal is a usage heuristic, not a claim that background tasks have stopped. Failures exponentially back off to fifteen minutes. Manual, wake and activation requests have a ten-second cooldown; opening a menu has a sixty-second cooldown. One request may run at a time. Known future resets shorten the scheduled delay.

A local baseline on 2026-09-07 measured one existing release quota query with /usr/bin/time -l: 2.16 seconds wall time, 0.05 user and 0.03 system CPU seconds. This single sample does not measure battery impact. The scheduling change reduces steady-state background process starts from 60/hour to 12/hour, and stopped-state starts to 4/hour, excluding explicit refresh and lifecycle events.

One candidate query measured 2.35 seconds wall time, 0.06 user and 0.05 system CPU seconds. These samples show no per-query speed improvement; the benefit is fewer scheduled queries. Presentation-only timers update cache expiry without starting an app-server process.

## Scope and migration

Remove Sol Control UI, runtime bridge, installer and bundled resources from Lume. Existing user-level Sol Control skill and policy remain available independently; Lume performs no global configuration migration. Git retains the previous integration source.

Keep preference decoding for previous single-window and dual-window versions. Remove internal single-window aliases so callers must choose 5H or 7D explicitly. Keep the existing panel gestures and fixed outer-5H/inner-7D mapping.
