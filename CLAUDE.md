@AGENTS.md

## Where things live

- `ios/Zorja/`: the SwiftUI app. Tests in `ios/ZorjaTests/`.
- `backend/src/`: the Python API and collector. Tests in `backend/tests/`, tooling in `backend/tools/`.
- `api/openapi.json` and `api/examples/`: the frozen v1 contract.
- `docs/`: product, model, API, hosting and decisions.
- `site/`: the zorja.app website.
- `_private/` (local only, never committed): the build plan with Figma node links, the store listing, research and archived records. See `_private/README.md`; read it only when the task needs it.

## Keeping sessions lean

Every step re-sends the whole conversation, so context size is the main cost.

- Search before reading, and read only the part of a file you need.
- Images stay in context for the rest of the session. Check Figma with `get_metadata` or layer data while working, and take one screenshot to confirm at the end, not one after every change. Same for simulator screenshots.
- Run long visual check loops and broad searches in a subagent, so their images and output stay out of this conversation.
- When a task is done, say so and suggest a new session instead of starting the next task here.
