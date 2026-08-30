# fact-grounding

## What it does

Stops the assistant from confidently making up facts about your own products. You give it a
file listing what you actually sell, what it costs, and what is in it. From then on, before
it states any price or specification, it has to look it up in your file, and after it
writes something it has to check its own claims back against that file and say which ones
it could not verify.

## Host

**Skills** (`Memory/Hybrid/SkillStore.swift`). This is a standing rule about how the
assistant should behave, not a sequence of steps to execute. A Skill is exactly that: a
named trigger plus a markdown procedure (`Memory/Hybrid/SkillStore.swift:14-21`), injected
into the stable system prompt by `asSystemContext()`
(`Memory/Hybrid/SkillStore.swift:121`) so every conversation sees it without anyone having
to remember to invoke it. Neither Schedules nor Workflows can do that, because both run
only when started.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `key.anthropic` | key | required | The skill is instructions to a model, so there must be a model. |

Nothing else. The catalog is a file on your own disk.

## Config keys read

| key | why |
|---|---|
| `grux.grounding.catalog_path` | The path to your own facts file. |
| `grux.model.provider` | Which provider the rule applies to. |
| `grux.model.chat_id` | Which model the rule applies to. |

## The blueprint itself

Two pieces: the catalog file you write, and the skill that points at it.

### The catalog file

Plain markdown at `grux.grounding.catalog_path`. One block per thing you sell. The format
matters less than the discipline of one canonical file, but this shape reads well both to a
person and to a model:

```markdown
# Catalog
Last verified: 2026-08-09

## widget-standard
Name: Acme Widget, Standard
Price: $24
Sizes: 3 inch, 5 inch
Materials: anodised aluminium, silicone gasket
In stock: yes
Claims we may make: dishwasher safe, 2 year warranty
Claims we may NOT make: waterproof (it is water resistant to IPX4, not waterproof)

## widget-pro
Name: Acme Widget, Pro
Price: $58
Sizes: 5 inch only
Materials: anodised aluminium, stainless steel core, silicone gasket
In stock: no, back 2026-09-15
Claims we may make: dishwasher safe, 5 year warranty, replaceable core
Claims we may NOT make: lifetime warranty
```

The `Claims we may NOT make` field is the one that earns its keep. A grounding file that
only lists true things still lets the assistant invent a plausible adjacent claim. Listing
the near-miss claims explicitly is what stops it.

### The skill

Install as `~/Library/Application Support/Grux/skills/fact-grounding/SKILL.md`, then run
`SkillStore.importFromFolders()` from Settings
(`Memory/Hybrid/SkillStore.swift:218`, `Memory/Hybrid/SkillFolderBackend.swift:130`).
The front matter shape is `name`, `trigger`, `updatedAt`
(`Memory/Hybrid/SkillFolderBackend.swift:158-170`); `trigger` must stay on one line
because newlines in it are flattened on export.

```markdown
---
name: fact-grounding
trigger: Any time you are about to state a price, a size, a material, a stock status, a warranty term, or any other specific claim about something we sell.
updatedAt: 2026-08-09T00:00:00Z
---

Never state a product fact from memory. Read <your-catalog-path> first, quote the value
from it, and if the value is not in there, say "I do not have that in the catalog" instead
of producing a number. This applies to prices, sizes, materials, stock, warranty terms and
delivery times, in every surface: chat, drafts, emails, captions, listings.

After you write anything containing a product claim, audit it before you hand it over:

1. List every specific claim you made, one per line.
2. Beside each, write the catalog line it came from, or write UNVERIFIED.
3. If anything is UNVERIFIED, remove it from the text or replace it with the catalog value.
   Do not hand over text with an unverified claim still in it and a note underneath.
4. Check each claim against the `Claims we may NOT make` field for that item. A claim
   listed there is a hard stop, not a judgement call, even when it feels true.
5. End your reply with one line: "Grounded against catalog, last verified <date from the
   catalog header>." If the catalog is more than 30 days old, say so in that line.

When the catalog and something you believe disagree, the catalog wins and you say the
disagreement out loud. When the catalog is missing or unreadable, say that plainly and
refuse to state product facts for the rest of the conversation rather than falling back on
memory.
```

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing this exact string.

- Anthropic API key: "Add your Anthropic API key in Settings to let Grux think. Get one at console.anthropic.com."

`grux.grounding.catalog_path` has no capability of its own in the contract, because it is a
path to a file you write rather than something Grux connects to. With the key present and
the path unset, the skill installs and its final instruction takes over: the assistant says
the catalog is missing and declines to state product facts. That is the correct degraded
behaviour and it is louder than a warning, which is the point.

## Example, not a default

```
Example, not a default

The owner of Grux runs this against a catalog of ten consumer products, seeded from a
Swift file that used to hardcode the same data inside the app. That is the instructive
part: the data was in the binary, where a stranger inherits someone else's product line.
Moving it to a file at a configured path is what turns a personal feature into a general
one. The contents below are sample data, not his.

Catalog, ~/grux/catalog.md:

  # Catalog
  Last verified: 2026-08-09

  ## widget-standard
  Name: Acme Widget, Standard
  Price: $24
  In stock: yes
  Claims we may NOT make: waterproof

Asked to write a product caption, before the skill:

  "The Acme Widget is $19, fully waterproof, and ships same day."

After the skill:

  "The Acme Widget, Standard is $24 and water resistant to IPX4."

  Claims audit
  $24                    catalog: widget-standard, Price
  water resistant IPX4   catalog: widget-standard, Claims we may NOT make (waterproof
                         was requested and refused)
  same day shipping      UNVERIFIED, removed

  Grounded against catalog, last verified 2026-08-09.
```

## Honest limitations

- **The first 400 characters are the whole skill in practice.** `asSystemContext()`
  truncates each procedure at 400 characters when building the system prompt
  (`Memory/Hybrid/SkillStore.swift:130`), and only the 12 most-used skills are included at
  all (`:129`). The full text is available on demand through `list_skills`, but the model
  has to choose to ask. That is why the procedure above front-loads the entire rule into
  the first paragraph and puts the audit steps after it. If you rewrite it, keep the
  non-negotiable part first.
- **It is an instruction, not an enforcement mechanism.** Nothing intercepts the output and
  checks it. A model that ignores the skill produces an ungrounded claim and there is no
  gate that catches it. This meaningfully reduces invented facts, it does not make them
  impossible.
- **A stale catalog is worse than no catalog**, because it grounds confidently in a wrong
  number. The `Last verified` line and the 30 day rule exist to make staleness visible, and
  they depend on you editing that date honestly.
- **It cannot verify the catalog.** If you write `$24` and the real price is `$29`, the
  assistant will defend `$24` and cite you as the source.
- **Skills compete for space.** The store caps at 200 skills
  (`Memory/Hybrid/SkillStore.swift:44`) and only 12 reach the system prompt, ranked by
  usage count then recency (`:123-126`). A skill you install and never trigger can be
  pushed out of the prompt by chattier ones.
- **The audit step doubles the length of every product answer.** That is a real cost in
  readability, and for casual questions it is annoying. There is no "audit only when it
  matters" setting, because the model deciding when it matters is the failure mode.
- **One catalog, one path.** There is no per-brand or per-project scoping, so if you sell
  under two names you need two skills with two triggers, or one catalog with a clear
  section per brand.
