# Standard: one Arabic search

**Rule.** Search text and queries go through `foldArabic` / `indexTokens` / `searchTokens` (`@ebda/foundation/text`); search boxes use `useLiveSearch` + `useListboxNav` + `highlightSegments` (`@ebda/foundation/web/search`): from 1 character, 150 ms debounce, the superseded request aborted, results only for the query in the box, ARIA combobox. A product keeps its own fetcher, list rendering and i18n strings. Behaviour is pinned by `vectors/arabic.json` (fold) and `vectors/arabic-search.json` (does query X find text Y).

**Fold.** أإآٱ to ا; ى ی ئ to ي; ؤ to و; ة to ه; Persian ک to ك; tashkeel, dagger alef and tatweel removed; ASCII upper to lower; Arabic-Indic and Persian digits to 0-9; whitespace collapsed. Known limits (pinned as `match:false` vectors): ئ and ؤ are not unified with ء, so `مسئول` does not find `مسؤول` and `حذاء` does not find `حذائي`.

**Ebda Chat migration (flag-gated, do not run before the foundation is re-vendored).**
1. Add `searchFold` (Chat feature flag, default off). Off: `normaliseText` builds and queries `contacts_fts` / `messages_fts` exactly as today.
2. On: index writes (`indexContactName`, `indexMessageText`) and query tokens (`/search`, campaign contact search, contacts screen) use `indexTokens` / `searchTokens`. Index and query MUST flip together per workspace, never one without the other.
3. Re-index = `rebuildContactIndex` + `rebuildMessageIndex` per workspace DO, triggered when the workspace's `searchFold` flips on (and recorded in `meta.search_fold = 'v2'`), batched (500 rows per DO tick) so one large workspace never blocks its alarm; the DO answers from the old index until its `meta.search_fold` equals the flag. No numbered DO migration is needed (FTS5 content is derived data and `messages_fts` is already rebuilt on restore); if the controller prefers one, it takes the next free version from the Chat registry. Rollback = flag off, re-run the same rebuild with `normaliseText`.
4. Verify per workspace after the flip: `SELECT count(*)` of `contacts_fts` equals contacts with a name; searches `مسؤول`, `شنطه`, `٠١٠` return the same rows as the Store rule in `vectors/arabic-search.json`.

sources: store ruling SEARCH-2, chat test/search-typeahead.test.ts, ruling FDN-SEARCH-1.
