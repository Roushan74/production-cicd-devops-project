'use strict';

const request = require('supertest');

const createApp = require('../src/app');
const notesService = require('../src/services/notes.service');

const VALID_ID = '3f1b2c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d';

describe('Notes API', () => {
  let app;

  beforeEach(() => {
    notesService.resetStore();
    app = createApp();
  });

  afterAll(() => {
    notesService.resetStore();
  });

  describe('GET /api/notes', () => {
    it('returns an empty collection when no notes exist', async () => {
      const res = await request(app).get('/api/notes');

      expect(res.status).toBe(200);
      expect(res.body).toEqual({ data: [], meta: { count: 0 } });
    });

    it('returns all created notes', async () => {
      await request(app).post('/api/notes').send({ title: 'First', content: 'One' });
      await request(app).post('/api/notes').send({ title: 'Second', content: 'Two' });

      const res = await request(app).get('/api/notes');

      expect(res.status).toBe(200);
      expect(res.body.meta.count).toBe(2);
      expect(res.body.data).toHaveLength(2);
      expect(res.body.data.map((n) => n.title)).toEqual(['First', 'Second']);
      expect(res.body.data[0]).toMatchObject({
        id: expect.any(String),
        title: 'First',
        content: 'One',
        createdAt: expect.any(String),
        updatedAt: expect.any(String),
      });
    });
  });

  describe('POST /api/notes', () => {
    it('creates a note and returns 201 with a Location header', async () => {
      const res = await request(app)
        .post('/api/notes')
        .send({ title: '  Deploy checklist  ', content: '  Run smoke tests  ' });

      expect(res.status).toBe(201);
      expect(res.headers.location).toBe(`/api/notes/${res.body.data.id}`);
      expect(res.body.data.title).toBe('Deploy checklist');
      expect(res.body.data.content).toBe('Run smoke tests');
      expect(res.body.data.id).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
      );
    });

    it('rejects a missing title with 400', async () => {
      const res = await request(app).post('/api/notes').send({ content: 'body only' });

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_ERROR');
      expect(res.body.error.details).toEqual(
        expect.arrayContaining([expect.objectContaining({ field: 'title' })]),
      );
    });

    it('rejects a missing content with 400', async () => {
      const res = await request(app).post('/api/notes').send({ title: 'only title' });

      expect(res.status).toBe(400);
      expect(res.body.error.details).toEqual(
        expect.arrayContaining([expect.objectContaining({ field: 'content' })]),
      );
    });

    it('rejects an empty body with 400', async () => {
      const res = await request(app).post('/api/notes').send({});

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_ERROR');
      expect(res.body.error.details).toHaveLength(2);
    });

    it('rejects whitespace-only values with 400', async () => {
      const res = await request(app).post('/api/notes').send({ title: '   ', content: '   ' });

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_ERROR');
    });

    it('rejects non-string types with 400', async () => {
      const res = await request(app).post('/api/notes').send({ title: 42, content: ['x'] });

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_ERROR');
    });

    it('rejects an over-long title with 400', async () => {
      const res = await request(app)
        .post('/api/notes')
        .send({ title: 'a'.repeat(121), content: 'ok' });

      expect(res.status).toBe(400);
      expect(res.body.error.details).toEqual(
        expect.arrayContaining([expect.objectContaining({ field: 'title' })]),
      );
    });

    it('rejects unknown fields with 400', async () => {
      const res = await request(app)
        .post('/api/notes')
        .send({ title: 'x', content: 'y', isAdmin: true });

      expect(res.status).toBe(400);
      expect(res.body.error.details).toEqual(
        expect.arrayContaining([expect.objectContaining({ field: 'isAdmin' })]),
      );
    });

    it('rejects malformed JSON with 400', async () => {
      const res = await request(app)
        .post('/api/notes')
        .set('Content-Type', 'application/json')
        .send('{"title": "broken",');

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('INVALID_JSON');
    });
  });

  describe('GET /api/notes/:id', () => {
    it('returns a single note', async () => {
      const created = await request(app)
        .post('/api/notes')
        .send({ title: 'Read me', content: 'Details' });

      const res = await request(app).get(`/api/notes/${created.body.data.id}`);

      expect(res.status).toBe(200);
      expect(res.body.data).toEqual(created.body.data);
    });

    it('returns 404 for a well-formed but unknown id', async () => {
      const res = await request(app).get(`/api/notes/${VALID_ID}`);

      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('NOTE_NOT_FOUND');
      expect(res.body.error.requestId).toEqual(expect.any(String));
    });

    it('returns 400 for a malformed id', async () => {
      const res = await request(app).get('/api/notes/not-a-uuid');

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('INVALID_NOTE_ID');
    });
  });

  describe('DELETE /api/notes/:id', () => {
    it('deletes an existing note and it disappears from the collection', async () => {
      const created = await request(app)
        .post('/api/notes')
        .send({ title: 'Temporary', content: 'Remove me' });
      const id = created.body.data.id;

      const del = await request(app).delete(`/api/notes/${id}`);
      expect(del.status).toBe(200);
      expect(del.body.meta.deleted).toBe(true);
      expect(del.body.data.id).toBe(id);

      const after = await request(app).get(`/api/notes/${id}`);
      expect(after.status).toBe(404);

      const list = await request(app).get('/api/notes');
      expect(list.body.meta.count).toBe(0);
    });

    it('returns 404 when deleting an unknown note', async () => {
      const res = await request(app).delete(`/api/notes/${VALID_ID}`);

      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('NOTE_NOT_FOUND');
    });

    it('returns 400 when deleting with a malformed id', async () => {
      const res = await request(app).delete('/api/notes/123');

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('INVALID_NOTE_ID');
    });
  });

  describe('unknown routes', () => {
    it('returns a structured 404', async () => {
      const res = await request(app).get('/api/does-not-exist');

      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('ROUTE_NOT_FOUND');
      expect(res.body.error.requestId).toEqual(expect.any(String));
    });
  });
});
