'use strict';

const AppError = require('../utils/AppError');

const TITLE_MAX = 120;
const CONTENT_MAX = 5000;

/**
 * Validates the POST /api/notes body.
 *
 * Returns a 400 with a `details` array listing every problem at once (rather
 * than failing on the first field) so API consumers can fix everything in a
 * single round-trip. Unknown fields are rejected to keep the contract explicit.
 */
function validateCreateNote(req, res, next) {
  const errors = [];
  const body = req.body;

  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return next(
      AppError.badRequest('INVALID_BODY', 'Request body must be a JSON object', [
        { field: 'body', message: 'expected a JSON object' },
      ]),
    );
  }

  const allowed = new Set(['title', 'content']);
  for (const key of Object.keys(body)) {
    if (!allowed.has(key)) {
      errors.push({ field: key, message: 'unknown field' });
    }
  }

  if (typeof body.title !== 'string' || body.title.trim().length === 0) {
    errors.push({ field: 'title', message: 'title is required and must be a non-empty string' });
  } else if (body.title.trim().length > TITLE_MAX) {
    errors.push({ field: 'title', message: `title must be at most ${TITLE_MAX} characters` });
  }

  if (typeof body.content !== 'string' || body.content.trim().length === 0) {
    errors.push({ field: 'content', message: 'content is required and must be a non-empty string' });
  } else if (body.content.trim().length > CONTENT_MAX) {
    errors.push({ field: 'content', message: `content must be at most ${CONTENT_MAX} characters` });
  }

  if (errors.length > 0) {
    return next(AppError.badRequest('VALIDATION_ERROR', 'Request validation failed', errors));
  }

  // Normalise before handing off to the service (trim once, in one place).
  req.body = { title: body.title.trim(), content: body.content.trim() };
  return next();
}

module.exports = { validateCreateNote, TITLE_MAX, CONTENT_MAX };
