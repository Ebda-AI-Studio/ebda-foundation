// workerd's global fetch throws "Illegal invocation" when it is called as a method of another object (`ctx.fetchImpl(url)`,
// `this.fetchImpl(url)`). Every injectable fetch default in the brain is this wrapper instead of the bare global, so storing it on
// a context or a class field is safe. Measured 2026-11-11: with the bare default every cloud watcher read failed as
// "network error" / "no response" against healthy hosts while the mocked unit tests stayed green (test/fetch-binding.test.ts).
export const boundFetch: typeof fetch = (input, init) => fetch(input, init);
