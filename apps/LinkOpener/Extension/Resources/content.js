// Sends x.com / twitter.com pages to the NeoFreeBird app (twitter://).
(function () {
    if (window.top !== window) {
        return;
    }

    // Paths that are not user names.
    const reserved = new Set(["i", "search", "explore", "settings", "notifications", "messages",
        "compose", "login", "logout", "signup", "tos", "privacy", "intent", "share", "account",
        "about", "home", "hashtag", "jobs", "lists", "communities", "bookmarks", "download"]);

    function target(url) {
        const parts = url.pathname.split("/").filter(Boolean);
        if (parts.length === 0 || parts[0] === "home") {
            return "twitter://timeline";
        }
        // /name/status/123, /i/web/status/123, /name/status/123/photo/1 ...
        const at = parts.indexOf("status");
        if (at >= 0 && /^\d+$/.test(parts[at + 1] || "")) {
            return "twitter://status?id=" + parts[at + 1];
        }
        if (parts[0] === "hashtag" && parts[1]) {
            return "twitter://search?query=" + encodeURIComponent("#" + parts[1]);
        }
        if (parts[0] === "search") {
            const q = url.searchParams.get("q");
            return q ? "twitter://search?query=" + encodeURIComponent(q) : null;
        }
        if (parts.length <= 2 && !reserved.has(parts[0].toLowerCase()) && /^[A-Za-z0-9_]{1,15}$/.test(parts[0])) {
            return "twitter://user?screen_name=" + parts[0];
        }
        return null;
    }

    let sent = null;
    function go() {
        const to = target(new URL(window.location.href));
        if (to && to !== sent) {
            sent = to;
            window.location.href = to;
        }
    }

    go();
    // x.com changes pages without reloading.
    let seen = window.location.href;
    setInterval(function () {
        if (window.location.href !== seen) {
            seen = window.location.href;
            go();
        }
    }, 400);
})();
