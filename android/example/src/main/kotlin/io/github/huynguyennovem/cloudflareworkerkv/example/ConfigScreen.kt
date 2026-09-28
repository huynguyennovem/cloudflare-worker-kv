package io.github.huynguyennovem.cloudflareworkerkv.example

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import io.github.huynguyennovem.cloudflareworkerkv.CloudflareRemoteConfig
import io.github.huynguyennovem.cloudflareworkerkv.RemoteConfigException
import io.github.huynguyennovem.cloudflareworkerkv.RemoteConfigValue
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.launch

/** Cloudflare orange. */
private val Accent = Color(0xFFF38020)

@Composable
fun ExampleTheme(content: @Composable () -> Unit) {
    val colorScheme = if (isSystemInDarkTheme()) {
        darkColorScheme(primary = Accent, onPrimary = Color.Black, secondaryContainer = Color(0xFF5A2D00))
    } else {
        lightColorScheme(primary = Accent, onPrimary = Color.White, secondaryContainer = Color(0xFFFFDCC4))
    }
    MaterialTheme(colorScheme = colorScheme, content = content)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConfigScreen(remoteConfig: CloudflareRemoteConfig, endpoint: String) {
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    var loading by remember { mutableStateOf(false) }
    // The getters are not observable: bump this after a fetch to recompose.
    var revision by remember { mutableIntStateOf(0) }
    var initialFetchDone by rememberSaveable { mutableStateOf(false) }

    fun refresh() {
        if (loading) return
        loading = true
        scope.launch {
            val message = try {
                if (remoteConfig.fetchAndActivate()) "New config activated" else "Config is up to date"
            } catch (e: RemoteConfigException) {
                "Fetch failed: ${e.code.value}"
            }
            loading = false
            revision++
            snackbarHostState.currentSnackbarData?.dismiss()
            snackbarHostState.showSnackbar(message)
        }
    }

    LaunchedEffect(Unit) {
        if (!initialFetchDone) {
            initialFetchDone = true
            refresh()
        }
    }

    val ui = remember(revision) { ConfigUi.from(remoteConfig) }

    Scaffold(
        topBar = { TopAppBar(title = { Text("Cloudflare Remote Config") }) },
        snackbarHost = { SnackbarHost(snackbarHostState) },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = ::refresh,
                icon = {
                    if (loading) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Filled.Refresh, contentDescription = null)
                    }
                },
                text = { Text("Fetch & activate") },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 96.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item { Text(ui.welcome, style = MaterialTheme.typography.headlineSmall) }
            item { Text("Max items: ${ui.maxItems} · Discount: ${ui.discountPercent}%") }
            item {
                AssistChip(
                    onClick = {},
                    label = { Text("New checkout ${if (ui.checkoutEnabled) "enabled" else "disabled"}") },
                    leadingIcon = {
                        Icon(
                            if (ui.checkoutEnabled) Icons.Filled.CheckCircle else Icons.Filled.Close,
                            contentDescription = null,
                        )
                    },
                )
            }
            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            item {
                Column {
                    Text("Status: ${ui.status}")
                    Text("Last fetch: ${ui.lastFetch}")
                    Text("Endpoint: $endpoint")
                }
            }
            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            items(ui.values, key = { it.first }) { (key, value) ->
                ListItem(
                    headlineContent = { Text(key) },
                    supportingContent = { Text(value.asString()) },
                    trailingContent = { Text(value.source.name.lowercase(Locale.ROOT)) },
                )
            }
        }
    }
}

/** What the screen shows, read once per fetch. */
private class ConfigUi(
    val welcome: String,
    val maxItems: Long,
    val discountPercent: String,
    val checkoutEnabled: Boolean,
    val status: String,
    val lastFetch: String,
    val values: List<Pair<String, RemoteConfigValue>>,
) {
    companion object {
        fun from(remoteConfig: CloudflareRemoteConfig): ConfigUi {
            val info = remoteConfig.info
            return ConfigUi(
                welcome = remoteConfig.getString("welcome_message"),
                maxItems = remoteConfig.getLong("max_items"),
                discountPercent = String.format(Locale.ROOT, "%.0f", remoteConfig.getDouble("discount_ratio") * 100),
                checkoutEnabled = remoteConfig.getBoolean("new_checkout_enabled"),
                status = info.lastFetchStatus.name.lowercase(Locale.ROOT),
                lastFetch = if (info.fetchTimeMillis < 0) {
                    "never"
                } else {
                    DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.MEDIUM).format(Date(info.fetchTimeMillis))
                },
                values = remoteConfig.getAll().entries.sortedBy { it.key }.map { it.key to it.value },
            )
        }
    }
}
