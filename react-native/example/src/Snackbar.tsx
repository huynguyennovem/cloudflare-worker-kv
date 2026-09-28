import { StyleSheet, Text, View } from 'react-native';

/** A message shown at the bottom of the screen, like a Material snackbar. */
export function Snackbar({ message, bottom }: { message: string | undefined; bottom: number }) {
  if (message === undefined) return null;
  return (
    <View
      style={[styles.snackbar, { bottom }]}
      accessibilityRole="alert"
      accessibilityLiveRegion="polite"
    >
      <Text style={styles.text}>{message}</Text>
    </View>
  );
}

/** Height of the snackbar plus its margin, used to lift the floating button. */
export const SNACKBAR_OFFSET = 64;

const styles = StyleSheet.create({
  snackbar: {
    position: 'absolute',
    left: 16,
    right: 16,
    minHeight: 48,
    justifyContent: 'center',
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 4,
    backgroundColor: '#313033',
    elevation: 6,
    shadowColor: '#000',
    shadowOpacity: 0.25,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 3 },
  },
  text: {
    color: '#F4EFF4',
    fontSize: 14,
  },
});
