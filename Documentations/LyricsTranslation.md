# Lyrics Translation

Lyrics translation is an opt-in Labs feature that fills in translations for the lyric lines that lack one. It is off by default. Pick what translates them from Preferences > Lab > Lyrics translation > Translation:

- **System Translation** translates on this Mac with the system's Translation framework. It needs macOS 26 or later, costs nothing, and sends nothing anywhere.
- **AI (OpenAI-compatible)** sends lines to an OpenAI-compatible chat-completions endpoint you configure.

One engine runs at a time. Both translate into the target language set in the same box, zh-Hans when the field is left blank, and only lines without a translation in that language are translated; a translation that names no language counts as one. The target language is separate from the display language set in the same box: the target language decides which language is generated, while the display language decides which of the translations a file carries is shown in the desktop lyrics, the Apple Music-style window, the widget, and the iTunes export, and in the lyrics window when it is Chinese. Leaving the display language blank shows the translation that covers the most lines, ties going to the language code that sorts first; a line without that translation falls back to one that names no language.

Translations are saved with the lyrics. Lyrics embedded in a track, or read from a file beside it while writing back to that file is off, are saved to the lyrics library instead, and the translations are read back from that copy the next time the track plays, so those lines are not translated again.

Adding a translation does not change how the lyrics rank against other search results. LyricsKit ranks lyrics that come with a translation above lyrics that do not, which rewards a provider for supplying one; lyrics that LyricsX translated keep the rank they had before, so a better result that arrives during the priority window can still replace them.

## System Translation

System Translation only uses languages that are already downloaded to this Mac. When the lyrics need a pair of languages that is not, the status line in the Lab pane names the pair and a Download… button appears beside it; it brings up the system's own download prompt over the Settings window, and the lyrics are translated again once the download is done. Translation languages can also be managed in System Settings > General > Language & Region > Translation Languages.

The lyrics are translated from the language they were recognized as being in, so a song needs only that language and the target downloaded; a line in another language, such as the English line of a Japanese song, is translated along with the rest. A line that comes back exactly as it went — one already in the target language, or romanized lyrics the models cannot read — is not saved as a translation.

Some pairs are not supported by the framework at all, Traditional to Simplified Chinese among them on macOS 26.7; the status line says so. On macOS 26.4 and later the framework is asked for its high-fidelity strategy, which uses Apple Intelligence where it is available and falls back to the traditional models where it is not.

System Translation starts as soon as lyrics appear. If the automatic search replaces them while it runs, the result is discarded.

## AI translation

When AI translation is chosen, LyricsX sends eligible lyric lines to the configured OpenAI-compatible chat-completions endpoint. The endpoint receives lyric text, the configured prompt, model name, and source/target language information; it does not receive playback history or account credentials other than the API key required by that endpoint.

The API key is stored in the macOS Keychain and is bound to the endpoint's origin. It is sent only as a Bearer authorization header. LyricsX does not include API keys, request bodies, or response bodies in logs. Remote providers may retain submitted lyrics and may charge for requests; use only a provider and endpoint you trust. HTTPS is required except for loopback development endpoints.

The endpoint, model, and prompt are configured from Preferences > Lab > Lyrics translation > Configure….

Requests are split into batches of at most 24 lines and 32 KiB of source-line JSON. While an automatic search can still replace the lyrics on screen — during its priority window, five seconds by default — nothing is sent; translation starts once the window closes or the search ends. Transient network failures and HTTP 429/5xx responses receive up to three attempts with exponential backoff, and oversized or malformed batch responses are split into smaller requests, but one song never makes more than three requests per batch. Valid indexed translations are kept even when other lines are missing or malformed; failed lines remain untranslated and are reported in the Lab pane. A line the endpoint hands back unchanged — one already in the target language — is not saved as a translation, as with System Translation, and does not count as failed. When no line comes back at all, the lyrics and their file are left as they were, and the Lab pane says why — for example, the HTTP status the endpoint answered. A temporary Keychain access failure is retried and reported in the UI without disabling the feature or changing its persistent preference.

Requests to api.openai.com send their token limit as `max_completion_tokens`, which OpenAI's reasoning models require; every other endpoint receives `max_tokens`.

## Tests

To run the pure policy tests, use:

```sh
cd LyricsXPackage
swift test --filter LyricsXFoundationTests
```

The suite includes probes that run System Translation against the real Translation framework. Which of them run depends on the languages the Mac has downloaded: each covers one state, such as Japanese to Simplified Chinese being downloaded or not, and skips itself in any other.
