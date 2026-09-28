import { StatusBar } from 'expo-status-bar';
import { StyleSheet, Text, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { ConfigScreen } from './src/ConfigScreen';

// Set these in .env.local (see .env.example) or in the environment of
// `npx expo start`. Expo inlines EXPO_PUBLIC_* variables at build time, which
// only works with static `process.env.NAME` access.
const endpoint = process.env.EXPO_PUBLIC_CF_CONFIG_ENDPOINT ?? '';
const clientKey = process.env.EXPO_PUBLIC_CF_CLIENT_KEY || undefined;

export default function App() {
  if (endpoint === '') return <MissingEndpointScreen />;
  return (
    <SafeAreaProvider>
      <ConfigScreen endpoint={endpoint} clientKey={clientKey} />
      <StatusBar style="dark" />
    </SafeAreaProvider>
  );
}

function MissingEndpointScreen() {
  return (
    <View style={styles.missing}>
      <Text selectable style={styles.missingText}>
        {'Run the example with your Worker URL:\n\n' +
          'EXPO_PUBLIC_CF_CONFIG_ENDPOINT=https://<worker>.<subdomain>.workers.dev npx expo start\n\n' +
          'or put it in .env.local (see .env.example).'}
      </Text>
      <StatusBar style="dark" />
    </View>
  );
}

const styles = StyleSheet.create({
  missing: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
    backgroundColor: '#FFFBFF',
  },
  missingText: {
    textAlign: 'center',
    fontSize: 14,
    color: '#201A17',
  },
});
