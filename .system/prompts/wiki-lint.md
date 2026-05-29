You are running a lint pass over the knowledge wiki at `${WORK_WIKI}`.

## Your job

Audit the wiki for health issues and write findings to `${WORK_WIKI}/wiki/syntheses/lint-${DATE_STR}.md`.

Read `${WORK_WIKI}/SCHEMA.md` first for the rules.

## Checks

For each, list specific findings with page paths. Don't fix — report.

1. **Orphaned pages**: pages in `wiki/` that no other page links to and that aren't in any index. List them.
2. **Broken links**: `[text](path)` links that point to non-existent pages. Also flag any `[[wikilink]]` style links — the wiki uses standard markdown only; `[[...]]` should be rewritten as `[name](relative/path.md)`.
3. **Missing index entries**: project pages not in `wiki/index/by-project.md`; wiki-touching activity not in `wiki/index/by-date.md`; acronyms used in pages but not defined in `wiki/index/glossary.md`.
4. **Contradictions**: pages that make conflicting claims (e.g. project A says X is shipped; project A's concept page says X is in-progress).
5. **Stale entries**: `Recent activity` sections with > 10 entries (should be capped per SCHEMA).
5b. **Oversized Recent-activity entries**: bullets in any `## Recent activity` section that violate the SCHEMA one-line rule. Flag any entry that (a) exceeds 200 characters, (b) contains nested sub-bullets (lines starting with whitespace + `-`/`*` directly under the entry), or (c) spans multiple paragraphs / has embedded blank lines before the next dated entry. Report the page, the date prefix of the offending entry, character count, and the first ~80 chars of the entry.
5c. **Oversized by-date pointers**: same rule applied to `wiki/index/by-date.md` — each dated bullet must be one line, ≤200 chars, no sub-bullets, no embedded newlines. Report violations the same way.
6. **Frontmatter issues**: pages missing required frontmatter (type, slug, created, updated, sources).
7. **Duplicates**: two pages covering the same entity/concept under different slugs.
8. **Length violations**: pages > 300 lines (should be split).
9. **Knowledge gaps**: project pages with empty Summary; concept pages with no cross-references; entity pages mentioned in many places but with no detail.

## Output format

```
---
type: synthesis
slug: lint-${DATE_STR}
created: ${DATE_STR}
updated: ${DATE_STR}
sources:
  - lint-pass: 1
---

# Wiki Lint — ${DATE_STR}

## Summary
- Total pages: N
- Issues found: N

## Orphans
- ...

## Broken links
- ...

(... one section per check, omit empty sections ...)

## Suggested next actions
- (1-5 bullets, prioritized)
```

Be specific. Don't suggest fixes you can't justify from the corpus.
