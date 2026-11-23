# Standard: one Arabic search

**Rule.** Search text and queries go through `foldArabic` / `indexTokens` / `searchTokens` (`@ebda/foundation/text`); search boxes use `useLiveSearch` + `useListboxNav` + `highlightSegments` (`@ebda/foundation/web/search`): from 1 character, 150 ms debounce, the superseded request aborted, results only for the query in the box, ARIA combobox. A product keeps its own fetcher, list rendering and i18n strings. Behaviour is pinned by `vectors/arabic.json` (fold) and `vectors/arabic-search.json` (does query X find text Y).

**Fold.** أإآٱ to ا; ى ی ئ to ي; ؤ to و; ة to ه; Persian ک to ك; tashkeel, dagger alef and tatweel removed; ASCII upper to lower; Arabic-Indic and Persian digits to 0-9; whitespace collapsed. Known limits (pinned as `match:false` vectors): ئ and ؤ are not unified with ء, so `مسئول` does not find `مسؤول` and `حذاء` does not find `حذائي`.

**Ebda Chat migration (flag-gated, do not run before the foundation is re-vendored).**
1. Flag: the platform var `SEARCH_FOLD` (`'v2'` = on; unset or anything else = off, the default). Off: `normaliseText` builds and queries `contacts_fts` / `messages_fts` exactly as today.
2. State per workspace: `store_state.search_fold = 'v2'` marks a workspace whose indexes were built with `indexTokens`. Index writes (`indexContactName`, `indexMessage`) and query words (`/conversations?q`, `/search`, campaign contact search) all read that ONE marker (`searchFoldOf(sql)`), so index and query can never disagree.
3. Re-index: when a DO wakes and `env.SEARCH_FOLD === 'v2'` differs from its marker, `syncSearchFold` writes the marker and runs `rebuildFts` (contacts + messages) in ONE `transactionSync`: a workspace is never half-way, and a crash rolls both back. Cost: one pass over `contacts` and `messages.preview` of that workspace (the same pass a backup restore already does); a very large workspace pays it once, on first wake after the flip. No numbered DO migration (FTS5 content is derived data). If the controller prefers a numbered migration, it takes the next free version from the Chat registry.
4. Rollback = unset the flag: the next wake deletes the marker and rebuilds with `normaliseText`.
5. Verify per workspace after the flip: `SELECT value FROM store_state WHERE key='search_fold'` is `v2`; `count(*)` of `contacts_fts` equals contacts with a name; `سوال` finds `سؤال`; `كوتشي` finds `کوتشی`. Behaviour changes versus the old fold are listed in the Chat PR (no NFKC: presentation forms such as the lam-alef ligature U+FEFB no longer meet the typed letters).

sources: store ruling SEARCH-2, chat test/search-typeahead.test.ts, ruling FDN-SEARCH-1.
