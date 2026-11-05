// Types for the brain (TypeScript) importing the provider selection. Shapes match os/cloud/brain/src/hands.ts.
export interface ProviderLike {
  readonly name: string;
  readonly pullOnly?: boolean;
  start(batch: { runId: string; kind: 'urgent' | 'nightly'; perJobCapMin: number }): Promise<{ runId: string; provider: string; externalId?: string; startedAt: number }>;
}
export declare const PROVIDER_NAMES: string[];
export declare function selectProvider(name: string, env?: Record<string, unknown>): { provider: ProviderLike | null; reason: string };
