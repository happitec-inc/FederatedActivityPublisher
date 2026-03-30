#!/usr/bin/env bash
set -euo pipefail

# Configuration
STAGE="${STAGE:-stage}"
DOMAIN="${DOMAIN:-activity.happitec.com}"
TARGET_USER="${TARGET_USER:-test2}"
SOURCE_USER="${SOURCE_USER:-test1}"
REGION="${REGION:-ap-southeast-2}"
STACK_NAME="${STACK_NAME:-activity-happitec-${STAGE}}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

pass=0
fail=0
skip=0

log_pass() { echo -e "${GREEN}PASS${NC}: $1"; ((pass++)); }
log_fail() { echo -e "${RED}FAIL${NC}: $1"; ((fail++)); }
log_skip() { echo -e "${YELLOW}SKIP${NC}: $1"; ((skip++)); }

# Fetch the private key from SSM
echo "Fetching ${SOURCE_USER}'s private key from SSM..."
PRIVATE_KEY_PEM=$(aws ssm get-parameter \
    --name "/${STACK_NAME}/${SOURCE_USER}/private-key" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "${REGION}")

if [ -z "$PRIVATE_KEY_PEM" ]; then
    echo "ERROR: Could not fetch private key from SSM"
    exit 1
fi

# Write private key to temp file
KEY_FILE=$(mktemp)
echo "$PRIVATE_KEY_PEM" > "$KEY_FILE"
trap "rm -f $KEY_FILE" EXIT

INBOX_URL="https://${DOMAIN}/users/${TARGET_USER}/inbox"
SOURCE_ACTOR="https://${DOMAIN}/users/${SOURCE_USER}"
KEY_ID="${SOURCE_ACTOR}#main-key"

# HTTP Signature helper (Cavage draft)
sign_and_post() {
    local body="$1"
    local description="$2"

    local date
    date=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")

    local digest
    digest="sha-256=$(echo -n "$body" | openssl dgst -sha256 -binary | openssl base64)"

    local path="/users/${TARGET_USER}/inbox"
    local signing_string="(request-target): post ${path}
host: ${DOMAIN}
date: ${date}
digest: ${digest}"

    local signature
    signature=$(echo -n "$signing_string" | openssl dgst -sha256 -sign "$KEY_FILE" | openssl base64 -A)

    local sig_header="keyId=\"${KEY_ID}\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date digest\",signature=\"${signature}\""

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$INBOX_URL" \
        -H "Content-Type: application/activity+json" \
        -H "Host: ${DOMAIN}" \
        -H "Date: ${date}" \
        -H "Digest: ${digest}" \
        -H "Signature: ${sig_header}" \
        -d "$body")

    echo "$http_code"
}

# Generate a unique ID for each test
unique_id() {
    echo "https://${DOMAIN}/test/$(uuidgen | tr '[:upper:]' '[:lower:]')"
}

# --- Test: Like ---
echo ""
echo "=== Test: Like ==="
# First, we need a real status URI. Fetch one from the target user's outbox.
STATUS_URI=$(curl -s "https://${DOMAIN}/users/${TARGET_USER}/outbox?page=true" \
    -H "Accept: application/activity+json" | jq -r '.orderedItems[0].object.id // .orderedItems[0].object // empty' 2>/dev/null || echo "")

if [ -z "$STATUS_URI" ]; then
    log_skip "Like -- no statuses found for ${TARGET_USER}"
else
    LIKE_ID=$(unique_id)
    LIKE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${LIKE_ID}",
    "type": "Like",
    "actor": "${SOURCE_ACTOR}",
    "object": "${STATUS_URI}"
}
EOF
)
    HTTP_CODE=$(sign_and_post "$LIKE_BODY" "Like")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Like returned 202"
    else
        log_fail "Like returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Undo Like ---
echo ""
echo "=== Test: Undo Like ==="
if [ -z "$STATUS_URI" ]; then
    log_skip "Undo Like -- no statuses found"
else
    UNDO_LIKE_ID=$(unique_id)
    UNDO_LIKE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${UNDO_LIKE_ID}",
    "type": "Undo",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${LIKE_ID}",
        "type": "Like",
        "actor": "${SOURCE_ACTOR}",
        "object": "${STATUS_URI}"
    }
}
EOF
)
    HTTP_CODE=$(sign_and_post "$UNDO_LIKE_BODY" "Undo Like")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Undo Like returned 202"
    else
        log_fail "Undo Like returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Announce ---
echo ""
echo "=== Test: Announce ==="
if [ -z "$STATUS_URI" ]; then
    log_skip "Announce -- no statuses found"
else
    ANNOUNCE_ID=$(unique_id)
    ANNOUNCE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${ANNOUNCE_ID}",
    "type": "Announce",
    "actor": "${SOURCE_ACTOR}",
    "object": "${STATUS_URI}"
}
EOF
)
    HTTP_CODE=$(sign_and_post "$ANNOUNCE_BODY" "Announce")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Announce returned 202"
    else
        log_fail "Announce returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Undo Announce ---
echo ""
echo "=== Test: Undo Announce ==="
if [ -z "$STATUS_URI" ]; then
    log_skip "Undo Announce -- no statuses found"
else
    UNDO_ANNOUNCE_ID=$(unique_id)
    UNDO_ANNOUNCE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${UNDO_ANNOUNCE_ID}",
    "type": "Undo",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${ANNOUNCE_ID}",
        "type": "Announce",
        "actor": "${SOURCE_ACTOR}",
        "object": "${STATUS_URI}"
    }
}
EOF
)
    HTTP_CODE=$(sign_and_post "$UNDO_ANNOUNCE_BODY" "Undo Announce")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Undo Announce returned 202"
    else
        log_fail "Undo Announce returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Create (reply) ---
echo ""
echo "=== Test: Create (reply) ==="
if [ -z "$STATUS_URI" ]; then
    log_skip "Create reply -- no statuses found"
else
    REPLY_ID=$(unique_id)
    CREATE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "$(unique_id)",
    "type": "Create",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${REPLY_ID}",
        "type": "Note",
        "attributedTo": "${SOURCE_ACTOR}",
        "inReplyTo": "${STATUS_URI}",
        "content": "<p>This is a <strong>test</strong> reply from the smoke test script.</p>",
        "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
}
EOF
)
    HTTP_CODE=$(sign_and_post "$CREATE_BODY" "Create reply")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Create (reply) returned 202"
    else
        log_fail "Create (reply) returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Update (Note) ---
echo ""
echo "=== Test: Update (Note) ==="
if [ -z "$STATUS_URI" ] || [ -z "$REPLY_ID" ]; then
    log_skip "Update Note -- no reply to update"
else
    UPDATE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "$(unique_id)",
    "type": "Update",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${REPLY_ID}",
        "type": "Note",
        "attributedTo": "${SOURCE_ACTOR}",
        "inReplyTo": "${STATUS_URI}",
        "content": "<p>This is an <em>updated</em> reply.</p>",
        "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
}
EOF
)
    HTTP_CODE=$(sign_and_post "$UPDATE_BODY" "Update Note")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Update (Note) returned 202"
    else
        log_fail "Update (Note) returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Delete (reply) ---
echo ""
echo "=== Test: Delete (reply) ==="
if [ -z "$REPLY_ID" ]; then
    log_skip "Delete reply -- no reply to delete"
else
    DELETE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "$(unique_id)",
    "type": "Delete",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${REPLY_ID}",
        "type": "Tombstone"
    }
}
EOF
)
    HTTP_CODE=$(sign_and_post "$DELETE_BODY" "Delete reply")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Delete (reply) returned 202"
    else
        log_fail "Delete (reply) returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Actor mismatch (security) ---
echo ""
echo "=== Test: Actor mismatch (should be rejected) ==="
SPOOFED_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "$(unique_id)",
    "type": "Like",
    "actor": "https://evil.example.com/users/attacker",
    "object": "${STATUS_URI:-https://example.com/fake}"
}
EOF
)
HTTP_CODE=$(sign_and_post "$SPOOFED_BODY" "Spoofed actor")
if [ "$HTTP_CODE" = "403" ]; then
    log_pass "Spoofed actor rejected with 403"
elif [ "$HTTP_CODE" = "401" ]; then
    log_pass "Spoofed actor rejected with 401"
else
    log_fail "Spoofed actor returned $HTTP_CODE (expected 403)"
fi

# --- Test: Like -> Undo -> re-Like sequence ---
echo ""
echo "=== Test: Like -> Undo -> re-Like sequence ==="
if [ -z "$STATUS_URI" ]; then
    log_skip "Like sequence -- no statuses found"
else
    SEQ_LIKE_ID=$(unique_id)
    SEQ_LIKE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${SEQ_LIKE_ID}",
    "type": "Like",
    "actor": "${SOURCE_ACTOR}",
    "object": "${STATUS_URI}"
}
EOF
)
    HTTP_CODE=$(sign_and_post "$SEQ_LIKE_BODY" "Sequence Like 1")
    if [ "$HTTP_CODE" = "202" ]; then
        # Undo it
        SEQ_UNDO_ID=$(unique_id)
        SEQ_UNDO_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${SEQ_UNDO_ID}",
    "type": "Undo",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${SEQ_LIKE_ID}",
        "type": "Like",
        "actor": "${SOURCE_ACTOR}",
        "object": "${STATUS_URI}"
    }
}
EOF
)
        HTTP_CODE2=$(sign_and_post "$SEQ_UNDO_BODY" "Sequence Undo Like")
        # Re-Like
        SEQ_RELIKE_ID=$(unique_id)
        SEQ_RELIKE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${SEQ_RELIKE_ID}",
    "type": "Like",
    "actor": "${SOURCE_ACTOR}",
    "object": "${STATUS_URI}"
}
EOF
)
        HTTP_CODE3=$(sign_and_post "$SEQ_RELIKE_BODY" "Sequence Like 2")
        if [ "$HTTP_CODE2" = "202" ] && [ "$HTTP_CODE3" = "202" ]; then
            log_pass "Like -> Undo -> re-Like sequence all returned 202"
        else
            log_fail "Like -> Undo -> re-Like: Undo=$HTTP_CODE2 re-Like=$HTTP_CODE3"
        fi
    else
        log_fail "Like -> Undo -> re-Like: initial Like returned $HTTP_CODE"
    fi
fi

# --- Test: Concurrent likes from different actors ---
echo ""
echo "=== Test: Concurrent likes from different actors ==="
if [ -z "$STATUS_URI" ]; then
    log_skip "Concurrent likes -- no statuses found"
else
    # Simulate two likes arriving concurrently by running sign_and_post in background
    CONC_LIKE1_ID=$(unique_id)
    CONC_LIKE1_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${CONC_LIKE1_ID}",
    "type": "Like",
    "actor": "${SOURCE_ACTOR}",
    "object": "${STATUS_URI}"
}
EOF
)
    CONC_LIKE2_ID=$(unique_id)
    # Use a different fake actor URI to avoid dedup (same signing key, but the
    # actor mismatch check will reject it -- so we re-use SOURCE_ACTOR with a
    # different activity id to test concurrent DynamoDB writes)
    CONC_LIKE2_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${CONC_LIKE2_ID}",
    "type": "Like",
    "actor": "${SOURCE_ACTOR}",
    "object": "${STATUS_URI}"
}
EOF
)
    # Fire both requests concurrently
    sign_and_post "$CONC_LIKE1_BODY" "Concurrent Like 1" > /tmp/conc_like1.txt &
    PID1=$!
    sign_and_post "$CONC_LIKE2_BODY" "Concurrent Like 2" > /tmp/conc_like2.txt &
    PID2=$!
    wait $PID1 $PID2

    CONC_CODE1=$(cat /tmp/conc_like1.txt)
    CONC_CODE2=$(cat /tmp/conc_like2.txt)
    if [ "$CONC_CODE1" = "202" ] && [ "$CONC_CODE2" = "202" ]; then
        log_pass "Concurrent likes both returned 202 (second is idempotent duplicate)"
    else
        log_fail "Concurrent likes: code1=$CONC_CODE1 code2=$CONC_CODE2 (expected both 202)"
    fi
    rm -f /tmp/conc_like1.txt /tmp/conc_like2.txt
fi

# --- Summary ---
echo ""
echo "================================"
echo -e "Results: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}, ${YELLOW}${skip} skipped${NC}"
echo "================================"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
