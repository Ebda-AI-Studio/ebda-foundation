import type { Env as BrainEnv } from '../src/env';

declare global {
  namespace Cloudflare {
    interface Env extends BrainEnv {}
  }
}
export {};
