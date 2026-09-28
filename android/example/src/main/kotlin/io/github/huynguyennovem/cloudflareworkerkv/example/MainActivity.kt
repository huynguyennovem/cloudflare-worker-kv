package io.github.huynguyennovem.cloudflareworkerkv.example

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import io.github.huynguyennovem.cloudflareworkerkv.CloudflareRemoteConfig
import kotlinx.coroutines.Deferred

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val remoteConfig = (application as ExampleApplication).remoteConfig
        setContent {
            ExampleTheme {
                if (remoteConfig == null) {
                    MessageScreen(
                        "Build the example with your Worker URL:\n\n" +
                            "./gradlew :example:installDebug " +
                            "-PCF_CONFIG_ENDPOINT=https://<worker>.<subdomain>.workers.dev",
                    )
                } else {
                    Loaded(remoteConfig)
                }
            }
        }
    }
}

private sealed interface LoadState {
    data object Loading : LoadState

    class Ready(val remoteConfig: CloudflareRemoteConfig) : LoadState

    class Failed(val message: String) : LoadState
}

@Composable
private fun Loaded(remoteConfig: Deferred<CloudflareRemoteConfig>) {
    val state by produceState<LoadState>(LoadState.Loading, remoteConfig) {
        value = try {
            LoadState.Ready(remoteConfig.await())
        } catch (e: IllegalArgumentException) {
            LoadState.Failed("Invalid CF_CONFIG_ENDPOINT: ${e.message}")
        }
    }
    when (val current = state) {
        LoadState.Loading -> Surface(Modifier.fillMaxSize()) {
            Box(contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        }
        is LoadState.Ready -> ConfigScreen(current.remoteConfig, endpoint = BuildConfig.CF_CONFIG_ENDPOINT)
        is LoadState.Failed -> MessageScreen(current.message)
    }
}

@Composable
private fun MessageScreen(message: String) {
    Surface(Modifier.fillMaxSize()) {
        Box(Modifier.padding(24.dp), contentAlignment = Alignment.Center) {
            SelectionContainer {
                Text(message, textAlign = TextAlign.Center)
            }
        }
    }
}
