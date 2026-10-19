# AI Lyrics Translation

AI lyrics translation is an opt-in Labs feature. It is disabled by default. When enabled, LyricsX sends eligible lyric lines to the configured OpenAI-compatible chat-completions endpoint. The endpoint receives lyric text, the configured prompt, model name, and source/target language information; it does not receive playback history or account credentials other than the API key required by that endpoint.

The API key is stored in the macOS Keychain and is bound to the endpoint's origin. It is sent only as a Bearer authorization header. LyricsX does not include API keys, request bodies, or response bodies in logs. Remote providers may retain submitted lyrics and may charge for requests; use only a provider and endpoint you trust. HTTPS is required except for loopback development endpoints.

The endpoint, model, target language, and prompt are configured from Preferences > Lab > Lyrics translation > Configure…. The target language is separate from the display language set in the same box: the target language decides which language is generated, while the display language decides which of the translations a file carries is shown in the desktop lyrics, the Apple Music-style window, the widget, and the iTunes export, and in the lyrics window when it is Chinese. Leaving the display language blank shows the translation that covers the most lines, ties going to the language code that sorts first; a line without that translation falls back to one that names no language.

Requests are split into batches of at most 24 lines and 32 KiB of source-line JSON. While an automatic search can still replace the lyrics on screen — during its priority window, five seconds by default — nothing is sent; translation starts once the window closes or the search ends. Transient network failures and HTTP 429/5xx responses receive up to three attempts with exponential backoff, and oversized or malformed batch responses are split into smaller requests, but one song never makes more than three requests per batch. Valid indexed translations are kept even when other lines are missing or malformed; failed lines remain untranslated and are reported in the Lab pane. When no line comes back at all, the lyrics and their file are left as they were, and the Lab pane says why — for example, the HTTP status the endpoint answered. A temporary Keychain access failure is retried and reported in the UI without disabling the feature or changing its persistent preference.

Requests to api.openai.com send their token limit as `max_completion_tokens`, which OpenAI's reasoning models require; every other endpoint receives `max_tokens`.

Translations are saved with the lyrics. Lyrics embedded in a track, or read from a file beside it while writing back to that file is off, are saved to the lyrics library instead, and the translations are read back from that copy the next time the track plays, so those lines are not sent again.

To run the pure policy tests, use:

```sh
cd LyricsXPackage
swift test --filter LyricsXFoundationTests
```
