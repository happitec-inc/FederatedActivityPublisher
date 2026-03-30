# Content Processing

How inbound and outbound HTML content is sanitized and transformed.

## Overview

ActivityPub content is exchanged as HTML fragments. FederatedActivityPublisher processes HTML in both directions: sanitizing inbound content received from remote servers, and converting plain text to HTML when local actors create posts.

### Inbound Sanitization

When a remote server sends a Create activity containing a Note, the HTML content may include arbitrary markup, scripts, or tracking elements. ``HTMLSanitizer`` strips the content down to a safe subset of tags and attributes, removing anything that could be used for cross-site scripting or tracking. The sanitized HTML is stored in DynamoDB and served both through the federation API and the server-rendered profile pages.

### Outbound Text-to-HTML Conversion

When a local actor posts through the client API, the content arrives as plain text. The ``convertTextToHTML(_:)`` function transforms this into valid HTML, handling paragraph breaks, linkifying URLs, and converting @-mentions and #-hashtags into proper links. The resulting HTML is what gets included in the ActivityPub Note object and delivered to followers.

### Profile Field Formatting

Profile metadata fields (key-value pairs displayed on an actor's profile) also go through HTML processing. ``formatFieldValueForActivityPub(_:)`` ensures field values are safe HTML for federation, while ``formatFieldValueForAPI(_:)`` strips markup for the client API response. The ``parseProfileFields(_:)`` and ``encodeProfileFields(_:)`` functions handle serialization of ``ProfileField`` arrays to and from the JSON stored in DynamoDB.
