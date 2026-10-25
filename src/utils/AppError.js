'use strict';

/**
 * Operational error carrying an HTTP status and a stable machine-readable code.
 * Anything that is *not* an AppError is treated as an unexpected fault by the
 * central error handler: it is logged with a stack trace and returned as a
 * generic 500 so internal details never leak to clients.
 */
class AppError extends Error {
  constructor(statusCode, code, message, details) {
    super(message);
    this.name = 'AppError';
    this.statusCode = statusCode;
    this.code = code;
    this.details = details;
    this.isOperational = true;
    Error.captureStackTrace(this, this.constructor);
  }

  static badRequest(code, message, details) {
    return new AppError(400, code, message, details);
  }

  static notFound(code, message) {
    return new AppError(404, code, message);
  }

  static conflict(code, message) {
    return new AppError(409, code, message);
  }

  static payloadTooLarge(code, message) {
    return new AppError(413, code, message);
  }
}

module.exports = AppError;
