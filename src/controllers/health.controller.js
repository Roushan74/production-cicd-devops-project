'use strict';

const config = require('../config');
const notesService = require('../services/notes.service');

/**
 * Liveness/readiness endpoint used by:
 *  - the Docker HEALTHCHECK
 *  - the deployment script (candidate verification before traffic switch)
 *  - the post-deployment smoke test from outside EC2
 */
function getHealth(req, res) {
  res.status(200).json({
    application: config.appName,
    status: 'ok',
    version: config.version,
    environment: config.env,
    uptimeSeconds: Math.round(process.uptime()),
    notesStored: notesService.countNotes(),
    timestamp: new Date().toISOString(),
  });
}

module.exports = { getHealth };
