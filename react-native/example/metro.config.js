// Consumes the library straight from the parent folder, the way an app would
// consume the published package: through ../package.json "exports", which
// points at ../dist. Run `npm run build` (or `npm run dev`) in ../ first.
// See https://docs.expo.dev/guides/monorepos/
const path = require('node:path');
const { getDefaultConfig } = require('expo/metro-config');

const projectRoot = __dirname;
const libraryRoot = path.resolve(projectRoot, '..');

const config = getDefaultConfig(projectRoot);

// Watch the library so that a rebuilt dist/ is picked up.
config.watchFolders = [libraryRoot];

// `react-native-cloudflare-worker-kv` resolves to the library folder.
config.resolver.extraNodeModules = {
  'react-native-cloudflare-worker-kv': libraryRoot,
};

// Every other module, including the library's own import of AsyncStorage,
// resolves from the example's node_modules only...
config.resolver.nodeModulesPaths = [path.join(projectRoot, 'node_modules')];

// ...and the library's node_modules (its dev tools) are never read, so there
// is exactly one copy of each package in the bundle.
const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');
config.resolver.blockList = [
  ...[].concat(config.resolver.blockList ?? []),
  new RegExp(`^${escapeRegExp(path.join(libraryRoot, 'node_modules'))}[\\\\/].*$`),
];

module.exports = config;
