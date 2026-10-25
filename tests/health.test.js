'use strict';

const request = require('supertest');

const createApp = require('../src/app');

describe('GET /health', () => {
  let app;

  beforeEach(() => {
    app = createApp();
  });

  it('returns 200 with application, status and version', async () => {
    const res = await request(app).get('/health');

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/application\/json/);
    expect(res.body).toMatchObject({
      application: expect.any(String),
      status: 'ok',
      version: expect.any(String),
    });
    expect(res.body.application.length).toBeGreaterThan(0);
    expect(res.body.version).toMatch(/^\d+\.\d+\.\d+/);
    expect(res.body.uptimeSeconds).toEqual(expect.any(Number));
    expect(Date.parse(res.body.timestamp)).not.toBeNaN();
  });

  it('sets security headers via helmet', async () => {
    const res = await request(app).get('/health');

    expect(res.headers['x-content-type-options']).toBe('nosniff');
    expect(res.headers['x-powered-by']).toBeUndefined();
    expect(res.headers['x-request-id']).toEqual(expect.any(String));
  });

  it('echoes an inbound correlation id', async () => {
    const res = await request(app).get('/health').set('X-Request-Id', 'test-correlation-id');

    expect(res.headers['x-request-id']).toBe('test-correlation-id');
  });
});
