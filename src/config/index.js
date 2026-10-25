'use strict';

const pkg = require('../../package.json');

/**
 * Centralised, validated runtime configuration.
 *
 * Every value can be overridden through environment variables so that the same
 * image can run locally, in CI and on EC2 without code changes. Nothing secret
 * is read here - this service only needs non-sensitive settings.
 */

function readInt(name, fallback, { min, max }) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isInteger(parsed) || parsed < min || parsed > max) {
    throw new Error(
      `Invalid configuration: ${name}="${raw}" must be an integer between ${min} and ${max}`,
    );
  }
  return parsed;
}

const config = {
  appName: process.env.APP_NAME || 'notes-api',
  // The version is baked into the image at build time (see Dockerfile) so that
  // /health can prove which artefact is actually running.
  version: process.env.APP_VERSION || pkg.version,
  env: process.env.NODE_ENV || 'development',
  host: process.env.HOST || '0.0.0.0',
  port: readInt('PORT', 3000, { min: 1, max: 65535 }),
  logLevel: (process.env.LOG_LEVEL || 'info').toLowerCase(),
  // How long in-flight requests get to finish during a graceful shutdown.
  shutdownTimeoutMs: readInt('SHUTDOWN_TIMEOUT_MS', 10000, { min: 0, max: 120000 }),
  // 1 = trust the first proxy hop (Nginx). Keeps client IPs meaningful in logs
  // without blindly trusting arbitrary X-Forwarded-For values.
  trustProxy: readInt('TRUST_PROXY', 1, { min: 0, max: 10 }),
  // In-memory store limit - guards against unbounded memory growth.
  maxNotes: readInt('MAX_NOTES', 1000, { min: 1, max: 100000 }),
};

config.isProduction = config.env === 'production';
config.isTest = config.env === 'test';

module.exports = config;
