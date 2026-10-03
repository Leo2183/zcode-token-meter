import { collectSnapshot, defaultDbPath } from './meter.mjs';
process.parentPort.on('message', (e) => {
  const { type, pinSid } = e.data ?? {};
  if (type !== 'collect') return;
  const snapshot = collectSnapshot(defaultDbPath(), { pinSid });
  process.parentPort.postMessage({ type: 'snapshot', pinSid: pinSid ?? null, snapshot });
});
