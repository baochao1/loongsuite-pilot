#!/usr/bin/env node
// Copyright 2026 Alibaba Group Holding Limited
// SPDX-License-Identifier: Apache-2.0
//
// CodeBuddy hook event writer (fail-open collection only).
//
// Reads the JSON payload CodeBuddy pipes via stdin, converts it into the
// canonical AgentActivityEntry JSONL shape consumed by CodeBuddyHookInput
// (src/inputs/codebuddy-hook/codebuddy-hook-input.ts), and appends one line
// per event to <dataDir>/logs/codebuddy/history/codebuddy-<date>.jsonl.
//
// The hook is a wakeup hint only. Any failure must be invisible to CodeBuddy,
// so the script always terminates by printing "{}".

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { decodePayload } from './shared/decode-payload.mjs';

// CodeBuddy hook event -> canonical AgentEventName
const EVENT_NAMES = new Map([
  ['session-start', 'other'],
  ['user-prompt-submit', 'llm.request'],
  ['pre-tool-use', 'tool.call'],
  ['post-tool-use', 'tool.result'],
  ['stop', 'other'],
]);

function readStdin() {
  // 去 UTF-8 BOM + 中文 Windows 上修复 Cursor/Qoder 的 UTF-8->GBK 双重编码。
  return decodePayload(fs.readFileSync(0));
}

function stringField(value) {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function toNano(date) {
  const ms = date.getTime();
  return String(ms * 1_000_000);
}

try {
  const payload = JSON.parse(readStdin() || '{}');
  const sessionId = stringField(payload.session_id);
  if (!sessionId) throw new Error('missing CodeBuddy session identity');

  const hookEvent = stringField(payload.hook_event_name)
    ?? EVENT_NAMES.get(process.argv[2])
    ?? process.argv[2]
    ?? 'unknown';
  const eventName = EVENT_NAMES.get(hookEvent) ?? 'other';

  const now = new Date();
  const installedDataDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const dataDir = process.env.LOONGSUITE_PILOT_DATA_DIR ?? installedDataDir;

  const record = {
    'event.id': crypto.randomUUID(),
    'event.name': eventName,
    'gen_ai.agent.type': 'codebuddy',
    'time_unix_nano': toNano(now),
    'observed_time_unix_nano': toNano(now),
    'user.id': stringField(payload.user_id) ?? 'codebuddy-user',
    'session.id': sessionId,
    'gen_ai.request.model': stringField(payload.model) ?? 'unknown',
    'gen_ai.response.model': stringField(payload.model) ?? 'unknown',
    'agent.codebuddy.hook_event_name': hookEvent,
    'agent.codebuddy.transcript_path': stringField(payload.transcript_path) ?? '',
    'agent.codebuddy.cwd': stringField(payload.cwd) ?? '',
    'agent.codebuddy.tool_name': stringField(payload.tool_name) ?? '',
    'agent.codebuddy.tool_call_id': stringField(payload.call_id) ?? stringField(payload.tool_use_id) ?? '',
    'agent.codebuddy.permission_mode': stringField(payload.permission_mode) ?? '',
  };

  const dir = path.join(dataDir, 'logs', 'codebuddy', 'history');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = path.join(dir, `codebuddy-${now.toISOString().slice(0, 10)}.jsonl`);

  try {
    fs.appendFileSync(file, JSON.stringify(record) + '\n', { encoding: 'utf8', mode: 0o600, flag: 'a' });
  } catch (error) {
    throw error;
  }
} catch {
  // Hook is a wakeup hint only. Any failure must be invisible to CodeBuddy.
}

process.stdout.write('{}\n');
