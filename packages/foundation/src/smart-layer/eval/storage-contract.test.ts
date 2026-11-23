import { describe, expect, it } from 'vitest';
import { memoryStorage } from './memory-storage';
import { runSmartLayerStorageContract } from './storage-contract';

// The reference in-memory storage must satisfy the contract every real adapter is held to.
runSmartLayerStorageContract(() => memoryStorage(), { describe, it, expect });
