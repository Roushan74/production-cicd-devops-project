'use strict';

/**
 * Jest configuration.
 *
 * Coverage is collected from application source only. `src/server.js` is
 * excluded because it is pure process bootstrap (signal handlers + listen) that
 * is verified by the Docker/deployment health checks instead of unit tests.
 */
module.exports = {
  testEnvironment: 'node',
  testMatch: ['**/tests/**/*.test.js'],
  collectCoverageFrom: ['src/**/*.js', '!src/server.js'],
  coverageDirectory: 'coverage',
  coverageReporters: ['text', 'lcov', 'json-summary', 'cobertura'],
  coveragePathIgnorePatterns: ['/node_modules/', '/tests/'],
  coverageThreshold: {
    global: {
      statements: 80,
      branches: 75,
      functions: 80,
      lines: 80,
    },
  },
  clearMocks: true,
  restoreMocks: true,
  verbose: true,
};
