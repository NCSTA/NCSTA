# Codex Scan Notes

This directory is for temporary but useful investigation notes when scanning the
toolkit repeatedly.

Use it for:

- search results from `rg`
- function maps
- bug reproduction notes
- JSON shape observations
- command output summaries
- open questions for the next pass

Keep production code and user-facing docs out of this folder.

## Suggested Note Format

Create files like:

```text
YYYYMMDD-topic.md
```

Example:

```text
20260520-nic-json-shape.md
```

Suggested sections:

```markdown
# Topic

## Question

## Searches

## Findings

## Files and Functions

## Next Step
```

## Useful Scan Commands

```powershell
rg -n "pattern" .
rg -n "^function " *.ps1
rg -n "FrontInterface|BackSideInterface|FrontSideNics" .
```
