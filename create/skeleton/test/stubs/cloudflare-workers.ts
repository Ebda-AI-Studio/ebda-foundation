// Unit-test stand-in for the workerd-only `cloudflare:workers` module (the Worker itself is exercised by `wrangler deploy --dry-run` and, later, the workerd pool).
export class DurableObject {
  constructor(
    protected ctx: unknown,
    protected env: unknown,
  ) {}
}
