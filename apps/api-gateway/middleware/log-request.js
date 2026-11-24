'use strict';

const fs = require('fs');
const path = require('path');

const LOG_DIR = path.join(__dirname, '..', '..', 'logs');
const ACCESS_LOG = path.join(LOG_DIR, 'access.log');
const MAX_SIZE = 10 * 1024 * 1024; // 10 MB
const MAX_FILES = 5;

/**
 * Rotate the access log when it exceeds MAX_SIZE.
 * Keeps up to MAX_FILES rotated files.
 */
function rotateLog() {
  try {
    if (!fs.existsSync(ACCESS_LOG)) return;
    const stat = fs.statSync(ACCESS_LOG);
    if (stat.size < MAX_SIZE) return;

    // Remove oldest
    const oldest = `${ACCESS_LOG}.${MAX_FILES}`;
    if (fs.existsSync(oldest)) fs.unlinkSync(oldest);

    // Shift existing rotations
    for (let i = MAX_FILES - 1; i >= 1; i--) {
      const src = `${ACCESS_LOG}.${i}`;
      const dst = `${ACCESS_LOG}.${i + 1}`;
      if (fs.existsSync(src)) fs.renameSync(src, dst);
    }

    fs.renameSync(ACCESS_LOG, `${ACCESS_LOG}.1`);
  } catch (err) {
    // Logging failures must never crash the gateway
    console.error('[log-request] rotation error:', err.message);
  }
}

/**
 * Ensure the log directory exists.
 */
function ensureLogDir() {
  try {
    if (!fs.existsSync(LOG_DIR)) {
      fs.mkdirSync(LOG_DIR, { recursive: true });
    }
  } catch (err) {
    console.error('[log-request] cannot create log dir:', err.message);
  }
}

/**
 * Request logging middleware.
 * Logs method, path, status, response time, and timestamp as JSON to stdout.
 * Optionally appends to logs/access.log with rotation.
 */
function logRequest(req, res, next) {
  const start = process.hrtime.bigint();

  res.on('finish', () => {
    const end = process.hrtime.bigint();
    const responseTimeMs = Number(end - start) / 1_000_000;

    const entry = {
      timestamp: new Date().toISOString(),
      method: req.method,
      path: req.originalUrl || req.url,
      status: res.statusCode,
      responseTimeMs: Number(responseTimeMs.toFixed(2)),
      ip: req.ip || (req.socket && req.socket.remoteAddress) || null,
    };

    // stdout (JSON, one line per request)
    console.log(JSON.stringify(entry));

    // Optional file logging with rotation
    try {
      ensureLogDir();
      rotateLog();
      fs.appendFileSync(ACCESS_LOG, JSON.stringify(entry) + '\n', 'utf8');
    } catch (err) {
      // File logging is best-effort; stdout is the primary sink
    }
  });

  next();
}

module.exports = logRequest;
