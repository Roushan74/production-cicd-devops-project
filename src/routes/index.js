'use strict';

const express = require('express');

const notesController = require('../controllers/notes.controller');
const healthController = require('../controllers/health.controller');
const { validateCreateNote } = require('../middleware/validateNote');

const router = express.Router();

router.get('/health', healthController.getHealth);

router
  .route('/api/notes')
  .get(notesController.list)
  .post(validateCreateNote, notesController.create);

router
  .route('/api/notes/:id')
  .get(notesController.getById)
  .delete(notesController.remove);

module.exports = router;
