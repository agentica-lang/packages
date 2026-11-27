## Agentica nodes that talk to each other, with a shared cookie. This first release has the wire format only (see
## docs/protocol.md): the kinds of the errors that a connection gives for bytes that break it.

import Types from "src/types"

export Types.PROTOCOL
export Types.TOO_LARGE
export Types.MAX_FRAME_BYTES
export Types.MAX_MAILBOX_BYTES
