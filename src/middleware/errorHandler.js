'use strict';

const logger = require('../utils/logger');

/** Terminal 404 for any unmatched route. */
function notFoundHandler(req, res, next) {
  res.status(404).json({
    error: {
      code: 'ROUTE_NOT_FOUND',
      message: `Cannot ${req.method} ${req.path}`,
      requestId: req.id,
    },
  });
  next?.();
}

/**
 * Single place where every error becomes an HTTP response.
 *
 * - AppError (expected/operational) -> its own status, code and details.
 * - Everything else -> 500 with a generic message; the stack stays in the logs.
 * - Express body-parser errors (malformed JSON, oversized payload) are mapped
 *   to 400/413 instead of leaking a 500.
 */
// eslint-disable-next-line no-unused-vars -- Express identifies error handlers by arity (4 args)
function errorHandler(err, req, res, next) {
  let statusCode = 500;
  let code = 'INTERNAL_ERROR';
  let message = 'An unexpected error occurred';
  let details;

  if (err instanceof SyntaxError && err.status === 400 && 'body' in err) {
    statusCode = 400;
    code = 'INVALID_JSON';
    message = 'Request body is not valid JSON';
  } else if (err.type === 'entity.too.large') {
    statusCode = 413;
    code = 'PAYLOAD_TOO_LARGE';
    message = 'Request body is too large';
  } else if (err.isOperational) {
    statusCode = err.statusCode;
    code = err.code;
    message = err.message;
    details = err.details;
  }

  const logMeta = {
    requestId: req.id,
    method: req.method,
    path: req.path,
    status: statusCode,
    code,
  };

  if (statusCode >= 500) {
    logger.error('request.failed', { ...logMeta, error: err.message, stack: err.stack });
  } else {
    logger.warn('request.rejected', { ...logMeta, error: err.message });
  }

  // The response deliberately carries no stack trace and no error internals:
  // stack frames and driver messages routinely contain connection strings,
  // file paths and other infrastructure detail. The full stack is in the log
  // line above, correlated by requestId.
  const body = {
    error: {
      code,
      message,
      ...(details ? { details } : {}),
      requestId: req.id,
    },
  };

  res.status(statusCode).json(body);
}

module.exports = { notFoundHandler, errorHandler };
