---
name: playwright-search-fallback
description: >-
  Automatic fallback to Playwright browser search when WebSearch or WebFetch
  fails. Use when WebSearch returns zero or irrelevant results, errors, or times
  out, or when WebFetch fails. Triggers silently — do not tell the user a
  fallback is happening. Triggers on: WebSearch failure, WebFetch error, search
  timeout, no search results, irrelevant results, need to scrape web content.
---

# Playwright Search Fallback

When `WebSearch` returns 0/irrelevant results, errors, or times out — or `WebFetch` fails — automatically fall back to Playwright browser search **without telling the user**.

## Procedure

Spawn a sub-agent using the `Agent` tool (`subagent_type: "general-purpose"`) with these instructions:

```
You have access to Playwright MCP tools. Search for: <original query>

Step 1 - Navigate to Google:
  browser_navigate → https://www.google.com/search?q=<url-encoded query>&hl=en
  If a consent/cookie popup appears, dismiss it (click "Reject all" or "I agree" or close button).

Step 2 - Read results:
  browser_snapshot → read the search results page
  Identify the top 3–5 most relevant result links.

Step 3 - Scrape content:
  For each of the top 2–3 most relevant links:
    browser_navigate → open the link
    browser_snapshot → read the page content
    Skip pages that require login or show a paywall.

Step 4 - Cleanup:
  browser_close → always close the browser when done.

Step 5 - Return:
  Return ONLY information directly extracted from the scraped pages.
  - Quote or paraphrase content with the exact URL it came from.
  - Do NOT add, infer, or generate any information beyond what was found on the pages.
  - If nothing useful was found on any page, say so explicitly.
  - Every claim must be traceable to a specific source URL.

Error handling:
- Google CAPTCHA detected → switch to https://duckduckgo.com/?q=<query> instead
- Rate limiting → wait 3 seconds, retry once
- Page load fails → skip to the next result
- Browser not installed → call browser_install first, then retry
- Consent popups on result pages → detect from snapshot, click dismiss
```

For queries about recent events, append the current year to the search query.

## Output Rules
- Cite URLs for every claim
- Do not infer beyond scraped content
- Use `browser_snapshot` (not screenshot)
- Always `browser_close`
- Do not mention fallback to user
