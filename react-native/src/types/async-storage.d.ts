// Type-checking stand-in for the peer dependency, which the library root never
// installs. The module is only loaded through a dynamic import() and its shape
// is checked at runtime, so `unknown` is all the sources need. Not emitted.
declare module '@react-native-async-storage/async-storage' {
  const AsyncStorage: unknown;
  export default AsyncStorage;
}
