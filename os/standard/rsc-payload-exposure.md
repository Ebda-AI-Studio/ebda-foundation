# rsc-payload-exposure — the UI is the window, the payload is the wall behind it

tags: [BOTH]
sources: reel lens pack `audit/lenses/reel-lenses-2026-09.md` L16 (Matt Murphy, `#aidirectedengineering`, reel `DdZDAYDkr3A`, watched 2026-09-19); applied to `mypovonai-learn` the same day (pass, with evidence)

A server component queries the database and hands the row to the components that render it.
The page displays a name, an email and a photo. The payload carries all twenty columns —
including the password hash, the internal role flag and the billing token — because React
serialises **every prop that crosses into a client component** into the RSC wire format, and
the browser parses that format to build the page.

Nothing renders them. That is the point: the attacker does not read the page, they read the
network tab. And the payload is structured, not HTML, so extraction is a parse rather than a
scrape: a list of twenty rows is twenty full records, once per visitor.

**The rule:** *a query that feeds a rendered component selects the fields that component
renders, and every server→client boundary passes a projection rather than a row.*

**Tradeoff:** an explicit `select` and a small DTO per boundary, against a class of leak that
no test fails, no log records, and no reviewer sees — because the code renders exactly what it
is supposed to render.

## 1. The failure mode

Three things have to be true at once, and an AI-written component routinely makes all three:

1. The query returns the whole row, because `findUnique({ where: { id } })` is the shortest
   thing to write and the type that comes back is the one the ORM already generated.
2. The row is passed as a single prop — `user={user}` — because threading six named props is
   more work than threading one object.
3. Some descendant of that component is a client component, so the prop serialises.

The third is the one that is invisible while reading the file. A prop handed from a server
component to another **server** component never reaches the browser as data; the same prop
handed to a client component does, in full, whether or not it is read. The boundary decides,
not the query — which is why "we only display three fields" is not a defence, and why this is
not the same concern as `scaling`'s explicit-`select` criterion (that one is about index use
and row size, and it passes happily while shipping a password hash to the browser).

It survives review because the rendered output is correct. It survives testing because
assertions are written against what the DOM shows. It is visible only in a place nobody looks
during development: the RSC payload in the network tab.

## 2. What to check

| # | Check | Why | Effort |
| --- | --- | --- | --- |
| 1 | Enumerate the client components (`"use client"`), then every server page that renders one | The serialising boundary is the client component; everything else is text | Low |
| 2 | For each such render, follow every prop back to its query | The finding is a prop whose value came out of the ORM/DB unprojected | Medium |
| 3 | Props that are whole objects (`user={user}`, `{...row}`, `data={record}`) | A spread or an object prop is how twenty fields travel where three were wanted | Low |
| 4 | Parent components that receive a row and pass it down | One over-broad prop at the top serialises once and exposes every child | Medium |
| 5 | Sensitive columns by name in the schema (hash, token, secret, role, internal flags) cross-referenced against the types that reach a boundary | Names the actual harm rather than the shape | Low |
| 6 | A test or build check that fails when a named sensitive field appears in the payload | Without it the fix holds only until the next prop is added | Medium |

## 3. What good looks like

The query names what the component renders, and the boundary carries a projection:

    const user = await db.user.findUnique({
      where: { id },
      select: { id: true, name: true, email: true, avatarUrl: true },
    });

    <ProfileCard name={user.name} email={user.email} avatarUrl={user.avatarUrl} />

…rather than `<ProfileCard user={user} />`. Where a shape is reused, the DTO is built once,
server-side, and is the only type that crosses the boundary — so adding a column to the table
cannot widen the payload by default.

Prove it the way `mutation-proof` requires: add a sensitive field to the projection, watch the
named test go red, and restore the file byte-identical.

## 4. Where it is graded

Any framework that serialises server-rendered props to the client: React Server Components
(Next.js App Router), and the same shape in Remix/TanStack loaders, Nuxt's `payload`, and
SvelteKit's `load` return — all of which ship their return value to the browser. Not
applicable to a pure client-fetch architecture, where the API response is the boundary and
`auth`/`security` already grade it.
