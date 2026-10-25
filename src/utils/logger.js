'use strict';

const config = require('../config');

/**
 * Minimal structured (JSON) logger.
 *
 * - One line per event so it is easy to ship to CloudWatch / Loki later.
 * - Keys that commonly hold credentials are redacted defensively. The
 *   application never logs request bodies or headers, but this is a second
 *   line of defence so a future log statement cannot leak a secret.
 */

const LEVELS = { error: 0, warn: 1, info: 2, debug: 3 };
const SENSITIVE_KEY = /pass(word|wd)?|secret|token|api[-_]?key|authorization|cookie|credential/i;

function redact(value, depth = 0) {
  if (depth > 4 || value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map((item) => redact(item, depth + 1));

  const output = {};
  for (const [key, val] of Object.entries(value)) {
    output[key] = SENSITIVE_KEY.test(key) ? '[REDACTED]' : redact(val, depth + 1);
  }
  return output;
}

function write(level, message, meta) {
  const threshold = LEVELS[config.logLevel] ?? LEVELS.info;
  if (LEVELS[level] > threshold) return;

  const entry = {
    timestamp: new Date().toISOString(),
    level,
    message,
    service: config.appName,
    version: config.version,
    env: config.env,
    ...(meta ? redact(meta) : {}),
  };

  const line = `${JSON.stringify(entry)}\n`;
  if (level === 'error') process.stderr.write(line);
  else process.stdout.write(line);
}

module.exports = {
  error: (message, meta) => write('error', message, meta),
  warn: (message, meta) => write('warn', message, meta),
  info: (message, meta) => write('info', message, meta),
  debug: (message, meta) => write('debug', message, meta),
};
