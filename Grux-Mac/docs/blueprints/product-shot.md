# product-shot

## What it does

Takes a photo of a real product you own and puts it into a scene you describe, so you get a
usable hero image without a studio. The important part is that it keeps the actual product
intact: the label stays readable, the colour stays right, the shape does not drift into
something that looks like your product but is not.

## Host

**Workflows** (`CommandsV2`). It is a sequence with a mandatory human checkpoint: prepare
the composite, generate the scene, show you the result, and only save it as approved after
you say so. That checkpoint is `userApprovalGate`
(`CommandsV2/CommandV2Models.swift:170`), which only Workflows has.

## Capabilities required

| id | class | required | notes |
|---|---|---|---|
| `key.replicate` | key | required | The image generation provider. |
| `endpoint.media_service` | endpoint | required | An image service you run yourself, as the alternative to the hosted key. See CR-2: this is genuinely "one of these two", which the contract cannot express, so both are listed as required and one will always be over-asked. |

## Config keys read

| key | why |
|---|---|
| `grux.media.service_url` | Your own image service, when you run one. |
| `grux.cost.daily_ceiling_usd` | Image generation is the most expensive thing in this set per call. |
| `grux.cost.warn_at_fraction` | Warns before the ceiling. |

`grux.media.replicate_token` is a secret held in Keychain and resolved by the capability layer,
never read from the config file (contract 2.4).

## The blueprint itself

The pipeline is composite first, then edit. You put the real product photo onto a plain
canvas yourself, then ask the model to build the scene around it. Asking a model to
generate a product from a description instead is what produces a bottle with a label that
is almost your label, and that failure is silent: the image looks great until someone who
knows the product sees it.

| # | phase id | action | note |
|---|---|---|---|
| 1 | `check-inputs` | `shell` | Confirms the product photo exists and is readable. |
| 2 | `stash-check` | `setState` | |
| 3 | `gate-inputs` | `branch` | Missing photo ends the run with a clear message. |
| 4 | `missing` | `speak` | |
| 5 | `composite` | `shell` | Places the product on a neutral canvas at a known position. |
| 6 | `generate` | `claudeAgent` | Calls the image service with the composite plus the scene prompt. |
| 7 | `review` | `userApprovalGate` | You look at it before it counts as a product shot. |
| 8 | `keep` | `shell` | Moves the approved image into the approved folder. |

```json
{
  "id": "product-shot",
  "displayName": "product in a scene",
  "voiceTriggers": ["product shot", "put the product in a scene", "hero image"],
  "description": "Composite a real product photo into a generated scene, keeping the label and colour exact, with a review step before anything is kept.",
  "category": "develop",
  "parameters": [
    { "name": "product_photo", "kind": "freeText", "prompt": "Absolute path to the product photo, cut out on a plain background." },
    { "name": "scene", "kind": "freeText", "prompt": "Describe the scene. Surface, light, mood, what is around it." },
    { "name": "slug", "kind": "freeText", "prompt": "Short name for this shot, lowercase, no spaces." }
  ],
  "phases": [
    {
      "id": "check-inputs",
      "displayName": "Check the product photo",
      "userApprovalRequired": false,
      "action": {
        "kind": "shell",
        "captureOutput": true,
        "command": "p='${param.product_photo}'; if [ -f \"$p\" ] && sips -g pixelWidth \"$p\" >/dev/null 2>&1; then sips -g pixelWidth -g pixelHeight \"$p\" | tail -2 | tr '\\n' ' '; echo ok; else echo missing; fi"
      }
    },
    {
      "id": "stash-check",
      "displayName": "Stash the input check",
      "userApprovalRequired": false,
      "action": {
        "kind": "setState",
        "key": "input_check",
        "valueExpr": { "kind": "fromShellOutput" }
      }
    },
    {
      "id": "gate-inputs",
      "displayName": "Do we have a usable photo?",
      "userApprovalRequired": false,
      "action": {
        "kind": "branch",
        "condition": { "kind": "stateMatches", "key": "input_check", "regex": "ok" },
        "ifTrue": "composite",
        "ifFalse": "missing"
      }
    },
    {
      "id": "missing",
      "displayName": "No usable photo",
      "userApprovalRequired": false,
      "action": {
        "kind": "speak",
        "text": "I could not read a photo at ${param.product_photo}. Point me at a real image file, cut out on a plain background, and run it again.",
        "audioCueAfter": { "kind": "warningChime", "postSpeakDelay": 0.4 }
      }
    },
    {
      "id": "composite",
      "displayName": "Place the product on a neutral canvas",
      "userApprovalRequired": false,
      "action": {
        "kind": "shell",
        "captureOutput": true,
        "command": "w=\"$HOME/Library/Application Support/Grux/media/${param.slug}\"; mkdir -p \"$w\"; cp '${param.product_photo}' \"$w/product.png\"; sips -Z 1024 \"$w/product.png\" --out \"$w/product-1024.png\" >/dev/null 2>&1; echo \"$w/product-1024.png\""
      }
    },
    {
      "id": "generate",
      "displayName": "Generate the scene around the product",
      "userApprovalRequired": false,
      "action": {
        "kind": "claudeAgent",
        "tools": ["fs_read", "fs_write", "shell"],
        "systemPrompt": "Generate one product-in-scene image.\n\nProduct image, already prepared: ${state.last_shell_output}\nScene requested by the owner: ${param.scene}\nWorking folder: ~/Library/Application Support/Grux/media/${param.slug}/\n\nMethod, and it matters that you use this one:\n\n1. Send the prepared product image to the image service as the image to EDIT, with a prompt that describes only the scene around it. Do not describe the product. Do not name its brand, its label text, or its colour. The product is supplied as pixels precisely so the model does not have to imagine it.\n2. The scene prompt should specify surface, light direction, light quality, depth of field, camera height and mood, and should end with the instruction to leave the supplied product unchanged in shape, colour and label.\n3. Save the result as scene-01.png in the working folder. Generate at most 3 candidates, named scene-01 through scene-03, and stop. Never loop.\n4. Then compare each candidate against product-1024.png and write, for each, one honest sentence about whether the product survived: is the label still the same text, is the colour the same, has the silhouette changed. If a candidate altered the product, say so plainly, that candidate is a failure regardless of how good the scene looks.\n\nWhich service to call: if grux.media.service_url is configured, POST the composite and the scene prompt to it. Otherwise use the fal.ai key from the environment. Do not fall back to any other provider: an unpriced or more expensive fallback is how a small job becomes a large bill.\n\nWrite a short note to the working folder as notes.md carrying the scene prompt you actually sent, the service you used, the candidate count, and your product-fidelity verdict per candidate.\n\nNo em dashes, no en dashes. Write dollar amounts as $50. Finish with one line beginning 'SHOT: ' naming the best candidate and whether the product survived, under 150 characters.",
        "maxTokens": null
      }
    },
    {
      "id": "review",
      "displayName": "Look at it before keeping it",
      "userApprovalRequired": true,
      "action": {
        "kind": "userApprovalGate",
        "prompt": "${state.last_agent_output} Open the working folder and look at the candidates. Say keep to move the best one into approved, or discard to throw them away.",
        "expectedReplies": ["keep", "discard"]
      }
    },
    {
      "id": "keep",
      "displayName": "Keep the approved shot",
      "userApprovalRequired": false,
      "action": {
        "kind": "shell",
        "captureOutput": true,
        "command": "w=\"$HOME/Library/Application Support/Grux/media/${param.slug}\"; a=\"$HOME/Library/Application Support/Grux/media/approved\"; mkdir -p \"$a\"; cp \"$w/scene-01.png\" \"$a/${param.slug}.png\" && echo \"approved: $a/${param.slug}.png\""
      }
    }
  ]
}
```

Until CR-3 lands there is no on-disk install path for a workflow definition. Add the
equivalent `CommandV2Definition` to `CommandV2Definitions.swift` and list it in
`registerBuiltinDefinitions()` (`CommandsV2/CommandV2Engine.swift:102`), or call
`CommandV2Engine.register(_:)` at runtime (`CommandsV2/CommandV2Engine.swift:136`).

## What you see when it is not set up

The feature renders `needs-setup` with a setup card showing these exact strings.

- fal.ai API key: "Add a fal.ai key in Settings to generate images."
- Image generation service: "Point Grux at your image generation service in Settings, or use a hosted provider key instead."

The second remediation is the one that resolves the awkwardness: it says out loud that a
hosted key is an acceptable substitute for running your own service. Until CR-2 lands, the
setup card will list both even though satisfying either is enough, so read that card as
"one of these", not "both of these".

If you have hit `grux.cost.daily_ceiling_usd`, the feature is `degraded` with the note
"Paused for today. You have reached your $2.00 ceiling. Raise it in Settings or wait until
tomorrow." Image generation is the fastest way to reach that ceiling in this whole set.

## Example, not a default

```
Example, not a default

Parameters:

  product_photo  /Users/you/photos/widget-cutout.png
  scene          On a warm oak table by a window, late afternoon light from the left,
                 shallow depth of field, a linen cloth just out of focus behind it,
                 calm and unstaged.
  slug           widget-oak-window

Spoken result:

  SHOT: scene-02 is the best. Product survived: label text and colour match the source.

Working folder:

  ~/Library/Application Support/Grux/media/widget-oak-window/
    product.png
    product-1024.png
    scene-01.png
    scene-02.png
    scene-03.png
    notes.md

notes.md:

  Service: fal.ai
  Prompt sent: "Place the supplied product on a warm oak table beside a window, late
  afternoon light from the left, shallow depth of field, a linen cloth out of focus
  behind. Leave the supplied product unchanged in shape, colour and label."
  Candidates: 3

  scene-01  Product survived. Scene light is flatter than asked for.
  scene-02  Product survived. Best light. Recommended.
  scene-03  FAILED. The label text was redrawn and now reads differently. Discard.
```

That `scene-03` line is the reason this blueprint has a review gate. A model that redraws a
label produces an image that looks correct to everyone except the person who knows the
product, which is exactly the audience that matters.

## Honest limitations

- **The product will sometimes not survive, and you have to check every time.** Composite
  then edit dramatically reduces label drift compared with generating a product from a
  description, and it does not eliminate it. That is why the review gate is mandatory and
  why removing it turns this blueprint into a liability.
- **It costs real money per image, and per image costs vary by more than an order of
  magnitude between models.** Three candidates is three charges. Before wiring any
  provider in, price it from an actual settled charge, not from a pricing page, and never
  put an unpriced model in a fallback chain. A cheap primary with an expensive fallback is
  a trap: the moment the cheap lane fails, you are silently paying the expensive rate.
- **The prompt forbids falling through to another provider for exactly that reason.** If
  the configured service is down, this blueprint fails rather than quietly spending more.
  That is the correct behaviour and it will occasionally be inconvenient.
- **Your input photo does most of the work.** A product shot photographed badly, lit
  unevenly, or not cleanly cut out will produce a bad composite and no scene prompt will
  rescue it. Budget your effort on the source photo.
- **`sips` resizing is all the preparation this does.** There is no background removal, no
  colour correction, no shadow generation. If your photo needs cutting out, cut it out
  before you start.
- **The composite places the product at a fixed size and the service decides everything
  else.** There is no control over where in the frame the product lands, so composition is
  luck across candidates rather than a setting.
- **No usage rights are checked or claimed.** Whether the output can be used commercially
  depends entirely on the provider's terms and your input photo's rights. This blueprint
  neither knows nor asks.
- **`scene-01.png` is what the keep phase copies**, not the candidate the model recommended.
  If the model recommends `scene-02`, you have to move it yourself or edit the keep command.
  Automating "keep the one the model liked" would mean trusting the model's own fidelity
  verdict, which is the one judgement in this pipeline it is least qualified to make.
