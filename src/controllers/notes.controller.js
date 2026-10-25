'use strict';

const notesService = require('../services/notes.service');

/**
 * HTTP layer only: translate request -> service call -> response.
 * No business rules and no storage details live here, which keeps the
 * controllers trivially testable and the service reusable.
 */

function list(req, res) {
  const notes = notesService.listNotes();
  res.status(200).json({
    data: notes,
    meta: { count: notes.length },
  });
}

function getById(req, res) {
  const note = notesService.getNoteById(req.params.id);
  res.status(200).json({ data: note });
}

function create(req, res) {
  const note = notesService.createNote(req.body);
  res
    .status(201)
    .location(`/api/notes/${note.id}`)
    .json({ data: note });
}

function remove(req, res) {
  const note = notesService.deleteNote(req.params.id);
  res.status(200).json({ data: note, meta: { deleted: true } });
}

module.exports = { list, getById, create, remove };
