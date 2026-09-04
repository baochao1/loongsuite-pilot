import * as path from 'node:path';
import { ClientType } from '../../types/index.js';
import type { AgentActivityEntry, JsonValue } from '../../types/index.js';
import { BaseHookInput, type HookInputOptions } from '../base/base-hook-input.js';
import { enrichCanonicalEntryWithGit } from '../../normalization/enrich-git-context.js';
import { resolveHome, directoryExists } from '../../utils/fs-utils.js';
import { buildCanonicalHookEntry } from '../base/canonical-hook-record.js';

function getPayload(record: Record<string, unknown>): Record<string, unknown> {
  if (record.data && typeof record.data === 'object' && !Array.isArray(record.data)) {
    return record.data as Record<string, unknown>;
  }
  return record;
}

function getStringValue(data: Record<string, unknown>, key: string): string | undefined {
  const val = data[key];
  return typeof val === 'string' && val.length > 0 ? val : undefined;
}

function getHookEvent(record: Record<string, unknown>, payload: Record<string, unknown>): string {
  return getStringValue(record, 'hookEvent')
    ?? getStringValue(payload, 'hook_event_name')
    ?? getStringValue(payload, 'hookEventName')
    ?? getStringValue(payload, 'hookEvent')
    ?? 'unknown';
}

function buildAttributes(
  record: Record<string, unknown>,
  payload: Record<string, unknown>,
  hookEvent: string,
): { [key: string]: JsonValue } {
  return toJsonObject({
    'codebuddy.hook_event_name': hookEvent,
    transcript_path: payload.transcript_path,
    cwd: payload.cwd,
    tool_name: payload.tool_name,
    tool_input: payload.tool_input,
    model: payload.model,
    command: payload.command,
  });
}

function toJsonObject(value: Record<string, unknown>): { [key: string]: JsonValue } {
  const out: { [key: string]: JsonValue } = {};
  for (const [key, raw] of Object.entries(value)) {
    const json = toJsonValue(raw);
    if (json !== undefined) out[key] = json;
  }
  return out;
}

function toJsonValue(value: unknown): JsonValue | undefined {
  if (value === undefined) return undefined;
  if (
    value === null ||
    typeof value === 'string' ||
    typeof value === 'number' ||
    typeof value === 'boolean'
  ) {
    return value;
  }
  if (Array.isArray(value)) {
    return value
      .map(item => toJsonValue(item))
      .filter((item): item is JsonValue => item !== undefined);
  }
  if (typeof value === 'object') return toJsonObject(value as Record<string, unknown>);
  return String(value);
}

export class CodeBuddyHookInput extends BaseHookInput {
  readonly id = 'codebuddy';
  readonly agentType = ClientType.CodeBuddyHook;

  constructor(opts?: Partial<HookInputOptions> & { stateStore: HookInputOptions['stateStore'] }) {
    super({
      stateStore: opts!.stateStore,
      logDir: opts?.logDir ?? resolveHome('~/.loongsuite-pilot/logs/codebuddy/history'),
      logPrefix: opts?.logPrefix ?? 'codebuddy',
      pollIntervalMs: opts?.pollIntervalMs ?? 30_000,
    });
  }

  static async checkAvailability(): Promise<boolean> {
    return directoryExists(resolveHome('~/.loongsuite-pilot/logs/codebuddy/history'));
  }

  static getWatchPaths(): string[] {
    return [resolveHome('~/.loongsuite-pilot/logs/codebuddy/history')];
  }

  protected async transformRecord(
    record: Record<string, unknown>,
  ): Promise<AgentActivityEntry | null> {
    const payload = getPayload(record);
    const hookEvent = getHookEvent(record, payload);
    const canonicalEntry = buildCanonicalHookEntry(
      record,
      ClientType.CodeBuddyHook,
      buildAttributes(record, payload, hookEvent),
    );
    if (!canonicalEntry) return null;

    if (hookEvent.toLowerCase() === 'stop') {
      const TOKEN_COST_KEYS = [
        'gen_ai.usage.input_tokens',
        'gen_ai.usage.output_tokens',
        'gen_ai.usage.total_tokens',
        'gen_ai.usage.input_cost',
        'gen_ai.usage.output_cost',
        'gen_ai.usage.total_cost',
      ] as const;
      for (const key of TOKEN_COST_KEYS) {
        delete (canonicalEntry as Record<string, unknown>)[key];
      }
    }

    await enrichCanonicalEntryWithGit(canonicalEntry, record, 'codebuddy');
    return canonicalEntry;
  }
}

export const ensureCodeBuddyLogDir = async (dataDir: string): Promise<void> => {
  await import('node:fs/promises').then(m =>
    m.mkdir(path.join(dataDir, 'logs', 'codebuddy', 'history'), { recursive: true }),
  );
};
