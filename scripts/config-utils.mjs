// Shared read-only JSONC parser; ignores comments and trailing commas outside strings.
export function parseJsonc(text) {
  text = text.replace(/^\uFEFF/, '');
  let out = '';
  let inString = false;
  let escaped = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i], n = text[i + 1];
    if (inString) {
      out += c;
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') inString = false;
    } else if (c === '"') { inString = true; out += c; }
    else if (c === '/' && n === '/') { while (i < text.length && text[i] !== '\n') i++; out += '\n'; }
    else if (c === '/' && n === '*') {
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++;
      i++;
    } else out += c;
  }
  // A second lexical pass avoids touching commas inside string values.
  let clean = '';
  inString = false; escaped = false;
  for (let i = 0; i < out.length; i++) {
    const c = out[i];
    if (!inString && c === ',' && /^\s*[}\]]/.test(out.slice(i + 1))) continue;
    clean += c;
    if (inString) {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') inString = false;
    } else if (c === '"') inString = true;
  }
  return JSON.parse(clean);
}

// Credential values may be references or unresolved template slots, never literal keys.
export function assertCredentialReferences(value) {
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    if (/apikey$/i.test(key)) {
      const reference = typeof child === 'string' && (
        /^!\S[\s\S]*$/.test(child) ||
        /^\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})$/.test(child) ||
        /^\{\{[A-Z0-9_]+\}\}$/.test(child)
      );
      if (!reference) throw new Error('credential field ' + key + ' requires !command or $ENV_VAR reference (value withheld)');
    }
    assertCredentialReferences(child);
  }
}

// Major-version changes to Pi or MC need explicit compatibility review.
export function versionStatus(actual, expected, majorCritical = false) {
  if (actual === expected) return 'PASS';
  if (majorCritical && /^\d+\./.test(actual) && /^\d+\./.test(expected) && actual.split('.')[0] !== expected.split('.')[0]) return 'FAIL';
  return 'WARN';
}
