import AWSLambdaEvents
import AWSLambdaRuntime
import AWSSSM
import ActivityPubCore
import Elementary
import Foundation

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}
let ssmKeyPrefixRaw = ProcessInfo.processInfo.environment["SSM_KEY_PREFIX"] ?? "/activity/stage/keys/"
let ssmKeyPrefix = ssmKeyPrefixRaw.hasSuffix("/") ? String(ssmKeyPrefixRaw.dropLast()) : ssmKeyPrefixRaw

let ssmClient = try await SSMClient()

/// Cached signing key
nonisolated(unsafe) var cachedSigningKey: String?

func getSigningKey() async throws -> String {
    if let key = cachedSigningKey { return key }
    let output = try await ssmClient.getParameter(input: .init(
        name: "\(ssmKeyPrefix)/session-signing-key",
        withDecryption: true
    ))
    guard let key = output.parameter?.value else {
        fatalError("Session signing key not configured")
    }
    cachedSigningKey = key
    return key
}

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    do {
        let signingKey = try await getSigningKey()
        let cookies = event.headers["cookie"] ?? event.headers["Cookie"] ?? ""

        guard let sessionJWT = extractCookie(name: "session", from: cookies) else {
            return redirectToLogin()
        }

        let claims: JWTSession.Claims
        do {
            claims = try JWTSession.verify(jwt: sessionJWT, key: signingKey, expectedIssuer: serverDomain)
        } catch {
            return redirectToLogin()
        }

        let csrfToken = JWTSession.csrfToken(signingKey: signingKey, sub: claims.sub, iat: claims.iat)
        let page = ComposePage(username: claims.sub, csrfToken: csrfToken, domain: serverDomain)
        let html = page.render()

        return APIGatewayResponse(
            statusCode: .ok,
            headers: [
                "content-type": "text/html; charset=utf-8",
                "cache-control": "no-store",
            ],
            body: html
        )
    } catch {
        context.logger.error("ComposeHandler error: \(error)")
        return redirectToLogin()
    }
}

func redirectToLogin() -> APIGatewayResponse {
    APIGatewayResponse(
        statusCode: .found,
        headers: ["location": "/auth/login"],
        body: nil
    )
}

try await runtime.run()

// MARK: - Compose Page

struct ComposePage: HTMLDocument {
    var username: String
    var csrfToken: String
    var domain: String

    var title: String { "Compose - Happitec" }
    var lang: String { "en" }

    var bodyAttributes: [HTMLAttribute<HTMLTag.body>] {
        [.class("latex-dark-auto")]
    }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        meta(.name("csrf-token"), .content(csrfToken))
        link(.rel("stylesheet"), .href("https://\(domain)/media/frontend/latex.min.css"))
        HTMLRaw("""
        <style>
            .compose-container { max-width: 600px; margin: 2rem auto; }
            .compose-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1.5rem; }
            .compose-header .user-info { font-size: 0.9rem; color: #666; }
            .compose-header a { color: inherit; }
            textarea { width: 100%; min-height: 150px; padding: 0.8rem; font-size: 1rem; font-family: inherit; border: 1px solid #ccc; border-radius: 4px; resize: vertical; box-sizing: border-box; }
            .char-count { text-align: right; font-size: 0.85rem; color: #666; margin-top: 0.3rem; }
            .char-count.over { color: #c00; font-weight: bold; }
            .form-group { margin-bottom: 1rem; }
            .form-group label { display: block; font-weight: bold; margin-bottom: 0.3rem; }
            .form-group input[type="text"] { width: 100%; padding: 0.5rem; font-size: 1rem; border: 1px solid #ccc; border-radius: 4px; box-sizing: border-box; }
            .form-group select { padding: 0.5rem; font-size: 1rem; border: 1px solid #ccc; border-radius: 4px; }
            .file-drop { border: 2px dashed #ccc; border-radius: 4px; padding: 1.5rem; text-align: center; cursor: pointer; margin-bottom: 0.5rem; }
            .file-drop.dragover { border-color: #333; background: #f0f0f0; }
            .file-drop input { display: none; }
            .image-preview { max-width: 100%; max-height: 200px; border-radius: 4px; margin-top: 0.5rem; }
            .image-preview-container { position: relative; display: inline-block; }
            .remove-image { position: absolute; top: 4px; right: 4px; background: rgba(0,0,0,0.6); color: white; border: none; border-radius: 50%; width: 24px; height: 24px; cursor: pointer; font-size: 14px; line-height: 24px; text-align: center; }
            .cw-toggle { cursor: pointer; font-size: 0.9rem; color: #666; margin-bottom: 0.5rem; display: inline-block; }
            .submit-btn { display: inline-block; padding: 0.7rem 2rem; font-size: 1rem; cursor: pointer; border: 1px solid #333; background: #333; color: #fff; border-radius: 4px; }
            .submit-btn:hover { background: #444; }
            .submit-btn:disabled { opacity: 0.5; cursor: not-allowed; }
            .status-msg { margin-top: 1rem; min-height: 1.5rem; }
            .error { color: #c00; }
            .success { color: #080; }
            .visibility-group { display: flex; gap: 1rem; flex-wrap: wrap; }
            .visibility-group label { font-weight: normal; display: flex; align-items: center; gap: 0.3rem; }
            @media (prefers-color-scheme: dark) {
                textarea { background: #1a1a1a; color: #ddd; border-color: #444; }
                .form-group input[type="text"] { background: #1a1a1a; color: #ddd; border-color: #444; }
                .form-group select { background: #1a1a1a; color: #ddd; border-color: #444; }
                .file-drop { border-color: #444; }
                .file-drop.dragover { border-color: #888; background: #2a2a2a; }
                .compose-header .user-info { color: #aaa; }
                .char-count { color: #aaa; }
                .submit-btn { background: #444; border-color: #555; }
                .submit-btn:hover { background: #555; }
            }
        </style>
        """)
    }

    var body: some HTML {
        article(.class("compose-container")) {
            header(.class("compose-header")) {
                h1 { "Compose" }
                span(.class("user-info")) {
                    "Signed in as "
                    strong { username }
                    " "
                    a(.href("/auth/login")) { "(sign out)" }
                }
            }

            HTMLRaw(#"<form id="compose-form" onsubmit="return false">"#)

            // Content warning toggle
            div(.class("form-group")) {
                span(.class("cw-toggle"), .id("cw-toggle")) { "Add content warning" }
                div(.id("cw-fields"), .style("display:none")) {
                    label(.for("spoiler-text")) { "Content warning" }
                    HTMLRaw(#"<input type="text" id="spoiler-text" name="spoiler_text" placeholder="Content warning text...">"#)
                }
            }

            // Text area
            div(.class("form-group")) {
                label(.for("status-text")) { "What's on your mind?" }
                HTMLRaw(#"<textarea id="status-text" name="status" maxlength="5000" placeholder="Write something..."></textarea>"#)
                div(.class("char-count"), .id("char-count")) { "0 / 5000" }
            }

            // Image upload
            div(.class("form-group")) {
                label { "Image (optional)" }
                div(.class("file-drop"), .id("file-drop")) {
                    "Drop an image here or click to select"
                    HTMLRaw(#"<input type="file" id="file-input" accept="image/*">"#)
                }
                div(.id("preview-container")) { "" }
                div(.id("alt-text-container"), .style("display:none")) {
                    label(.for("alt-text")) { "Alt text" }
                    HTMLRaw(#"<input type="text" id="alt-text" placeholder="Describe the image...">"#)
                }
            }

            // Visibility
            div(.class("form-group")) {
                label { "Visibility" }
                div(.class("visibility-group")) {
                    label { HTMLRaw(#"<input type="radio" name="visibility" value="public" checked>"#); "Public" }
                    label { HTMLRaw(#"<input type="radio" name="visibility" value="unlisted">"#); "Unlisted" }
                    label { HTMLRaw(#"<input type="radio" name="visibility" value="private">"#); "Followers only" }
                }
            }

            // Submit
            button(.class("submit-btn"), .id("post-btn")) { "Post" }

            p(.class("status-msg"), .id("status-msg")) { "" }

            HTMLRaw("</form>")
        }

        HTMLRaw("""
        <script>
        (function() {
            const csrf = document.querySelector('meta[name="csrf-token"]').content;
            const textarea = document.getElementById('status-text');
            const charCount = document.getElementById('char-count');
            const postBtn = document.getElementById('post-btn');
            const statusMsg = document.getElementById('status-msg');
            const fileDrop = document.getElementById('file-drop');
            const fileInput = document.getElementById('file-input');
            const previewContainer = document.getElementById('preview-container');
            const altTextContainer = document.getElementById('alt-text-container');
            const cwToggle = document.getElementById('cw-toggle');
            const cwFields = document.getElementById('cw-fields');

            let selectedFile = null;

            // Character count
            textarea.addEventListener('input', () => {
                const len = textarea.value.length;
                charCount.textContent = len + ' / 5000';
                charCount.className = len > 5000 ? 'char-count over' : 'char-count';
                postBtn.disabled = len > 5000;
            });

            // Content warning toggle
            cwToggle.addEventListener('click', () => {
                const showing = cwFields.style.display !== 'none';
                cwFields.style.display = showing ? 'none' : 'block';
                cwToggle.textContent = showing ? 'Add content warning' : 'Remove content warning';
            });

            // File drop
            fileDrop.addEventListener('click', () => fileInput.click());
            fileDrop.addEventListener('dragover', (e) => { e.preventDefault(); fileDrop.classList.add('dragover'); });
            fileDrop.addEventListener('dragleave', () => fileDrop.classList.remove('dragover'));
            fileDrop.addEventListener('drop', (e) => {
                e.preventDefault();
                fileDrop.classList.remove('dragover');
                if (e.dataTransfer.files.length) handleFile(e.dataTransfer.files[0]);
            });
            fileInput.addEventListener('change', () => {
                if (fileInput.files.length) handleFile(fileInput.files[0]);
            });

            function handleFile(file) {
                if (file.size > 5.5 * 1024 * 1024) {
                    statusMsg.textContent = 'Image too large (max 5.5 MB)';
                    statusMsg.className = 'status-msg error';
                    return;
                }
                selectedFile = file;
                const url = URL.createObjectURL(file);
                previewContainer.innerHTML = '<div class="image-preview-container"><img src="' + url + '" class="image-preview"><button class="remove-image" type="button">&times;</button></div>';
                previewContainer.querySelector('.remove-image').addEventListener('click', removeImage);
                altTextContainer.style.display = 'block';
                fileDrop.style.display = 'none';
            }

            function removeImage() {
                selectedFile = null;
                previewContainer.innerHTML = '';
                altTextContainer.style.display = 'none';
                fileDrop.style.display = 'block';
                fileInput.value = '';
            }

            // Post
            postBtn.addEventListener('click', async () => {
                const text = textarea.value.trim();
                if (!text) { statusMsg.textContent = 'Write something first'; statusMsg.className = 'status-msg error'; return; }
                if (text.length > 5000) return;

                postBtn.disabled = true;
                statusMsg.textContent = 'Posting...';
                statusMsg.className = 'status-msg';

                try {
                    let mediaId = null;

                    // Upload image first if selected
                    if (selectedFile) {
                        statusMsg.textContent = 'Uploading image...';
                        const formData = new FormData();
                        formData.append('file', selectedFile);
                        const altText = document.getElementById('alt-text').value;
                        if (altText) formData.append('description', altText);

                        const mediaResp = await fetch('/api/v2/media', {
                            method: 'POST',
                            headers: { 'X-CSRF-Token': csrf },
                            body: formData,
                            credentials: 'include'
                        });
                        if (!mediaResp.ok) {
                            const err = await mediaResp.json().catch(() => ({}));
                            throw new Error(err.error || 'Image upload failed');
                        }
                        const mediaData = await mediaResp.json();
                        mediaId = mediaData.id;
                    }

                    // Post status
                    statusMsg.textContent = 'Publishing...';
                    const visibility = document.querySelector('input[name="visibility"]:checked').value;
                    const spoilerText = cwFields.style.display !== 'none' ? document.getElementById('spoiler-text').value : '';

                    const body = { status: text, visibility: visibility };
                    if (mediaId) body.media_ids = [mediaId];
                    if (spoilerText) { body.spoiler_text = spoilerText; body.sensitive = true; }

                    const postResp = await fetch('/api/v1/statuses', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf },
                        body: JSON.stringify(body),
                        credentials: 'include'
                    });

                    if (!postResp.ok) {
                        const err = await postResp.json().catch(() => ({}));
                        throw new Error(err.error || 'Post failed');
                    }

                    const postData = await postResp.json();
                    statusMsg.innerHTML = 'Posted! <a href="' + postData.url + '">View post</a>';
                    statusMsg.className = 'status-msg success';
                    textarea.value = '';
                    charCount.textContent = '0 / 5000';
                    removeImage();
                } catch (e) {
                    statusMsg.textContent = e.message || 'Something went wrong';
                    statusMsg.className = 'status-msg error';
                    postBtn.disabled = false;
                }
            });
        })();
        </script>
        """)
    }
}
