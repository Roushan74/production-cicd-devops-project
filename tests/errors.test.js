'use strict';

const request = require('supertest');

const createApp = require('../src/app');
const notesService = require('../src/services/notes.service');
const logger = require('../src/utils/logger');

describe('Error handling and resilience', () => {
  let app;

  beforeEach(() => {
    notesService.resetStore();
    app = createApp();
  });

  it('returns 413 when the JSON body exceeds the 32kb limit', async () => {
    const res = await request(app)
      .post('/api/notes')
      .send({ title: 'big', content: 'x'.repeat(40000) });

    expect(res.status).toBe(413);
    expect(res.body.error.code).toBe('PAYLOAD_TOO_LARGE');
  });

  it('returns a generic 500 without leaking internals for unexpected errors', async () => {
    const spy = jest.spyOn(logger, 'error').mockImplementation(() => {});
    // Force an unexpected (non-operational) failure inside the service layer.
    jest.spyOn(notesService, 'listNotes').mockImplementation(() => {
      throw new Error('database exploded: connection string postgres://user:pass@host');
    });

    const res = await request(app).get('/api/notes');

    expect(res.status).toBe(500);
    expect(res.body.error.code).toBe('INTERNAL_ERROR');
    expect(res.body.error.message).toBe('An unexpected error occurred');
    expect(JSON.stringify(res.body)).not.toMatch(/postgres:\/\//);
    expect(spy).toHaveBeenCalled();
  });

  it('does not log request bodies or headers', async () => {
    const infoSpy = jest.spyOn(logger, 'info').mockImplementation(() => {});

    await request(app)
      .post('/api/notes')
      .set('Authorization', 'Bearer super-secret-token')
      .send({ title: 'Secret-ish', content: 'do-not-log-this-content' });

    // Access logging happens on response finish; give the event loop a tick.
    await new Promise((resolve) => setImmediate(resolve));

    const logged = JSON.stringify(infoSpy.mock.calls);
    expect(logged).not.toMatch(/super-secret-token/);
    expect(logged).not.toMatch(/do-not-log-this-content/);
    expect(logged).not.toMatch(/Bearer/);
  });

  it('rejects a body that is a JSON array', async () => {
    const res = await request(app).post('/api/notes').send([{ title: 'a', content: 'b' }]);

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('INVALID_BODY');
  });
});

describe('notes.service', () => {
  beforeEach(() => {
    notesService.resetStore();
  });

  it('seeds demo notes and counts them', () => {
    notesService.seed();
    expect(notesService.countNotes()).toBeGreaterThan(0);
  });

  it('returns defensive copies so callers cannot mutate the store', () => {
    const created = notesService.createNote({ title: 'immutable', content: 'safe' });
    created.title = 'tampered';

    expect(notesService.getNoteById(created.id).title).toBe('immutable');
  });

  it('validates uuid format', () => {
    expect(notesService.isUuid('3f1b2c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d')).toBe(true);
    expect(notesService.isUuid('nope')).toBe(false);
    expect(notesService.isUuid(undefined)).toBe(false);
  });
});
