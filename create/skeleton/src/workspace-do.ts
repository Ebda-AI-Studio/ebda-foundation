import { DurableObject } from 'cloudflare:workers';

/** One Durable Object per workspace (SQLite-backed). Tenant data is reachable only through `env.WORKSPACE_DO.get(idFromName(workspaceId))`. */
export class WorkspaceDO extends DurableObject {
  async ping(): Promise<string> {
    return 'ok';
  }
}
