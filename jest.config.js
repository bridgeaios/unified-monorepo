module.exports = {
  testEnvironment: 'node',
  testMatch: ['**/test/*.test.js'],
  collectCoverageFrom: ['**/*.js', '!**/node_modules/**'],
  coverageThreshold: {
    global: {
      lines: 70,
    },
  },
};
