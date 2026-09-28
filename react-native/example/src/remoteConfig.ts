import { CloudflareRemoteConfig } from 'react-native-cloudflare-worker-kv';

let setup: Promise<CloudflareRemoteConfig> | undefined;

/**
 * Creates the shared instance and applies the example's settings and
 * defaults, once. Later calls return the same promise.
 */
export function setUpRemoteConfig(options: {
  endpoint: string;
  clientKey: string | undefined;
}): Promise<CloudflareRemoteConfig> {
  setup ??= (async () => {
    const remoteConfig = await CloudflareRemoteConfig.initialize({
      endpoint: options.endpoint,
      clientKey: options.clientKey,
    });
    await remoteConfig.setConfigSettings({
      fetchTimeoutMillis: 10_000,
      // Use a long interval (e.g. 1 hour) in production.
      minimumFetchIntervalMillis: 0,
    });
    await remoteConfig.setDefaults({
      welcome_message: 'Hello from defaults',
      max_items: 5,
      discount_ratio: 0,
      new_checkout_enabled: false,
    });
    return remoteConfig;
  })();
  return setup;
}
