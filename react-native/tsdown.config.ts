import { defineConfig } from 'tsdown';

// One ESM file plus its declarations. `isolatedDeclarations` in tsconfig.json
// lets the dts step use oxc (TypeScript 7 has no classic JS API).
export default defineConfig({
  entry: 'src/index.ts',
  format: 'esm',
  platform: 'neutral',
  fixedExtension: false,
  target: 'es2020',
  dts: true,
  sourcemap: false,
  clean: true,
});
