# Decision parts, images and `box`

*2026-11-10. Agreed design. Decision state and question instructions are lists of content parts, which fixed OpenAI Decisions rejecting list states and gives images and System One's `box` question a place to go. Three phases: phase 1 (parts and `Content.Data`) landed for v2.0; phases 2 (images) and 3 (`box`) are additive and planned for v2.1, with some questions left until that work starts. Host behaviour is from each host's docs as read on 2026-11-10, none of it verified live unless said.*

## Why

- **The OpenAI bug.** The OpenAI Decisions dialect sends any map or list state as one `input_json` part, but `input_json.data` must be an object or an array of objects. Confirmed live 2026-11-10: `["Charged twice for order 1234", "Wants the money back"]` gets a 400 (`Invalid type for 'input[0].content[0].data[0]': expected an object ...`); a list of maps works.
- **Images need a place.** Hosts disagree on where an image sits in a decision (see [Images by host](#images-by-host)). The one placement every host can carry is "an image is a top-level item of the input": OpenAI parts, TypeSafe/OpenRouter refs, Ollama/Venice's `images` list. OpenRouter uses the same rule for its own cross-host mapping.
- Today `state` and `instructions` are any JSON-like term, so each dialect decides what a list means, which is how the bug happened. A list of typed parts gives a list one meaning everywhere.

## Phase 1: parts and `Content.Data` (v2.0, landed)

Landed 2026-11-10 and live-checked on OpenAI. State and instructions are lists of `Content.Text` and `Content.Data` parts; the design as built is in `design.md` (Content blocks summary; Decisions: Data, Validation, Encoding). Phases 2 and 3 build on it.

## Phase 2: images (v2.1)

### Settled

- An image is a `%Content.Attachment{}` part in the state or in instructions. No image inside a `Data` part (it can't be built: `Data.new/1` raises on it).
- **TypeSafe, OpenRouter:** a top-level `assets` map, each attachment a ref derived from a hash of its content (one image used twice is one asset, referenced twice; request bodies stay stable for tests and caching).
- **OpenAI:** `input_image` parts in the state message and in instructions. Base64 becomes a data URL; a URL attachment is sent as its URL (OpenAI accepts https).
- Omni never fetches a URL on the user's behalf.
- `handle_body/3` keeps its signature; no validation step is added to dialects.

### A consideration, not a rule

When a part has no faithful encoding on a host (a URL image to a base64-only host, an image in instructions on Ollama, `box` on OpenAI), a text dialect would silently drop it. For a decision that is worse than for text: a text model can say it sees no image, a decision model just returns a confident probability. Raising (an `ArgumentError` saying what can't be sent) was suggested over dropping. Weigh it per case when phase 2 is built; parts the host can reject itself (a PDF to TypeSafe, `box` to a non-Jev host) can simply be encoded and left to its 400.

### Left for phase 2

1. **Ollama (and Venice).** A System One compat flag for the `images` list, e.g. `image_format: :images`, shipping with the `:ollama` built-in. Image parts move out of the state into `images`. What happens to an image in instructions (Ollama's images are shared by every question).
2. **TypeSafe header.** `TypeSafe-Danger-Zone-Images: true` added automatically by the TypeSafe module's `modify_request/3` when the body has `assets` (or a `box` question), or left to the user. Leaning automatic: passing an image is the opt-in.
3. **Unwrapping on OpenRouter.** OpenRouter converts refs to `image_url` parts for non-Jev models only at top-level items of a list state; whether a state that is a bare ref string counts is unknown. Leaning: never unwrap a state holding an attachment.
4. **Model input check.** Whether to check `:image in model.input_modalities` before sending (leaning no, as on the text side). The TypeSafe module's listed models need `:image` input either way.
5. **Verify and fixtures.** A `decision_image` scenario for models with image input, using a small PNG or JPEG in the repo (TypeSafe needs each side 280–1568 px). Captures for TypeSafe, OpenAI, Ollama and OpenRouter; verify runs for OpenCode Zen's `jev-1.13` and NearAI, which are undocumented.

## Phase 3: `box` (v2.1)

### Settled

- `Question.Box{instructions}`, built with `Omni.box/1`; `Answer.Box{top, bottom, left, right, confidence}`, flat, fractions of the image (0–1), `confidence` may be `nil`, no probabilities (the one answer without them).
- Served by TypeSafe Jev 1.14 only (`jev-1.14.0`, `jev-latest` and `jev-preview` while they point there; OpenRouter's `typesafe/jev-1.14`). Other System One hosts answer it with a 400.

### Left for phase 3

1. Whether `Decision.validate/1` requires an attachment when a `box` question is asked (every host needs one). Leaning yes.
2. Verify: no catalog data says which models serve `box`, so a `decision_box` scenario run only when named, or a hard-coded model list. Leaning run-when-named.
3. Naming: `box` (wire name) or `bounding_box`. Leaning `box`.
4. What the OpenAI dialect does with a `Box` question (see the consideration above).

## Images by host

| Host | Wire | Position | Notes |
|---|---|---|---|
| TypeSafe | top-level `assets: %{ref => %{type: "image", format: "png" \| "jpg" \| "jpeg", data_base64}}` (or multipart, `part:` naming a file part) | anywhere: a ref string stands in for the image in `state` (any depth, whole string or inside text), `instructions`, or `criteria` | header `TypeSafe-Danger-Zone-Images: true`; "Dreamer-ready" (format may change between releases). Base64 only, PNG/JPEG only, each side 280–1568 px (rejected, not resized), 16 MiB per image, 32 MiB per request. Every asset must be referenced (else 400). Images bill as input tokens. Jev 1.13 and 1.14 |
| OpenRouter | TypeSafe's `assets` (no `part`, no header) | Jev: as TypeSafe. Other models: only a whole-string ref as a top-level item of a list state (becomes an `image_url` part); a ref inside text is a 400 | no limits documented |
| Ollama | top-level `images: [base64]` | none: shared by every question, in order | Cloud: ≤ 4 images, 4 MiB each, 8 MiB total. Vision model needed (Clef). No URLs or data URLs |
| Venice | top-level `images`, 1–4, each `data:image/(png\|jpeg);base64,...` or `%{content_type, base64}` | none | beta; not a decision built-in (awaiting catalog data) |
| Alibaba | not documented | — | |
| OpenAI Decisions | `input_image` parts `{image_url, detail?}` | parts of a user message (beside `input_text`, `input_json`); also in question `instructions` (`input_text`, `input_image` only) | data URL or public http(s) URL; no `file_id`, files or PDFs. No count or size limits documented |

`box` on the wire: request `{type: "box", instructions}` (no criteria; needs an image and the TypeSafe header); answer `{type: "box", box: %{top, bottom, left, right}, confidence}`, edges as fractions (top/bottom of height from the top, left/right of width from the left), one box per answer, no "not found" (pair with a predicate), no image index (the instructions pick the image).

## Not in these phases

**`%Context{}` as state** (deciding over a conversation). OpenAI's `input` takes user, developer, system and assistant messages; System One state is JSON, so a context would be serialised. Parts make it closer (message content and state share structs) but it needs its own design pass.
