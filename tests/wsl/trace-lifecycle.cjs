// Diagnostic only: never install as a deployment extension. Does not catch errors.
const { threadId } = require('node:worker_threads');
const emit = (event, detail) => process.stderr.write(JSON.stringify({ event, pid: process.pid, threadId, detail }) + '\n');
const abort = AbortController.prototype.abort;
AbortController.prototype.abort = function (...args) {
  emit('AbortController.abort', new Error('abort requested').stack);
  return Reflect.apply(abort, this, args);
};
const exit = process.exit;
process.exit = function (...args) {
  emit('process.exit', { code: args[0], stack: new Error('exit requested').stack, sharedObjects: process.report.getReport().sharedObjects });
  return Reflect.apply(exit, this, args);
};
process.on('uncaughtExceptionMonitor', (error, origin) => emit('uncaughtExceptionMonitor', { origin, stack: error.stack }));
process.on('beforeExit', (code) => emit('beforeExit', { code, sharedObjects: process.report.getReport().sharedObjects }));
