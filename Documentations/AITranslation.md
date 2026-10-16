# AI Lyrics Translation

AI lyrics translation is an opt-in Labs feature. It is disabled by default. When enabled, LyricsX sends eligible lyric lines to the configured OpenAI-compatible chat-completions endpoint. The endpoint receives lyric text, the configured prompt, model name, and source/target language information; it does not receive playback history or account credentials other than the API key required by that endpoint.

The API key is stored in the macOS Keychain and is bound to the endpoint's origin. It is sent only as a Bearer authorization header. LyricsX does not include API keys, request bodies, or response bodies in logs. Remote providers may retain submitted lyrics and may charge for requests; use only a provider and endpoint you trust. HTTPS is required except for loopback development endpoints.

The endpoint, model, target language, and prompt are configured from Preferences > Lab > Lyrics translation. Translation is separate from the display-language preference: AI target language controls which language is generated, while the optional display-language preference selects which existing translation appears in the bilingual desktop overlay, HUD, and iTunes export. Leaving the display preference blank shows the AI target language when the file carries one, and otherwise falls back to the remaining translations in a fixed order, so the choice does not change between launches. The widget follows the same selected display language.

Requests are split into batches of at most 24 lines and 32 KiB of source-line JSON. Transient network failures and HTTP 429/5xx responses receive up to three attempts with exponential backoff. Oversized or malformed batch responses are split into smaller requests where possible. Valid indexed translations are retained even when other lines are missing or malformed; failed lines remain untranslated and are reported in the Lab pane. A temporary Keychain access failure is retried and reported in the UI without disabling the feature or changing its persistent preference.

To run the pure policy tests, use:

```sh
cd LyricsXPackage
swift test --filter LyricsXFoundationTests
```
