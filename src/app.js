'use strict';

const express = require('express');
const helmet = require('helmet');

const config = require('./config');
const routes = require('./routes');
const { requestContext, accessLog } = require('./middleware/requestLogger');
const { notFoundHandler, errorHandler } = require('./middleware/errorHandler');

/**
 * Builds the Express application without starting a listener.
 * Keeping this separate from server.js is what lets Supertest exercise the
 * real middleware stack in tests without binding a TCP port.
 */
function createApp() {
  const app = express();

  app.disable('x-powered-by');
  // Behind Nginx: trust exactly one proxy hop so req.ip is the real client.
  app.set('trust proxy', config.trustProxy);

  app.use(helmet());
  app.use(express.json({ limit: '32kb' }));
  app.use(requestContext);
  app.use(accessLog);

  app.use(routes);

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}

module.exports = createApp;
