# Federation Serialization

How actors and activities are serialized into ActivityPub JSON-LD for federation.

## Overview

ActivityPub is a JSON-LD based protocol. When remote servers request an actor profile or when the deliver Lambda sends activities to follower inboxes, the data must be serialized into the specific JSON-LD format that the fediverse expects. The serialization functions in `ActivityPubCore` handle this translation from the internal model types to spec-compliant JSON.

### Actor Serialization

``buildActorJSONLD(actor:serverDomain:handleDomain:)`` takes an ``Actor`` record and produces the full JSON-LD actor document that remote servers fetch via `GET /users/{username}`. This includes the actor's public key, inbox/outbox URLs, endpoints, profile fields as `attachment` objects, and the discoverable/indexable flags. The `handleDomain` parameter supports the domain consolidation strategy where handles use `happitec.com` but the server runs at `activity.happitec.com`.

### Status and Activity Serialization

``buildNoteJSON(status:serverDomain:username:)`` converts a ``Status`` into an ActivityPub Note object with the correct `id`, `attributedTo`, `content`, `published`, `to`/`cc` addressing, media attachments, and reply metadata. ``buildCreateActivityJSON(status:noteJSON:serverDomain:username:)`` wraps a Note in a Create activity, which is what actually gets delivered to follower inboxes.

### Addressing

``computeAddressing(visibility:serverDomain:username:)`` determines the `to` and `cc` arrays based on visibility level (public, unlisted, followers-only, or direct). Public posts address the ActivityStreams public collection; followers-only posts address the actor's followers collection; and the cc field is adjusted accordingly.
