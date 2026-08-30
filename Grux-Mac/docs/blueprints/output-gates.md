# output-gates

## What it does

Applies your house rules to anything the assistant is about to send out, before it goes.
You write the rules once, in a file, in your own words. Then every email, post, caption and
message gets checked against them, and anything that breaks a rule gets fixed rather than
sent.

## Host

**Skills** (`Memory/Hybrid/SkillStore.swift`). A gate is a standing rule that must apply
without anyone remembering to invoke it, which is exactly what the system prompt injection
in `asSystemContext()` provides (`Memory/Hybrid/SkillStore.swift:121`). A Workflow would
only gate output that went through that workflow, and outbound text comes from everywhere.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `key.anthropic` | key | required | The gate is instructions to a model, so there must be a model. |

## Config keys read

| key | why |
|---|---|
| `grux.gates.rules_path` | The path to your own rules file. |
| `grux.model.provider` | Which provider the gate applies to. |
| `grux.model.chat_id` | Which model the gate applies to. |

## The blueprint itself

Two pieces: your rules file, and the skill that enforces it.

### The rules file

Plain markdown at `grux.gates.rules_path`. Each rule needs three things: what is banned,
what to do instead, and whether it is a hard stop or a preference. Rules without a
replacement produce text that is merely shorter, not better.

```markdown
# Output rules
Applies to: email, social posts, product copy, support replies.
Does not apply to: code, code comments, commit messages, internal notes.

## Hard stops
Never use an em dash or an en dash. Use a comma, a colon, or a full stop, or split the
sentence.

Never write out a currency amount in words. Write $50, never fifty dollars.

Never write a clock time in 24 hour form. Write 7:30 PM, never 19:30.

Never use kilometres or metres for a distance a reader will act on. Use miles, and feet
below a tenth of a mile.

Never name a customer, a partner, or a private address in public copy.

## Preferences
Prefer the shorter sentence. If a sentence has two clauses joined by "and", check whether
it should be two sentences.

Prefer the concrete noun. "The report" beats "the deliverable".

Avoid: leverage, utilise, synergy, seamless, robust, game changing, unlock, empower.

Do not open with "I hope this finds you well" or any variant.
```

The split between hard stops and preferences is what makes the gate usable. A gate where
everything is a hard stop gets switched off within a week.

### The skill

Install as `~/Library/Application Support/Grux/skills/output-gates/SKILL.md`, then run
`SkillStore.importFromFolders()` from Settings
(`Memory/Hybrid/SkillStore.swift:218`, `Memory/Hybrid/SkillFolderBackend.swift:130`).
Front matter is `name`, `trigger`, `updatedAt`
(`Memory/Hybrid/SkillFolderBackend.swift:158-170`), and `trigger` must stay on one line.

```markdown
---
name: output-gates
trigger: Before you send, publish, post, or hand over any text that another person will read. Emails, social posts, product copy, support replies, App Store text, anything outbound.
updatedAt: 2026-08-09T00:00:00Z
---

Read <your-rules-path> before writing outbound text, and check the finished text against
it before handing it over. Fix every hard-stop violation yourself, silently, by rewriting
the sentence rather than deleting the idea. Never hand over text with a known violation
still in it plus a note saying so.

For preferences, apply them where they improve the sentence and leave them where they do
not. A preference you apply mechanically makes worse copy than one you ignore.

After the text, print a two-line gate report and nothing more:

  Gates: N hard stops fixed, M preferences applied.
  Left alone: <the preferences you deliberately did not apply, and why, in one clause each>

Rules for the gate itself:

1. The gate applies to outbound text only. Do not apply it to code, code comments, commit
   messages, file paths, quoted material, or anything the rules file excludes. Rewriting a
   quote to fit house style is misquoting someone.
2. When a hard stop and the meaning conflict, keep the meaning and say which rule you had
   to break and why. A gate that silently mangles a sentence to satisfy a rule is worse
   than the violation.
3. When the rules file is missing or unreadable, say so once and carry on without gating.
   Do not invent house rules from what you think the person would want.
4. Never claim a gate ran that did not run. If you did not read the file, the report says
   "Gates: not run, rules file not read."
```

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing this exact string.

- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."

`grux.gates.rules_path` has no capability of its own, because it points at a file you write
rather than a service Grux connects to. With no rules file, the skill's own fourth rule
takes over: it says once that the file is missing and gates nothing, rather than inventing
house style. Silent invented rules would be the worst outcome here, since you would not
know which of your sentences had been rewritten or why.

## Example, not a default

```
Example, not a default

The owner of Grux runs a rules file whose first hard stop is a total ban on em dashes and
en dashes across every surface. The instructive part is not the rule, it is that the rule
is his and lives in a file. A stranger installing this gets the mechanism and writes their
own list, which might ban the Oxford comma, or require British spelling, or forbid
exclamation marks. Same gate, different file.

Rules file, ~/grux/output-rules.md, hard stops section:

  Never use an em dash or an en dash.
  Write $50, never fifty dollars.
  Write 7:30 PM, never 19:30.
  Never open with "I hope this finds you well".

Draft before the gate:

  I hope this finds you well. Just circling back on the invoice for forty-five dollars,
  and we can hop on a call at 15:30 if that is easier.

After the gate:

  Following up on the invoice for $45. I can take a call at 3:30 PM if that is easier.

  Gates: 3 hard stops fixed, 1 preference applied.
  Left alone: kept "if that is easier", it softens the ask and cutting it would make the
  line read as a summons.
```

## Honest limitations

- **A skill is an instruction, not a filter.** Nothing sits between the model and the
  outbound text. If the model does not apply the gate, the text goes out ungated and the
  only signal is a missing gate report. Anyone treating this as compliance tooling is
  treating a suggestion as a guarantee.
- **Only the first 400 characters reliably reach the system prompt**
  (`Memory/Hybrid/SkillStore.swift:130`), and only the 12 most-used skills are injected at
  all (`:129`). The procedure above front-loads the read-the-file instruction for that
  reason. A longer, more nuanced gate will be quietly truncated.
- **The gate report is easy to fake.** A model can print "Gates: 3 hard stops fixed"
  without having read the file. Rule 4 addresses this by naming the honest alternative, and
  a model that would fabricate the report would fabricate that too. Spot check it.
- **Hard stops applied mechanically produce stiff copy.** Banning a punctuation mark
  changes rhythm, and the replacement is not always as good. Rule 2 exists so meaning wins,
  which means the gate will sometimes report a rule it declined to enforce.
- **It cannot see what it is not shown.** Text you write yourself, paste from elsewhere, or
  produce in another application never passes through here.
- **Scope creep is the failure mode.** Every rule you add costs prompt space and adds a
  chance of a wrong rewrite. A rules file with 40 hard stops will make worse copy than one
  with 5.
- **No per-surface rules.** The file can name what it applies to, and the enforcement is
  the model reading that line, not a mechanism. An email rule and a social post rule live
  in the same file and are distinguished only by the model's judgement.
- **Quoting is the sharpest edge.** Rule 1 forbids rewriting quoted material, and a model
  that misses a quotation boundary will silently edit someone else's words into your house
  style. Read anything that contains a quote before you send it.
