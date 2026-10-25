'use strict';

const { randomUUID } = require('node:crypto');

const config = require('../config');
const AppError = require('../utils/AppError');

/**
 * In-memory notes repository.
 *
 * IMPORTANT LIMITATION: data lives in a process-local Map. Notes are lost when
 * the container restarts, and they are NOT shared between replicas. This is a
 * deliberate trade-off: the point of this project is the delivery pipeline, and
 * adding a managed database would add cost and operational surface without
 * demonstrating anything new about CI/CD.
 *
 * The interface (list/get/create/remove) is intentionally the same shape a
 * database-backed repository would expose, so swapping in Postgres later means
 * replacing this file only.
 */

const notes = new Map();
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Seed a couple of notes so the API is demonstrable straight after boot. */
function seed() {
  const samples = [
    {
      title: 'Welcome to the Notes API',
      content:
        'This note is seeded at start-up so the deployed service has data to show immediately.',
    },
    {
      title: 'In-memory storage',
      content: 'Notes are held in a process-local Map and reset whenever the container restarts.',
    },
  ];

  for (const sample of samples) {
    createNote(sample);
  }
}

function isUuid(id) {
  return typeof id === 'string' && UUID_PATTERN.test(id);
}

function assertValidId(id) {
  if (!isUuid(id)) {
    throw AppError.badRequest('INVALID_NOTE_ID', 'Note id must be a valid UUID v4 string', [
      { field: 'id', message: 'invalid UUID format' },
    ]);
  }
}

function clone(note) {
  return { ...note };
}

function listNotes() {
  return [...notes.values()].sort((a, b) => a.createdAt.localeCompare(b.createdAt)).map(clone);
}

function getNoteById(id) {
  assertValidId(id);
  const note = notes.get(id);
  if (!note) {
    throw AppError.notFound('NOTE_NOT_FOUND', `Note with id "${id}" was not found`);
  }
  return clone(note);
}

function createNote({ title, content }) {
  if (notes.size >= config.maxNotes) {
    throw AppError.conflict('NOTE_LIMIT_REACHED', 'Maximum number of notes reached for this instance');
  }

  const now = new Date().toISOString();
  const note = {
    id: randomUUID(),
    title: title.trim(),
    content: content.trim(),
    createdAt: now,
    updatedAt: now,
  };

  notes.set(note.id, note);
  return clone(note);
}

function deleteNote(id) {
  assertValidId(id);
  const note = notes.get(id);
  if (!note) {
    throw AppError.notFound('NOTE_NOT_FOUND', `Note with id "${id}" was not found`);
  }

  notes.delete(id);
  return clone(note);
}

function countNotes() {
  return notes.size;
}

/** Test helper - not exposed over HTTP. */
function resetStore() {
  notes.clear();
}

module.exports = {
  seed,
  resetStore,
  listNotes,
  getNoteById,
  createNote,
  deleteNote,
  countNotes,
  isUuid,
};
