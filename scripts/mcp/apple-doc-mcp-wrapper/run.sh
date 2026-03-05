#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/.runtime"
PKG_ROOT="$RUNTIME_DIR/package"
PKG_JSON="$PKG_ROOT/package.json"
PACKAGE_VERSION="${APPLE_DOC_MCP_VERSION:-1.9.1}"
INSTALL_STAMP="$RUNTIME_DIR/.installed_${PACKAGE_VERSION}"
TARGET_HTTP_CLIENT="$PKG_ROOT/node_modules/apple-doc-mcp-server/dist/apple-client/http-client.js"
PATCH_MARKER="// xmnote-wrapper: fetch-http-client"

prepare_runtime() {
    mkdir -p "$PKG_ROOT"

    if [[ ! -f "$PKG_JSON" ]]; then
        cat > "$PKG_JSON" <<EOF
{
  "name": "apple-doc-mcp-wrapper-runtime",
  "private": true,
  "description": "Runtime package for XMNote apple-doc-mcp wrapper",
  "dependencies": {
    "apple-doc-mcp-server": "${PACKAGE_VERSION}"
  }
}
EOF
    fi

    if [[ ! -f "$INSTALL_STAMP" || ! -f "$TARGET_HTTP_CLIENT" ]]; then
        npm --prefix "$PKG_ROOT" install --silent --no-audit --no-fund
        rm -f "$RUNTIME_DIR"/.installed_*
        touch "$INSTALL_STAMP"
    fi

    patch_http_client
}

patch_http_client() {
    if [[ ! -f "$TARGET_HTTP_CLIENT" ]]; then
        echo "apple-doc-mcp wrapper: missing target file: $TARGET_HTTP_CLIENT" >&2
        exit 1
    fi

    if grep -Fq "$PATCH_MARKER" "$TARGET_HTTP_CLIENT"; then
        return
    fi

    cat > "$TARGET_HTTP_CLIENT" <<'EOF'
import { MemoryCache } from './cache/memory-cache.js';
const baseUrl = 'https://developer.apple.com/tutorials/data';
const headers = {
    dnt: '1',
    referer: 'https://developer.apple.com/documentation',
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
};
const requestTimeoutMs = 15_000;
const maxAttempts = 3;
const sameUrlRedirectStatus = new Set([301, 302, 307, 308]);
const createTimeoutSignal = (timeoutMs) => {
    if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
        return AbortSignal.timeout(timeoutMs);
    }
    const controller = new AbortController();
    setTimeout(() => controller.abort(), timeoutMs).unref?.();
    return controller.signal;
};
const fetchJson = async (url) => {
    const response = await fetch(url, {
        headers,
        redirect: 'manual',
        signal: createTimeoutSignal(requestTimeoutMs),
    });
    const location = response.headers.get('location');
    if (location && sameUrlRedirectStatus.has(response.status)) {
        const resolved = new URL(location, url).toString();
        if (resolved === url) {
            const retry = await fetch(url, {
                headers,
                redirect: 'error',
                signal: createTimeoutSignal(requestTimeoutMs),
            });
            if (!retry.ok) {
                throw new Error(`HTTP ${retry.status} when fetching ${url}`);
            }
            return await retry.json();
        }
    }
    if (!response.ok) {
        throw new Error(`HTTP ${response.status} when fetching ${url}`);
    }
    return await response.json();
};
// xmnote-wrapper: fetch-http-client
export class HttpClient {
    cache;
    constructor() {
        this.cache = new MemoryCache();
    }
    async makeRequest(path) {
        const url = `${baseUrl}/${path}`;
        const cached = this.cache.get(url);
        if (cached) {
            return cached;
        }
        let lastError;
        for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
            try {
                const data = await fetchJson(url);
                this.cache.set(url, data);
                return data;
            }
            catch (error) {
                lastError = error;
                if (attempt < maxAttempts) {
                    await new Promise(resolve => setTimeout(resolve, 250 * attempt));
                    continue;
                }
            }
        }
        console.error(`Error fetching ${url}:`, lastError instanceof Error ? lastError.message : String(lastError));
        throw new Error(`Failed to fetch documentation: ${lastError instanceof Error ? lastError.message : String(lastError)}`);
    }
    async getDocumentation(path) {
        return this.makeRequest(`${path}.json`);
    }
    clearCache() {
        this.cache.clear();
    }
}
EOF
}

prepare_runtime

unset HTTP_PROXY HTTPS_PROXY ALL_PROXY
unset http_proxy https_proxy all_proxy
export NO_PROXY="developer.apple.com,${NO_PROXY:-}"

exec node "$PKG_ROOT/node_modules/apple-doc-mcp-server/dist/index.js"
