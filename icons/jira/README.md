# Loupe JIRA icons

Custom SVG reproductions of JIRA-standard issue-type and priority icons, colored to match Atlassian's canonical palette so users recognize them instantly. These are **not** Atlassian's actual asset files — they're functionally equivalent reproductions safe to ship.

## Files

```
icons/jira/
├── issuetype/
│   ├── story.svg        — green bookmark         (#65BA3A)
│   ├── task.svg         — blue checkmark         (#4BADE8)
│   ├── bug.svg          — red bug body           (#E54A4A)
│   ├── epic.svg         — purple lightning       (#904EE2)
│   ├── subtask.svg      — light blue linked      (#4BADE8)
│   ├── improvement.svg  — teal up arrow          (#3DA597)
│   └── spike.svg        — grey magnifier         (#9097A3)
└── priority/
    ├── highest.svg      — red double up chevron  (#CD1316)
    ├── high.svg         — red single up chevron  (#D04437)
    ├── medium.svg       — orange equals          (#EA7D24)
    ├── low.svg          — blue single down       (#2684FF)
    └── lowest.svg       — blue double down       (#4598DF)
```

All icons are 24×24 `viewBox`, no defined width/height — scale freely via CSS:

```html
<img src="/icons/jira/issuetype/story.svg" width="14" height="14" alt="Story">
```

Or inline them for CSS color override:

```html
<svg width="14" height="14"><use href="/icons/jira/issuetype/story.svg#root"/></svg>
```

(Each file has its root `<svg>` as the addressable element.)

## Why custom, not Atlassian's actual files

Atlassian's issue-type icons are part of their trademark. Embedding their files in a shipping product invites a *"please remove"* email. These reproductions preserve the iconography the user expects (green Story bookmark, red Bug body, purple Epic lightning) without using Atlassian's exact bitmaps or SVG paths.

If you ever want pixel-perfect parity, two options:
1. **License the Atlassian Design System assets** (their marketplace path).
2. **Pull live from a connected user's JIRA instance** — each Cloud workspace serves them at `https://<workspace>.atlassian.net/images/icons/issuetypes/<type>.svg`. This is technically OK because it's the user's own JIRA instance serving the icons; you're just rendering them. But you're now dependent on their instance being up.

For v1, recommend shipping these reproductions and revisiting only if a design partner explicitly says they want exact JIRA glyph fidelity.

## Mapping JIRA priority names → file names

JIRA's priority field comes back as a localized name. Map server-side:

| JIRA `priority.name`           | File              |
|--------------------------------|-------------------|
| `Highest`, `Blocker`, `P0`     | `highest.svg`     |
| `High`, `Major`, `P1`          | `high.svg`        |
| `Medium`, `P2`                 | `medium.svg`      |
| `Low`, `Minor`, `P3`           | `low.svg`         |
| `Lowest`, `Trivial`, `P4`, `P5`| `lowest.svg`      |

Different JIRA configurations use different vocabularies; fall back to `medium.svg` if the value doesn't match.

## Mapping JIRA issue-type names → file names

| JIRA `issuetype.name`                   | File              |
|-----------------------------------------|-------------------|
| `Story`, `User Story`                   | `story.svg`       |
| `Task`                                  | `task.svg`        |
| `Bug`, `Defect`                         | `bug.svg`         |
| `Epic`                                  | `epic.svg`        |
| `Sub-task`, `Subtask`, `Sub Task`       | `subtask.svg`     |
| `Improvement`, `Enhancement`            | `improvement.svg` |
| `Spike`, `Research`, `Investigation`    | `spike.svg`       |

For unknown types, fall back to `task.svg`.
