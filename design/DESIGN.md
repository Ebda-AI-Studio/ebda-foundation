# Ebda design language v1

How to build any Ebda product (Store, Chat, CRM, ERP, accounts, marketing, help, docs, status). Source of truth is this repo:
tokens in `packages/foundation/src/tokens.ts` + `tokens.css`, guard rules in `src/guards.ts`, component specs in `design/components.md`,
logos in `packages/foundation/assets/brand/`. Products consume it (vendored by `ebda-foundation sync`, ruling FDN-VENDOR-1) and never fork it.
Merchant storefront themes are the one exception: each look keeps its own fonts and colours.

Derived from the 2026-11-11 Store admin audit and the storefront/Chat/shell audit (business/ebda/audits, local). Judged with impeccable
(Operate mode: scanability, consistency, native expectations; brand lives in precise details).

## Palette

Night `#0A0B0C` and Ebda gold `#B08D57` (lift `#CBA873`, cream `#FAF8F3`); brass and moon silver are metals and allowed (METAL-1). No orange, no blue
or violet chrome. Status roles: success, warning (brass, not amber), info, destructive, each as solid + 10% tint + an `-ink` text colour that passes 4.5:1 on its
tint (gold as text on light is `primary-ink`, never the raw gold: 3.1:1). Deep grounds with a light or metallic accent; never flat SaaS grey.

## Type (DS-FONT-1)

One family, IBM Plex Sans Arabic, for Arabic and Latin. Scale (px): 12 caption · 14 ui · 16 body · 18 title-sm · 20 title · 24 kpi · 30 display. Arabic leading (px):
20 / 24 / 28 / 30 / 32 / 36 / 44. Weights 400-600 in UI. 12px is for counters, badges and timestamps only, never the sole carrier of meaning. Tabular numerals come from
the face. Numbers and Latin runs inside Arabic stay LTR (`<bdi>` / `dir="ltr"`).

## Space, radius, size, elevation, motion

- Space (4px base): 4 · 8 · 12 · 16 · 24 · 32 · 48. Gutter 16 (phones) / 24 (lg). Card padding 16 lists / 24 forms.
- Radius: control 12 (buttons, inputs, selects, nav, tabs, chips) · surface 14 (cards, popovers, modals, sheets) · pill (status pills, avatars, switches).
- Control height: sm 32 · md 40 (44 on phones) · lg 44. Nav: sidebar 44, tab 40 (44 phones), rail 40, bottom bar 56. Every target is 44px on phones (sm gets a hit area).
- Elevation: 0 flat hairline (default) · 1 cards · 2 menus · 3 modals. No coloured shadows; border before shadow.
- Motion: 150ms colour/press, 200ms menus/tabs, 300ms sheets, one easing. Transform only for sheets and menus. Reduced motion removes slides.

## Arabic and RTL (non-negotiable)

RTL first, mirrored logically (`ms-/me-/ps-/pe-/start-/end-`, never `ml-/mr-/left-/right-`). Egyptian Arabic in full sentences, neutral short buttons, no emoji. Never negative
or positive letter-spacing on Arabic (breaks joining); never per-letter animation; slide and tab transitions mirror. Line-height from the table above, not the Latin default.
Check every borrowed rule against Arabic before adopting it.

### Signed numbers (SIGN-1, non-negotiable)

Points, money deltas, stock adjustments, refunds, discounts and percentage changes render through ONE formatter per product (ebda-store: `formatSigned` in `@ebda/shared/region`), never a hand-built `'-'`/`'+'` prefix.
- Zero never carries a sign: `-0`, `+0` and a value that rounds to zero (`-0.04` at one decimal) print plain `0`.
- The sign and the number are one unit: wrap in a bidi isolate (`<bdi dir="ltr">` in JSX, Unicode LRI...PDI in strings, emails and CSV) so Arabic never moves the minus to the far side ("N-").
- Minus is U+2212, not a hyphen. Plus shows only where the direction is the meaning (earned, credit).
- Where meaning matters, prefer a word to a sign ("owed", "refunded", "used"); the sign is the fallback, not the label.
- Guard: a product test fails on a hand-built sign prefix in UI source (ebda-store `tests/unit/signed-number-guard.test.ts`).

## Do

- One filled gold primary action per view, at the inline-end of the page header; secondary beside it; destructive never first.
- One active-state language in navigation: soft gold tint + `-ink` text (+ a 3px start bar in the sidebar).
- A plan-gated feature shows an upgrade card (what it unlocks, which plan, an upgrade button), a lock badge in the nav, never an error and never a retry.
- Every empty / loading / error / locked state is designed; a real crash keeps the shell and never prints a JS message.
- Icon-only buttons carry `aria-label` and the icon set (no glyph characters); every switch and input has a programmatic label.

## Don't

- No raw Tailwind palette colours, hex literals, `text-[Npx]`, bare `rounded`, `tracking-*`, hover translate on buttons.
- No second font family, no Latin-only face beside Arabic text.
- No stacked cards of chrome before content; no three navigation systems on one screen.

## References adopted

| Reference | Take                                                                                                                        | Reject                                                                 | Why                                                            |
| --------- | --------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------- |
| Shopify   | admin page shape (header, one primary action, resource list in a card), 8/12/16/24 density, status pill at the end of a row | cinematic black marketing track, thin display weights, black-pill CTAs | merchant-admin patterns fit; weight 330 is illegible in Arabic |
| Vercel    | hairline before shadow, flat default, square app controls vs pills on marketing, grey-text ladder, 12/16/24/32 rhythm       | negative tracking, mono eyebrows, mesh gradient                        | negative tracking breaks Arabic joining                        |
| Cursor    | warm neutral canvas, hierarchy by weight, 8/12/16 radii restraint                                                           | orange voltage, tight display tracking                                 | orange banned; tracking breaks Arabic                          |
| Apple     | few sizes with real jumps, 44px targets, 150-300ms motion with reduced-motion fallback, no chrome shadows                   | photography-first tiles, Action Blue, optical negative tracking        | blue and tracking conflict with brand and Arabic               |
| Claude    | cream + dark navy surfaces, generous reading leading                                                                        | coral CTA, slab serif display                                          | coral is orange-adjacent; no Arabic serif of equal quality     |
| Meta      | primary filled + outlined secondary pairing, tight radii for dense data                                                     | cobalt purchase blue, 100px app pills                                  | off brand                                                      |

## Guard rules

`src/guards.ts` exports G1-G6 (raw palette, one-off sizes, hex, bare `rounded`, letter-spacing, self-styled nav items). A product runs them over its UI source in a unit test with a per-file
baseline that may only shrink; an empty baseline is the exit gate. Reference implementation: ebda-store `tests/unit/admin-design-tokens.test.ts`.
