'use strict';

const config = require('./config');
const createApp = require('./app');
const notesService = require('./services/notes.service');
const logger = require('./utils/logger');

/**
 * Process entrypoint: start the listener, seed demo data, and shut down
 * cleanly on SIGTERM/SIGINT.
 *
 * Graceful shutdown matters in this project because every deployment replaces
 * the running container: Docker sends SIGTERM and waits before SIGKILL. Closing
 * the server first lets in-flight requests (including the deployment health
 * check) finish instead of being dropped.
 */

notesService.seed();

const app = createApp();
const server = app.listen(config.port, config.host, () => {
  logger.info('server.started', {
    host: config.host,
    port: config.port,
    pid: process.pid,
    nodeVersion: process.version,
  });
});

let shuttingDown = false;

function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;

  logger.info('server.shutdown.initiated', { signal, timeoutMs: config.shutdownTimeoutMs });

  // Stop accepting new connections, then wait for in-flight requests.
  server.close((closeErr) => {
    if (closeErr) {
      logger.error('server.shutdown.failed', { error: closeErr.message });
      process.exit(1);
    }
    logger.info('server.shutdown.completed', { signal });
    process.exit(0);
  });

  // Safety net: never hang forever waiting for a stuck connection.
  const forceExit = setTimeout(() => {
    logger.error('server.shutdown.forced', { signal, timeoutMs: config.shutdownTimeoutMs });
    process.exit(1);
  }, config.shutdownTimeoutMs);
  forceExit.unref();

  // Keep-alive sockets would otherwise hold the server open.
  server.closeIdleConnections?.();
}

['SIGTERM', 'SIGINT'].forEach((signal) => {
  process.on(signal, () => shutdown(signal));
});

process.on('unhandledRejection', (reason) => {
  logger.error('process.unhandledRejection', {
    error: reason instanceof Error ? reason.message : String(reason),
  });
  shutdown('unhandledRejection');
});

process.on('uncaughtException', (err) => {
  logger.error('process.uncaughtException', { error: err.message, stack: err.stack });
  shutdown('uncaughtException');
});

module.exports = server;
