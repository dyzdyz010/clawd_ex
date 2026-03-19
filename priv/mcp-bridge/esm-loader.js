/**
 * Custom ESM loader that resolves extensionless imports to .js files.
 * Needed for TypeScript-compiled OpenClaw plugins.
 */
import { existsSync } from 'fs';

export async function resolve(specifier, context, nextResolve) {
  // Only handle relative imports without extensions
  if (specifier.startsWith('.') && !specifier.match(/\.\w+$/)) {
    // Try adding .js
    try {
      return await nextResolve(specifier + '.js', context);
    } catch {
      // Try as directory with index.js
      try {
        return await nextResolve(specifier + '/index.js', context);
      } catch {
        // Fall through to default
      }
    }
  }
  return nextResolve(specifier, context);
}
