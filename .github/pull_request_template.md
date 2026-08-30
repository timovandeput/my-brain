## What this changes

<!-- One or two sentences. What is different after this merges? -->

## Why

<!-- The problem, not the patch. If a simpler approach was rejected, say which and why —
     that reasoning is what the comments in this codebase are for, and it belongs here too. -->

## Testing

<!-- What you ran, and what it said. `dart test`, `dart test -P scale` if you touched
     indexing or retrieval, and anything you checked by hand. -->

## Checklist

- [ ] `dart format .` and `dart analyze --fatal-infos` are clean
- [ ] `dart test` passes; `dart test -P scale` too if this touches scan, index or search
- [ ] Templates edited under `assets/templates/`, then `dart run tool/gen_templates.dart`
- [ ] `indexFormatVersion` bumped and the `format.dart` header doc updated, if the on-disk layout moved
- [ ] README and AGENTS.md still describe what the code does
