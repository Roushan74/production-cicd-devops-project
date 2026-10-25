'use strict';

/**
 * Configuration is validated at start-up so a typo (PORT=abc) fails fast at
 * boot instead of producing a mysterious runtime error later. These tests load
 * the module in isolation with different environment variables.
 */

const CONFIG_PATH = require.resolve('../src/config');

const MANAGED_KEYS = [
  'NODE_ENV',
  'PORT',
  'HOST',
  'APP_NAME',
  'APP_VERSION',
  'LOG_LEVEL',
  'SHUTDOWN_TIMEOUT_MS',
  'TRUST_PROXY',
  'MAX_NOTES',
];

function loadConfig(overrides = {}) {
  const snapshot = {};
  for (const key of MANAGED_KEYS) snapshot[key] = process.env[key];

  for (const key of MANAGED_KEYS) delete process.env[key];
  Object.assign(process.env, overrides);

  let loaded;
  jest.isolateModules(() => {
    loaded = require(CONFIG_PATH);
  });

  for (const key of MANAGED_KEYS) {
    if (snapshot[key] === undefined) delete process.env[key];
    else process.env[key] = snapshot[key];
  }

  return loaded;
}

describe('config', () => {
  it('falls back to safe defaults', () => {
    const config = loadConfig();

    expect(config.port).toBe(3000);
    expect(config.host).toBe('0.0.0.0');
    expect(config.trustProxy).toBe(1);
    expect(config.maxNotes).toBe(1000);
    expect(config.shutdownTimeoutMs).toBe(10000);
    expect(config.logLevel).toBe('info');
    expect(config.version).toMatch(/^\d+\.\d+\.\d+/);
  });

  it('reads overrides from the environment and lowercases LOG_LEVEL', () => {
    const config = loadConfig({ PORT: '8080', LOG_LEVEL: 'DEBUG', APP_NAME: 'custom-api' });

    expect(config.port).toBe(8080);
    expect(config.logLevel).toBe('debug');
    expect(config.appName).toBe('custom-api');
  });

  it('rejects a non-numeric PORT at start-up', () => {
    expect(() => loadConfig({ PORT: 'not-a-port' })).toThrow(/Invalid configuration: PORT/);
  });

  it('rejects an out-of-range PORT', () => {
    expect(() => loadConfig({ PORT: '70000' })).toThrow(/between 1 and 65535/);
  });

  it('flags production mode', () => {
    const config = loadConfig({ NODE_ENV: 'production' });

    expect(config.isProduction).toBe(true);
    expect(config.isTest).toBe(false);
  });
});
