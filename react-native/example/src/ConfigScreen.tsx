import { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { isRemoteConfigError } from 'react-native-cloudflare-worker-kv';
import type { CloudflareRemoteConfig } from 'react-native-cloudflare-worker-kv';

import { setUpRemoteConfig } from './remoteConfig';
import { SNACKBAR_OFFSET, Snackbar } from './Snackbar';

export const ACCENT = '#F38020';
const SNACKBAR_MILLIS = 4_000;

/**
 * Shows the remote config values, their source and the fetch status, like
 * flutter/example/lib/main.dart.
 */
export function ConfigScreen({
  endpoint,
  clientKey,
}: {
  endpoint: string;
  clientKey: string | undefined;
}) {
  const insets = useSafeAreaInsets();
  const [remoteConfig, setRemoteConfig] = useState<CloudflareRemoteConfig>();
  const [setupError, setSetupError] = useState<string>();
  const [loading, setLoading] = useState(false);
  const [snackbar, setSnackbar] = useState<{ text: string; id: number }>();
  const mounted = useRef(true);

  const refresh = useCallback(async (rc: CloudflareRemoteConfig) => {
    setLoading(true);
    let text: string;
    try {
      const activated = await rc.fetchAndActivate();
      text = activated ? 'New config activated' : 'Config is up to date';
    } catch (e) {
      text = `Fetch failed: ${isRemoteConfigError(e) ? e.code : String(e)}`;
    }
    if (!mounted.current) return;
    setLoading(false);
    setSnackbar({ text, id: Date.now() });
  }, []);

  useEffect(() => {
    mounted.current = true;
    let cancelled = false;
    setUpRemoteConfig({ endpoint, clientKey }).then(
      (rc) => {
        if (cancelled) return;
        setRemoteConfig(rc);
        void refresh(rc);
      },
      (e: unknown) => {
        if (!cancelled) setSetupError(String(e));
      },
    );
    return () => {
      cancelled = true;
      mounted.current = false;
    };
  }, [endpoint, clientKey, refresh]);

  // Hide the snackbar after a few seconds; a new message restarts the timer.
  useEffect(() => {
    if (snackbar === undefined) return;
    const timer = setTimeout(() => setSnackbar(undefined), SNACKBAR_MILLIS);
    return () => clearTimeout(timer);
  }, [snackbar]);

  const header = (
    <View style={[styles.appBar, { paddingTop: insets.top + 12 }]}>
      <Text style={styles.appBarTitle} accessibilityRole="header">
        Cloudflare Remote Config
      </Text>
    </View>
  );

  if (remoteConfig === undefined) {
    return (
      <View style={styles.screen}>
        {header}
        <View style={styles.centered}>
          {setupError === undefined ? (
            <ActivityIndicator color={ACCENT} />
          ) : (
            <Text selectable style={styles.error}>
              {setupError}
            </Text>
          )}
        </View>
      </View>
    );
  }

  const values = Object.entries(remoteConfig.getAll()).sort(([a], [b]) =>
    a < b ? -1 : a > b ? 1 : 0,
  );
  const checkoutEnabled = remoteConfig.getBoolean('new_checkout_enabled');
  const discount = (remoteConfig.getNumber('discount_ratio') * 100).toFixed(0);
  const lastFetch =
    remoteConfig.fetchTimeMillis === -1
      ? 'never'
      : new Date(remoteConfig.fetchTimeMillis).toLocaleString();
  const fabBottom = insets.bottom + 16 + (snackbar === undefined ? 0 : SNACKBAR_OFFSET);

  return (
    <View style={styles.screen}>
      {header}
      <ScrollView
        contentContainerStyle={[styles.content, { paddingBottom: insets.bottom + 96 }]}
      >
        <Text style={styles.headline}>{remoteConfig.getString('welcome_message')}</Text>
        <Text style={styles.body}>
          Max items: {remoteConfig.getNumber('max_items')} · Discount: {discount}%
        </Text>
        <View style={[styles.chip, checkoutEnabled && styles.chipEnabled]}>
          <Text style={styles.chipIcon}>{checkoutEnabled ? '✓' : '✕'}</Text>
          <Text style={styles.chipLabel}>
            New checkout {checkoutEnabled ? 'enabled' : 'disabled'}
          </Text>
        </View>

        <View style={styles.divider} />
        <Text style={styles.body}>Status: {remoteConfig.lastFetchStatus}</Text>
        <Text style={styles.body}>Last fetch: {lastFetch}</Text>
        <Text style={styles.body} selectable>
          Endpoint: {endpoint}
        </Text>
        <View style={styles.divider} />

        {values.map(([key, value]) => (
          <View key={key} style={styles.row}>
            <View style={styles.rowText}>
              <Text style={styles.rowTitle}>{key}</Text>
              <Text style={styles.rowSubtitle} selectable>
                {value.asString()}
              </Text>
            </View>
            <Text style={styles.rowTrailing}>{value.getSource()}</Text>
          </View>
        ))}
      </ScrollView>

      <Pressable
        onPress={() => void refresh(remoteConfig)}
        disabled={loading}
        accessibilityRole="button"
        accessibilityState={{ disabled: loading, busy: loading }}
        style={({ pressed }) => [
          styles.fab,
          { bottom: fabBottom },
          pressed && styles.fabPressed,
          loading && styles.fabDisabled,
        ]}
      >
        {loading ? (
          <ActivityIndicator size="small" color="#FFFFFF" style={styles.fabIcon} />
        ) : (
          <Text style={[styles.fabIcon, styles.fabIconText]}>↻</Text>
        )}
        <Text style={styles.fabLabel}>Fetch & activate</Text>
      </Pressable>

      <Snackbar message={snackbar?.text} bottom={insets.bottom + 16} />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: '#FFFBFF',
  },
  appBar: {
    paddingHorizontal: 16,
    paddingBottom: 12,
    backgroundColor: '#FFF3EA',
    borderBottomWidth: 3,
    borderBottomColor: ACCENT,
  },
  appBarTitle: {
    fontSize: 22,
    color: '#201A17',
  },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  error: {
    color: '#BA1A1A',
    textAlign: 'center',
  },
  content: {
    padding: 16,
  },
  headline: {
    fontSize: 24,
    color: '#201A17',
  },
  body: {
    marginTop: 8,
    fontSize: 14,
    color: '#201A17',
  },
  chip: {
    marginTop: 8,
    alignSelf: 'flex-start',
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#85736B',
  },
  chipEnabled: {
    backgroundColor: '#FFDBCB',
    borderColor: ACCENT,
  },
  chipIcon: {
    marginRight: 8,
    fontSize: 14,
    color: '#201A17',
  },
  chipLabel: {
    fontSize: 14,
    color: '#201A17',
  },
  divider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: '#D8C2B8',
    marginVertical: 16,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 6,
  },
  rowText: {
    flex: 1,
    paddingRight: 12,
  },
  rowTitle: {
    fontSize: 14,
    color: '#201A17',
  },
  rowSubtitle: {
    fontSize: 13,
    color: '#53433D',
  },
  rowTrailing: {
    fontSize: 12,
    color: '#53433D',
  },
  fab: {
    position: 'absolute',
    right: 16,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 20,
    height: 56,
    borderRadius: 16,
    backgroundColor: ACCENT,
    elevation: 6,
    shadowColor: '#000',
    shadowOpacity: 0.25,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 3 },
  },
  fabPressed: {
    opacity: 0.85,
  },
  fabDisabled: {
    opacity: 0.7,
  },
  fabIcon: {
    marginRight: 12,
    width: 18,
  },
  fabIconText: {
    color: '#FFFFFF',
    fontSize: 18,
    textAlign: 'center',
  },
  fabLabel: {
    color: '#FFFFFF',
    fontSize: 14,
    fontWeight: '600',
  },
});
