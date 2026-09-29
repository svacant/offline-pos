import { StatusBar } from 'expo-status-bar';
import { Tabs } from 'expo-router/js-tabs';
import { StripeTerminalProvider } from '@stripe/stripe-terminal-react-native';
import { fetchConnectionToken } from '../lib/config';
import { PosProvider } from '../pos/PosProvider';
import { colors } from '../components/theme';

export default function RootLayout() {
  return (
    <StripeTerminalProvider tokenProvider={fetchConnectionToken} logLevel="verbose">
      <PosProvider>
        <StatusBar style="light" />
        <Tabs
          screenOptions={{
            headerStyle: { backgroundColor: colors.background },
            headerTintColor: colors.text,
            tabBarStyle: { backgroundColor: colors.background, borderTopColor: colors.surface },
            tabBarActiveTintColor: colors.primary,
            tabBarInactiveTintColor: colors.textMuted,
            sceneStyle: { backgroundColor: colors.background },
          }}
        >
          <Tabs.Screen name="index" options={{ title: 'Cassa' }} />
          <Tabs.Screen name="history" options={{ title: 'Transazioni' }} />
          <Tabs.Screen name="reader" options={{ title: 'Lettore' }} />
        </Tabs>
      </PosProvider>
    </StripeTerminalProvider>
  );
}
