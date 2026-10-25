'use strict';

const { randomUUID } = require('node:crypto');

const logger = require('../utils/logger');

/**
 * Attaches a correlation id to every request and echoes it back in the
 * `X-Request-Id` response header so a log line can be tied to a specific call
 * (useful when debugging through Nginx and Docker).
 */
function requestContext(req, res, next) {
  const incoming = req.get('x-request-id');
  req.id = typeof incoming === 'string' && incoming.length <= 100 ? incoming : randomUUID();
  res.setHeader('X-Request-Id', req.id);
  next();
}

/**
 * Access logging without leaking secrets.
 *
 * Only the *path* is logged - never the query string, headers or body - because
 * those are the places credentials accidentally end up. Health-check noise is
 * demoted to debug level so the container log stays readable.
 */
function accessLog(req, res, next) {
  const startedAt = process.hrtime.bigint();

  res.on('finish', () => {
    const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    const isHealth = req.path === '/health';

    const meta = {
      requestId: req.id,
      method: req.method,
      path: req.path,
      status: res.statusCode,
      durationMs: Math.round(durationMs * 100) / 100,
      clientIp: req.ip,
      userAgent: req.get('user-agent'),
    };

    if (isHealth) logger.debug('request.completed', meta);
    else logger.info('request.completed', meta);
  });

  next();
}

module.exports = { requestContext, accessLog };
