// Read-only native runtime probe shared by deployment checks and doctor (via a child process).
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

export function checkOnnx({ agentDir, platform = process.platform, existsSync = fs.existsSync, requireFactory = createRequire, env = process.env }) {
  let packageMissing = false;
  try {
    const require = requireFactory(path.join(agentDir, 'npm/node_modules/@cortexkit/pi-magic-context/package.json'));
    try { require.resolve('onnxruntime-node'); }
    catch (error) { packageMissing = error.code === 'MODULE_NOT_FOUND'; throw error; }
    const versions = require('onnxruntime-node').env.versions;
    return { ok: true, versions, detail: JSON.stringify(versions) };
  } catch (error) {
    let detail = error.message;
    if (platform === 'win32') {
      const system32 = path.win32.join(env.SystemRoot || env.WINDIR || 'C:\\Windows', 'System32');
      const missing = ['vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll'].filter((name) => !existsSync(path.win32.join(system32, name)));
      if (missing.length) detail += '\nMissing VC++ runtime in System32: ' + missing.join(', ') + '. Install Microsoft Visual C++ 2015-2022 x64 Redistributable: https://aka.ms/vs/17/release/vc_redist.x64.exe (administrator; /install /quiet /norestart), then run node scripts/deploy-check.mjs onnx again.';
      else detail += '\nVC++ runtime files exist in System32; inspect the original native binding error and its other DLL dependencies.';
    } else if (platform === 'linux' && packageMissing) {
      detail += '\nonnxruntime-node is missing. On Linux x64 its default CUDA provider download can fail on HTTP 302 and npm can discard this optional dependency. For CPU use, reinstall in <agent-dir>/npm: ONNXRUNTIME_NODE_INSTALL=skip npm install --include=optional. Then run node scripts/deploy-check.mjs onnx again. GPU setup is untested.';
    }
    return { ok: false, detail };
  }
}
